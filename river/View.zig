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
const math = std.math;
const os = std.os;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = if (build_options.xwayland) @import("XwaylandView.zig") else @import("VoidView.zig");

const log = std.log.scoped(.view);

pub const Constraints = struct {
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
};

// Minimum width/height for surfaces.
// This is needed, because external layouts and large padding and border sizes
// may cause surfaces so small, that bugs in client applications are encountered,
// or even surfaces of zero or negative size,which are a protocol error and would
// likely cause river to crash. The value is totally arbitrary and low enough,
// that it should never be encountered during normal usage.
pub const min_size = 50;

const Impl = union(enum) {
    xdg_toplevel: XdgToplevel,
    xwayland_view: XwaylandView,
};

const State = struct {
    /// The output-relative effective coordinates and effective dimensions of the view. The
    /// surface itself may have other dimensions which are stored in the
    /// surface_box member.
    box: Box = Box{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The tags of the view, as a bitmask
    tags: u32,

    /// Number of seats currently focusing the view
    focus: u32 = 0,

    float: bool = false,
    fullscreen: bool = false,

    /// Opacity the view is transitioning to
    target_opacity: f32,
};

const SavedBuffer = struct {
    client_buffer: *wlr.ClientBuffer,
    box: Box,
    transform: wl.Output.Transform,
};

/// The implementation of this view
impl: Impl = undefined,

/// The output this view is currently associated with
output: *Output,

/// This is non-null from the point where the view is mapped until the
/// surface is destroyed by wlroots.
surface: ?*wlr.Surface = null,

/// This View struct outlasts the wlroots object it wraps. This bool is set to
/// true when the backing wlr.XdgToplevel or equivalent has been destroyed.
destroying: bool = false,

/// The double-buffered state of the view
current: State,
pending: State,

/// The serial sent with the currently pending configure event
pending_serial: ?u32 = null,

/// The currently commited geometry of the surface. The x/y may be negative if
/// for example the client has decided to draw CSD shadows a la GTK.
surface_box: Box = undefined,

/// The geometry the view's surface had when the transaction started and
/// buffers were saved.
saved_surface_box: Box = undefined,

/// These are what we render while a transaction is in progress
saved_buffers: std.ArrayList(SavedBuffer),

/// The floating dimensions the view, saved so that they can be restored if the
/// view returns to floating mode.
float_box: Box = undefined,

/// While a view is in fullscreen, it is still arranged if a layout is active but
/// the resulting dimensions are stored here instead of being applied to the view's
/// state. This allows us to avoid an arrange when the view returns from fullscreen
/// and for more intuitive behavior if there is no active layout for the output.
post_fullscreen_box: Box = undefined,

/// The current opacity of this view
opacity: f32,

/// Opacity change timer event source
opacity_timer: ?*wl.EventSource = null,

draw_borders: bool = true,

/// This is created when the view is mapped and destroyed with the view
foreign_toplevel_handle: ?*wlr.ForeignToplevelHandleV1 = null,
foreign_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated).init(handleForeignActivate),
foreign_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen).init(handleForeignFullscreen),
foreign_close: wl.Listener(*wlr.ForeignToplevelHandleV1) =
    wl.Listener(*wlr.ForeignToplevelHandleV1).init(handleForeignClose),

pub fn init(self: *Self, output: *Output, tags: u32, surface: anytype) void {
    self.* = .{
        .output = output,
        .current = .{
            .tags = tags,
            .target_opacity = server.config.opacity.initial,
        },
        .pending = .{
            .tags = tags,
            .target_opacity = server.config.opacity.initial,
        },
        .saved_buffers = std.ArrayList(SavedBuffer).init(util.gpa),
        .opacity = server.config.opacity.initial,
    };

    if (@TypeOf(surface) == *wlr.XdgSurface) {
        self.impl = .{ .xdg_toplevel = undefined };
        self.impl.xdg_toplevel.init(self, surface);
    } else if (build_options.xwayland and @TypeOf(surface) == *wlr.XwaylandSurface) {
        self.impl = .{ .xwayland_view = undefined };
        self.impl.xwayland_view.init(self, surface);
    } else unreachable;
}

/// Deinit the view, remove it from the view stack and free the memory.
pub fn destroy(self: *Self) void {
    self.dropSavedBuffers();
    self.saved_buffers.deinit();

    if (self.foreign_toplevel_handle) |handle| {
        self.foreign_activate.link.remove();
        self.foreign_fullscreen.link.remove();
        self.foreign_close.link.remove();
        handle.destroy();
    }

    switch (self.impl) {
        .xdg_toplevel => |*xdg_toplevel| xdg_toplevel.deinit(),
        .xwayland_view => |*xwayland_view| xwayland_view.deinit(),
    }

    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.remove(node);
    util.gpa.destroy(node);
}

/// Handle changes to pending state and start a transaction to apply them
pub fn applyPending(self: *Self) void {
    var arrange_output = false;

    if (self.current.tags != self.pending.tags)
        arrange_output = true;

    // If switching from float -> layout or layout -> float arrange the output
    // to get assigned a new size or fill the hole in the layout left behind
    if (self.current.float != self.pending.float)
        arrange_output = true;

    // If switching from float to non-float, save the dimensions
    if (self.current.float and !self.pending.float)
        self.float_box = self.current.box;

    // If switching from non-float to float, apply the saved float dimensions
    if (!self.current.float and self.pending.float)
        self.pending.box = self.float_box;

    // If switching to fullscreen set the dimensions to the full area of the output
    // and turn the view fully opaque
    if (!self.current.fullscreen and self.pending.fullscreen) {
        self.setFullscreen(true);
        self.post_fullscreen_box = self.current.box;

        self.pending.target_opacity = 1.0;
        const layout_box = server.root.output_layout.getBox(self.output.wlr_output).?;
        self.pending.box = .{
            .x = 0,
            .y = 0,
            .width = @intCast(u32, layout_box.width),
            .height = @intCast(u32, layout_box.height),
        };
    }

    if (self.current.fullscreen and !self.pending.fullscreen) {
        self.setFullscreen(false);
        self.pending.box = self.post_fullscreen_box;

        // Restore configured opacity
        self.pending.target_opacity = if (self.pending.focus > 0)
            server.config.opacity.focused
        else
            server.config.opacity.unfocused;
    }

    if (arrange_output) self.output.arrangeViews();

    server.root.startTransaction();
}

pub fn needsConfigure(self: Self) bool {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.needsConfigure(),
        .xwayland_view => |xwayland_view| xwayland_view.needsConfigure(),
    };
}

pub fn configure(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.configure(),
        .xwayland_view => |xwayland_view| xwayland_view.configure(),
    }
}

pub fn sendFrameDone(self: Self) void {
    var now: os.timespec = undefined;
    os.clock_gettime(os.CLOCK_MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    self.surface.?.sendFrameDone(&now);
}

pub fn dropSavedBuffers(self: *Self) void {
    for (self.saved_buffers.items) |buffer| buffer.client_buffer.base.unlock();
    self.saved_buffers.items.len = 0;
}

pub fn saveBuffers(self: *Self) void {
    std.debug.assert(self.saved_buffers.items.len == 0);
    self.saved_surface_box = self.surface_box;
    self.surface.?.forEachSurface(*std.ArrayList(SavedBuffer), saveBuffersIterator, &self.saved_buffers);
}

fn saveBuffersIterator(
    surface: *wlr.Surface,
    surface_x: c_int,
    surface_y: c_int,
    saved_buffers: *std.ArrayList(SavedBuffer),
) callconv(.C) void {
    if (surface.buffer) |buffer| {
        saved_buffers.append(.{
            .client_buffer = buffer,
            .box = Box{
                .x = surface_x,
                .y = surface_y,
                .width = @intCast(u32, surface.current.width),
                .height = @intCast(u32, surface.current.height),
            },
            .transform = surface.current.transform,
        }) catch return;
        _ = buffer.base.lock();
    }
}

/// Move a view from one output to another, sending the required enter/leave
/// events.
pub fn sendToOutput(self: *Self, destination_output: *Output) void {
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);

    self.output.views.remove(node);
    destination_output.views.attach(node, server.config.attach_mode);

    self.output.sendViewTags();
    destination_output.sendViewTags();

    if (self.surface) |surface| {
        surface.sendLeave(self.output.wlr_output);
        surface.sendEnter(destination_output.wlr_output);

        // Must be present if surface is non-null indicating that the view
        // is mapped.
        self.foreign_toplevel_handle.?.outputLeave(self.output.wlr_output);
        self.foreign_toplevel_handle.?.outputEnter(destination_output.wlr_output);
    }

    self.output = destination_output;
}

pub fn close(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
        .xwayland_view => |xwayland_view| xwayland_view.close(),
    }
}

pub fn setActivated(self: Self, activated: bool) void {
    if (self.foreign_toplevel_handle) |handle| handle.setActivated(activated);
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setActivated(activated),
        .xwayland_view => |xwayland_view| xwayland_view.setActivated(activated),
    }
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    if (self.foreign_toplevel_handle) |handle| handle.setFullscreen(fullscreen);
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setFullscreen(fullscreen),
        .xwayland_view => |xwayland_view| xwayland_view.setFullscreen(fullscreen),
    }
}

pub fn setResizing(self: Self, resizing: bool) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setResizing(resizing),
        .xwayland_view => {},
    }
}

pub inline fn forEachPopupSurface(
    self: Self,
    comptime T: type,
    iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) callconv(.C) void,
    user_data: T,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.forEachPopupSurface(T, iterator, user_data),
        .xwayland_view => {},
    }
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.surfaceAt(ox, oy, sx, sy),
        .xwayland_view => |xwayland_view| xwayland_view.surfaceAt(ox, oy, sx, sy),
    };
}

/// Return the current title of the view if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getTitle(),
        .xwayland_view => |xwayland_view| xwayland_view.getTitle(),
    };
}

/// Return the current app_id of the view if any.
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getAppId(),
        .xwayland_view => |xwayland_view| xwayland_view.getAppId(),
    };
}

/// Clamp the width/height of the pending state to the constraints of the view
pub fn applyConstraints(self: *Self) void {
    const constraints = self.getConstraints();
    const box = &self.pending.box;
    box.width = math.clamp(box.width, constraints.min_width, constraints.max_width);
    box.height = math.clamp(box.height, constraints.min_height, constraints.max_height);
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) Constraints {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getConstraints(),
        .xwayland_view => |xwayland_view| xwayland_view.getConstraints(),
    };
}

/// Modify the pending x/y of the view by the given deltas, clamping to the
/// bounds of the output.
pub fn move(self: *Self, delta_x: i32, delta_y: i32) void {
    const border_width = if (self.draw_borders) @intCast(i32, server.config.border_width) else 0;
    const output_resolution = self.output.getEffectiveResolution();

    const max_x = @intCast(i32, output_resolution.width) - @intCast(i32, self.pending.box.width) - border_width;
    self.pending.box.x += delta_x;
    self.pending.box.x = math.max(self.pending.box.x, border_width);
    self.pending.box.x = math.min(self.pending.box.x, max_x);
    self.pending.box.x = math.max(self.pending.box.x, 0);

    const max_y = @intCast(i32, output_resolution.height) - @intCast(i32, self.pending.box.height) - border_width;
    self.pending.box.y += delta_y;
    self.pending.box.y = math.max(self.pending.box.y, border_width);
    self.pending.box.y = math.min(self.pending.box.y, max_y);
    self.pending.box.y = math.max(self.pending.box.y, 0);
}

/// Find and return the view corresponding to a given surface, if any
pub fn fromWlrSurface(surface: *wlr.Surface) ?*Self {
    if (surface.isXdgSurface()) {
        const xdg_surface = wlr.XdgSurface.fromWlrSurface(surface);
        if (xdg_surface.role == .toplevel) {
            return @intToPtr(*Self, xdg_surface.data);
        }
    }
    if (build_options.xwayland) {
        if (surface.isXWaylandSurface()) {
            const xwayland_surface = wlr.XwaylandSurface.fromWlrSurface(surface);
            return @intToPtr(*Self, xwayland_surface.data);
        }
    }
    return null;
}

pub fn shouldTrackConfigure(self: Self) bool {
    // We don't give a damn about frame perfection for xwayland views
    if (build_options.xwayland and self.impl == .xwayland_view) return false;

    // There are exactly three cases in which we do not track configures
    // 1. the view was and remains floating
    // 2. the view is changing from float/layout to fullscreen
    // 3. the view is changing from fullscreen to float
    return !((self.pending.float and self.current.float) or
        (self.pending.fullscreen and !self.current.fullscreen) or
        (self.pending.float and !self.pending.fullscreen and self.current.fullscreen));
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(self: *Self) void {
    self.pending.target_opacity = server.config.opacity.unfocused;

    log.debug("view '{s}' mapped", .{self.getTitle()});

    if (self.foreign_toplevel_handle == null) {
        self.foreign_toplevel_handle = wlr.ForeignToplevelHandleV1.create(
            server.foreign_toplevel_manager,
        ) catch {
            log.crit("out of memory", .{});
            self.surface.?.resource.getClient().postNoMemory();
            return;
        };

        self.foreign_toplevel_handle.?.events.request_activate.add(&self.foreign_activate);
        self.foreign_toplevel_handle.?.events.request_fullscreen.add(&self.foreign_fullscreen);
        self.foreign_toplevel_handle.?.events.request_close.add(&self.foreign_close);

        if (self.getTitle()) |s| self.foreign_toplevel_handle.?.setTitle(s);
        if (self.getAppId()) |s| self.foreign_toplevel_handle.?.setAppId(s);

        self.foreign_toplevel_handle.?.outputEnter(self.output.wlr_output);
    }

    // Add the view to the stack of its output
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.attach(node, server.config.attach_mode);

    // Focus the new view, assuming the seat is focusing the proper output
    // and there isn't something else like a fullscreen view grabbing focus.
    var it = server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) seat_node.data.focus(self);

    self.surface.?.sendEnter(self.output.wlr_output);

    self.output.sendViewTags();

    if (!self.current.float) self.output.arrangeViews();

    server.root.startTransaction();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(self: *Self) void {
    log.debug("view '{s}' unmapped", .{self.getTitle()});

    assert(!self.destroying);
    self.destroying = true;

    if (self.saved_buffers.items.len == 0) self.saveBuffers();

    if (self.opacity_timer != null) {
        self.killOpacityTimer();
    }

    // Inform all seats that the view has been unmapped so they can handle focus
    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.handleViewUnmap(self);
    }

    self.output.sendViewTags();

    // Still need to arrange if fullscreened from the layout
    if (!self.current.float) self.output.arrangeViews();

    server.root.startTransaction();
}

pub fn notifyTitle(self: Self) void {
    if (self.foreign_toplevel_handle) |handle| {
        if (self.getTitle()) |s| handle.setTitle(s);
    }
    // Send title to all status listeners attached to a seat which focuses this view
    var seat_it = server.input_manager.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        if (seat_node.data.focused == .view and seat_node.data.focused.view == &self) {
            var client_it = seat_node.data.status_trackers.first;
            while (client_it) |client_node| : (client_it = client_node.next) {
                client_node.data.sendFocusedView();
            }
        }
    }
}

pub fn notifyAppId(self: Self) void {
    if (self.foreign_toplevel_handle) |handle| {
        if (self.getAppId()) |s| handle.setAppId(s);
    }
}

/// Change the opacity of a view by config.opacity.delta.
/// If the target opacity was reached, return true.
fn incrementOpacity(self: *Self) bool {
    self.output.damage.addWhole();
    if (self.opacity < self.current.target_opacity) {
        self.opacity += server.config.opacity.delta;
        if (self.opacity < self.current.target_opacity) return false;
    } else {
        self.opacity -= server.config.opacity.delta;
        if (self.opacity > self.current.target_opacity) return false;
    }
    self.opacity = self.current.target_opacity;
    return true;
}

/// Destroy a views opacity timer
fn killOpacityTimer(self: *Self) void {
    self.opacity_timer.?.remove();
    self.opacity_timer = null;
}

/// Set the timeout on a views opacity timer
fn armOpacityTimer(self: *Self) void {
    const delta_t = server.config.opacity.delta_t;
    self.opacity_timer.?.timerUpdate(delta_t) catch |err| {
        log.err("failed to update opacity timer: {s}", .{err});
        self.killOpacityTimer();
    };
}

/// Called by the opacity timer
fn handleOpacityTimer(self: *Self) callconv(.C) c_int {
    if (self.incrementOpacity()) {
        self.killOpacityTimer();
    } else {
        self.armOpacityTimer();
    }
    return 0;
}

/// Create an opacity timer for a view and arm it
fn attachOpacityTimer(self: *Self) void {
    const event_loop = server.wl_server.getEventLoop();
    self.opacity_timer = event_loop.addTimer(*Self, handleOpacityTimer, self) catch {
        log.err("failed to create opacity timer for view '{s}'", .{self.getTitle()});
        return;
    };
    self.armOpacityTimer();
}

/// Commit an opacity transition
pub fn commitOpacityTransition(self: *Self) void {
    if (self.opacity == self.current.target_opacity) return;

    // A running timer can handle a target_opacity change
    if (self.opacity_timer != null) return;

    // Do the first step now, if that step was not enough, attach timer
    if (!self.incrementOpacity()) {
        self.attachOpacityTimer();
    }
}

fn handleForeignActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const self = @fieldParentPtr(Self, "foreign_activate", listener);
    const seat = @intToPtr(*Seat, event.seat.data);

    // If view is not currently visible, focus its tags.
    if (self.output.pending.tags & self.pending.tags == 0) {
        self.output.pending.tags = self.pending.tags;
        self.output.arrangeViews();
    }

    // Will change output focus, if necessary.
    seat.focus(self);
    server.root.startTransaction();
}

fn handleForeignFullscreen(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
    event: *wlr.ForeignToplevelHandleV1.event.Fullscreen,
) void {
    const self = @fieldParentPtr(Self, "foreign_fullscreen", listener);
    self.pending.fullscreen = event.fullscreen;
    self.applyPending();
}

fn handleForeignClose(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1),
    event: *wlr.ForeignToplevelHandleV1,
) void {
    const self = @fieldParentPtr(Self, "foreign_close", listener);
    self.close();
}
