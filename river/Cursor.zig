// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const math = std.math;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const c = @import("c.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const Config = @import("Config.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

pub const ResizeDirection = enum {
    top,
    right,
    bottom,
    left,
    topleft,
    topright,
    botleft,
    botright,

    /// Returns the resize direction that makes the most sense based on the
    /// position of the cursor on the current surface.
    pub fn fromCursorPosition(cursor: *Self, view: *View) ResizeDirection {
        const cur_box = &view.current.box;
        const pointer_surface_x = @floatToInt(i32, cursor.wlr_cursor.x) - cur_box.x;
        const pointer_surface_y = @floatToInt(i32, cursor.wlr_cursor.y) - cur_box.y;

        const Position = enum {
            start, // top or left
            center,
            end, // bottom or right

            /// Arbitrary size of resize "handle" area. Must be smaller than
            /// View.min_size / 2, as otherwise an integer underflow can occur.
            const area_size = 20;

            fn fromCoords(pos: i32, size: u32) @This() {
                assert(2 * area_size < size);
                if (pos < area_size) return .start;
                if (pos > size - area_size) return .end;
                return .center;
            }
        };

        const horizontal = Position.fromCoords(pointer_surface_x, cur_box.width);
        const vertical = Position.fromCoords(pointer_surface_y, cur_box.height);

        // The compiler complains when returning on outer switch...
        switch (horizontal) {
            .start => return switch (vertical) {
                .start => .topleft,
                .center => .left,
                .end => .botleft,
            },
            .center => return switch (vertical) {
                .start => .top,
                .center => .botright, // the center should not be a dead-zone
                .end => .bottom,
            },
            .end => return switch (vertical) {
                .start => .topright,
                .center => .right,
                .end => .botright,
            },
        }
    }

    /// Tries to convert wlr.Edges to ResizeDirection.
    pub fn fromWlrEdges(edges: wlr.Edges) !ResizeDirection {
        // Only two edges may be active at max and they must not be opposing.
        if (edges.top and edges.bottom) return error.InvalidEdges;
        if (edges.right and edges.left) return error.InvalidEdges;

        if (edges.top) {
            if (edges.right) return .topright;
            if (edges.left) return .topleft;
            return .top;
        }

        if (edges.bottom) {
            if (edges.right) return .botright;
            if (edges.left) return .botleft;
            return .bottom;
        }

        if (edges.right) return .right;

        if (edges.left) return .left;

        return error.InvalidEdges;
    }

    /// Return the canonical name of the cursor belonging the the resize
    /// operation corresponding to the resize direction. The return value is a
    /// NULL terminated string, since the return of this function will only ever
    /// be used when calling functions from C libraries.
    pub fn cursorNameZ(self: ResizeDirection) [*:0]const u8 {
        return switch (self) {
            .top => "n-resize",
            .right => "e-resize",
            .bottom => "s-resize",
            .left => "w-resize",
            .topleft => "nw-resize",
            .topright => "ne-resize",
            .botleft => "sw-resize",
            .botright => "se-resize",
        };
    }
};

const Mode = union(enum) {
    passthrough: void,
    down: *View,
    move: *View,
    resize: struct {
        view: *View,
        resize_direction: ResizeDirection,

        /// The distance between cursor and the nearest corner or edge.
        offset_x: i32,
        offset_y: i32,
    },
};

const default_size = 24;

const log = std.log.scoped(.cursor);

/// Current cursor mode as well as any state needed to implement that mode
mode: Mode = .passthrough,

seat: *Seat,
wlr_cursor: *wlr.Cursor,
pointer_gestures: *wlr.PointerGesturesV1,
xcursor_manager: *wlr.XcursorManager,

constraint: ?*wlr.PointerConstraintV1 = null,

/// Number of distinct buttons currently pressed
pressed_count: u32 = 0,

axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(handleAxis),
frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(handleFrame),
button: wl.Listener(*wlr.Pointer.event.Button) =
    wl.Listener(*wlr.Pointer.event.Button).init(handleButton),
motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) =
    wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(handleMotionAbsolute),
motion: wl.Listener(*wlr.Pointer.event.Motion) =
    wl.Listener(*wlr.Pointer.event.Motion).init(handleMotion),
pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) =
    wl.Listener(*wlr.Pointer.event.PinchBegin).init(handlePinchBegin),
pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) =
    wl.Listener(*wlr.Pointer.event.PinchUpdate).init(handlePinchUpdate),
pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) =
    wl.Listener(*wlr.Pointer.event.PinchEnd).init(handlePinchEnd),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) =
    wl.Listener(*wlr.Seat.event.RequestSetCursor).init(handleRequestSetCursor),
swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) =
    wl.Listener(*wlr.Pointer.event.SwipeBegin).init(handleSwipeBegin),
swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) =
    wl.Listener(*wlr.Pointer.event.SwipeUpdate).init(handleSwipeUpdate),
swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) =
    wl.Listener(*wlr.Pointer.event.SwipeEnd).init(handleSwipeEnd),

pub fn init(self: *Self, seat: *Seat) !void {
    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();
    wlr_cursor.attachOutputLayout(server.root.output_layout);

    // This is here so that self.xcursor_manager doesn't need to be an
    // optional pointer. This isn't optimal as it does a needless allocation,
    // but this is not a hot path.
    const xcursor_manager = try wlr.XcursorManager.create(null, default_size);
    errdefer xcursor_manager.destroy();

    self.* = .{
        .seat = seat,
        .wlr_cursor = wlr_cursor,
        .pointer_gestures = try wlr.PointerGesturesV1.create(server.wl_server),
        .xcursor_manager = xcursor_manager,
    };
    try self.setTheme(null, null);

    // wlr_cursor *only* displays an image on screen. It does not move around
    // when the pointer moves. However, we can attach input devices to it, and
    // it will generate aggregate events for all of them. In these events, we
    // can choose how we want to process them, forwarding them to clients and
    // moving the cursor around. See following post for more detail:
    // https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html
    wlr_cursor.events.axis.add(&self.axis);
    wlr_cursor.events.button.add(&self.button);
    wlr_cursor.events.frame.add(&self.frame);
    wlr_cursor.events.motion_absolute.add(&self.motion_absolute);
    wlr_cursor.events.motion.add(&self.motion);
    wlr_cursor.events.swipe_begin.add(&self.swipe_begin);
    wlr_cursor.events.swipe_update.add(&self.swipe_update);
    wlr_cursor.events.swipe_end.add(&self.swipe_end);
    wlr_cursor.events.pinch_begin.add(&self.pinch_begin);
    wlr_cursor.events.pinch_update.add(&self.pinch_update);
    wlr_cursor.events.pinch_end.add(&self.pinch_end);
    seat.wlr_seat.events.request_set_cursor.add(&self.request_set_cursor);
}

pub fn deinit(self: *Self) void {
    self.xcursor_manager.destroy();
    self.wlr_cursor.destroy();
}

/// Set the cursor theme for the given seat, as well as the xwayland theme if
/// this is the default seat. Either argument may be null, in which case a
/// default will be used.
pub fn setTheme(self: *Self, theme: ?[*:0]const u8, _size: ?u32) !void {
    const size = _size orelse default_size;

    self.xcursor_manager.destroy();
    self.xcursor_manager = try wlr.XcursorManager.create(theme, size);

    // For each output, ensure a theme of the proper scale is loaded
    var it = server.root.outputs.first;
    while (it) |node| : (it = node.next) {
        const wlr_output = node.data.wlr_output;
        self.xcursor_manager.load(wlr_output.scale) catch
            log.err("failed to load xcursor theme '{s}' at scale {}", .{ theme, wlr_output.scale });
    }

    // If this cursor belongs to the default seat, set the xcursor environment
    // variables and the xwayland cursor theme.
    if (self.seat == server.input_manager.defaultSeat()) {
        const size_str = try std.fmt.allocPrint0(util.gpa, "{}", .{size});
        defer util.gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;

        if (build_options.xwayland) {
            self.xcursor_manager.load(1) catch {
                log.err("failed to load xcursor theme '{s}' at scale 1", .{theme});
                return;
            };
            const wlr_xcursor = self.xcursor_manager.getXcursor("left_ptr", 1).?;
            const image = wlr_xcursor.images[0];
            server.xwayland.setCursor(
                image.buffer,
                image.width * 4,
                image.width,
                image.height,
                @intCast(i32, image.hotspot_x),
                @intCast(i32, image.hotspot_y),
            );
        }
    }
}

pub fn handleViewUnmap(self: *Self, view: *View) void {
    if (switch (self.mode) {
        .passthrough => false,
        .down => |target_view| target_view == view,
        .move => |target_view| target_view == view,
        .resize => |data| data.view == view,
    }) {
        self.mode = .passthrough;
        self.clearFocus();
    }
}

fn clearFocus(self: Self) void {
    self.xcursor_manager.setCursorImage("left_ptr", self.wlr_cursor);
    self.seat.wlr_seat.pointerNotifyClearFocus();
}

/// Axis event is a scroll wheel or similiar
fn handleAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const self = @fieldParentPtr(Self, "axis", listener);

    self.seat.handleActivity();

    // Notify the client with pointer focus of the axis event.
    self.seat.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
    );
}

fn handleButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const self = @fieldParentPtr(Self, "button", listener);

    self.seat.handleActivity();

    if (event.state == .pressed) {
        self.pressed_count += 1;
    } else {
        assert(self.pressed_count > 0);
        self.pressed_count -= 1;
        if (self.pressed_count == 0 and self.mode != .passthrough) {
            self.leaveMode(event);
            return;
        }
    }

    if (self.surfaceAt()) |result| {
        switch (result.parent) {
            .view => |view| {
                // If a view has been clicked on, give that view keyboard focus and
                // perhaps enter move/resize mode.
                if (event.state == .pressed and self.pressed_count == 1) {
                    // If there is an active mapping for this button which is
                    // handled we are done here
                    if (self.handlePointerMapping(event, view)) return;
                    // Otherwise enter cursor down mode, giving keyboard focus
                    self.enterMode(.down, view, null);
                }
            },
            .layer_surface => |layer_surface| {
                // If a keyboard inteactive layer surface has been clicked on,
                // give it keyboard focus.
                if (layer_surface.wlr_layer_surface.current.keyboard_interactive == .exclusive) {
                    self.seat.focusOutput(layer_surface.output);
                    self.seat.setFocusRaw(.{ .layer = layer_surface });
                }
            },
        }
        _ = self.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    }
}

fn handlePinchBegin(
    listener: *wl.Listener(*wlr.Pointer.event.PinchBegin),
    event: *wlr.Pointer.event.PinchBegin,
) void {
    const self = @fieldParentPtr(Self, "pinch_begin", listener);
    self.pointer_gestures.sendPinchBegin(
        self.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handlePinchUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.PinchUpdate),
    event: *wlr.Pointer.event.PinchUpdate,
) void {
    const self = @fieldParentPtr(Self, "pinch_update", listener);
    self.pointer_gestures.sendPinchUpdate(
        self.seat.wlr_seat,
        event.time_msec,
        event.dx,
        event.dy,
        event.scale,
        event.rotation,
    );
}

fn handlePinchEnd(
    listener: *wl.Listener(*wlr.Pointer.event.PinchEnd),
    event: *wlr.Pointer.event.PinchEnd,
) void {
    const self = @fieldParentPtr(Self, "pinch_end", listener);
    self.pointer_gestures.sendPinchEnd(
        self.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

fn handleSwipeBegin(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeBegin),
    event: *wlr.Pointer.event.SwipeBegin,
) void {
    const self = @fieldParentPtr(Self, "swipe_begin", listener);
    self.pointer_gestures.sendSwipeBegin(
        self.seat.wlr_seat,
        event.time_msec,
        event.fingers,
    );
}

fn handleSwipeUpdate(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeUpdate),
    event: *wlr.Pointer.event.SwipeUpdate,
) void {
    const self = @fieldParentPtr(Self, "swipe_update", listener);
    self.pointer_gestures.sendSwipeUpdate(
        self.seat.wlr_seat,
        event.time_msec,
        event.dx,
        event.dy,
    );
}

fn handleSwipeEnd(
    listener: *wl.Listener(*wlr.Pointer.event.SwipeEnd),
    event: *wlr.Pointer.event.SwipeEnd,
) void {
    const self = @fieldParentPtr(Self, "swipe_end", listener);
    self.pointer_gestures.sendSwipeEnd(
        self.seat.wlr_seat,
        event.time_msec,
        event.cancelled,
    );
}

/// Handle the mapping for the passed button if any. Returns true if there
/// was a mapping and the button was handled.
fn handlePointerMapping(self: *Self, event: *wlr.Pointer.event.Button, view: *View) bool {
    const wlr_keyboard = self.seat.wlr_seat.getKeyboard() orelse return false;
    const modifiers = wlr_keyboard.getModifiers();

    const fullscreen = view.current.fullscreen or view.pending.fullscreen;

    return for (server.config.modes.items[self.seat.mode_id].pointer_mappings.items) |mapping| {
        if (event.button == mapping.event_code and std.meta.eql(modifiers, mapping.modifiers)) {
            switch (mapping.action) {
                .move => if (!fullscreen) self.enterMode(.move, view, null),
                .resize => if (!fullscreen) self.enterMode(
                    .resize,
                    view,
                    ResizeDirection.fromCursorPosition(self, view),
                ),
            }
            break true;
        }
    } else false;
}

/// Frame events are sent after regular pointer events to group multiple
/// events together. For instance, two axis events may happen at the same
/// time, in which case a frame event won't be sent in between.
fn handleFrame(listener: *wl.Listener(*wlr.Cursor), wlr_cursor: *wlr.Cursor) void {
    const self = @fieldParentPtr(Self, "frame", listener);
    self.seat.wlr_seat.pointerNotifyFrame();
}

/// This event is forwarded by the cursor when a pointer emits an _absolute_
/// motion event, from 0..1 on each axis. This happens, for example, when
/// wlroots is running under a Wayland window rather than KMS+DRM, and you
/// move the mouse over the window. You could enter the window from any edge,
/// so we have to warp the mouse there. There is also some hardware which
/// emits these events.
fn handleMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const self = @fieldParentPtr(Self, "motion_absolute", listener);

    self.seat.handleActivity();

    var lx: f64 = undefined;
    var ly: f64 = undefined;
    self.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

    const dx = lx - self.wlr_cursor.x;
    const dy = ly - self.wlr_cursor.y;
    self.processMotion(event.device, event.time_msec, dx, dy, dx, dy);
}

/// This event is forwarded by the cursor when a pointer emits a _relative_
/// pointer motion event (i.e. a delta)
fn handleMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const self = @fieldParentPtr(Self, "motion", listener);

    self.seat.handleActivity();

    self.processMotion(event.device, event.time_msec, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
}

fn handleRequestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    // This event is rasied by the seat when a client provides a cursor image
    const self = @fieldParentPtr(Self, "request_set_cursor", listener);
    const focused_client = self.seat.wlr_seat.pointer_state.focused_client;

    // This can be sent by any client, so we check to make sure this one is
    // actually has pointer focus first.
    if (focused_client == event.seat_client) {
        // Once we've vetted the client, we can tell the cursor to use the
        // provided surface as the cursor image. It will set the hardware cursor
        // on the output that it's currently on and continue to do so as the
        // cursor moves between outputs.
        log.debug("focused client set cursor", .{});
        self.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

const SurfaceAtResult = struct {
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
    parent: union(enum) {
        view: *View,
        layer_surface: *LayerSurface,
    },
};

/// Find the surface under the cursor if any, and return information about that
/// surface and the cursor's position in surface local coords.
/// This function must be kept in sync with the rendering order in render.zig.
pub fn surfaceAt(self: Self) ?SurfaceAtResult {
    const lx = self.wlr_cursor.x;
    const ly = self.wlr_cursor.y;
    const wlr_output = server.root.output_layout.outputAt(lx, ly) orelse return null;
    const output = @intToPtr(*Output, wlr_output.data);

    // Get output-local coords from the layout coords
    var ox = lx;
    var oy = ly;
    server.root.output_layout.outputCoords(wlr_output, &ox, &oy);

    // Find the first visible fullscreen view in the stack if there is one
    var it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    const fullscreen_view = while (it.next()) |view| {
        if (view.current.fullscreen) break view;
    } else null;

    // Check surfaces in the reverse order they are rendered in:
    //
    // fullscreen:
    //  1. overlay layer toplevels and popups
    //  2. xwayland unmanaged stuff
    //  3. fullscreen view toplevels and popups
    //
    // non-fullscreen:
    //  1. overlay layer toplevels and popups
    //  2. top, bottom, background layer popups
    //  3. top layer toplevels
    //  4. xwayland unmanaged stuff
    //  5. view toplevels and popups
    //  6. bottom, background layer toplevels

    if (layerSurfaceAt(output.getLayer(.overlay).*, ox, oy)) |s| return s;

    if (fullscreen_view) |view| {
        //if (build_options.xwayland) if (xwaylandUnmanagedSurfaceAt(ly, lx)) |s| return s;
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (view.surfaceAt(ox, oy, &sx, &sy)) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .view = view },
            };
        }
    } else {
        for ([_]zwlr.LayerShellV1.Layer{ .top, .bottom, .background }) |layer| {
            if (layerPopupSurfaceAt(output.getLayer(layer).*, ox, oy)) |s| return s;
        }

        if (layerSurfaceAt(output.getLayer(.top).*, ox, oy)) |s| return s;

        //if (build_options.xwayland) if (xwaylandUnmanagedSurfaceAt(lx, ly)) |s| return s;

        if (viewSurfaceAt(output, ox, oy)) |s| return s;

        for ([_]zwlr.LayerShellV1.Layer{ .bottom, .background }) |layer| {
            if (layerSurfaceAt(output.getLayer(layer).*, ox, oy)) |s| return s;
        }
    }

    return null;
}

/// Find the topmost popup surface on the given layer at ox,oy.
fn layerPopupSurfaceAt(layer: std.TailQueue(LayerSurface), ox: f64, oy: f64) ?SurfaceAtResult {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (layer_surface.wlr_layer_surface.popupSurfaceAt(
            ox - @intToFloat(f64, layer_surface.box.x),
            oy - @intToFloat(f64, layer_surface.box.y),
            &sx,
            &sy,
        )) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .layer_surface = layer_surface },
            };
        }
    }
    return null;
}

/// Find the topmost surface (or popup surface) on the given layer at ox,oy.
fn layerSurfaceAt(layer: std.TailQueue(LayerSurface), ox: f64, oy: f64) ?SurfaceAtResult {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (layer_surface.wlr_layer_surface.surfaceAt(
            ox - @intToFloat(f64, layer_surface.box.x),
            oy - @intToFloat(f64, layer_surface.box.y),
            &sx,
            &sy,
        )) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .layer_surface = layer_surface },
            };
        }
    }
    return null;
}

/// Find the topmost visible view surface (incl. popups) at ox,oy.
fn viewSurfaceAt(output: *const Output, ox: f64, oy: f64) ?SurfaceAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;

    // focused, floating views
    var it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.current.focus == 0 or !view.current.float) continue;
        if (view.surfaceAt(ox, oy, &sx, &sy)) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .view = view },
            };
        }
    }

    // non-focused, floating views
    it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.current.focus != 0 or !view.current.float) continue;
        if (view.surfaceAt(ox, oy, &sx, &sy)) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .view = view },
            };
        }
    }

    // focused, non-floating views
    it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.current.focus == 0 or view.current.float) continue;
        if (view.surfaceAt(ox, oy, &sx, &sy)) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .view = view },
            };
        }
    }

    // non-focused, non-floating views
    it = ViewStack(View).iter(output.views.first, .forward, output.current.tags, surfaceAtFilter);
    while (it.next()) |view| {
        if (view.current.focus != 0 or view.current.float) continue;
        if (view.surfaceAt(ox, oy, &sx, &sy)) |found| {
            return SurfaceAtResult{
                .surface = found,
                .sx = sx,
                .sy = sy,
                .parent = .{ .view = view },
            };
        }
    }

    return null;
}

fn xwaylandUnmanagedSurfaceAt(lx: f64, ly: f64) ?*wlr.Surface {
    var it = server.root.xwayland_unmanaged_views.first;
    while (it) |node| : (it = node.next) {
        const xwayland_surface = node.data.xwayland_surface;
        if (xwayland_surface.surface.?.surfaceAt(
            lx - @intToFloat(f64, xwayland_surface.x),
            ly - @intToFloat(f64, xwayland_surface.y),
            sx,
            sy,
        )) |found| return found;
    }
    return null;
}

fn surfaceAtFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and view.current.tags & filter_tags != 0;
}

pub fn enterMode(self: *Self, mode: std.meta.Tag((Mode)), view: *View, resize_direction: ?ResizeDirection) void {
    log.debug("enter {s} cursor mode", .{@tagName(mode)});

    self.seat.focus(view);

    switch (mode) {
        .passthrough => unreachable,
        .down => {
            self.mode = .{ .down = view };
            server.root.startTransaction();
        },
        .move, .resize => {
            switch (mode) {
                .passthrough, .down => unreachable,
                .move => self.mode = .{ .move = view },
                .resize => {
                    assert(resize_direction != null);

                    view.setResizing(true);

                    self.mode = .{ .resize = .{
                        .view = view,
                        .resize_direction = resize_direction.?,
                        .offset_x = undefined,
                        .offset_y = undefined,
                    } };

                    const cur_box = &view.current.box;
                    const pointer_surface_x = @floatToInt(i32, self.wlr_cursor.x) - cur_box.x;
                    const pointer_surface_y = @floatToInt(i32, self.wlr_cursor.y) - cur_box.y;
                    switch (resize_direction.?) {
                        .top, .left, .topleft => {
                            self.mode.resize.offset_x = pointer_surface_x;
                            self.mode.resize.offset_y = pointer_surface_y;
                        },
                        .topright => {
                            self.mode.resize.offset_x = @intCast(i32, cur_box.width) - pointer_surface_x;
                            self.mode.resize.offset_y = pointer_surface_y;
                        },
                        .bottom, .right, .botright => {
                            self.mode.resize.offset_x = @intCast(i32, cur_box.width) - pointer_surface_x;
                            self.mode.resize.offset_y = @intCast(i32, cur_box.height) - pointer_surface_y;
                        },
                        .botleft => {
                            self.mode.resize.offset_x = pointer_surface_x;
                            self.mode.resize.offset_y = @intCast(i32, cur_box.height) - pointer_surface_y;
                        },
                    }
                },
            }

            // Automatically float all views being moved by the pointer, if
            // their dimensions are set by a layout client. If however the views
            // are unarranged, leave them as non-floating so the next active
            // layout can affect them.
            if (!view.current.float and view.output.current.layout != null) {
                view.pending.float = true;
                view.float_box = view.current.box;
                view.applyPending();
            } else {
                // The View.applyPending() call in the other branch starts
                // the transaction needed after the seat.focus() call above.
                server.root.startTransaction();
            }

            // Clear cursor focus, so that the surface does not receive events
            self.seat.wlr_seat.pointerNotifyClearFocus();

            self.xcursor_manager.setCursorImage(
                if (mode == .resize) self.mode.resize.resize_direction.cursorNameZ() else "move",
                self.wlr_cursor,
            );
        },
    }
}

/// Return from down/move/resize to passthrough
fn leaveMode(self: *Self, event: *wlr.Pointer.event.Button) void {
    log.debug("leave {s} mode", .{@tagName(self.mode)});

    switch (self.mode) {
        .passthrough => unreachable,
        .down => {
            // If we were in down mode, we need pass along the release event
            _ = self.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        },
        .move => {},
        .resize => |resize| resize.view.setResizing(false),
    }

    self.mode = .passthrough;
    self.passthrough(event.time_msec);
}

fn processMotion(self: *Self, device: *wlr.InputDevice, time: u32, delta_x: f64, delta_y: f64, unaccel_dx: f64, unaccel_dy: f64) void {
    server.input_manager.relative_pointer_manager.sendRelativeMotion(
        self.seat.wlr_seat,
        @as(u64, time) * 1000,
        delta_x,
        delta_y,
        unaccel_dx,
        unaccel_dy,
    );
    var dx: f64 = delta_x;
    var dy: f64 = delta_y;
    if (self.constraint) |constraint| {
        if (self.mode == .passthrough or self.mode == .down) {
            if (constraint.type == .locked) return;

            const result = self.surfaceAt() orelse return;

            if (result.surface != constraint.surface) return;

            const sx = result.sx;
            const sy = result.sy;
            var sx_con: f64 = undefined;
            var sy_con: f64 = undefined;
            if (!wlr.region.confine(&constraint.region, sx, sy, sx + dx, sy + dy, &sx_con, &sy_con)) {
                return;
            }

            dx = sx_con - sx;
            dy = sy_con - sy;
        }
    }
    switch (self.mode) {
        .passthrough => {
            self.wlr_cursor.move(device, dx, dy);
            self.passthrough(time);
        },
        .down => |view| {
            self.wlr_cursor.move(device, dx, dy);
            // This takes surface-local coordinates
            const output_box = server.root.output_layout.getBox(view.output.wlr_output).?;
            self.seat.wlr_seat.pointerNotifyMotion(
                time,
                self.wlr_cursor.x - @intToFloat(f64, output_box.x + view.current.box.x - view.surface_box.x),
                self.wlr_cursor.y - @intToFloat(f64, output_box.y + view.current.box.y - view.surface_box.y),
            );
        },
        .move => |view| {
            view.move(@floatToInt(i32, delta_x), @floatToInt(i32, delta_y));
            self.wlr_cursor.move(
                device,
                @intToFloat(f64, view.pending.box.x - view.current.box.x),
                @intToFloat(f64, view.pending.box.y - view.current.box.y),
            );
            view.applyPending();
        },
        .resize => |data| {
            const border_width = if (data.view.draw_borders) server.config.border_width else 0;
            const box = &data.view.pending.box;
            const constraints = data.view.getConstraints();
            const min_width = @intCast(i32, math.max(View.min_size, constraints.min_width));
            const min_height = @intCast(i32, math.max(View.min_size, constraints.min_height));

            // Using two points instead of a box makes this logic a bit more
            // readable for humans. The compiler should optimize the conversion out.
            var botright_x = box.x + @intCast(i32, box.width);
            var botright_y = box.y + @intCast(i32, box.height);

            if (data.resize_direction == .top or data.resize_direction == .topleft or data.resize_direction == .topright) {
                const min_y = math.max(@intCast(i32, border_width), botright_y - @intCast(i32, @truncate(u16, constraints.max_height)));
                const max_y = botright_y - min_height;
                box.y = math.clamp(box.y + @floatToInt(i32, delta_y), min_y, max_y);
            }

            if (data.resize_direction == .bottom or data.resize_direction == .botleft or data.resize_direction == .botright) {
                const min_y = box.y + min_height;
                const max_y = box.y + @intCast(i32, @truncate(u16, constraints.max_height));
                botright_y = math.clamp(botright_y + @floatToInt(i32, delta_y), min_y, max_y);
            }

            if (data.resize_direction == .right or data.resize_direction == .topright or data.resize_direction == .botright) {
                const min_x = box.x + min_width;
                const max_x = box.x + @intCast(i32, @truncate(u16, constraints.max_width));
                botright_x = math.clamp(botright_x + @floatToInt(i32, delta_x), min_x, max_x);
            }

            if (data.resize_direction == .left or data.resize_direction == .topleft or data.resize_direction == .botleft) {
                const min_x = math.max(@intCast(i32, border_width), botright_x - @intCast(i32, @truncate(u16, constraints.max_width)));
                const max_x = botright_x - min_width;
                box.x = math.clamp(box.x + @floatToInt(i32, delta_x), min_x, max_x);
            }

            box.width = @intCast(u32, botright_x - box.x);
            box.height = @intCast(u32, botright_y - box.y);

            const output_resolution = data.view.output.getEffectiveResolution();
            box.width = math.min(box.width, output_resolution.width - border_width - @intCast(u32, box.x));
            box.height = math.min(box.height, output_resolution.height - border_width - @intCast(u32, box.y));

            data.view.applyPending();

            // Warp cursor so that its distance to the dragged corner remains
            // constant. We have to do this here in a second switch instead of
            // in the one above to follow the view constraints.
            switch (data.resize_direction) {
                .top, .left, .topleft => self.wlr_cursor.warpClosest(
                    device,
                    @intToFloat(f64, box.x + data.offset_x),
                    @intToFloat(f64, box.y + data.offset_y),
                ),
                .topright => self.wlr_cursor.warpClosest(
                    device,
                    @intToFloat(f64, box.x + @intCast(i32, box.width) - data.offset_x),
                    @intToFloat(f64, box.y + data.offset_y),
                ),
                .bottom, .right, .botright => self.wlr_cursor.warpClosest(
                    device,
                    @intToFloat(f64, box.x + @intCast(i32, box.width) - data.offset_x),
                    @intToFloat(f64, box.y + @intCast(i32, box.height) - data.offset_y),
                ),
                .botleft => self.wlr_cursor.warpClosest(
                    device,
                    @intToFloat(f64, box.x + data.offset_x),
                    @intToFloat(f64, box.y + @intCast(i32, box.height) - data.offset_y),
                ),
            }
        },
    }
}

/// Handle potential change in location of views on the output, as well as
/// the target view of a cursor operation potentially being moved to a non-visible tag,
/// becoming fullscreen, etc.
pub fn updateState(self: *Self) void {
    if (self.shouldPassthrough()) {
        self.mode = .passthrough;
        var now: os.timespec = undefined;
        os.clock_gettime(os.CLOCK_MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
        const msec = @intCast(u32, now.tv_sec * std.time.ms_per_s +
            @divFloor(now.tv_nsec, std.time.ns_per_ms));
        self.passthrough(msec);
    }
}

fn shouldPassthrough(self: Self) bool {
    switch (self.mode) {
        .passthrough => {
            // If we are not currently in down/resize/move mode, we *always* need to passthrough()
            // as what is under the cursor may have changed and we are not locked to a single
            // target view.
            return true;
        },
        .down => |target| {
            // The target view is no longer visible
            return target.current.tags & target.output.current.tags == 0;
        },
        .resize, .move => {
            const target = if (self.mode == .resize) self.mode.resize.view else self.mode.move;
            // The target view is no longer visible, is part of the layout, or is fullscreen.
            return target.current.tags & target.output.current.tags == 0 or
                (!target.current.float and target.output.current.layout != null) or
                target.current.fullscreen;
        },
    }
}

/// Pass an event on to the surface under the cursor, if any.
fn passthrough(self: *Self, time: u32) void {
    assert(self.mode == .passthrough);

    if (self.surfaceAt()) |result| {
        // If input is allowed on the surface, send pointer enter and motion
        // events. Note that wlroots won't actually send an enter event if
        // the surface has already been entered.
        if (server.input_manager.inputAllowed(result.surface)) {
            // The focus change must be checked before sending enter events
            const focus_change = self.seat.wlr_seat.pointer_state.focused_surface != result.surface;

            self.seat.wlr_seat.pointerNotifyEnter(result.surface, result.sx, result.sy);
            self.seat.wlr_seat.pointerNotifyMotion(time, result.sx, result.sy);

            if (server.config.focus_follows_cursor == .normal and focus_change) {
                switch (result.parent) {
                    .view => |view| {
                        if (self.seat.focused != .view or self.seat.focused.view != view) {
                            self.seat.focusOutput(view.output);
                            self.seat.focus(view);
                            server.root.startTransaction();
                        }
                    },
                    .layer_surface => {},
                }
            }
        }
    } else {
        // There is either no surface under the cursor or input is disallowed
        // Reset the cursor image to the default and clear focus.
        self.clearFocus();
    }
}
