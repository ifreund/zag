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

const Cursor = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const c = @import("c.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Config = @import("Config.zig");
const DragIcon = @import("DragIcon.zig");
const InputDevice = @import("InputDevice.zig");
const LockSurface = @import("LockSurface.zig");
const Output = @import("Output.zig");
const PointerBinding = @import("PointerBinding.zig");
const PointerConstraint = @import("PointerConstraint.zig");
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");
const Tablet = @import("Tablet.zig");
const TabletTool = @import("TabletTool.zig");
const Window = @import("Window.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");

const log = std.log.scoped(.input);

const Mode = union(enum) {
    passthrough,
    /// This mode is entered when a binding is triggered and exited when there
    /// are no longer any buttons pressed.
    ignore,
    down: struct {
        // TODO: To handle the surface with pointer focus being moved during
        // down mode we need to store the starting location of the surface as
        // well and take that into account. This is currently not at all easy
        // to do, but moing to the wlroots scene graph will allow us to fix this.

        // Initial cursor position in layout coordinates
        lx: f64,
        ly: f64,
        // Initial cursor position in surface-local coordinates
        sx: f64,
        sy: f64,
    },
    op: struct {
        /// Window coordinates are stored as i32s as they are in logical pixels.
        /// However, it is possible to move the cursor by a fraction of a
        /// logical pixel and this happens in practice with low dpi, high
        /// polling rate mice. Therefore we must accumulate the current
        /// fractional offset of the mouse to avoid rounding down tiny
        /// motions to 0.
        delta_x: f64 = 0,
        delta_y: f64 = 0,
    },
};

const default_size = 24;

const LayoutPoint = struct {
    lx: f64,
    ly: f64,
};

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

seat: *Seat,
wlr_cursor: *wlr.Cursor,

/// Xcursor manager for the currently configured Xcursor theme.
xcursor_manager: *wlr.XcursorManager,
/// Name of the current Xcursor shape, or null if a client has configured a
/// surface to be used as the cursor shape instead.
xcursor_name: ?[*:0]const u8 = null,

/// The set of currently pressed pointer buttons and the corresponding pointer mapping if any.
pressed: std.AutoHashMapUnmanaged(u32, ?*PointerBinding) = .{},

/// The pointer constraint for the surface that currently has keyboard focus, if any.
/// This constraint is not necessarily active, activation only occurs once the cursor
/// has been moved inside the constraint region.
constraint: ?*PointerConstraint = null,

/// Keeps track of the last known location of all touch points in layout coordinates.
/// This information is necessary for proper touch dnd support if there are multiple touch points.
touch_points: std.AutoHashMapUnmanaged(i32, LayoutPoint) = .{},

request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) =
    wl.Listener(*wlr.Seat.event.RequestSetCursor).init(handleRequestSetCursor),

motion_relative: wl.Listener(*wlr.Pointer.event.Motion) =
    wl.Listener(*wlr.Pointer.event.Motion).init(queueMotionRelative),
motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) =
    wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(queueMotionAbsolute),
button: wl.Listener(*wlr.Pointer.event.Button) =
    wl.Listener(*wlr.Pointer.event.Button).init(queueButton),
axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(queueAxis),
frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(queueFrame),

swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) =
    wl.Listener(*wlr.Pointer.event.SwipeBegin).init(queueSwipeBegin),
swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) =
    wl.Listener(*wlr.Pointer.event.SwipeUpdate).init(queueSwipeUpdate),
swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) =
    wl.Listener(*wlr.Pointer.event.SwipeEnd).init(queueSwipeEnd),

pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) =
    wl.Listener(*wlr.Pointer.event.PinchBegin).init(queuePinchBegin),
pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) =
    wl.Listener(*wlr.Pointer.event.PinchUpdate).init(queuePinchUpdate),
pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) =
    wl.Listener(*wlr.Pointer.event.PinchEnd).init(queuePinchEnd),

touch_down: wl.Listener(*wlr.Touch.event.Down) =
    wl.Listener(*wlr.Touch.event.Down).init(handleTouchDown),
touch_motion: wl.Listener(*wlr.Touch.event.Motion) =
    wl.Listener(*wlr.Touch.event.Motion).init(handleTouchMotion),
touch_up: wl.Listener(*wlr.Touch.event.Up) =
    wl.Listener(*wlr.Touch.event.Up).init(handleTouchUp),
touch_cancel: wl.Listener(*wlr.Touch.event.Cancel) =
    wl.Listener(*wlr.Touch.event.Cancel).init(handleTouchCancel),
touch_frame: wl.Listener(void) = wl.Listener(void).init(handleTouchFrame),

tablet_tool_axis: wl.Listener(*wlr.Tablet.event.Axis) =
    wl.Listener(*wlr.Tablet.event.Axis).init(handleTabletToolAxis),
tablet_tool_proximity: wl.Listener(*wlr.Tablet.event.Proximity) =
    wl.Listener(*wlr.Tablet.event.Proximity).init(handleTabletToolProximity),
tablet_tool_tip: wl.Listener(*wlr.Tablet.event.Tip) =
    wl.Listener(*wlr.Tablet.event.Tip).init(handleTabletToolTip),
tablet_tool_button: wl.Listener(*wlr.Tablet.event.Button) =
    wl.Listener(*wlr.Tablet.event.Button).init(handleTabletToolButton),

pub fn init(cursor: *Cursor, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(server.om.output_layout);

    // This is here so that cursor.xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const xcursor_manager = try wlr.XcursorManager.create(null, default_size);
    errdefer xcursor_manager.destroy();

    cursor.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .xcursor_manager = xcursor_manager,
    };
    try cursor.setTheme(null, null);

    seat.wlr_seat.events.request_set_cursor.add(&cursor.request_set_cursor);

    wlr_cursor.events.motion.add(&cursor.motion_relative);
    wlr_cursor.events.motion_absolute.add(&cursor.motion_absolute);
    wlr_cursor.events.button.add(&cursor.button);
    wlr_cursor.events.axis.add(&cursor.axis);
    wlr_cursor.events.frame.add(&cursor.frame);

    wlr_cursor.events.swipe_begin.add(&cursor.swipe_begin);
    wlr_cursor.events.swipe_update.add(&cursor.swipe_update);
    wlr_cursor.events.swipe_end.add(&cursor.swipe_end);

    wlr_cursor.events.pinch_begin.add(&cursor.pinch_begin);
    wlr_cursor.events.pinch_update.add(&cursor.pinch_update);
    wlr_cursor.events.pinch_end.add(&cursor.pinch_end);

    wlr_cursor.events.touch_down.add(&cursor.touch_down);
    wlr_cursor.events.touch_motion.add(&cursor.touch_motion);
    wlr_cursor.events.touch_up.add(&cursor.touch_up);
    wlr_cursor.events.touch_cancel.add(&cursor.touch_cancel);
    wlr_cursor.events.touch_frame.add(&cursor.touch_frame);

    wlr_cursor.events.tablet_tool_axis.add(&cursor.tablet_tool_axis);
    wlr_cursor.events.tablet_tool_proximity.add(&cursor.tablet_tool_proximity);
    wlr_cursor.events.tablet_tool_tip.add(&cursor.tablet_tool_tip);
    wlr_cursor.events.tablet_tool_button.add(&cursor.tablet_tool_button);
}

pub fn deinit(cursor: *Cursor) void {
    cursor.xcursor_manager.destroy();
    cursor.wlr_cursor.destroy();
    cursor.pressed.deinit(util.gpa);
    cursor.touch_points.deinit(util.gpa);
}

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(cursor: *Cursor, theme: ?[*:0]const u8, _size: ?u32) !void {
    const size = _size orelse default_size;

    const xcursor_manager = try wlr.XcursorManager.create(theme, size);
    errdefer xcursor_manager.destroy();

    // If this cursor belongs to the default seat, set the xcursor environment
    // variables as well as the xwayland cursor theme.
    if (cursor.seat == server.input_manager.defaultSeat()) {
        const size_str = try std.fmt.allocPrintZ(util.gpa, "{}", .{size});
        defer util.gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str.ptr, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;

        if (build_options.xwayland) {
            if (server.xwayland) |xwayland| {
                try xcursor_manager.load(1);
                const wlr_xcursor = xcursor_manager.getXcursor("default", 1).?;
                const image = wlr_xcursor.images[0];
                xwayland.setCursor(
                    image.buffer,
                    image.width * 4,
                    image.width,
                    image.height,
                    @intCast(image.hotspot_x),
                    @intCast(image.hotspot_y),
                );
            }
        }
    }

    // Everything fallible is now done so the the old xcursor_manager can be destroyed.
    cursor.xcursor_manager.destroy();
    cursor.xcursor_manager = xcursor_manager;

    if (cursor.xcursor_name) |name| {
        cursor.setXcursor(name);
    }
}

pub fn setXcursor(cursor: *Cursor, name: [*:0]const u8) void {
    cursor.wlr_cursor.setXcursor(cursor.xcursor_manager, name);
    cursor.xcursor_name = name;
}

fn handleRequestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    // This event is rasied by the seat when a client provides a cursor image
    const cursor: *Cursor = @fieldParentPtr("request_set_cursor", listener);
    const focused_client = cursor.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        log.debug("focused client set cursor", .{});
        cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
        cursor.xcursor_name = null;
    }
}

fn clearFocus(cursor: *Cursor) void {
    cursor.setXcursor("default");
    cursor.seat.wlr_seat.pointerNotifyClearFocus();
}

pub fn startOpPointer(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) constraint.deactivate();
    }

    log.debug("entering cursor mode op", .{});
    cursor.mode = .{ .op = .{} };

    cursor.clearFocus();
}

pub fn endOpPointer(cursor: *Cursor) void {
    if (cursor.pressed.count() == 0) {
        log.debug("entering cursor mode passthrough", .{});
        cursor.mode = .passthrough;
        cursor.updateState();
    } else {
        log.debug("entering cursor mode ignore", .{});
        cursor.mode = .ignore;
    }
}

pub fn processMotionRelative(cursor: *Cursor, event: *const wlr.Pointer.event.Motion) void {
    server.input_manager.relative_pointer_manager.sendRelativeMotion(
        cursor.seat.wlr_seat,
        @as(u64, event.time_msec) * 1000,
        event.delta_x,
        event.delta_y,
        event.unaccel_dx,
        event.unaccel_dy,
    );

    var dx: f64 = event.delta_x;
    var dy: f64 = event.delta_y;

    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) {
            switch (constraint.wlr_constraint.type) {
                .locked => return,
                .confined => constraint.confine(&dx, &dy),
            }
        }
    }

    switch (cursor.mode) {
        .passthrough, .ignore, .down => {
            cursor.wlr_cursor.move(event.device, dx, dy);

            switch (cursor.mode) {
                .passthrough => {
                    cursor.passthrough(event.time_msec);
                },
                .ignore => {},
                .down => |data| {
                    cursor.seat.wlr_seat.pointerNotifyMotion(
                        event.time_msec,
                        data.sx + (cursor.wlr_cursor.x - data.lx),
                        data.sy + (cursor.wlr_cursor.y - data.ly),
                    );
                },
                else => unreachable,
            }

            cursor.updateDragIcons();

            if (cursor.constraint) |constraint| {
                constraint.maybeActivate();
            }
        },
        .op => |*data| {
            dx += data.delta_x;
            dy += data.delta_y;
            data.delta_x = dx - @trunc(dx);
            data.delta_y = dy - @trunc(dy);

            cursor.wlr_cursor.move(event.device, dx, dy);
            cursor.seat.updateOp(@intFromFloat(cursor.wlr_cursor.x), @intFromFloat(cursor.wlr_cursor.y));
        },
    }
}

pub fn processMotionAbsolute(cursor: *Cursor, event: *const wlr.Pointer.event.MotionAbsolute) void {
    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    const dx = lx - cursor.wlr_cursor.x;
    const dy = ly - cursor.wlr_cursor.y;
    cursor.processMotionRelative(&.{
        .device = event.device,
        .time_msec = event.time_msec,
        .delta_x = dx,
        .delta_y = dy,
        .unaccel_dx = dx,
        .unaccel_dy = dy,
    });
}

pub fn processButton(cursor: *Cursor, event: *const wlr.Pointer.event.Button) void {
    if (event.state == .pressed) {
        const result = cursor.pressed.getOrPut(util.gpa, event.button) catch {
            log.err("out of memory", .{});
            return;
        };
        if (result.found_existing) {
            log.err("ignoring duplicate pointer button {d} press", .{event.button});
            return;
        }

        if (cursor.seat.matchPointerBinding(event.button)) |binding| {
            result.value_ptr.* = binding;
            binding.pressed();
            log.debug("entering cursor mode ignore", .{});
            cursor.mode = .ignore;
            cursor.clearFocus();
            return;
        }

        result.value_ptr.* = null;

        switch (cursor.mode) {
            .passthrough => {
                if (server.scene.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |at| {
                    cursor.interact(at);

                    if (at.surface != null) {
                        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                        log.debug("entering cursor mode down", .{});
                        cursor.mode = .{
                            .down = .{
                                .lx = cursor.wlr_cursor.x,
                                .ly = cursor.wlr_cursor.y,
                                .sx = at.sx,
                                .sy = at.sy,
                            },
                        };
                        return;
                    }
                }

                log.debug("entering cursor mode ignore", .{});
                cursor.mode = .ignore;
                cursor.clearFocus();
                return;
            },
            // Pointer focus does not change while in down mode.
            .down => {
                _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            },
            // No client has pointer focus while in ignore/op mode.
            .ignore, .op => {},
        }
    } else {
        assert(event.state == .released);
        const result = cursor.pressed.fetchRemove(event.button);
        if (result) |kv| {
            if (kv.value) |binding| {
                binding.released();
            }

            switch (cursor.mode) {
                .passthrough => unreachable,
                .down, .ignore => {
                    if (cursor.mode == .down) {
                        _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                    }
                    if (cursor.pressed.count() == 0) {
                        log.debug("exiting cursor mode {s}", .{@tagName(cursor.mode)});
                        cursor.mode = .passthrough;
                        cursor.passthrough(event.time_msec);
                    }
                },
                .op => {},
            }
        } else {
            log.err("ignoring duplicate pointer button {d} release", .{event.button});
            return;
        }
    }
}

pub fn processAxis(cursor: *Cursor, event: *const wlr.Pointer.event.Axis) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    cursor.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta * device.config.scroll_factor,
        @intFromFloat(math.clamp(
            @round(@as(f32, @floatFromInt(event.delta_discrete)) * device.config.scroll_factor),
            // It seems that clamping to exactly the bounds of an i32 is insufficient to make the
            // @intFromFloat() call safe due to the max/min i32 not being exactly representable
            // by an f32. Dividing by 2 is a low effort way to ensure the value is in bounds and
            // allow users to set their scroll-factor to inf without crashing river.
            math.minInt(i32) / 2,
            math.maxInt(i32) / 2,
        )),
        event.source,
        event.relative_direction,
    );
}

fn interact(cursor: Cursor, result: Scene.AtResult) void {
    switch (result.data) {
        .window => |window| {
            cursor.seat.pending.window_interaction = window;
            server.wm.dirtyPending();
        },
        .lock_surface => |lock_surface| {
            assert(server.lock_manager.state != .unlocked);
            cursor.seat.focus(.{ .lock_surface = lock_surface });
        },
        .override_redirect => |override_redirect| {
            assert(server.lock_manager.state != .locked);
            override_redirect.focusIfDesired();
        },
    }
}

fn handleTouchDown(
    listener: *wl.Listener(*wlr.Touch.event.Down),
    event: *wlr.Touch.event.Down,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_down", listener);

    cursor.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    cursor.touch_points.putNoClobber(util.gpa, event.touch_id, .{ .lx = lx, .ly = ly }) catch {
        log.err("out of memory", .{});
        return;
    };

    if (server.scene.at(lx, ly)) |result| {
        cursor.interact(result);

        if (result.surface) |surface| {
            _ = cursor.seat.wlr_seat.touchNotifyDown(
                surface,
                event.time_msec,
                event.touch_id,
                result.sx,
                result.sy,
            );
        }
    }
}

fn handleTouchMotion(
    listener: *wl.Listener(*wlr.Touch.event.Motion),
    event: *wlr.Touch.event.Motion,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_motion", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.getPtr(event.touch_id)) |point| {
        cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &point.lx, &point.ly);

        cursor.updateDragIcons();

        if (server.scene.at(point.lx, point.ly)) |result| {
            cursor.seat.wlr_seat.touchNotifyMotion(event.time_msec, event.touch_id, result.sx, result.sy);
        }
    }
}

fn handleTouchUp(
    listener: *wl.Listener(*wlr.Touch.event.Up),
    event: *wlr.Touch.event.Up,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_up", listener);

    cursor.seat.handleActivity();

    if (cursor.touch_points.remove(event.touch_id)) {
        _ = cursor.seat.wlr_seat.touchNotifyUp(event.time_msec, event.touch_id);
    }
}

fn handleTouchCancel(
    listener: *wl.Listener(*wlr.Touch.event.Cancel),
    _: *wlr.Touch.event.Cancel,
) void {
    const cursor: *Cursor = @fieldParentPtr("touch_cancel", listener);

    cursor.seat.handleActivity();

    cursor.touch_points.clearRetainingCapacity();

    const wlr_seat = cursor.seat.wlr_seat;
    while (wlr_seat.touch_state.touch_points.first()) |touch_point| {
        wlr_seat.touchNotifyCancel(touch_point.client);
    }
}

fn handleTouchFrame(listener: *wl.Listener(void)) void {
    const cursor: *Cursor = @fieldParentPtr("touch_frame", listener);

    cursor.seat.handleActivity();

    cursor.seat.wlr_seat.touchNotifyFrame();
}

fn handleTabletToolAxis(
    _: *wl.Listener(*wlr.Tablet.event.Axis),
    event: *wlr.Tablet.event.Axis,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.axis(tablet, event);
}

fn handleTabletToolProximity(
    _: *wl.Listener(*wlr.Tablet.event.Proximity),
    event: *wlr.Tablet.event.Proximity,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.proximity(tablet, event);
}

fn handleTabletToolTip(
    _: *wl.Listener(*wlr.Tablet.event.Tip),
    event: *wlr.Tablet.event.Tip,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.tip(tablet, event);
}

fn handleTabletToolButton(
    _: *wl.Listener(*wlr.Tablet.event.Button),
    event: *wlr.Tablet.event.Button,
) void {
    const device: *InputDevice = @ptrFromInt(event.device.data);
    const tablet: *Tablet = @fieldParentPtr("device", device);

    device.seat.handleActivity();

    const tool = TabletTool.get(device.seat.wlr_seat, event.tool) catch return;

    tool.button(tablet, event);
}

pub fn startResize(cursor: *Cursor, window: *Window, proposed_edges: ?wlr.Edges) void {
    if (cursor.constraint) |constraint| {
        if (constraint.state == .active) constraint.deactivate();
    }

    const edges = blk: {
        if (proposed_edges) |edges| {
            if (edges.top or edges.bottom or edges.left or edges.right) {
                break :blk edges;
            }
        }
        break :blk cursor.computeEdges(window);
    };

    const box = &window.current.box;
    const lx: i32 = @intFromFloat(cursor.wlr_cursor.x);
    const ly: i32 = @intFromFloat(cursor.wlr_cursor.y);
    const offset_x = if (edges.left) lx - box.x else box.x + box.width - lx;
    const offset_y = if (edges.top) ly - box.y else box.y + box.height - ly;

    window.pending.resizing = true;

    const new_mode: Mode = .{ .resize = .{
        .window = window,
        .edges = edges,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .initial_width = @intCast(box.width),
        .initial_height = @intCast(box.height),
    } };
    cursor.enterMode(new_mode, window, wlr.Xcursor.getResizeName(edges));
}

fn computeEdges(cursor: *const Cursor, window: *const Window) wlr.Edges {
    const min_handle_size = 20;
    const box = &window.current.box;

    const sx = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - box.x;
    const sy = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - box.y;

    var edges: wlr.Edges = .{};

    if (box.width > min_handle_size * 2) {
        const handle = @max(min_handle_size, @divFloor(box.width, 5));
        if (sx < handle) {
            edges.left = true;
        } else if (sx > box.width - handle) {
            edges.right = true;
        }
    }

    if (box.height > min_handle_size * 2) {
        const handle = @max(min_handle_size, @divFloor(box.height, 5));
        if (sy < handle) {
            edges.top = true;
        } else if (sy > box.height - handle) {
            edges.bottom = true;
        }
    }

    if (!edges.top and !edges.bottom and !edges.left and !edges.right) {
        return .{ .bottom = true, .right = true };
    } else {
        return edges;
    }
}

pub fn updateState(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        constraint.updateState();
    }

    switch (cursor.mode) {
        .passthrough => {
            var now: posix.timespec = undefined;
            posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
            const msec: u32 = @intCast(now.tv_sec * std.time.ms_per_s +
                @divTrunc(now.tv_nsec, std.time.ns_per_ms));
            cursor.passthrough(msec);
        },
        // TODO: Leave down mode if the target surface is no longer visible.
        .ignore, .down, .op => {},
    }
}

/// Pass an event on to the surface under the cursor, if any.
fn passthrough(cursor: *Cursor, time: u32) void {
    assert(cursor.mode == .passthrough);

    if (server.scene.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
        if (result.data == .lock_surface) {
            assert(server.lock_manager.state != .unlocked);
        } else {
            assert(server.lock_manager.state != .locked);
        }

        if (result.surface) |surface| {
            cursor.seat.wlr_seat.pointerNotifyEnter(surface, result.sx, result.sy);
            cursor.seat.wlr_seat.pointerNotifyMotion(time, result.sx, result.sy);
            return;
        }
    }

    cursor.clearFocus();
}

fn updateDragIcons(cursor: *Cursor) void {
    var it = server.scene.drag_icons.children.iterator(.forward);
    while (it.next()) |node| {
        const icon = @as(*DragIcon, @ptrFromInt(node.data));

        if (icon.wlr_drag_icon.drag.seat == cursor.seat.wlr_seat) {
            icon.updatePosition(cursor);
        }
    }
}

fn queueMotionRelative(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
    const cursor: *Cursor = @fieldParentPtr("motion_relative", listener);
    cursor.seat.queueEvent(.{ .pointer_motion_relative = event.* });
}

fn queueMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
    const cursor: *Cursor = @fieldParentPtr("motion_absolute", listener);
    cursor.seat.queueEvent(.{ .pointer_motion_absolute = event.* });
}

fn queueButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const cursor: *Cursor = @fieldParentPtr("button", listener);
    cursor.seat.queueEvent(.{ .pointer_button = event.* });
}

fn queueAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const cursor: *Cursor = @fieldParentPtr("axis", listener);
    cursor.seat.queueEvent(.{ .pointer_axis = event.* });
}

fn queueFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const cursor: *Cursor = @fieldParentPtr("frame", listener);
    cursor.seat.queueEvent(.pointer_frame);
}

fn queuePinchBegin(listener: *wl.Listener(*wlr.Pointer.event.PinchBegin), event: *wlr.Pointer.event.PinchBegin) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_begin", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_begin = event.* });
}

fn queuePinchUpdate(listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate), event: *wlr.Pointer.event.PinchUpdate) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_update", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_update = event.* });
}

fn queuePinchEnd(listener: *wl.Listener(*wlr.Pointer.event.PinchEnd), event: *wlr.Pointer.event.PinchEnd) void {
    const cursor: *Cursor = @fieldParentPtr("pinch_end", listener);
    cursor.seat.queueEvent(.{ .pointer_pinch_end = event.* });
}

fn queueSwipeBegin(listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin), event: *wlr.Pointer.event.SwipeBegin) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_begin", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_begin = event.* });
}

fn queueSwipeUpdate(listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate), event: *wlr.Pointer.event.SwipeUpdate) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_update", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_update = event.* });
}

fn queueSwipeEnd(listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd), event: *wlr.Pointer.event.SwipeEnd) void {
    const cursor: *Cursor = @fieldParentPtr("swipe_end", listener);
    cursor.seat.queueEvent(.{ .pointer_swipe_end = event.* });
}
