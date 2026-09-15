const std = @import("std");
const font = @import("font.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("river-status-unstable-v1-client-protocol.h");
});

extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, count: usize, file: *anyopaque) usize;
extern "c" fn fclose(file: *anyopaque) c_int;

const pad_v: u32 = 3;
const glyph_w: u32 = 9;
const advance: u32 = 9;
const bar_h: u32 = font.h + 2 * pad_v;
const n_buffers: usize = 2;
const line_cap: usize = 512;
const status_cap: usize = 256;
const n_tags: u32 = 8;
const n_outputs_max: usize = 4;

const bg: u32 = 0xFF000000;
const fg: u32 = 0xFFFFFFFF;
const dim: u32 = 0xFF606060;
const urgent: u32 = 0xFFFF4040;

const Buffer = struct {
    wl_buffer: ?*c.struct_wl_buffer = null,
    pool: ?*c.struct_wl_shm_pool = null,
    data: []align(std.heap.page_size_min) u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    busy: bool = false,
};

const TagSet = struct {
    status: ?*c.struct_zriver_output_status_v1 = null,
    proxy: ?*c.struct_wl_output = null,
    owner: ?*Bar = null,
    focused: u32 = 0,
    view: u32 = 0,
    urgent_mask: u32 = 0,
};

const OutputArr = struct {
    items: [n_outputs_max]TagSet = .{ .{}, .{}, .{}, .{} },
    len: usize = 0,
};

const Bar = struct {
    display: ?*c.struct_wl_display = null,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    status_manager: ?*c.struct_zriver_status_manager_v1 = null,
    outputs: OutputArr = .{},
    surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    running: bool = true,
    buffers: [n_buffers]Buffer = .{ .{}, .{} },
    next_idx: usize = 0,
    stdin_open: bool = true,
    dirty: bool = true,
    last_sec: u64 = 0,
    dump_done: bool = false,
    status: [status_cap]u8 = undefined,
    status_len: usize = 0,
    line: [line_cap]u8 = undefined,
    line_len: usize = 0,
    line_buf: [256]u8 = undefined,
};

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
    if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1") and version >= 1)
        bar.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 1))
    else if (std.mem.eql(u8, iface, "wl_compositor") and version >= 1)
        bar.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 1))
    else if (std.mem.eql(u8, iface, "wl_shm") and version >= 1)
        bar.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1))
    else if (std.mem.eql(u8, iface, "zriver_status_manager_v1") and version >= 1)
        bar.status_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zriver_status_manager_v1_interface, 1))
    else if (std.mem.eql(u8, iface, "wl_output") and version >= 1 and bar.outputs.len < n_outputs_max) {
        bar.outputs.items[bar.outputs.len].proxy = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 1));
        bar.outputs.len += 1;
    }
}

fn onGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

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
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    if (!bar.configured) std.debug.print("bar: configured {d}x{d}\n", .{ width, height });
    bar.configured = true;
    if (width != bar.width or height != bar.height) {
        bar.width = width;
        bar.height = height;
        remapBuffers(bar);
    }
}

fn onLayerClosed(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
    _ = layer_surface;
    const bar: *Bar = @ptrCast(@alignCast(data orelse return));
    bar.running = false;
}

const buffer_listener = c.wl_buffer_listener{
    .release = onBufferRelease,
};

fn onBufferRelease(data: ?*anyopaque, wl_buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = wl_buffer;
    const buf: *Buffer = @ptrCast(@alignCast(data orelse return));
    buf.busy = false;
}

const output_status_listener = c.zriver_output_status_v1_listener{
    .focused_tags = onFocusedTags,
    .view_tags = onViewTags,
    .urgent_tags = onUrgentTags,
    .layout_name = onLayoutName,
    .layout_name_clear = onLayoutNameClear,
};

fn onTagEvent(ts: *TagSet) void {
    if (ts.owner) |b| b.dirty = true;
}

fn onFocusedTags(data: ?*anyopaque, status: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.c) void {
    _ = status;
    const ts: *TagSet = @ptrCast(@alignCast(data orelse return));
    ts.focused = tags;
    onTagEvent(ts);
}

fn onViewTags(data: ?*anyopaque, status: ?*c.struct_zriver_output_status_v1, tags: ?*const c.wl_array) callconv(.c) void {
    _ = status;
    const ts: *TagSet = @ptrCast(@alignCast(data orelse return));
    const arr = tags orelse return;
    const n = arr.size / @sizeOf(u32);
    if (n == 0) return;
    const p: [*]align(4) const u32 = @ptrCast(@alignCast(arr.data));
    var mask: u32 = 0;
    for (p[0..n]) |v| mask |= v;
    ts.view = mask;
    onTagEvent(ts);
}

fn onUrgentTags(data: ?*anyopaque, status: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.c) void {
    _ = status;
    const ts: *TagSet = @ptrCast(@alignCast(data orelse return));
    ts.urgent_mask = tags;
    onTagEvent(ts);
}

fn onLayoutName(data: ?*anyopaque, status: ?*c.struct_zriver_output_status_v1, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = status;
    _ = name;
}

fn onLayoutNameClear(data: ?*anyopaque, status: ?*c.struct_zriver_output_status_v1) callconv(.c) void {
    _ = data;
    _ = status;
}

fn remapBuffers(bar: *Bar) void {
    if (bar.width == 0 or bar.height == 0) return;
    for (&bar.buffers) |*buf| {
        if (buf.pool) |p| c.wl_shm_pool_destroy(p);
        if (buf.wl_buffer) |wb| c.wl_buffer_destroy(wb);
        if (buf.data.len > 0) std.posix.munmap(buf.data);
        buf.* = .{};
    }
    const stride = bar.width * 4;
    const size = stride * bar.height;
    for (&bar.buffers) |*buf| {
        const fd = std.posix.memfd_create("bar", 0) catch return;
        defer {
            if (fd > 0) _ = close(fd);
        }
        if (ftruncate(fd, @intCast(size)) != 0) return;
        const pool = c.wl_shm_create_pool(bar.shm, fd, @intCast(size)) orelse return;
        const wb = c.wl_shm_pool_create_buffer(pool, 0, @intCast(bar.width), @intCast(bar.height), @intCast(stride), c.WL_SHM_FORMAT_ARGB8888) orelse return;
        buf.data = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return;
        buf.pool = pool;
        buf.wl_buffer = wb;
        buf.width = bar.width;
        buf.height = bar.height;
        _ = c.wl_buffer_add_listener(wb, &buffer_listener, @ptrCast(buf));
    }
}

fn blobData(buf: *const Buffer) []u32 {
    return std.mem.bytesAsSlice(u32, buf.data);
}

fn fillRect(bar: *const Bar, px: []u32, x0: u32, y0: u32, w: u32, h: u32, color: u32) void {
    for (0..h) |dy| {
        for (0..w) |dx| {
            const xx = x0 + @as(u32, @intCast(dx));
            const yy = y0 + @as(u32, @intCast(dy));
            if (xx < bar.width and yy < bar.height)
                px[@as(usize, yy) * @as(usize, bar.width) + @as(usize, xx)] = color;
        }
    }
}

fn blitGlyph(bar: *const Bar, px: []u32, ch: u8, x0: u32, y0: u32, color: u32) void {
    const g = font.glyphs[ch - 0x20];
    for (g, 0..) |row, r| {
        for (0..glyph_w) |col| {
            if (row & (@as(u16, 1) << @intCast(8 - col)) == 0) continue;
            const xx = x0 + col;
            const yy = y0 + @as(u32, @intCast(r));
            if (xx < bar.width and yy < bar.height)
                px[@as(usize, yy) * @as(usize, bar.width) + @as(usize, xx)] = color;
        }
    }
}

fn drawTags(bar: *const Bar, px: []u32, x: *u32) void {
    for (bar.outputs.items[0..bar.outputs.len]) |*ts| {
        for (0..n_tags) |t| {
            const bit: u32 = @as(u32, 1) << @intCast(t);
            const sel = ts.focused & bit != 0;
            const urg = ts.urgent_mask & bit != 0;
            if (sel or urg) fillRect(bar, px, x.*, pad_v, glyph_w, font.h, if (urg) urgent else fg);
            blitGlyph(bar, px, '1' + @as(u8, @intCast(t)), x.*, pad_v, if (sel or urg) bg else if (ts.view & bit != 0) fg else dim);
            x.* += advance + 1;
        }
        x.* += 3;
    }
}

fn composeText(bar: *const Bar, out: []u8) usize {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const sec = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const yd = sec.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = sec.getDaySeconds();
    const head = std.fmt.bufPrint(out, " {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch return 0;
    out[head.len] = ' ';
    out[head.len + 1] = '|';
    out[head.len + 2] = ' ';
    const n = head.len + 3;
    const take = @min(out.len - n, bar.status_len);
    @memcpy(out[n..][0..take], bar.status[0..take]);
    return n + take;
}

fn draw(bar: *Bar) void {
    if (!bar.configured or bar.buffers[0].wl_buffer == null) return;
    const idx = if (bar.buffers[bar.next_idx].busy) 1 - bar.next_idx else bar.next_idx;
    if (bar.buffers[idx].busy) return;
    const buf = &bar.buffers[idx];

    const px = blobData(buf);
    @memset(px, bg);

    var x: u32 = 1;
    drawTags(bar, px, &x);
    x += 3;

    var text: [status_cap + 64]u8 = undefined;
    const text_len = composeText(bar, &text);
    for (text[0..text_len]) |ch| {
        if (ch < 0x20 or ch > 0x7e) continue;
        blitGlyph(bar, px, ch, x, pad_v, fg);
        x += advance;
        if (x + glyph_w > buf.width) break;
    }
    while (x + glyph_w <= buf.width) {
        blitGlyph(bar, px, ' ', x, pad_v, fg);
        x += advance;
    }

    if (!bar.dump_done) {
        bar.dump_done = true;
        if (std.c.getenv("BAR_DUMP")) |fname_raw| {
            const fname = std.mem.span(fname_raw);
            if (fopen(fname.ptr, "wb")) |f| {
                _ = fwrite(buf.data.ptr, 1, buf.data.len, f);
                _ = fclose(f);
            }
        }
    }

    _ = c.wl_surface_attach(bar.surface, buf.wl_buffer, 0, 0);
    _ = c.wl_surface_damage(bar.surface, 0, 0, @intCast(buf.width), @intCast(buf.height));
    _ = c.wl_surface_commit(bar.surface);
    buf.busy = true;
    bar.next_idx = 1 - idx;
}

fn appendLine(bar: *Bar, data: []const u8) void {
    for (data) |b| {
        if (b == '\n') {
            if (bar.line_len > 0) {
                const end = std.mem.trimEnd(u8, bar.line[0..bar.line_len], " \t\r");
                const take = @min(end.len, status_cap);
                @memcpy(bar.status[0..take], end[0..take]);
                bar.status_len = take;
                bar.line_len = 0;
                bar.dirty = true;
            }
            continue;
        }
        if (bar.line_len < bar.line.len) {
            bar.line[bar.line_len] = b;
            bar.line_len += 1;
        }
    }
}

fn drainStdin(bar: *Bar) void {
    const n = std.posix.read(0, &bar.line_buf) catch |e| {
        if (e != error.WouldBlock) bar.running = false;
        return;
    };
    if (n == 0) {
        bar.stdin_open = false;
        return;
    }
    appendLine(bar, bar.line_buf[0..n]);
}

fn nowSec() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn runLoop(bar: *Bar) void {
    var fds = [_]std.posix.pollfd{
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = c.wl_display_get_fd(bar.display), .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (bar.running) {
        const s = nowSec();
        if (s != bar.last_sec or bar.dirty) {
            draw(bar);
            bar.last_sec = s;
            bar.dirty = false;
        }
        if (c.wl_display_flush(bar.display) < 0) break;

        fds[0].revents = 0;
        fds[1].revents = 0;
        _ = std.posix.poll(&fds, 1000) catch break;

        if (fds[0].revents & std.posix.POLL.IN != 0) drainStdin(bar);
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            if (c.wl_display_dispatch(bar.display) < 0) break;
        }

        if (!bar.stdin_open) fds[0].fd = -1;
        if (fds[1].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
    }
}

pub fn main() void {
    var bar = Bar{};
    bar.display = c.wl_display_connect(null) orelse {
        std.debug.print("bar: cannot connect\n", .{});
        std.process.exit(1);
    };
    defer c.wl_display_disconnect(bar.display);

    const registry = c.wl_display_get_registry(bar.display) orelse {
        std.debug.print("bar: no registry\n", .{});
        std.process.exit(1);
    };
    defer c.wl_registry_destroy(registry);

    if (c.wl_registry_add_listener(registry, &registry_listener, @ptrCast(&bar)) != 0 or
        c.wl_display_roundtrip(bar.display) < 0) {
        std.debug.print("bar: registry failed\n", .{});
        std.process.exit(1);
    }
    if (bar.compositor == null or bar.shm == null or bar.layer_shell == null) {
        std.debug.print("bar: missing globals\n", .{});
        std.process.exit(1);
    }

    if (bar.status_manager) |m| {
        for (0..bar.outputs.len) |i| {
            if (bar.outputs.items[i].proxy) |o| {
                if (c.zriver_status_manager_v1_get_river_output_status(m, o)) |st| {
                    bar.outputs.items[i].owner = &bar;
                    _ = c.zriver_output_status_v1_add_listener(st, &output_status_listener, &bar.outputs.items[i]);
                    bar.outputs.items[i].status = st;
                }
            }
        }
    }

    bar.surface = c.wl_compositor_create_surface(bar.compositor) orelse {
        std.debug.print("bar: no surface\n", .{});
        std.process.exit(1);
    };
    defer c.wl_surface_destroy(bar.surface);

    bar.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        bar.layer_shell,
        bar.surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        "bar",
    ) orelse {
        std.debug.print("bar: no layer surface\n", .{});
        std.process.exit(1);
    };
    defer c.zwlr_layer_surface_v1_destroy(bar.layer_surface);

    if (c.zwlr_layer_surface_v1_add_listener(bar.layer_surface, &layer_listener, @ptrCast(&bar)) != 0) {
        std.debug.print("bar: layer listener failed\n", .{});
        std.process.exit(1);
    }

    c.zwlr_layer_surface_v1_set_anchor(
        bar.layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
    );
    c.zwlr_layer_surface_v1_set_size(bar.layer_surface, 0, bar_h);
    c.zwlr_layer_surface_v1_set_exclusive_zone(bar.layer_surface, @intCast(bar_h));
    c.zwlr_layer_surface_v1_set_keyboard_interactivity(bar.layer_surface, 0);

    _ = c.wl_surface_commit(bar.surface);
    if (c.wl_display_roundtrip(bar.display) < 0 or !bar.configured) {
        std.debug.print("bar: not configured\n", .{});
        std.process.exit(1);
    }

    std.debug.print("bar: ready\n", .{});
    runLoop(&bar);
}