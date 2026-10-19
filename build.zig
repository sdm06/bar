const std = @import("std");
const fontc = @import("src/fontc.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const font_path = b.option(
        []const u8,
        "font",
        "BDF bitmap font to build in (default: fonts/X11Misc-Fixed-Medium-R-9x15.bdf)",
    ) orelse "fonts/X11Misc-Fixed-Medium-R-9x15.bdf";
    const font_scale = b.option(
        u8,
        "font-scale",
        "Integer scale applied to the font at build time, 1..4",
    ) orelse 1;
    const font_advance = b.option(
        u16,
        "font-advance",
        "Advance for glyphs with no DWIDTH (0 = use the cell width)",
    ) orelse 0;

    const gen = b.addWriteFiles();

    // The font is compiled here, in the build script, and handed to the bar as
    // an anonymous module. Nothing generated lands in the source tree, so there
    // is no stale checked-in font table to go out of sync with the BDF.
    // `zig build` runs with the build root as its working directory, so a
    // relative -Dfont path and the default both resolve from here.
    const bdf_abs = b.path(font_path).getPath2(b, null);
    const bdf_bytes = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        bdf_abs,
        b.allocator,
        .limited(8 << 20),
    );
    const font = fontc.compile(b.allocator, bdf_bytes, .{
        .scale = font_scale,
        .default_advance = font_advance,
    }) catch |err| {
        std.log.err("cannot compile font '{s}': {s}", .{ font_path, @errorName(err) });
        return err;
    };
    defer fontc.deinit(b.allocator, font);

    const font_zig = gen.add("font.zig", try renderFont(b.allocator, font, font_path, font_scale));


    // ---------------------------------------------------------------------
    // Wayland protocol plumbing
    // ---------------------------------------------------------------------
    const wl_protocol = b.path("protocol/wlr-layer-shell-unstable-v1.xml");
    const river_protocol = b.path("protocol/river-status-unstable-v1.xml");

    // xdg-shell is needed by libwayland's own headers; it is not a real
    // dependency of the bar, so an absolute path outside the tree is used
    // rather than vendoring it.
    const xdg_protocol: std.Build.LazyPath =
        .{ .cwd_relative = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" };

    const wl_header = scan(b, wl_protocol, "wlr-layer-shell-unstable-v1-client-protocol.h");
    const wl_c = scanCode(b, wl_protocol, "wlr-layer-shell-unstable-v1-protocol.c");
    const river_header = scan(b, river_protocol, "river-status-unstable-v1-client-protocol.h");
    const river_c = scanCode(b, river_protocol, "river-status-unstable-v1-protocol.c");
    const xdg_header = scan(b, xdg_protocol, "xdg-shell-client-protocol.h");
    const xdg_c = scanCode(b, xdg_protocol, "xdg-shell-protocol.c");

    // ---------------------------------------------------------------------
    // The bar
    // ---------------------------------------------------------------------
    const bar_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bar_mod.addAnonymousImport("font", .{ .root_source_file = font_zig });
    bar_mod.addIncludePath(wl_header.dirname());
    bar_mod.addIncludePath(river_header.dirname());
    bar_mod.addIncludePath(xdg_header.dirname());
    bar_mod.addCSourceFile(.{ .file = wl_c, .flags = &.{} });
    bar_mod.addCSourceFile(.{ .file = river_c, .flags = &.{} });
    bar_mod.addCSourceFile(.{ .file = xdg_c, .flags = &.{} });
    bar_mod.linkSystemLibrary("wayland-client", .{});

    const bar = b.addExecutable(.{ .name = "bar", .root_module = bar_mod });
    b.installArtifact(bar);

    // config.zig holds the tests. It needs the generated protocol header for
    // the layer/anchor names, and nothing else from the bar.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(wl_header.dirname());
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the config tests");
    test_step.dependOn(&run_tests.step);

    const run_cmd = b.addRunArtifact(bar);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the bar");
    run_step.dependOn(&run_cmd.step);
}

fn scan(b: *std.Build, xml: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    cmd.addFileArg(xml);
    return cmd.addOutputFileArg(name);
}

fn scanCode(b: *std.Build, xml: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    cmd.addFileArg(xml);
    return cmd.addOutputFileArg(name);
}

/// Emit the glyph table as Zig source. The table is flat and pre-scaled so the
/// bar only ever indexes into it.
fn renderFont(
    gpa: std.mem.Allocator,
    font: fontc.Font,
    path: []const u8,
    scale: u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print(
        \\// Generated by build.zig from {s} at scale {d}. Do not edit.
        \\pub const source = "{s}";
        \\pub const scale = {d};
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const ascent: u16 = {d};
        \\pub const first: u21 = {d};
        \\pub const last: u21 = {d};
        \\pub const count: usize = {d};
        \\
        \\pub const advances = [_]u16{{
    , .{
        path,
        scale,
        path,
        scale,
        font.metrics.width,
        font.metrics.height,
        font.metrics.ascent,
        font.first,
        font.last,
        font.count(),
    });

    for (font.advances, 0..) |a, i| {
        if (i % 16 == 0) try w.writeAll("    ");
        try w.print("{d}, ", .{a});
        if (i % 16 == 15) try w.writeAll("\n");
    }
    if (font.count() % 16 != 0) try w.writeAll("\n");
    try w.writeAll("};\n\npub const bitmap = [_]u32{\n");

    for (font.bitmap, 0..) |m, i| {
        if (i % 8 == 0) try w.writeAll("    ");
        try w.print("0x{x:0>8}, ", .{m});
        if (i % 8 == 7) try w.writeAll("\n");
    }
    if (font.bitmap.len % 8 != 0) try w.writeAll("\n");
    try w.writeAll("};\n");

    return out.toOwnedSlice();
}
