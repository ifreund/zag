// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020-2024 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Output = @This();

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const LockSurface = @import("LockSurface.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.output);

pub const State = struct {
    state: enum {
        /// Powered on and exposed to the window manager
        enabled,
        /// Powered off and exposed to the window manager
        disabled_soft,
        /// Powered off and hidden from the window manager
        disabled_hard,
        /// Corresponding hardware no longer present
        destroying,
    } = .disabled_hard,
    /// Logical coordinate space
    x: i32 = 0,
    /// Logical coordinate space
    y: i32 = 0,
    /// The width/height of modes is in physical pixels, not in the
    /// compositors logical coordinate space.
    mode: union(enum) {
        standard: *wlr.Output.Mode,
        custom: struct {
            width: i32 = 0,
            height: i32 = 0,
            refresh: i32 = 0,
        },
        /// Used before the initial modeset and after the wlr_output is destroyed.
        none,
    } = .none,
    scale: f32 = 1,
    transform: wl.Output.Transform = .normal,
    adaptive_sync: bool = false,
    auto_layout: bool = true,

    /// Width in the logical coordinate space
    pub fn width(state: *const State) i32 {
        const physical: f32 = blk: {
            if (@mod(@intFromEnum(state.transform), 2) == 0) {
                break :blk @floatFromInt(switch (state.mode) {
                    .standard => |mode| mode.width,
                    .custom => |mode| mode.width,
                    .none => 0,
                });
            } else {
                break :blk @floatFromInt(switch (state.mode) {
                    .standard => |mode| mode.height,
                    .custom => |mode| mode.height,
                    .none => 0,
                });
            }
        };
        return @intFromFloat(physical / state.scale);
    }

    /// Height in the logical coordinate space
    pub fn height(state: *const State) i32 {
        const physical: f32 = blk: {
            if (@mod(@intFromEnum(state.transform), 2) == 0) {
                break :blk @floatFromInt(switch (state.mode) {
                    .standard => |mode| mode.height,
                    .custom => |mode| mode.height,
                    .none => 0,
                });
            } else {
                break :blk @floatFromInt(switch (state.mode) {
                    .standard => |mode| mode.width,
                    .custom => |mode| mode.width,
                    .none => 0,
                });
            }
        };
        return @intFromFloat(physical / state.scale);
    }

    pub fn apply(state: *const State, wlr_state: *wlr.Output.State) void {
        wlr_state.setEnabled(state.state == .enabled);
        switch (state.mode) {
            .standard => |mode| wlr_state.setMode(mode),
            .custom => |mode| wlr_state.setCustomMode(mode.width, mode.height, mode.refresh),
            .none => {},
        }
        wlr_state.setScale(state.scale);
        wlr_state.setTransform(state.transform);
        wlr_state.setAdaptiveSyncEnabled(state.adaptive_sync);
    }
};

/// Set to null when the wlr_output is destroyed.
wlr_output: ?*wlr.Output,
scene_output: ?*wlr.SceneOutput,

object: ?*river.OutputV1 = null,

/// Tracks the currently presented frame on the output as it pertains to ext-session-lock.
/// The output is initially considered blanked:
/// If using the DRM backend it will be blanked with the initial modeset.
/// If using the Wayland or X11 backend nothing will be visible until the first frame is rendered.
/// XXX set this to blanked on enabled->disabled transition
lock_render_state: enum {
    /// Submitted an unlocked buffer but the buffer has not yet been presented.
    pending_unlock,
    /// Normal, "unlocked" content may be visible.
    unlocked,
    /// Submitted a blank buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_blank,
    /// A blank buffer has been presented.
    blanked,
    /// Submitted the lock surface buffer but the buffer has not yet been presented.
    /// Normal, "unlocked" content may be visible.
    pending_lock_surface,
    /// The lock surface buffer has been presented.
    lock_surface,
} = .blanked,

/// Set to true if a gamma control client makes a set gamma request.
/// This request is handled while rendering the next frame in handleFrame().
gamma_dirty: bool = false,

/// Root.outputs
link: wl.list.Link,

/// Pending state to be sent to the wm in the next update sequence.
pending: State = .{},
link_pending: wl.list.Link,
/// State sent to the wm in the latest update sequence.
sent: State = .{},
link_sent: wl.list.Link,
/// State applied to the wlr_output and rendered.
current: State = .{},

destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = wl.Listener(*wlr.Output.event.RequestState).init(handleRequestState),
frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = wl.Listener(*wlr.Output.event.Present).init(handlePresent),

pub fn create(wlr_output: *wlr.Output) !void {
    const output = try util.gpa.create(Output);
    errdefer util.gpa.destroy(output);

    {
        const title = try fmt.allocPrintZ(util.gpa, "river - {s}", .{wlr_output.name});
        defer util.gpa.free(title);
        if (wlr_output.isWl()) {
            wlr_output.wlSetTitle(title);
        } else if (wlr.config.has_x11_backend and wlr_output.isX11()) {
            wlr_output.x11SetTitle(title);
        }
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    const scene_output = try server.scene.wlr_scene.createSceneOutput(wlr_output);

    errdefer comptime unreachable;

    output.* = .{
        .wlr_output = wlr_output,
        .scene_output = scene_output,
        .link = undefined,
        .link_pending = undefined,
        .link_sent = undefined,
    };
    wlr_output.data = @intFromPtr(output);

    server.root.outputs.append(output);
    server.wm.pending.outputs.append(output);
    output.link_sent.init();

    wlr_output.events.destroy.add(&output.destroy);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);

    output.pending.state = .enabled;
    if (wlr_output.preferredMode()) |preferred_mode| {
        output.pending.mode = .{ .standard = preferred_mode };
    }

    server.wm.dirtyPending();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);

    log.debug("output '{s}' destroyed", .{wlr_output.name});

    output.link.remove();

    output.destroy.link.remove();
    output.request_state.link.remove();
    output.frame.link.remove();
    output.present.link.remove();

    wlr_output.data = 0;

    output.wlr_output = null;
    output.scene_output = null;
    output.pending.state = .destroying;

    server.wm.dirtyPending();
}

pub fn sendDirty(output: *Output) !void {
    switch (output.pending.state) {
        .enabled, .disabled_soft => {
            const wm_v1 = server.wm.object.?;
            const new = output.object == null;
            const output_v1 = output.object orelse blk: {
                const output_v1 = try river.OutputV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0);
                output.object = output_v1;

                output_v1.setHandler(*Output, handleRequest, null, output);
                wm_v1.sendOutput(output_v1);
                output.link_sent.remove();
                server.wm.sent.outputs.append(output);

                break :blk output_v1;
            };
            errdefer comptime unreachable;

            const pending = &output.pending;
            const sent = &output.sent;

            if (new or pending.width() != sent.width() or pending.height() != sent.height()) {
                output_v1.sendDimensions(pending.width(), pending.height());
            }
            if (new or pending.x != sent.x or pending.y != sent.y) {
                output_v1.sendPosition(pending.x, pending.y);
            }

            output.sent = output.pending;
        },
        .disabled_hard, .destroying => {
            if (output.object) |output_v1| {
                output_v1.sendRemoved();
                output_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
                output.object = null;
            }

            output.link_pending.remove();
            output.link_sent.remove();
            output.link_pending.init();
            output.link_sent.init();

            if (output.pending.state == .destroying) {
                util.gpa.destroy(output);
            }
        },
    }
}

fn handleRequestInert(
    output_v1: *river.OutputV1,
    request: river.OutputV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) output_v1.destroy();
}

fn handleRequest(
    _: *river.OutputV1,
    request: river.OutputV1.Request,
    _: ?*Output,
) void {
    switch (request) {
        .destroy => {}, // XXX send protocol error
    }
}

fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    // The only state currently requested by a wlroots backend is a
    // custom mode as the Wayland/X11 backend window is resized.
    const committed: u32 = @bitCast(event.state.committed);
    const supported: u32 = @bitCast(wlr.Output.State.Fields{ .mode = true });

    if (committed != supported) {
        log.err("backend requested unsupported state {}", .{committed});
        return;
    }

    if (event.state.mode) |mode| {
        output.pending.mode = .{ .standard = mode };
    } else {
        output.pending.mode = .{ .custom = .{
            .width = event.state.custom_mode.width,
            .height = event.state.custom_mode.height,
            .refresh = event.state.custom_mode.refresh,
        } };
    }

    server.wm.dirtyPending();
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);

    // TODO this should probably be retried on failure
    output.renderAndCommit() catch |err| switch (err) {
        error.OutOfMemory => log.err("out of memory", .{}),
        error.CommitFailed => log.err("output commit failed for {s}", .{wlr_output.name}),
    };

    var now: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    output.scene_output.?.sendFrameDone(&now);
}

fn renderAndCommit(output: *Output) !void {
    const wlr_output = output.wlr_output.?;

    var state = wlr.Output.State.init();
    defer state.finish();

    output.current.apply(&state);

    if (output.gamma_dirty) {
        const control = server.root.gamma_control_manager.getControl(wlr_output);
        if (!wlr.GammaControlV1.apply(control, &state)) return error.OutOfMemory;

        if (!wlr_output.testState(&state)) {
            wlr.GammaControlV1.sendFailedAndDestroy(control);
            state.clearGammaLut();
            // If the backend does not support gamma LUTs it will reject any
            // state with the gamma LUT committed bit set even if the state
            // has a null LUT. The wayland backend for example has this behavior.
            state.committed.gamma_lut = false;
        }
    }

    if (!output.scene_output.?.buildState(&state, null)) return error.CommitFailed;

    if (!wlr_output.commitState(&state)) return error.CommitFailed;

    output.gamma_dirty = false;

    const lock_surface_mapped = blk: {
        if (server.lock_manager.lockSurfaceFromOutput(output)) |lock_surface| {
            break :blk lock_surface.wlr_lock_surface.surface.mapped;
        } else {
            break :blk false;
        }
    };

    if (server.lock_manager.state == .locked or
        (server.lock_manager.state == .waiting_for_lock_surfaces and lock_surface_mapped) or
        server.lock_manager.state == .waiting_for_blank)
    {
        assert(!server.scene.normal_tree.node.enabled);
        assert(server.scene.locked_tree.node.enabled);

        switch (server.lock_manager.state) {
            .unlocked => unreachable,
            .locked => switch (output.lock_render_state) {
                .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
                .blanked, .lock_surface => {},
            },
            .waiting_for_blank => {
                if (output.lock_render_state != .blanked) {
                    output.lock_render_state = .pending_blank;
                }
            },
            .waiting_for_lock_surfaces => {
                if (output.lock_render_state != .lock_surface) {
                    output.lock_render_state = .pending_lock_surface;
                }
            },
        }
    } else {
        if (output.lock_render_state != .unlocked) {
            output.lock_render_state = .pending_unlock;
        }
    }
}

fn handlePresent(
    listener: *wl.Listener(*wlr.Output.event.Present),
    event: *wlr.Output.event.Present,
) void {
    const output: *Output = @fieldParentPtr("present", listener);

    if (!event.presented) {
        return;
    }

    switch (output.lock_render_state) {
        .pending_unlock => {
            assert(server.lock_manager.state != .locked);
            output.lock_render_state = .unlocked;
        },
        .unlocked => assert(server.lock_manager.state != .locked),
        .pending_blank, .pending_lock_surface => {
            output.lock_render_state = switch (output.lock_render_state) {
                .pending_blank => .blanked,
                .pending_lock_surface => .lock_surface,
                .pending_unlock, .unlocked, .blanked, .lock_surface => unreachable,
            };

            if (server.lock_manager.state != .locked) {
                server.lock_manager.maybeLock();
            }
        },
        .blanked, .lock_surface => {},
    }
}
