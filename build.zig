const std = @import("std");
const assert = std.debug.assert;
const Build = std.Build;
const fs = std.fs;
const mem = std.mem;

const Scanner = @import("deps/zig-wayland/build.zig").Scanner;

/// While a river release is in development, this string should contain the version in development
/// with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "0.3.0-dev";

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    const omit_frame_pointer = switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&.{"scdoc"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    const bash_completion = b.option(
        bool,
        "bash-completion",
        "Set to true to install bash completion for riverctl. Defaults to true.",
    ) orelse true;

    const zsh_completion = b.option(
        bool,
        "zsh-completion",
        "Set to true to install zsh completion for riverctl. Defaults to true.",
    ) orelse true;

    const fish_completion = b.option(
        bool,
        "fish-completion",
        "Set to true to install fish completion for riverctl. Defaults to true.",
    ) orelse true;

    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support",
    ) orelse false;

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.execAllowFail(
                &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .Inherit,
            ) catch break :blk version;

            var it = mem.split(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk b.fmt(version ++ ".{s}+{s}", .{ commit_count, commit_hash[1..] });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);
    options.addOption([]const u8, "version", full_version);

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/tablet/tablet-unstable-v2.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");

    scanner.addCustomProtocol("protocol/river-control-unstable-v1.xml");
    scanner.addCustomProtocol("protocol/river-status-unstable-v1.xml");
    scanner.addCustomProtocol("protocol/river-layout-v3.xml");
    scanner.addCustomProtocol("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addCustomProtocol("protocol/wlr-output-power-management-unstable-v1.xml");

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as river successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thnig that can happen due to a version being too
    // old is that river fails to compile.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);

    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    scanner.generate("zriver_control_v1", 1);
    scanner.generate("zriver_status_manager_v1", 5);
    scanner.generate("river_layout_manager_v3", 2);

    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_output_power_manager_v1", 1);

    const wayland = b.createModule(.{ .source_file = scanner.result });
    const xkbcommon = b.createModule(.{
        .source_file = .{ .path = "deps/zig-xkbcommon/src/xkbcommon.zig" },
    });
    const pixman = b.createModule(.{
        .source_file = .{ .path = "deps/zig-pixman/pixman.zig" },
    });
    const wlroots = b.createModule(.{
        .source_file = .{ .path = "deps/zig-wlroots/src/wlroots.zig" },
        .dependencies = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "xkbcommon", .module = xkbcommon },
            .{ .name = "pixman", .module = pixman },
        },
    });

    const flags = b.createModule(.{ .source_file = .{ .path = "common/flags.zig" } });
    const globber = b.createModule(.{ .source_file = .{ .path = "common/globber.zig" } });

    {
        const river = b.addExecutable(.{
            .name = "river",
            .root_source_file = .{ .path = "river/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        river.addOptions("build_options", options);

        river.linkLibC();
        river.linkSystemLibrary("libevdev");
        river.linkSystemLibrary("libinput");

        river.addModule("wayland", wayland);
        river.linkSystemLibrary("wayland-server");

        river.addModule("xkbcommon", xkbcommon);
        river.linkSystemLibrary("xkbcommon");

        river.addModule("pixman", pixman);
        river.linkSystemLibrary("pixman-1");

        river.addModule("wlroots", wlroots);
        river.linkSystemLibrary("wlroots");

        river.addModule("flags", flags);
        river.addModule("globber", globber);
        river.addCSourceFile(.{
            .file = .{ .path = "river/wlroots_log_wrapper.c" },
            .flags = &.{ "-std=c99", "-O2" },
        });

        // TODO: remove when zig issue #131 is implemented
        scanner.addCSource(river);

        river.strip = strip;
        river.pie = pie;
        river.omit_frame_pointer = omit_frame_pointer;

        b.installArtifact(river);
    }

    {
        const riverctl = b.addExecutable(.{
            .name = "riverctl",
            .root_source_file = .{ .path = "riverctl/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        riverctl.addOptions("build_options", options);

        riverctl.addModule("flags", flags);
        riverctl.addModule("wayland", wayland);
        riverctl.linkLibC();
        riverctl.linkSystemLibrary("wayland-client");

        scanner.addCSource(riverctl);

        riverctl.strip = strip;
        riverctl.pie = pie;
        riverctl.omit_frame_pointer = omit_frame_pointer;

        b.installArtifact(riverctl);
    }

    {
        const rivertile = b.addExecutable(.{
            .name = "rivertile",
            .root_source_file = .{ .path = "rivertile/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        rivertile.addOptions("build_options", options);

        rivertile.addModule("flags", flags);
        rivertile.addModule("wayland", wayland);
        rivertile.linkLibC();
        rivertile.linkSystemLibrary("wayland-client");

        scanner.addCSource(rivertile);

        rivertile.strip = strip;
        rivertile.pie = pie;
        rivertile.omit_frame_pointer = omit_frame_pointer;

        b.installArtifact(rivertile);
    }

    {
        const wf = Build.Step.WriteFile.create(b);
        const pc_file = wf.add("river-protocols.pc", b.fmt(
            \\prefix={s}
            \\datadir=${{prefix}}/share
            \\pkgdatadir=${{datadir}}/river-protocols
            \\
            \\Name: river-protocols
            \\URL: https://github.com/riverwm/river
            \\Description: protocol files for the river wayland compositor
            \\Version: {s}
        , .{ b.install_prefix, full_version }));

        b.installFile("protocol/river-layout-v3.xml", "share/river-protocols/river-layout-v3.xml");
        b.getInstallStep().dependOn(&b.addInstallFile(pc_file, "share/pkgconfig/river-protocols.pc").step);
    }

    if (man_pages) {
        inline for (.{ "river", "riverctl", "rivertile" }) |page| {
            // Workaround for https://github.com/ziglang/zig/issues/16369
            // Even passing a buffer to std.Build.Step.Run appears to be racy and occasionally deadlocks.
            const scdoc = b.addSystemCommand(&.{ "/bin/sh", "-c", "scdoc < doc/" ++ page ++ ".1.scd" });
            // This makes the caching work for the Workaround, and the extra argument is ignored by /bin/sh.
            scdoc.addFileArg(.{ .path = "doc/" ++ page ++ ".1.scd" });

            const stdout = scdoc.captureStdOut();
            b.getInstallStep().dependOn(&b.addInstallFile(stdout, "share/man/man1/" ++ page ++ ".1").step);
        }
    }

    if (bash_completion) {
        b.installFile("completions/bash/riverctl", "share/bash-completion/completions/riverctl");
    }

    if (zsh_completion) {
        b.installFile("completions/zsh/_riverctl", "share/zsh/site-functions/_riverctl");
    }

    if (fish_completion) {
        b.installFile("completions/fish/riverctl.fish", "share/fish/vendor_completions.d/riverctl.fish");
    }

    {
        const globber_test = b.addTest(.{
            .root_source_file = .{ .path = "common/globber.zig" },
            .target = target,
            .optimize = optimize,
        });
        const run_globber_test = b.addRunArtifact(globber_test);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&run_globber_test.step);
    }
}
