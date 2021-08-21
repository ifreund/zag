const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const zbs = std.build;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

/// While a river release is in development, this string should contain the version in development
/// with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "0.1.0-dev";

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support",
    ) orelse false;

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&[_][]const u8{"scdoc"}, &[_][]const u8{}) catch |err| switch (err) {
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

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;
            const git_dir = try fs.path.join(b.allocator, &[_][]const u8{ b.build_root, ".git" });
            const git_commit_hash = b.execAllowFail(
                &[_][]const u8{ "git", "--git-dir", git_dir, "--work-tree", b.build_root, "rev-parse", "--short", "HEAD" },
                &ret,
                .Inherit,
            ) catch break :blk version;
            break :blk try std.fmt.allocPrintZ(b.allocator, "{s}-{s}", .{ version, git_commit_hash });
        } else {
            break :blk version;
        }
    };

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-foreign-toplevel-management-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-control-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-status-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-layout-v3.xml");
    scanner.addProtocolPath("protocol/river-toplevel-v1.xml");
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-output-power-management-unstable-v1.xml");

    {
        const river = b.addExecutable("river", "river/main.zig");
        river.setTarget(target);
        river.setBuildMode(mode);
        river.addBuildOption(bool, "xwayland", xwayland);
        river.addBuildOption([:0]const u8, "version", full_version);

        addServerDeps(river, scanner);

        river.install();
    }

    {
        const riverctl = b.addExecutable("riverctl", "riverctl/main.zig");
        riverctl.setTarget(target);
        riverctl.setBuildMode(mode);
        riverctl.addBuildOption([:0]const u8, "version", full_version);

        riverctl.step.dependOn(&scanner.step);
        riverctl.addPackage(scanner.getPkg());
        riverctl.addPackagePath("flags", "common/flags.zig");
        riverctl.linkLibC();
        riverctl.linkSystemLibrary("wayland-client");

        scanner.addCSource(riverctl);

        riverctl.install();
    }

    {
        const rivertile = b.addExecutable("rivertile", "rivertile/main.zig");
        rivertile.setTarget(target);
        rivertile.setBuildMode(mode);
        rivertile.addBuildOption([:0]const u8, "version", full_version);

        rivertile.step.dependOn(&scanner.step);
        rivertile.addPackage(scanner.getPkg());
        rivertile.addPackagePath("flags", "common/flags.zig");
        rivertile.linkLibC();
        rivertile.linkSystemLibrary("wayland-client");

        scanner.addCSource(rivertile);

        rivertile.install();
    }

    {
        const file = try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "river-protocols.pc" });
        const pkgconfig_file = try std.fs.cwd().createFile(file, .{});

        const writer = pkgconfig_file.writer();
        try writer.print(
            \\prefix={s}
            \\datadir=${{prefix}}/share
            \\pkgdatadir=${{datadir}}/river-protocols
            \\
            \\Name: river-protocols
            \\URL: https://github.com/ifreund/river
            \\Description: protocol files for the river wayland compositor
            \\Version: {s}
        , .{ b.install_prefix, full_version });
        defer pkgconfig_file.close();

        b.installFile("protocol/river-layout-v3.xml", "share/river-protocols/river-layout-v3.xml");
        b.installFile(file, "share/pkgconfig/river-protocols.pc");
    }

    if (man_pages) {
        const scdoc_step = ScdocStep.create(b);
        try scdoc_step.install();
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
        const river_test = b.addTest("river/test_main.zig");
        river_test.setTarget(target);
        river_test.setBuildMode(mode);
        river_test.addBuildOption(bool, "xwayland", xwayland);

        addServerDeps(river_test, scanner);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&river_test.step);
    }
}

fn addServerDeps(exe: *zbs.LibExeObjStep, scanner: *ScanProtocolsStep) void {
    const wayland = scanner.getPkg();
    const xkbcommon = zbs.Pkg{ .name = "xkbcommon", .path = "deps/zig-xkbcommon/src/xkbcommon.zig" };
    const pixman = zbs.Pkg{ .name = "pixman", .path = "deps/zig-pixman/pixman.zig" };
    const wlroots = zbs.Pkg{
        .name = "wlroots",
        .path = "deps/zig-wlroots/src/wlroots.zig",
        .dependencies = &[_]zbs.Pkg{ wayland, xkbcommon, pixman },
    };

    exe.step.dependOn(&scanner.step);

    exe.linkLibC();
    exe.linkSystemLibrary("libevdev");
    exe.linkSystemLibrary("libinput");

    exe.addPackage(wayland);
    exe.linkSystemLibrary("wayland-server");

    exe.addPackage(xkbcommon);
    exe.linkSystemLibrary("xkbcommon");

    exe.addPackage(pixman);
    exe.linkSystemLibrary("pixman-1");

    exe.addPackage(wlroots);
    exe.linkSystemLibrary("wlroots");

    exe.addPackagePath("flags", "common/flags.zig");
    exe.addCSourceFile("river/wlroots_log_wrapper.c", &[_][]const u8{ "-std=c99", "-O2" });

    // TODO: remove when zig issue #131 is implemented
    scanner.addCSource(exe);
}

const ScdocStep = struct {
    const scd_paths = [_][]const u8{
        "doc/river.1.scd",
        "doc/riverctl.1.scd",
        "doc/rivertile.1.scd",
    };

    builder: *zbs.Builder,
    step: zbs.Step,

    fn create(builder: *zbs.Builder) *ScdocStep {
        const self = builder.allocator.create(ScdocStep) catch @panic("out of memory");
        self.* = init(builder);
        return self;
    }

    fn init(builder: *zbs.Builder) ScdocStep {
        return ScdocStep{
            .builder = builder,
            .step = zbs.Step.init(.Custom, "Generate man pages", builder.allocator, make),
        };
    }

    fn make(step: *zbs.Step) !void {
        const self = @fieldParentPtr(ScdocStep, "step", step);
        for (scd_paths) |path| {
            const command = try std.fmt.allocPrint(
                self.builder.allocator,
                "scdoc < {s} > {s}",
                .{ path, path[0..(path.len - 4)] },
            );
            _ = try self.builder.exec(&[_][]const u8{ "sh", "-c", command });
        }
    }

    fn install(self: *ScdocStep) !void {
        self.builder.getInstallStep().dependOn(&self.step);

        for (scd_paths) |path| {
            const path_no_ext = path[0..(path.len - 4)];
            const basename_no_ext = fs.path.basename(path_no_ext);
            const section = path_no_ext[(path_no_ext.len - 1)..];

            const output = try std.fmt.allocPrint(
                self.builder.allocator,
                "share/man/man{s}/{s}",
                .{ section, basename_no_ext },
            );

            self.builder.installFile(path_no_ext, output);
        }
    }
};
