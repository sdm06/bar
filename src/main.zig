//! bar - a status bar for the River Wayland compositor.
//!
//! Everything is comptime: `config.zig` is the only file meant to be edited,
//! and the font is baked in from a BDF file at build time. There is no runtime
//! config parsing and no dependency beyond libwayland.
//!
//! Structure, top to bottom:
//!   1. c bindings            5. river status
//!   2. font access           6. canvas
//!   3. protocol constants    7. modules
//!   4. state                 8. event loop and main

const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("config.zig");
const font_data = @import("font");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/wait.h");
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("river-status-unstable-v1-client-protocol.h");
});

// ===========================================================================
// 1. c bindings
// ===========================================================================

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bar: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// ===========================================================================
// 2. Font access
// ===========================================================================
//
// The generated table stores one u32 per cell row, bit `p` meaning "column p
// is lit". Glyphs are already positioned inside the cell and already scaled,
// so drawing is a shift and a run of set bits.

/// A compiled BDF face.
///
/// The bitmap arrives as a generated module, so one type covers every face the
/// bar draws with. The tag face is not a second, larger font: it is these same
/// digits, so there is one height to lay out and one table to compile.
fn Font(comptime data: type) type {
    return struct {
        pub const width: u16 = data.width;
        pub const height: u16 = data.height;
        pub const first: u21 = data.first;
        pub const last: u21 = data.last;

        /// Horizontal room one codepoint takes, `font_spacing` included.
        pub fn advance(cp: u21) u32 {
            if (cp < first or cp > last) return width;
            const w: i32 = @intCast(data.advances[cp - first]);
            return @intCast(@max(w + cfg.font_spacing, 0));
        }

        /// Cell-relative row mask, already shifted to start at column 0.
        pub fn row(cp: u21, y: u16) u32 {
            if (y >= height or cp < first or cp > last) return 0;
            return data.bitmap[@as(usize, cp - first) * height + y];
        }
    };
}

/// The one face the whole bar draws with. Tags are not a second, larger font:
/// they are the same digits, so there is a single height to lay out and a
/// single table to compile.
const font = Font(font_data);

/// Set from the SIGUSR1 handler when something outside the bar changed state we
/// poll for -- in practice the volume keys, which run `wpctl` behind the
/// compositor's back. Without this the bar would not notice until its next
/// poll, which reads as a lag on every keypress.
var refresh_now: bool = false;

/// Async-signal-safe: it only sets a flag, and the event loop does the work.
fn onRefresh(_: c_int) callconv(.c) void {
    refresh_now = true;
}

fn installRefreshSignal() void {
    _ = c.signal(c.SIGUSR1, @ptrCast(&onRefresh));
}

/// Height of the bar: tall enough for whichever of the two fonts needs the
/// most room, plus the vertical padding either side.
fn barHeight() u32 {
    const tallest = font.height;
    return tallest + 2 * cfg.padding_v;
}

/// Top row of the tall tag cell: `padding_v` down from the top, which clears it
/// because `barHeight` already accounts for the scaled tag face.
const tag_top: u32 = cfg.padding_v;

/// Row inside the bar that the top of a text cell is drawn at. The font table
/// already places the font's own ascent inside the cell, so the
/// cell itself starts at `cfg.text_top`; adding the ascent here as well would
/// push every glyph clean off the bottom of the bar.
const text_top: u32 = cfg.text_top orelse cfg.padding_v;

// ===========================================================================
// 3. Protocol constants
// ===========================================================================
//
// Layer and anchor live in config.zig, which reads them straight out of the
// generated header so the protocol spells them. Only what main needs on its
// own is mirrored here.

const KEYBOARD_NONE = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;

// ===========================================================================
// 4. State
// ===========================================================================

/// Total modules across both groups. The first `cfg.modules.len` are the
/// left-aligned group, the rest the right-aligned one.
const n_modules = cfg.modules.len + cfg.right_modules.len;

const n_buffers = 2;
const max_outputs = 8;

/// One output's tags, as river reports them. The river listeners are
/// registered with `*Output` as their data, so each event is O(1).
const Output = struct {
    bar: ?*Bar = null,
    name: u32 = 0,
    proxy: ?*c.struct_wl_output = null,
    status: ?*c.struct_zriver_output_status_v1 = null,
    focused: u32 = 0,
    view: u32 = 0,
    urgent: u32 = 0,
    scale: u32 = 1,
};

/// A wl_buffer plus its mapping. Two of these share one shm pool.
const Buffer = struct {
    wl_buffer: ?*c.struct_wl_buffer = null,
    /// Offset into the pool's mapping.
    offset: usize = 0,
    busy: bool = false,
    released: bool = true,
};

/// One memfd, one shm pool, one mapping, `n_buffers` wl_buffers carved out of
/// it. Sharing the pool halves the syscalls and keeps both buffers inside a
/// single page-aligned mapping.
const Pool = struct {
    fd: c_int = -1,
    shm_pool: ?*c.struct_wl_shm_pool = null,
    data: []align(std.heap.page_size_min) u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    stride: usize = 0,
    size: usize = 0,
    buffers: [n_buffers]Buffer = [_]Buffer{.{}} ** n_buffers,
    valid: bool = false,

    fn px(self: *const Pool, index: usize) []u32 {
        const start = self.buffers[index].offset;
        // mmap is page aligned and every offset is a whole number of pixels,
        // so the rows behind a wl_buffer stay naturally aligned.
        const bytes: []align(@alignOf(u32)) u8 = @alignCast(self.data[start..][0 .. self.stride * self.height]);
        return std.mem.bytesAsSlice(u32, bytes);
    }

    fn free(self: *Pool, shm: ?*c.struct_wl_shm) void {
        if (!self.valid) return;
        for (&self.buffers) |*buf| {
            if (buf.wl_buffer) |wb| c.wl_buffer_destroy(wb);
            buf.* = .{};
        }
        if (self.shm_pool) |p| c.wl_shm_pool_destroy(p);
        if (self.data.len > 0) std.posix.munmap(self.data);
        if (self.fd >= 0) _ = c.close(self.fd);
        _ = shm;
        self.* = .{};
    }
};

const Bar = struct {
    display: ?*c.struct_wl_display = null,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    status_manager: ?*c.struct_zriver_status_manager_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    seat_status: ?*c.struct_zriver_seat_status_v1 = null,

    surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,

    outputs: [max_outputs]Output = [_]Output{.{}} ** max_outputs,
    output_len: usize = 0,

    /// The pool being drawn into. Older pools move to `retired` and stay there
    /// until the compositor has released every buffer in them, which is what
    /// stops a resize from pulling shm out from under a scanout.
    active: Pool = .{},
    retired: [max_retired]Pool = [_]Pool{.{}} ** max_retired,
    retired_len: usize = 0,

    /// Buffer size the current surface geometry needs. Kept apart from the
    /// live pool so a resize that cannot retire the old pool yet is simply
    /// retried on the next wake instead of losing the frame.
    want_w: u32 = 0,
    want_h: u32 = 0,

    /// Output size in surface (unscaled) coordinates.
    width: u32 = 0,
    height: u32 = 0,
    /// Integer scale from wl_output, clamped by config.
    scale: u32 = 1,
    configured: bool = false,
    running: bool = true,

    /// Set when anything on screen changed. Cleared only after a frame is
    /// actually presented, so a skipped frame is retried.
    dirty: bool = true,

    /// `dump_frame` only writes on the first presented frame.
    dumped: bool = false,

    stdin_fd: c_int = 0,
    stdin_open: bool = true,

    /// Monotonic milliseconds, for module deadlines.
    now_ms: u64 = 0,
    /// Wall clock second of the last frame, so the clock module can tell when
    /// the second rolled over.
    last_sec: i64 = -1,

    /// Left-aligned group first, then the right-aligned group. `present` splits the
/// array back apart at `cfg.modules.len`.
modules: [n_modules]Module = undefined,
    /// Title of the focused view, shared with the title module.
    focused_title: [cfg.title.max_chars * 2]u8 = undefined,
    focused_title_len: usize = 0,
    /// Layout name of the focused output.
    layout_name: [32]u8 = undefined,
    layout_name_len: usize = 0,
    layout_dirty: bool = false,
};

// ===========================================================================
// 6. Canvas
// ===========================================================================
//
// Bounds are clipped once per primitive instead of once per pixel, and glyph
// rows are shifted and walked with @ctz.

/// Width a string needs, without drawing it.
fn textWidth(s: []const u8) u32 {
    var w: u32 = 0;
    for (s) |ch| w += font.advance(ch);
    return w;
}

const Canvas = struct {
    px: []u32,
    w: u32,
    h: u32,

    fn init(buf: *const Pool, index: usize) Canvas {
        return .{ .px = buf.px(index), .w = buf.width, .h = buf.height };
    }

    fn clear(self: *Canvas, color: u32) void {
        @memset(self.px, color);
    }

    fn rect(self: *Canvas, x0: u32, y0: u32, w: u32, h: u32, color: u32) void {
        const x1 = @min(x0 +| w, self.w);
        const y1 = @min(y0 +| h, self.h);
        if (x0 >= x1 or y0 >= y1) return;
        for (0..y1 - y0) |dy| {
            const dst = self.px[@as(usize, y0 + dy) * self.w + x0 ..][0..x1 - x0];
            @memset(dst, color);
        }
    }

    fn text(self: *Canvas, x0: u32, y0: u32, s: []const u8, color: u32) u32 {
        var x = x0;
        for (s) |ch| {
            if (x >= self.w) break;
            Canvas.glyph(font, self, x, y0, ch, color);
            x += font.advance(ch);
        }
        return x - x0;
    }

    /// One glyph. `x0` may be anywhere on screen. The row mask is already
    /// cell-relative and the row slice already starts at `x0`, so the mask is
    /// used as-is and only clipped against the right edge.
    fn glyph(comptime F: type, self: *Canvas, x0: u32, y0: u32, ch: u8, color: u32) void {
        if (x0 >= self.w) return;
        // Columns still inside the buffer. A cell is at most 32 columns wide,
        // so a wider remainder needs no clipping at all.
        const right = self.w - x0;
        const keep: u32 = if (right >= 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(right)) - 1;

        var y: u16 = 0;
        while (y < F.height) : (y += 1) {
            const dy = y0 + y;
            if (dy >= self.h) break;
            var bits = F.row(ch, y) & keep;
            if (bits == 0) continue;

            const row = self.px[@as(usize, dy) * self.w + x0 ..];
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                row[bit] = color;
            }
        }
    }
};

// ===========================================================================
// 5. river status
// ===========================================================================

const output_status_listener = c.zriver_output_status_v1_listener{
    .focused_tags = onFocusedTags,
    .view_tags = onViewTags,
    .urgent_tags = onUrgentTags,
    .layout_name = onLayoutName,
    .layout_name_clear = onLayoutNameClear,
};

fn onFocusedTags(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    out.focused = tags;
    if (out.bar) |bar| bar.dirty = true;
}

fn onViewTags(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, tags: ?*const c.wl_array) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    const arr = tags orelse return;
    const n = @min(arr.size / @sizeOf(u32), 32);
    var mask: u32 = 0;
    if (n > 0) {
        const p: [*]align(4) const u32 = @ptrCast(@alignCast(arr.data));
        for (p[0..n]) |v| mask |= v;
    }
    out.view = mask;
    if (out.bar) |bar| bar.dirty = true;
}

fn onUrgentTags(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    out.urgent = tags;
    if (out.bar) |bar| bar.dirty = true;
}

fn onLayoutName(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, name: [*c]const u8) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    const bar = out.bar orelse return;
    const src = std.mem.span(name);
    const n = @min(src.len, bar.layout_name.len);
    @memcpy(bar.layout_name[0..n], src[0..n]);
    bar.layout_name_len = n;
    bar.dirty = true;
}

fn onLayoutNameClear(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    const bar = out.bar orelse return;
    bar.layout_name_len = 0;
    bar.dirty = true;
}

const seat_status_listener = c.zriver_seat_status_v1_listener{
    .focused_output = onFocusedOutput,
    .unfocused_output = onUnfocusedOutput,
    .focused_view = onFocusedView,
    .mode = onSeatMode,
};

fn onFocusedOutput(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, _: ?*c.struct_wl_output) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    // The layout name belongs to whichever output was focused; drop the old.
    bar.layout_name_len = 0;
    bar.dirty = true;
}

fn onUnfocusedOutput(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, _: ?*c.struct_wl_output) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    bar.dirty = true;
}

fn onFocusedView(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, title: [*c]const u8) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    const src = std.mem.span(title);
    const n = @min(src.len, bar.focused_title.len);
    @memcpy(bar.focused_title[0..n], src[0..n]);
    bar.focused_title_len = n;
    bar.dirty = true;
}

fn onSeatMode(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, name: [*c]const u8) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    _ = name;
    bar.dirty = true;
}

// ===========================================================================
// Registry
// ===========================================================================

const registry_listener = c.wl_registry_listener{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1") and version >= 1) {
        bar.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_compositor") and version >= 1) {
        // v4 for wl_surface_damage_buffer, which v4 wl_output scale needs.
        const v: u32 = @min(version, 4);
        bar.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, v));
    } else if (std.mem.eql(u8, iface, "wl_shm") and version >= 1) {
        bar.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "zriver_status_manager_v1") and version >= 1) {
        // Bind at the highest version river offers: v4 adds the layout name.
        const v: u32 = @min(version, 4);
        bar.status_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zriver_status_manager_v1_interface, v));
    } else if (std.mem.eql(u8, iface, "wl_seat") and version >= 1) {
        bar.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_output") and version >= 1) {
        if (bar.output_len < max_outputs) {
            var it: usize = 0;
            while (it < bar.output_len) : (it += 1) {
                if (bar.outputs[it].name == name) return;
            }
            const out = &bar.outputs[bar.output_len];
            out.* = .{ .name = name };
            out.scale = 1;
            out.proxy = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 2));
            _ = c.wl_output_add_listener(out.proxy, &output_listener, @ptrCast(out));
            bar.outputs[bar.output_len] = out.*;
            bar.output_len += 1;
            bar.dirty = true;
        }
    }
}

/// Unplugged outputs used to leak their wl_output and status objects and leave
/// stale tags on screen. Both the proxy and the per-output status go away.
const output_listener = c.wl_output_listener{
    .geometry = onOutputGeometry,
    .mode = onOutputMode,
    .done = onOutputDone,
    .scale = onOutputScale,
};

fn onOutputGeometry(_: ?*anyopaque, _: ?*c.struct_wl_output, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: [*c]const u8, _: [*c]const u8, _: c_int) callconv(.c) void {}

fn onOutputMode(_: ?*anyopaque, _: ?*c.struct_wl_output, _: u32, _: c_int, _: c_int, _: c_int) callconv(.c) void {}

fn onOutputDone(_: ?*anyopaque, _: ?*c.struct_wl_output) callconv(.c) void {}

/// wl_output sends its scale as a negative fixed point: -12000 means 1.2.
/// The bar draws one surface for every output, so it renders at the largest
/// scale any of them asks for.
fn onOutputScale(data: ?*anyopaque, _: ?*c.struct_wl_output, factor: c_int) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data orelse return));
    if (factor <= 0) return;
    out.scale = @intCast(@min(@divTrunc(factor, 12000), cfg.color.max_output_scale));
    if (out.bar) |bar| rescale(bar);
}

/// Recompute the bar scale from the outputs and reallocate if it moved.
fn rescale(self: *Bar) void {
    var want: u32 = 1;
    for (self.outputs[0..self.output_len]) |out| want = @max(want, out.scale);
    want = @max(1, @min(want, cfg.color.max_output_scale));
    if (want == self.scale) return;

    self.scale = want;
    _ = c.wl_surface_set_buffer_scale(self.surface, @intCast(want));
    self.want_w = self.width * want;
    self.want_h = self.height * want;
    self.dirty = true;
}

fn onGlobalRemove(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    var i: usize = 0;
    while (i < bar.output_len) : (i += 1) {
        if (bar.outputs[i].name != name) continue;

        if (bar.outputs[i].status) |st| c.zriver_output_status_v1_destroy(st);
        if (bar.outputs[i].proxy) |p| c.wl_output_destroy(p);

        // Shift the tail down so the slice stays dense.
        var j = i + 1;
        while (j < bar.output_len) : (j += 1) bar.outputs[j - 1] = bar.outputs[j];
        bar.output_len -= 1;
        bar.outputs[bar.output_len] = .{};
        bar.dirty = true;
        return;
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Copy a fixed size C char array into a zig buffer, stopping at the NUL.
/// Returns `out` truncated to whatever was copied, never a null term view.
fn copyC(src: []const u8, out: []u8) []const u8 {
    const n = @min(std.mem.indexOfScalar(u8, src, 0) orelse src.len, out.len);
    @memcpy(out[0..n], src[0..n]);
    return out[0..n];
}

/// Wall clock seconds, so the clock module notices a second rollover.
fn wallSec() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @intCast(ts.tv_sec);
}

/// Monotonic milliseconds, the base for every module deadline.
fn monoMs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.tv_nsec, 1_000_000)));
}

// ===========================================================================
// 7. Modules
// ===========================================================================
//
// Every module is a variant of `Module`. To add one: write the struct, add it
// to the union and to `init`, and name it in `cfg.modules` or
// `cfg.right_modules`. Nothing else in
// the bar changes.
//
// Most modules are text-only, so they all share `TextBuf` plus `Render`.
// A module refreshes on a timer and sets its buffer; if the bytes come out
// the same as last time, `changed` stays false and the bar never repaints.

/// A fixed-capacity string that only reports itself dirty when it really
/// changed. Nothing here allocates: capacity is a comptime parameter.
fn TextBuf(comptime cap: usize) type {
    return struct {
        const Self = @This();

        data: [cap]u8 = undefined,
        len: usize = 0,
        changed: bool = false,
        color: u32 = cfg.color.foreground,

        fn set(self: *Self, bytes: []const u8) void {
            const n = @min(bytes.len, cap);
            if (n == self.len and std.mem.eql(u8, self.data[0..n], bytes[0..n])) return;
            @memcpy(self.data[0..n], bytes[0..n]);
            self.len = n;
            self.changed = true;
        }

        fn setColor(self: *Self, color: u32) void {
            if (color == self.color) return;
            self.color = color;
            self.changed = true;
        }

        fn clear(self: *Self) void {
            if (self.len == 0) return;
            self.len = 0;
            self.changed = true;
        }

        fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }

        /// Report whether anything changed since the last call, then clear the
        /// flag. `changed` is a latch, so it has to be consumed: leaving it
        /// set would make every module claim to be dirty on every event loop
        /// pass and repaint the bar forever.
        fn take(self: *Self) bool {
            const was = self.changed;
            self.changed = false;
            return was;
        }
    };
}

/// Drawing for a text-only module, embedded by value so the union's draw
/// switch stays one line per module.
const Render = struct {
    fn width(text: anytype) u32 {
        return textWidth(text.slice());
    }
    fn draw(text: anytype, cv: *Canvas, x: u32) u32 {
        const slice = text.slice();
        if (slice.len == 0) return 0;
        return cv.text(x, text_top, slice, text.color);
    }
};

/// Read a whole small file. Returns null when it cannot be read.
fn slurp(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf.ptr + total, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return null;
    return buf[0..total];
}

/// Format a path into a NUL-terminated buffer for libc.
fn pathBuf(buf: []u8, comptime fmt: []const u8, args: anytype) ?[*:0]const u8 {
    const s = std.fmt.bufPrintZ(buf, fmt, args) catch return null;
    return s.ptr;
}

/// First entry of `dir` whose name starts with `prefix`, else the first entry
/// at all when the prefix is empty. Used to find a battery or a backlight.
fn firstEntry(dir: [*:0]const u8, prefix: []const u8, out: []u8) ?[]const u8 {
    const d = c.opendir(dir) orelse return null;
    defer _ = c.closedir(d);
    const empty = prefix.len == 0;
    while (true) {
        const ent = c.readdir(d) orelse return null;
        const dirent = &ent[0];
        var name_buf: [256]u8 = undefined;
        const name = copyC(&dirent.d_name, &name_buf);
        if (eq(name, ".") or eq(name, "..")) continue;
        if (!empty and !std.mem.startsWith(u8, name, prefix)) continue;
        const n = @min(name.len, out.len);
        @memcpy(out[0..n], name[0..n]);
        return out[0..n];
    }
}

// --- tags ------------------------------------------------------------------

/// The one module that draws instead of blitting text: a digit per tag on a
/// block, inverted when focused, red when urgent, dim when empty.
const Tags = struct {
    /// Last drawn masks, so a repaint only happens when they actually move.
    seen: [max_outputs]Masks = [_]Masks{.{}} ** max_outputs,
    primed: bool = false,

    const Masks = struct { focused: u32 = 0, view: u32 = 0, urgent: u32 = 0 };

    fn update(self: *Tags, bar: *Bar) bool {
        var changed = !self.primed;
        for (bar.outputs[0..bar.output_len], 0..) |out, i| {
            const s = self.seen[i];
            if (s.focused != out.focused or s.view != out.view or s.urgent != out.urgent) changed = true;
            self.seen[i] = .{ .focused = out.focused, .view = out.view, .urgent = out.urgent };
        }
        // A removed output leaves stale entries; they are harmless because
        // drawing only looks at the live ones.
        self.primed = true;
        return changed;
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(_: *const Tags, bar: *const Bar) u32 {
        const cell: u32 = @max(font.advance('0'), 1);
        if (bar.output_len == 0) return 0;
        const per_output = (cell + cfg.tags.spacing) * cfg.tags.count + cfg.tags.gap;
        const outputs: u32 = @intCast(bar.output_len);
        return outputs * per_output;
    }

    fn draw(_: *const Tags, bar: *const Bar, cv: *Canvas, x0: u32) u32 {
        const cell: u32 = @max(font.advance('0'), 1);
        var x = x0;
        for (bar.outputs[0..bar.output_len]) |*out| {
            var t: u32 = 0;
            while (t < cfg.tags.count) : (t += 1) {
                const bit = @as(u32, 1) << @intCast(t % 32);
                const selected = out.focused & bit != 0;
                const urgent = out.urgent & bit != 0;
                const occupied = out.view & bit != 0;

                if (selected or urgent) {
                    cv.rect(x, tag_top, cell, font.height, if (urgent) cfg.color.urgent else cfg.color.focused);
                }
                if (cfg.tags.show_empty or selected or urgent or occupied) {
                    const tone = if (selected or urgent)
                        cfg.color.background
                    else if (occupied)
                        cfg.color.foreground
                    else
                        cfg.color.occupied;
                    Canvas.glyph(font, cv, x, tag_top, '1' + @as(u8, @intCast(t)), tone);
                }
                x += cell + cfg.tags.spacing;
            }
            x += cfg.tags.gap;
        }
        return x - x0;
    }
};

// --- clock -----------------------------------------------------------------

const Clock = struct {
    text: TextBuf(64) = .{},
    next: u64 = 0,

    fn update(self: *Clock, _: *Bar) bool {
        const now = wallSec();
        var tm: c.struct_tm = undefined;
        if (c.localtime_r(&now, &tm) == null) return false;

        var buf: [64]u8 = undefined;
        const n = c.strftime(&buf, buf.len, cfg.clock.format.ptr, &tm);
        self.next = monoMs() + (if (cfg.clock.seconds) 250 else 999);
        if (n == 0) {
            self.text.clear();
            return self.text.take();
        }
        self.text.set(buf[0..n]);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Clock, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Clock, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- layout ----------------------------------------------------------------

/// River's layout name for the focused output. Event driven, never polled.
const Layout = struct {
    text: TextBuf(32) = .{},

    fn update(self: *Layout, bar: *Bar) bool {
        self.text.set(bar.layout_name[0..bar.layout_name_len]);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Layout, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Layout, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- title -----------------------------------------------------------------

const Title = struct {
    text: TextBuf(cfg.title.max_chars * 2) = .{},

    fn update(self: *Title, bar: *Bar) bool {
        const src = bar.focused_title[0..bar.focused_title_len];
        // Keep both ends of a long title; the middle is the least useful.
        if (cfg.title.max_chars > 0 and src.len > cfg.title.max_chars) {
            const keep = cfg.title.max_chars - 1;
            const head = @min((keep + 1) / 2, src.len);
            const tail = @min(keep - head, src.len - head);
            var joined: [cfg.title.max_chars * 2]u8 = undefined;
            @memcpy(joined[0..head], src[0..head]);
            joined[head] = '~';
            @memcpy(joined[head + 1 ..][0..tail], src[src.len - tail ..]);
            self.text.set(joined[0 .. head + 1 + tail]);
            return self.text.take();
        }
        self.text.set(src);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Title, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Title, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- status ----------------------------------------------------------------

/// Text piped in on stdin, the dwmblocks/slstatus interface.
const Status = struct {
    text: TextBuf(cfg.status.max_bytes) = .{},
    line: [cfg.status.line_bytes]u8 = undefined,
    line_len: usize = 0,
    chunk: [512]u8 = undefined,

    /// Consume whatever stdin has. Lines replace the status; a partial line
    /// is held until its newline arrives.
    fn feed(self: *Status, bar: *Bar) void {
        while (true) {
            const n = c.read(bar.stdin_fd, &self.chunk, self.chunk.len);
            if (n > 0) {
                for (self.chunk[0..@intCast(n)]) |b| {
                    if (b != '\n') {
                        if (self.line_len < self.line.len) {
                            self.line[self.line_len] = b;
                            self.line_len += 1;
                        }
                        continue;
                    }
                    const line = std.mem.trimEnd(u8, self.line[0..self.line_len], " \t\r");
                    self.text.set(line);
                    self.line_len = 0;
                }
                continue;
            }
            if (n == 0) {
                bar.stdin_open = false;
                // Flush a trailing line that never got its newline.
                if (self.line_len > 0) {
                    self.text.set(std.mem.trimEnd(u8, self.line[0..self.line_len], " \t\r"));
                    self.line_len = 0;
                }
            }
            // -1 is EAGAIN: nothing more to read right now.
            break;
        }
    }

    fn update(self: *Status, _: *Bar) bool {
        // The text itself arrives from stdin in feed(); this just reports and
        // clears what feed() latched, so a status line still marks the bar
        // dirty exactly once.
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Status, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Status, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- cpu -------------------------------------------------------------------
//
// Two samples of /proc/stat's aggregate line, so the percentage is a real
// rate between ticks rather than an average since boot.

const Cpu = struct {
    text: TextBuf(32) = .{},
    next: u64 = 0,
    prev: Cpu.Times = .{},
    started: bool = false,

    const Times = struct {
        busy: u64 = 0,
        total: u64 = 0,
    };

    /// Sum the aggregate "cpu " line. Idle and iowait count as not busy.
    fn sample(buf: []u8) ?Times {
        const body = slurp("/proc/stat", buf) orelse return null;
        var line = std.mem.splitScalar(u8, body, '\n');
        const first = line.next() orelse return null;
        if (!std.mem.startsWith(u8, first, "cpu ")) return null;

        // Fields: user nice system idle iowait irq softirq steal guest guest_nice
        var it = std.mem.tokenizeScalar(u8, first[4..], ' ');
        var total: u64 = 0;
        var idle: u64 = 0;
        var index: usize = 0;
        while (it.next()) |field| : (index += 1) {
            const v = std.fmt.parseInt(u64, field, 10) catch return null;
            total += v;
            if (index == 3 or index == 4) idle += v;
        }
        return .{ .busy = total - idle, .total = total };
    }

    fn update(self: *Cpu, _: *Bar) bool {
        if (monoMs() < self.next) return false;
        var buf: [4096]u8 = undefined;
        const now = Cpu.sample(&buf) orelse return false;
        self.next = monoMs() + cfg.cpu.interval * 1000;

        if (!self.started) {
            self.started = true;
            self.prev = now;
            self.text.set("--%");
            return true;
        }
        const d_busy = now.busy -| self.prev.busy;
        const d_total = now.total -| self.prev.total;
        self.prev = now;
        if (d_total == 0) return false;

        const pct = @min(100, d_busy * 100 / d_total);
        var buf_tmp: [64]u8 = undefined;
        self.text.set(std.fmt.bufPrint(&buf_tmp, "{d:>3}%", .{pct}) catch return false);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Cpu, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Cpu, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- mem -------------------------------------------------------------------

const Mem = struct {
    text: TextBuf(32) = .{},
    next: u64 = 0,

    fn update(self: *Mem, _: *Bar) bool {
        if (monoMs() < self.next) return false;
        var buf: [8192]u8 = undefined;
        const body = slurp("/proc/meminfo", &buf) orelse return false;
        self.next = monoMs() + cfg.mem.interval * 1000;

        var total_kb: u64 = 0;
        var avail_kb: u64 = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total_kb = field(line) orelse continue;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                avail_kb = field(line) orelse continue;
            }
            if (total_kb != 0 and avail_kb != 0) break;
        }
        if (total_kb == 0) return false;
        const used_kb = total_kb -| avail_kb;

        if (cfg.mem.absolute) {
            // Format into a scratch buffer: writing straight into text.data
            // would make `set` compare the bytes against themselves and
            // report "unchanged" forever.
            var ab: [64]u8 = undefined;
            self.text.set(std.fmt.bufPrint(&ab, "{d}M/{d}M", .{
                used_kb / 1024, total_kb / 1024,
            }) catch return false);
        } else {
            const pct = used_kb * 100 / total_kb;
            var buf_tmp: [64]u8 = undefined;
            self.text.set(std.fmt.bufPrint(&buf_tmp, "{d:>3}%", .{pct}) catch return false);
            self.text.setColor(if (pct >= 90) cfg.color.urgent else cfg.color.foreground);
        }
        return self.text.take();
    }

    /// Value of a `Key:   1234 kB` line.
    fn field(line: []const u8) ?u64 {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const v = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        return v;
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Mem, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Mem, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- load ------------------------------------------------------------------

const Load = struct {
    text: TextBuf(32) = .{},
    next: u64 = 0,

    fn update(self: *Load, _: *Bar) bool {
        if (monoMs() < self.next) return false;
        var buf: [256]u8 = undefined;
        const body = slurp("/proc/loadavg", &buf) orelse return false;
        self.next = monoMs() + cfg.load.interval * 1000;

        // /proc/loadavg: "one five ...", both plain decimals.
        var fields = std.mem.tokenizeScalar(u8, body, ' ');
        const one = std.fmt.parseFloat(f64, fields.next() orelse return false) catch return false;
        const five = std.fmt.parseFloat(f64, fields.next() orelse return false) catch return false;

        var lb: [64]u8 = undefined; self.text.set(std.fmt.bufPrint(&lb, "{d:.2} {d:.2}", .{ one, five }) catch return false);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Load, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Load, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- battery ---------------------------------------------------------------

const Battery = struct {
    text: TextBuf(32) = .{},
    next: u64 = 0,

    fn update(self: *Battery, _: *Bar) bool {
        if (monoMs() < self.next) return false;
        self.next = monoMs() + cfg.battery.interval * 1000;

        var name_buf: [64]u8 = undefined;
        // `supply` is a glob; firstEntry does a prefix match, so only a
        // trailing `*` has to come off.
        const supply = cfg.battery.supply;
        const prefix = if (supply.len > 0 and supply[supply.len - 1] == '*')
            supply[0 .. supply.len - 1]
        else
            supply;
        const name = firstEntry("/sys/class/power_supply", prefix, &name_buf) orelse {
            self.text.clear();
            return self.text.take();
        };

        // The path and the file contents need separate buffers: slurp would
        // otherwise read the sysfs file over the path it just opened.
        var path_buf_: [64]u8 = undefined;
        var value_buf: [64]u8 = undefined;
        const cap_path = pathBuf(&path_buf_, "/sys/class/power_supply/{s}/capacity", .{name}) orelse return false;
        const value = slurp(cap_path, &value_buf) orelse return false;
        const pct = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\n"), 10) catch return false;
        var buf_tmp: [64]u8 = undefined;

        var status_buf: [64]u8 = undefined;
        const status_path = pathBuf(&status_buf, "/sys/class/power_supply/{s}/status", .{name}) orelse return false;
        var status_body: [32]u8 = undefined;
        const status = slurp(status_path, &status_body) orelse return false;
        const charging = std.mem.startsWith(u8, status, "Charging");

        self.text.set(std.fmt.bufPrint(&buf_tmp, "{d:>3}%", .{pct}) catch return false);
        self.text.setColor(if (charging)
            cfg.color.battery_charging
        else if (pct < cfg.color.battery_low)
            cfg.color.urgent
        else
            cfg.color.foreground);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Battery, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Battery, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- brightness ------------------------------------------------------------

const Brightness = struct {
    text: TextBuf(32) = .{},
    next: u64 = 0,

    fn update(self: *Brightness, _: *Bar) bool {
        if (monoMs() < self.next) return false;
        self.next = monoMs() + cfg.brightness.interval * 1000;

        var device_buf: [64]u8 = undefined;
        const device = firstEntry("/sys/class/backlight", cfg.brightness.device, &device_buf) orelse {
            self.text.clear();
            return self.text.take();
        };

        var num_buf: [64]u8 = undefined;
        const num_path = pathBuf(&num_buf, "/sys/class/backlight/{s}/brightness", .{device}) orelse return false;
        var body: [32]u8 = undefined;
        const value = slurp(num_path, &body) orelse return false;
        const current = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\n"), 10) catch return false;

        const max_path = pathBuf(&num_buf, "/sys/class/backlight/{s}/max_brightness", .{device}) orelse return false;
        const max_value = slurp(max_path, &body) orelse return false;
        const max = std.fmt.parseInt(u32, std.mem.trim(u8, max_value, " \t\n"), 10) catch return false;
        if (max == 0) return false;

        var bb: [64]u8 = undefined; self.text.set(std.fmt.bufPrint(&bb, "{d:>3}%", .{current * 100 / max}) catch return false);
        return self.text.take();
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Brightness, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Brightness, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

// --- cmd -------------------------------------------------------------------
//
// The escape hatch, and the only module that forks. The child runs
// `/bin/sh -c` with its stderr pointed at /dev/null; its stdout is read
// incrementally from the event loop, so the bar never blocks waiting for it.
//
// `volume` is the same machinery with a command already filled in, because
// the kernel exposes no audio volume at all.

const Cmd = struct {
    const Format = enum { text, number, volume };

    text: TextBuf(256) = .{},
    command: []const u8,
    /// How to turn the child's output into the text to show.
    format: Format = .text,

    /// Seconds between runs. Volume has its own so it can poll slower.
    interval: u32,

    next: u64 = 0,
    pid: c.pid_t = -1,
    fd: c_int = -1,
    /// Set once the pipe reports end-of-file. The child may still be running at
    /// that point, and a drained pipe never becomes readable again, so this is
    /// what tells the event loop to keep coming back for the exit status.
    eof: bool = false,
    started_ms: u64 = 0,
    collected: usize = 0,
    scratch: [256]u8 = undefined,

    const timeout_ms = cfg.cmd.timeout_ms;

    fn update(self: *Cmd, _: *Bar) bool {
        const now = monoMs();
        if (now < self.next) return false;
        self.next = now + self.interval * 1000;
        if (self.pid > 0) return false; // still running
        self.start();
        return false;
    }

    fn start(self: *Cmd) void {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        // OR onto the existing flags rather than replacing them, and keep the
        // read end out of any child forked later.
        const flags = c.fcntl(fds[0], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fds[0], c.F_SETFL, flags | c.O_NONBLOCK);
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);

        var cmd_buf: [512]u8 = undefined;
        const shell_cmd = pathBuf(&cmd_buf, "{s}", .{self.command}) orelse {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return;
        };

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return;
        }
        if (pid == 0) {
            // Child. Only async-signal-safe calls from here on.
            _ = c.close(fds[0]);
            _ = c.dup2(fds[1], 1);
            _ = c.close(fds[1]);
            const null_fd = c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
            if (null_fd >= 0) {
                _ = c.dup2(null_fd, 2);
                _ = c.close(null_fd);
            }
            var argv = [_:null]?[*:0]const u8{ "sh", "-c", shell_cmd, null };
            _ = c.execvp("sh", @ptrCast(&argv));
            c._exit(127);
        }

        _ = c.close(fds[1]);
        self.pid = pid;
        self.fd = fds[0];
        self.started_ms = monoMs();
        self.collected = 0;
        self.eof = false;
    }

    /// Called from the event loop when the child's pipe becomes readable.
    fn pump(self: *Cmd) bool {
        if (self.fd < 0) return false;
        while (self.collected < self.scratch.len) {
            const n = c.read(self.fd, self.scratch[self.collected..].ptr, self.scratch.len - self.collected);
            if (n > 0) {
                self.collected += @intCast(n);
                continue;
            }
            // n == 0 is a real end-of-file; a negative n is EAGAIN. Only the
            // former means the child is done writing, and only then is it worth
            // trying to collect the result.
            if (n == 0) self.eof = true;
            break;
        }
        if (self.eof) return self.reap();
        return false;
    }

    /// Retry collection for a child whose output is complete but which has not
    /// been reaped yet. A drained pipe stops reporting readable, so without
    /// this the result would be dropped and the module would stay empty for
    /// the rest of the run.
    fn settle(self: *Cmd) bool {
        if (!self.eof) return false;
        return self.reap();
    }

    fn reap(self: *Cmd) bool {
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, c.WNOHANG);
        if (r == 0) return false;

        // The child is gone; take whatever it managed to print.
        _ = c.close(self.fd);
        self.fd = -1;
        self.pid = -1;
        self.eof = false;

        const full = self.scratch[0..self.collected];
        const line = std.mem.trimEnd(u8, full[0 .. std.mem.indexOfScalar(u8, full, '\n') orelse full.len], " \t\r");
        switch (self.format) {
            .text => {
                self.text.set(line);
                return self.text.take();
            },
            .number => {
                if (firstNumber(line)) |n| {
                    var cb: [128]u8 = undefined; self.text.set(std.fmt.bufPrint(&cb, "{d}%", .{n}) catch return false);
                } else {
                    self.text.clear();
                }
                return self.text.take();
            },
            .volume => {
                var cb: [128]u8 = undefined;
                if (cfg.volumePercent(line, &cb)) |v| {
                    self.text.set(v);
                } else {
                    self.text.clear();
                }
                return self.text.take();
            },
        }
    }

    /// Kill a child that overran its budget.
    /// A child still running this long past its start is considered wedged.
    fn timedOut(self: *const Cmd, now_ms: u64) bool {
        return self.pid > 0 and now_ms -| self.started_ms > timeout_ms;
    }

    fn abort(self: *Cmd) void {
        self.eof = false;
        if (self.pid > 0) {
            _ = c.kill(self.pid, c.SIGKILL);
            var status: c_int = 0;
            _ = c.waitpid(self.pid, &status, 0);
            self.pid = -1;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    fn firstNumber(s: []const u8) ?u32 {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] < '0' or s[i] > '9') continue;
            var v: u32 = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1)
                v = v * 10 + (s[i] - '0');
            return v;
        }
        return null;
    }

    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Cmd, _: *const Bar) u32 {
        return Render.width(&self.text);
    }

    fn draw(self: *const Cmd, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.text, cv, x);
    }
};

/// `volume` is a `cmd` with the command and parsing preset.
const Volume = struct {
    inner: Cmd = .{ .command = cfg.volume.command, .format = .volume, .interval = cfg.volume.interval },

    fn update(self: *Volume, bar: *Bar) bool {
        return self.inner.update(bar);
    }
    /// Same width `draw` reports, without drawing anything.
    fn width(self: *const Volume, _: *const Bar) u32 {
        return Render.width(&self.inner.text);
    }

    fn draw(self: *const Volume, _: *const Bar, cv: *Canvas, x: u32) u32 {
        return Render.draw(&self.inner.text, cv, x);
    }
};

// --- the set ---------------------------------------------------------------

const Module = union(enum) {
    tags: Tags,
    clock: Clock,
    layout: Layout,
    title: Title,
    status: Status,
    cpu: Cpu,
    mem: Mem,
    load: Load,
    battery: Battery,
    brightness: Brightness,
    volume: Volume,
    cmd: Cmd,

    fn init(name: []const u8) Module {
        if (eq(name, "tags")) return .{ .tags = .{} };
        if (eq(name, "clock")) return .{ .clock = .{} };
        if (eq(name, "layout")) return .{ .layout = .{} };
        if (eq(name, "title")) return .{ .title = .{} };
        if (eq(name, "status")) return .{ .status = .{} };
        if (eq(name, "cpu")) return .{ .cpu = .{} };
        if (eq(name, "mem")) return .{ .mem = .{} };
        if (eq(name, "load")) return .{ .load = .{} };
        if (eq(name, "battery")) return .{ .battery = .{} };
        if (eq(name, "brightness")) return .{ .brightness = .{} };
        if (eq(name, "volume")) return .{ .volume = .{} };
        for (cfg.cmd.commands) |entry| {
            if (eq(name, entry.name)) {
                return .{ .cmd = .{ .command = entry.command, .interval = cfg.cmd.interval } };
            }
        }
        die("unknown module '{s}' in config.zig", .{name});
    }

    /// Every module that forks exposes its child pipe here, -1 otherwise.
    fn childFd(self: *const Module) c_int {
        return switch (self.*) {
            .cmd => |m| m.fd,
            .volume => |m| m.inner.fd,
            else => -1,
        };
    }

    fn settle(self: *Module) bool {
        switch (self.*) {
            .cmd => |*m| return m.settle(),
            .volume => |*m| return m.inner.settle(),
            else => return false,
        }
    }

    fn onChildReadable(self: *Module) bool {
        switch (self.*) {
            .cmd => |*m| return m.pump(),
            .volume => |*m| return m.inner.pump(),
            else => return false,
        }
    }

    /// Kill any child of this module that has outrun its budget, so a wedged
    /// command cannot hold a pipe open forever.
    fn killStuck(self: *Module, now_ms: u64) void {
        switch (self.*) {
            .cmd => |*m| {
                if (m.timedOut(now_ms)) m.abort();
            },
            .volume => |*m| {
                if (m.inner.timedOut(now_ms)) m.inner.abort();
            },
            else => {},
        }
    }

    /// Stop every child this module owns.
    fn shutdown(self: *Module) void {
        switch (self.*) {
            .cmd => |*m| m.abort(),
            .volume => |*m| m.inner.abort(),
            else => {},
        }
    }

    /// Monotonic ms at which this module should refresh, or null if it only
    /// changes on an external event.
    /// Bring a polled module forward to run on the next pass. Used by the
    /// SIGUSR1 path so an external change shows up without waiting out the
    /// module's interval. Modules driven by events (tags, title, layout,
    /// status) have no interval to cut short and are left alone.
    fn kick(self: *Module) void {
        switch (self.*) {
            .tags, .layout, .title, .status => {},
            .clock => |*m| m.next = 0,
            .cpu => |*m| m.next = 0,
            .mem => |*m| m.next = 0,
            .load => |*m| m.next = 0,
            .battery => |*m| m.next = 0,
            .brightness => |*m| m.next = 0,
            .cmd => |*m| m.next = 0,
            .volume => |*m| m.inner.next = 0,
        }
    }

    fn deadline(self: *const Module) ?u64 {
        return switch (self.*) {
            .tags, .layout, .title, .status => null,
            .clock => |m| m.next,
            .cpu => |m| m.next,
            .mem => |m| m.next,
            .load => |m| m.next,
            .battery => |m| m.next,
            .brightness => |m| m.next,
            .cmd => |m| m.next,
            .volume => |m| m.inner.next,
        };
    }

    fn update(self: *Module, bar: *Bar) bool {
        switch (self.*) {
            inline else => |*m| return m.update(bar),
        }
    }

    fn draw(self: *const Module, bar: *const Bar, cv: *Canvas, x: u32) u32 {
        return switch (self.*) {
            .tags => |m| m.draw(bar, cv, x),
            .clock => |m| m.draw(bar, cv, x),
            .layout => |m| m.draw(bar, cv, x),
            .title => |m| m.draw(bar, cv, x),
            .status => |m| m.draw(bar, cv, x),
            .cpu => |m| m.draw(bar, cv, x),
            .mem => |m| m.draw(bar, cv, x),
            .load => |m| m.draw(bar, cv, x),
            .battery => |m| m.draw(bar, cv, x),
            .brightness => |m| m.draw(bar, cv, x),
            .cmd => |m| m.draw(bar, cv, x),
            .volume => |m| m.draw(bar, cv, x),
        };
    }

    /// How wide this module wants to be, so a group can be measured and
    /// placed before anything is drawn.
    fn width(self: *const Module, bar: *const Bar) u32 {
        return switch (self.*) {
            .tags => |m| m.width(bar),
            .clock => |m| m.width(bar),
            .layout => |m| m.width(bar),
            .title => |m| m.width(bar),
            .status => |m| m.width(bar),
            .cpu => |m| m.width(bar),
            .mem => |m| m.width(bar),
            .load => |m| m.width(bar),
            .battery => |m| m.width(bar),
            .brightness => |m| m.width(bar),
            .cmd => |m| m.width(bar),
            .volume => |m| m.width(bar),
        };
    }
};

// ===========================================================================
// Buffers
// ===========================================================================

/// One memfd, one pool, one mapping, both buffers inside it. The old pool is
/// kept in `spare` until the compositor has released both of its buffers,
/// which is what stops a resize from pulling shm out from under it.
fn allocPool(bar: *Bar, width: u32, height: u32) bool {
    const stride = @as(usize, width) * 4;
    const one = stride * height;
    const size = one * n_buffers;

    var pool = Pool{
        .width = width,
        .height = height,
        .stride = stride,
        .size = size,
    };

    pool.fd = std.posix.memfd_create("bar", std.posix.MFD.CLOEXEC) catch return false;
    // ftruncate takes off_t; note the >= 0, memfd can legitimately hand back 0.
    if (c.ftruncate(pool.fd, @intCast(size)) != 0) {
        pool.free(bar.shm);
        return false;
    }

    pool.shm_pool = c.wl_shm_create_pool(bar.shm, pool.fd, @intCast(size));
    if (pool.shm_pool == null) {
        pool.free(bar.shm);
        return false;
    }

    pool.data = std.posix.mmap(null, size, .{
        .READ = true,
        .WRITE = true,
    }, .{ .TYPE = .SHARED }, pool.fd, 0) catch {
        pool.free(bar.shm);
        return false;
    };

    for (&pool.buffers, 0..) |*buf, i| {
        buf.offset = one * i;
        buf.wl_buffer = c.wl_shm_pool_create_buffer(
            pool.shm_pool,
            @intCast(buf.offset),
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        );
        buf.released = true;
        if (buf.wl_buffer == null) {
            pool.free(bar.shm);
            return false;
        }
        // The listener gets the Bar, not the Buffer: pools move between the
        // active and retired slots, so a Buffer address is not stable.
        _ = c.wl_buffer_add_listener(buf.wl_buffer, &buffer_listener, @ptrCast(bar));
    }

    pool.valid = true;
    if (bar.active.valid and !retire(bar, bar.active)) return false;
    bar.active = pool;
    return true;
}

/// Hand a pool off to be freed later. Fails only when every retired slot is
/// still in flight, in which case the caller keeps the pool it has.
fn retire(bar: *Bar, pool: Pool) bool {
    if (bar.retired_len == max_retired) return false;
    bar.retired[bar.retired_len] = pool;
    bar.retired_len += 1;
    return true;
}

/// Free every retired pool the compositor is done with.
fn reapRetired(bar: *Bar) void {
    var i: usize = 0;
    while (i < bar.retired_len) {
        if (poolBusy(bar.retired[i])) {
            i += 1;
            continue;
        }
        bar.retired[i].free(bar.shm);
        bar.retired[i] = bar.retired[bar.retired_len - 1];
        bar.retired_len -= 1;
    }
}

fn poolBusy(pool: Pool) bool {
    for (pool.buffers) |buf| if (buf.busy) return true;
    return false;
}

const buffer_listener = c.wl_buffer_listener{
    .release = onBufferRelease,
};

/// Mark whichever buffer the compositor just let go of. The bar knows where
/// every buffer lives, so match on the handle rather than trusting a pointer.
fn onBufferRelease(data: ?*anyopaque, handle: ?*c.struct_wl_buffer) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    for (&bar.active.buffers) |*buf| {
        if (buf.wl_buffer == handle) {
            buf.busy = false;
            return;
        }
    }
    for (bar.retired[0..bar.retired_len]) |*pool| {
        for (&pool.buffers) |*buf| {
            if (buf.wl_buffer == handle) {
                buf.busy = false;
                return;
            }
        }
    }
}

// ===========================================================================
// Rendering
// ===========================================================================

fn present(bar: *Bar) bool {
    if (!bar.active.valid) return false;
    if (bar.active.width != bar.want_w or bar.active.height != bar.want_h) return false;
    // Both buffers still with the compositor: try again next wake rather than
    // overwriting one that is being scanned out.
    var index: usize = 0;
    while (index < n_buffers) : (index += 1) {
        if (!bar.active.buffers[index].busy) break;
    }
    if (index == n_buffers) return false;

    const buf = &bar.active.buffers[index];
    var cv = Canvas.init(&bar.active, index);
    cv.clear(cfg.color.background);

    // Two groups: `left` packed against the left edge, `right` packed against
    // the right edge. The right one is measured first so it can be placed.
    const left = bar.modules[0..cfg.modules.len];
    const right = bar.modules[cfg.modules.len..];

    _ = drawGroup(bar, &cv, left, cfg.padding_h);

    const right_w = groupWidth(bar, right);
    const right_x = if (cfg.padding_h +| right_w <= cv.w)
        cv.w - cfg.padding_h - right_w
    else
        cfg.padding_h; // wider than the bar: fall back to the left edge
    _ = drawGroup(bar, &cv, right, right_x);

    if (cfg.dump_frame and !bar.dumped) dumpFrame(bar, &cv);

    _ = c.wl_surface_attach(bar.surface, buf.wl_buffer, 0, 0);
    // Damage in buffer coordinates, which are `scale` times the surface size.
    _ = c.wl_surface_damage_buffer(bar.surface, 0, 0, @intCast(cv.w), @intCast(cv.h));
    _ = c.wl_surface_commit(bar.surface);
    buf.busy = true;
    return true;
}

/// Width a group of modules needs, separators included. Modules that draw
/// nothing are skipped, exactly as `drawGroup` skips them.
fn groupWidth(bar: *const Bar, group: []const Module) u32 {
    var w: u32 = 0;
    var drew = false;
    for (group) |*m| {
        const mw = m.width(bar);
        if (mw == 0) continue;
        if (drew) w += cfg.padding_h;
        w += mw;
        drew = true;
    }
    return w;
}

/// Draw a group left to right starting at `x0`, dropping a separator rule into
/// each gap. Returns the columns consumed.
fn drawGroup(bar: *const Bar, cv: *Canvas, group: []const Module, x0: u32) u32 {
    var x = x0;
    var drew = false;
    for (group) |*m| {
        if (x >= cv.w) break;
        // Ask before drawing the separator: an empty module must not leave an
        // orphan rule behind, and skipping it here is what keeps this in step
        // with groupWidth, which is what placed the group.
        if (m.width(bar) == 0) continue;
        if (drew) {
            // The rule has to be a rect, not a '|' glyph: the gap is only
            // padding_h columns wide, and a glyph cell is one `font.advance` wide,
            // so a glyph would spill over both neighbouring modules.
            x += cfg.padding_h / 2;
            cv.rect(x, text_top, 1, font.height, cfg.color.separator);
            x += cfg.padding_h - cfg.padding_h / 2;
            if (x >= cv.w) break;
        }
        const used = m.draw(bar, cv, x);
        if (used == 0) continue;
        drew = true;
        x += used;
    }
    return x - x0;
}

/// Write the first drawn frame to `$BAR_DUMP` as raw ARGB, so the bar can be
/// eyeballed on setups with no screenshot tool. Set by `cfg.dump_frame`.
fn dumpFrame(bar: *Bar, cv: *const Canvas) void {
    bar.dumped = true;
    const env = c.getenv("BAR_DUMP") orelse {
        std.debug.print("bar: dump_frame is on but BAR_DUMP is not set\n", .{});
        return;
    };
    const fd = c.open(env, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) {
        std.debug.print("bar: cannot open '{s}' for BAR_DUMP\n", .{std.mem.span(@as([*:0]const u8, @ptrCast(env)))});
        return;
    }
    defer _ = c.close(fd);

    const bytes = std.mem.sliceAsBytes(cv.px);
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    std.debug.print("bar: wrote {d}x{d} frame to {s}\n", .{ cv.w, cv.h, std.mem.span(@as([*:0]const u8, @ptrCast(env))) });
}

// ===========================================================================
// 8. Event loop and main
// ===========================================================================

const layer_listener = c.zwlr_layer_surface_v1_listener{
    .configure = onLayerConfigure,
    .closed = onLayerClosed,
};

fn onLayerConfigure(
    data: ?*anyopaque,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    _ = c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    bar.configured = true;

    if (width == bar.width and height == bar.height) return;

    bar.width = width;
    bar.height = height;
    // The surface is in unscaled coordinates; the buffer is scale times bigger.
    bar.want_w = width * bar.scale;
    bar.want_h = height * bar.scale;
    bar.dirty = true;
}

fn onLayerClosed(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    bar.running = false;
}

/// poll() slots: the Wayland socket, stdin, and one per running child.
const max_poll = 2 + n_modules;
/// Pools a resize may leave behind before giving up and retrying later.
const max_retired = 4;
const PollSlot = struct { kind: Kind, module: usize = 0 };
const Kind = enum { wayland, stdin, child };

fn runLoop(bar: *Bar) void {
    var slots: [max_poll]PollSlot = undefined;
    var fds: [max_poll]std.posix.pollfd = undefined;

    while (bar.running) {
        var n: usize = 0;

        // A SIGUSR1 arrived (the volume keys poke us after running wpctl).
        // Zeroing the deadlines first also shortens this pass's poll timeout,
        // so the refresh does not wait for a wakeup that may be a second out.
        if (refresh_now) {
            refresh_now = false;
            for (&bar.modules) |*m| m.kick();
        }

        const wl_fd = c.wl_display_get_fd(bar.display);
        slots[n] = .{ .kind = .wayland };
        fds[n] = .{ .fd = wl_fd, .events = std.posix.POLL.IN, .revents = 0 };
        n += 1;

        if (bar.stdin_open) {
            slots[n] = .{ .kind = .stdin };
            fds[n] = .{ .fd = bar.stdin_fd, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
        }

        for (&bar.modules, 0..) |*m, i| {
            const child = m.childFd();
            if (child < 0) continue;
            slots[n] = .{ .kind = .child, .module = i };
            fds[n] = .{ .fd = child, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
        }

        // Sleep until the next module deadline, the next second boundary, or
        // until something happens. No fixed 1000 ms poll.
        const now = monoMs();
        var wake: u64 = now + 1000;
        for (&bar.modules) |*m| {
            if (m.deadline()) |d| wake = @min(wake, d);
        }
        if (cfg.repaint_interval > 0) wake = @min(wake, now + cfg.repaint_interval * 1000);
        const timeout: i32 = if (wake <= now) 0 else @intCast(@min(wake - now, 1000));

        _ = c.wl_display_flush(bar.display);

        const ready = std.posix.poll(fds[0..n], timeout) catch break;
        if (ready == 0) bar.dirty = true;
        bar.now_ms = monoMs();

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const revents = fds[i].revents;
            if (revents == 0) continue;
            switch (slots[i].kind) {
                .wayland => {
                    if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                        bar.running = false;
                    }
                    if (c.wl_display_dispatch(bar.display) < 0) {
                        bar.running = false;
                    }
                },
                .stdin => {
                    // A closed or invalid stdin must be dropped, or poll returns
                    // POLLNVAL immediately and the loop spins at 100% cpu.
                    if (revents & (std.posix.POLL.NVAL | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                        bar.stdin_open = false;
                    } else {
                        for (&bar.modules) |*m| {
                            if (m.* == .status) m.status.feed(bar);
                        }
                    }
                },
                .child => {
                    if (bar.modules[slots[i].module].onChildReadable()) bar.dirty = true;
                },
            }
        }

        reapRetired(bar);

        // A resize may have been refused while the compositor still held the
        // old buffers; try again now that some may have come back.
        if (bar.want_w > 0 and bar.want_h > 0 and
            (bar.active.width != bar.want_w or bar.active.height != bar.want_h))
        {
            if (!allocPool(bar, bar.want_w, bar.want_h))
                std.debug.print("bar: still waiting for shm to resize to {d}x{d}\n", .{ bar.want_w, bar.want_h });
        }

        // A child that overran its budget is killed rather than waited on.
        for (&bar.modules) |*m| m.killStuck(bar.now_ms);

        // Pick up any child that finished writing but had not exited yet.
        for (&bar.modules) |*m| {
            if (m.settle()) bar.dirty = true;
        }

        // Refresh whatever is due.
        for (&bar.modules) |*m| {
            if (m.update(bar)) bar.dirty = true;
        }

        // Only give up the dirty flag once a frame has really been shown, so a
        // frame dropped for want of a free buffer is retried.
        if (bar.dirty and present(bar)) bar.dirty = false;

        if (c.wl_display_flush(bar.display) < 0) break;
    }

    for (&bar.modules) |*m| m.shutdown();
}

fn initModules(bar: *Bar) void {
    for (cfg.modules, 0..) |name, i| bar.modules[i] = Module.init(name);
    for (cfg.right_modules, 0..) |name, i| bar.modules[cfg.modules.len + i] = Module.init(name);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var bar = Bar{};

    installRefreshSignal();

    bar.display = c.wl_display_connect(null) orelse die("cannot connect to a Wayland display", .{});
    defer _ = c.wl_display_disconnect(bar.display);

    bar.registry = c.wl_display_get_registry(bar.display) orelse die("no registry", .{});
    if (c.wl_registry_add_listener(bar.registry, &registry_listener, @ptrCast(&bar)) != 0)
        die("cannot listen to the registry", .{});
    if (c.wl_display_roundtrip(bar.display) < 0) die("registry roundtrip failed", .{});

    if (bar.compositor == null or bar.shm == null or bar.layer_shell == null)
        die("missing wl_compositor, wl_shm or zwlr_layer_shell_v1", .{});

    // Ask river for tags and the layout name.
    if (bar.status_manager) |manager| {
        for (bar.outputs[0..bar.output_len]) |*out| {
            out.bar = &bar;
            const proxy = out.proxy orelse continue;
            const st = c.zriver_status_manager_v1_get_river_output_status(manager, proxy) orelse continue;
            _ = c.zriver_output_status_v1_add_listener(st, &output_status_listener, @ptrCast(out));
            out.status = st;
        }
    }

    // Ask river for the focused view's title.
    if (bar.status_manager != null and bar.seat != null) {
        bar.seat_status = c.zriver_status_manager_v1_get_river_seat_status(bar.status_manager, bar.seat);
        if (bar.seat_status) |ss| {
            _ = c.zriver_seat_status_v1_add_listener(ss, &seat_status_listener, @ptrCast(&bar));
        }
    }

    // stdin must be non-blocking: poll says there is data, but read must not
    // be allowed to sit there waiting for more.
    _ = c.fcntl(0, c.F_SETFL, c.O_NONBLOCK);

    bar.surface = c.wl_compositor_create_surface(bar.compositor) orelse die("no surface", .{});
    bar.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        bar.layer_shell,
        bar.surface,
        null,
        cfg.layer,
        "bar",
    ) orelse die("no layer surface", .{});
    if (c.zwlr_layer_surface_v1_add_listener(bar.layer_surface, &layer_listener, @ptrCast(&bar)) != 0)
        die("cannot listen to the layer surface", .{});

    const requested_h = barHeight();
    c.zwlr_layer_surface_v1_set_anchor(bar.layer_surface, cfg.anchor);
    c.zwlr_layer_surface_v1_set_size(bar.layer_surface, 0, @intCast(requested_h));
    if (cfg.exclusive) {
        c.zwlr_layer_surface_v1_set_exclusive_zone(bar.layer_surface, @intCast(requested_h));
    }
    c.zwlr_layer_surface_v1_set_keyboard_interactivity(bar.layer_surface, KEYBOARD_NONE);

    _ = c.wl_surface_commit(bar.surface);
    if (c.wl_display_roundtrip(bar.display) < 0 or !bar.configured)
        die("the compositor never configured the surface", .{});

    initModules(&bar);
    runLoop(&bar);

    bar.active.free(bar.shm);
    for (bar.retired[0..bar.retired_len]) |*pool| pool.free(bar.shm);
}

