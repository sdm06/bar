//! Bar configuration. This is the only file you should need to edit.
//!
//! Everything here is comptime: there is no runtime config parser and no
//! hidden state. Change a value, run `zig build`, and the change is in the
//! binary with nothing left to interpret at startup.
//!
//! Layout is two groups. `modules` is packed against the left edge in the
//! order given; `right_modules` is packed against the right edge, also in the
//! order given. Within a group the modules are separated by a thin rule sitting
//! in a `padding_h` gap. Order in each list is the order on screen.

const std = @import("std");
const builtin = @import("builtin");

const cfg = @This();

// The generated protocol headers are on the include path already, so the
// layer and anchor names below can be written the way the protocol spells them
// instead of as bare numbers.
const wl = @cImport({
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
});

comptime {
    std.debug.assert(cfg.builtin.os.tag == .linux);
}

// ---------------------------------------------------------------------------
// Font
//
// The font is chosen at build time: `zig build -Dfont=/path/to/font.bdf`.
// Only BDF (the plain text bitmap font format) is understood, so no font
// library is needed. The vendored default is the 9x15 bitmap font dwm falls
// back to.
// ---------------------------------------------------------------------------

/// Row inside the bar that the top of a text cell is drawn at. null means
/// `padding_v`, so module text sits flush in the vertical padding. Raise it to
/// nudge module text down inside the bar.
///
/// The font already carries its own ascent inside the cell, so this is the top
/// of the cell, not the baseline: setting it to `Font.ascent` as well would
/// push every glyph off the bottom of the bar.
pub const text_top: ?u32 = null;

/// Blank columns between cells. 0 gives the font's own advance.
pub const font_spacing: u32 = 0;

/// Pixels above and below the tallest module.
pub const padding_v: u32 = 3;

/// Blank columns at the left and right edge of the bar, and the width of the
/// gap between two modules. A separator rule sits in the middle of each gap,
/// so anything below 3 leaves it touching its neighbours.
pub const padding_h: u32 = 6;

// ---------------------------------------------------------------------------
// Colours, as 0xAARRGGBB
// ---------------------------------------------------------------------------

pub const color = struct {
    pub const background: u32 = 0xff1d2021;
    pub const foreground: u32 = 0xffc5c8c6;
    /// Tag with views on it, not focused.
    pub const occupied: u32 = 0xff7f8c8d;
    /// Tag the focused view is on.
    pub const focused: u32 = 0xff83a598;
    /// Tag asking for attention.
    pub const urgent: u32 = 0xffbf616a;
    /// Separator drawn between modules.
    pub const separator: u32 = 0xff4e5e5e;
    /// Battery below this fraction turns `urgent`.
    pub const battery_low: u32 = 15;
    pub const battery_charging: u32 = 0xffa3be8c;
    /// Scale factor reported by wl_output is clamped to this.
    pub const max_output_scale: u32 = 3;
};

// ---------------------------------------------------------------------------
// Geometry and behaviour
// ---------------------------------------------------------------------------

/// Which output edges the bar sticks to.
pub const anchor: u32 = wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
    wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
    wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

/// background, bottom, top or overlay.
pub const layer: u32 = wl.ZWLR_LAYER_SHELL_V1_LAYER_TOP;
/// Reserve screen space so windows do not cover the bar.
pub const exclusive: bool = true;

/// Seconds between full repaints even when nothing changed. The clock is the
/// only reason a bar ever repaints on its own; set this to 0 to repaint
/// strictly on state changes.
pub const repaint_interval: u32 = 0;

/// Draw the frame to BAR_DUMP as raw ARGB once, for debugging on setups with
/// no screenshot tool.
pub const dump_frame: bool = builtin.mode == .Debug;

// ---------------------------------------------------------------------------
// Modules
//
// Each entry names a module; see `Module` in main.zig. Options are set in the
// module's own `Config` block below. Order is the order on screen within each
// group.
// ---------------------------------------------------------------------------

/// Left-hand group, packed against the left edge.
pub const modules: []const []const u8 = &.{
    "tags",
    "title",
};

/// Right-hand group, packed against the right edge.
pub const right_modules: []const []const u8 = &.{
    "clock",
    "layout",
    "status",
    "cpu",
    "mem",
    "load",
    "battery",
    "brightness",
    "volume",
};

// --- tags ------------------------------------------------------------------

pub const tags = struct {
    /// How many tags river is configured with. Must match `riverctl`/config.
    /// Your river `init` loops `for i = 1, 9`, so this is 9.
    ///
    /// Tags are drawn as the digits '1'..count, so anything above 9 would need
    /// two-digit labels.
    pub const count: u32 = 9;
    /// Show a block per tag, or only tags that have something on them.
    pub const show_empty: bool = true;
    /// Leave a blank column between the tags of each output.
    pub const gap: u32 = 4;
    /// Blank columns between one tag and the next, on top of the glyph cell.
    pub const spacing: u32 = 3;
};

// --- clock -----------------------------------------------------------------

pub const clock = struct {
    /// strftime format. See `man 3 strftime`.
    pub const format: []const u8 = "%a %b %d %H:%M";
    /// Seconds granularity. 0 hides the seconds field.
    pub const seconds: bool = false;
};

// --- title -----------------------------------------------------------------

pub const title = struct {
    /// Characters kept; the middle is elided with `~`.
    pub const max_chars: u32 = 64;
};

// --- status ----------------------------------------------------------------

/// Text piped in on stdin, like dwmblocks/slstatus.
pub const status = struct {
    /// Longest line kept from stdin, in bytes.
    pub const max_bytes: u32 = 256;
    /// Longest partial line buffered before a newline arrives.
    pub const line_bytes: u32 = 1024;
};

// --- cpu / mem / load ------------------------------------------------------
//
// Read straight out of /proc. No slstatus, no shell loop, no fork per update.

pub const cpu = struct {
    /// Seconds between samples.
    pub const interval: u32 = 1;
};

pub const mem = struct {
    pub const interval: u32 = 5;
    /// Show `used/total` in MiB rather than a percentage.
    pub const absolute: bool = false;
};

pub const load = struct {
    pub const interval: u32 = 5;
};

// --- battery ---------------------------------------------------------------

pub const battery = struct {
    pub const interval: u32 = 30;
    /// Glob of the power supply directory to read.
    pub const supply: []const u8 = "BAT*";
};

// --- brightness ------------------------------------------------------------

pub const brightness = struct {
    pub const interval: u32 = 5;
    /// First backlight device under /sys/class/backlight.
    pub const device: []const u8 = "";
};

// --- volume ----------------------------------------------------------------

/// The kernel exposes no audio volume, so this shells out.
pub const volume = struct {
    /// Only a backstop. The volume keys run `wpctl` behind the compositor's
    /// back, so the bar cannot see them happen; the river bindings send it
    /// SIGUSR1 afterwards, which makes it re-poll at once. This interval is
    /// how long a change made any *other* way takes to show up.
    pub const interval: u32 = 1;
    /// Parsed in the bar (see `Cmd.volumePercent`), so this stays a single
    /// process with no shell pipeline around it.
    pub const command: []const u8 = "wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null";
};

// --- anything else ---------------------------------------------------------

/// Escape hatch for modules that have no built-in implementation. Runs
/// `command` through `/bin/sh` and keeps the first line of output.
pub const cmd = struct {
    pub const interval: u32 = 5;
    pub const timeout_ms: u32 = 500;
    /// Registered commands, keyed by the name you put in `modules`.
    pub const commands: []const struct { name: []const u8, command: []const u8 } = &.{
        .{ .name = "uptime", .command = "uptime -p" },
        .{ .name = "kernel", .command = "uname -r" },
        .{ .name = "disk", .command = "df -h / | awk 'NR==2{print $3\"/\"$2\" \"$5}'" },
    };
};

/// Interpret the output of `volume.command`. `wpctl get-volume` answers
/// `Volume: 0.85`, appending `[MUTED]` to the same line when the sink is
/// muted, and that turns into `85%` / `85% muted`. Doing it here rather than in
/// a shell pipeline keeps the poll down to a single process.
pub fn volumePercent(line: []const u8, out: []u8) ?[]const u8 {
    const rest = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, rest, "Volume:")) return null;
    const after = std.mem.trim(u8, rest["Volume:".len..], " \t");

    var it = std.mem.tokenizeAny(u8, after, " \t");
    const num = it.next() orelse return null;
    const frac = std.fmt.parseFloat(f64, num) catch return null;

    // PipeWire allows values above 1.0 when a sink over-amplifies, and the bar
    // only has room for a sane percentage.
    const pct: u32 = @intFromFloat(@round(@max(frac, 0.0) * 100.0));
    const muted = std.mem.indexOf(u8, after, "[MUTED]") != null;
    return std.fmt.bufPrint(out, "{d}%{s}", .{ @min(pct, 100), if (muted) " muted" else "" }) catch null;
}

test "volume output becomes a percentage" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("85%", volumePercent("Volume: 0.85", &buf).?);
    try std.testing.expectEqualStrings("0%", volumePercent("Volume: 0.00", &buf).?);
    try std.testing.expectEqualStrings("100%", volumePercent("Volume: 1.00", &buf).?);
}

test "volume output rounds rather than truncates" {
    var buf: [64]u8 = undefined;
    // The old integer extraction took the "0" of "0.85" and called it 0%.
    try std.testing.expectEqualStrings("5%", volumePercent("Volume: 0.045", &buf).?);
    try std.testing.expectEqualStrings("67%", volumePercent("Volume: 0.666", &buf).?);
}

test "volume output reports mute and clamps over-amplification" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("85% muted", volumePercent("Volume: 0.85 [MUTED]", &buf).?);
    try std.testing.expectEqualStrings("100%", volumePercent("Volume: 1.20", &buf).?);
    try std.testing.expectEqualStrings("0%", volumePercent("Volume: -1", &buf).?);
}

test "volume output rejects anything else" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(volumePercent("", &buf) == null);
    try std.testing.expect(volumePercent("Mute: no", &buf) == null);
    try std.testing.expect(volumePercent("Volume:", &buf) == null);
    try std.testing.expect(volumePercent("Volume: abc", &buf) == null);
}

test "module names are all known" {
    const known = [_][]const u8{
        "tags",    "clock",      "layout",  "title",   "status",         "cpu",
        "mem",     "load",       "battery", "brightness", "volume",
    };
    for (cfg.modules) |name| try checkName(name, &known);
    for (cfg.right_modules) |name| try checkName(name, &known);
}

fn checkName(name: []const u8, known: []const []const u8) !void {
    for (known) |k| {
        if (std.mem.eql(u8, name, k)) return;
    }
    for (cmd.commands) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return;
    }
    std.debug.print("unknown module '{s}'\n", .{name});
    return error.UnknownModule;
}

test "a module is not listed twice" {
    for (cfg.modules, 0..) |a, i| {
        for (cfg.modules, 0..) |b, j| {
            if (i == j or !std.mem.eql(u8, a, b)) continue;
            std.debug.print("'{s}' is in modules twice\n", .{a});
            return error.DuplicateModule;
        }
        for (cfg.right_modules) |b| {
            if (!std.mem.eql(u8, a, b)) continue;
            std.debug.print("'{s}' is in modules and right_modules\n", .{a});
            return error.DuplicateModule;
        }
    }
}

test "layout is sane for the vendored font" {
    std.debug.assert(cfg.anchor != 0);
    std.debug.assert(cfg.padding_v < 32);
    // A gap narrower than this leaves the separator rule touching text.
    std.debug.assert(cfg.padding_h >= 3);
}
