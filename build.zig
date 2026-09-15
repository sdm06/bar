const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol_xml = b.path("protocol/wlr-layer-shell-unstable-v1.xml");

    const scan = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    scan.addFileArg(protocol_xml);
    const header = scan.addOutputFileArg("wlr-layer-shell-unstable-v1-client-protocol.h");

    const codegen = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    codegen.addFileArg(protocol_xml);
    const generated_c = codegen.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.c");

    const river_status_xml = b.path("protocol/river-status-unstable-v1.xml");
    const river_scan = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    river_scan.addFileArg(river_status_xml);
    const river_header = river_scan.addOutputFileArg("river-status-unstable-v1-client-protocol.h");
    const river_codegen = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    river_codegen.addFileArg(river_status_xml);
    const river_generated_c = river_codegen.addOutputFileArg("river-status-unstable-v1-protocol.c");

    const xdg_xml: std.Build.LazyPath = .{ .cwd_relative = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" };
    const xdg_scan = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    xdg_scan.addFileArg(xdg_xml);
    const xdg_header = xdg_scan.addOutputFileArg("xdg-shell-client-protocol.h");
    const xdg_codegen = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    xdg_codegen.addFileArg(xdg_xml);
    const xdg_generated_c = xdg_codegen.addOutputFileArg("xdg-shell-protocol.c");

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addIncludePath(header.dirname());
    root_mod.addIncludePath(xdg_header.dirname());
    root_mod.addIncludePath(river_header.dirname());
    root_mod.addCSourceFile(.{ .file = generated_c, .flags = &.{} });
    root_mod.addCSourceFile(.{ .file = xdg_generated_c, .flags = &.{} });
    root_mod.addCSourceFile(.{ .file = river_generated_c, .flags = &.{} });
    root_mod.linkSystemLibrary("wayland-client", .{});

    const exe = b.addExecutable(.{
        .name = "bar",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the bar");
    run_step.dependOn(&run_cmd.step);
}