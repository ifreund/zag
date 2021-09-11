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
    urgent: bool = false,
};

const SavedBuffer = struct {
    client_buffer: *wlr.ClientBuffer,
    /// x/y relative to the root surface in the surface tree.
    surface_box: Box,
    source_box: wlr.FBox,
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

/// This state exists purely to allow for more intuitive behavior when
/// exiting fullscreen if there is no active layout.
post_fullscreen_box: Box = undefined,

draw_borders: bool = true,

/// This is created when the view is mapped and destroyed with the view
foreign_toplevel_handle: ?*wlr.ForeignToplevelHandleV1 = null,
foreign_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated).init(handleForeignActivate),
foreign_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) =
    wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen).init(handleForeignFullscreen),
foreign_close: wl.Listener(*wlr.ForeignToplevelHandleV1) =
    wl.Listener(*wlr.ForeignToplevelHandleV1).init(handleForeignClose),

request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) =
    wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(handleRequestActivate),

pub fn init(self: *Self, output: *Output, tags: u32, surface: anytype) void {
    self.* = .{
        .output = output,
        .current = .{ .tags = tags },
        .pending = .{ .tags = tags },
        .saved_buffers = std.ArrayList(SavedBuffer).init(util.gpa),
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

    self.request_activate.link.remove();

    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.remove(node);
    util.gpa.destroy(node);
}

/// Handle changes to pending state and start a transaction to apply them
pub fn applyPending(self: *Self) void {
    var arrange_output = false;

    if (self.current.tags != self.pending.tags) arrange_output = true;

    // If switching from float -> layout or layout -> float arrange the output
    // to get assigned a new size or fill the hole in the layout left behind.
    if (self.current.float != self.pending.float) {
        assert(!self.pending.fullscreen); // float state modifed while in fullscreen
        arrange_output = true;
    }

    // If switching from float to non-float, save the dimensions.
    if (self.current.float and !self.pending.float) self.float_box = self.current.box;

    // If switching from non-float to float, apply the saved float dimensions.
    if (!self.current.float and self.pending.float) self.pending.box = self.float_box;

    // If switching to fullscreen, set the dimensions to the full area of the output
    // Since no other views will be visible, we can skip arranging the output.
    if (!self.current.fullscreen and self.pending.fullscreen) {
        self.setFullscreen(true);
        self.post_fullscreen_box = self.current.box;
        const dimensions = self.output.getEffectiveResolution();
        self.pending.box = .{
            .x = 0,
            .y = 0,
            .width = dimensions.width,
            .height = dimensions.height,
        };
    }

    if (self.current.fullscreen and !self.pending.fullscreen) {
        self.setFullscreen(false);
        self.pending.box = self.post_fullscreen_box;
        // If switching from fullscreen to layout, we need to arrange the output.
        if (!self.pending.float) arrange_output = true;
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
    assert(self.saved_buffers.items.len == 0);
    self.saved_surface_box = self.surface_box;
    self.forEachSurface(*std.ArrayList(SavedBuffer), saveBuffersIterator, &self.saved_buffers);
}

fn saveBuffersIterator(
    surface: *wlr.Surface,
    surface_x: c_int,
    surface_y: c_int,
    saved_buffers: *std.ArrayList(SavedBuffer),
) callconv(.C) void {
    if (surface.buffer) |buffer| {
        var source_box: wlr.FBox = undefined;
        surface.getBufferSourceBox(&source_box);
        saved_buffers.append(.{
            .client_buffer = buffer,
            .surface_box = .{
                .x = surface_x,
                .y = surface_y,
                .width = @intCast(u32, surface.current.width),
                .height = @intCast(u32, surface.current.height),
            },
            .source_box = source_box,
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

    if (self.pending.urgent) {
        self.output.sendUrgentTags();
        destination_output.sendUrgentTags();
    }

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

/// Iterates over all surfaces, subsurfaces, and popups in the tree
pub inline fn forEachSurface(
    self: Self,
    comptime T: type,
    iterator: fn (surface: *wlr.Surface, sx: c_int, sy: c_int, data: T) callconv(.C) void,
    user_data: T,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| {
            xdg_toplevel.xdg_surface.forEachSurface(T, iterator, user_data);
        },
        .xwayland_view => {
            assert(build_options.xwayland);
            self.surface.?.forEachSurface(T, iterator, user_data);
        },
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
    self.setPosition(self.pending.box.x + delta_x, self.pending.box.y + delta_y);
}

/// Set the pending x/y of the view to (x,y), clamping to the bounds of the
/// output.
pub fn setPosition(self: *Self, x: i32, y: i32) void {
    const border_width = if (self.draw_borders) @intCast(i32, server.config.border_width) else 0;
    const output_resolution = self.output.getEffectiveResolution();

    const max_x = @intCast(i32, output_resolution.width) - @intCast(i32, self.pending.box.width) - border_width;
    self.pending.box.x = x;
    self.pending.box.x = math.max(self.pending.box.x, border_width);
    self.pending.box.x = math.min(self.pending.box.x, max_x);
    self.pending.box.x = math.max(self.pending.box.x, 0);

    const max_y = @intCast(i32, output_resolution.height) - @intCast(i32, self.pending.box.height) - border_width;
    self.pending.box.y = y;
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
pub fn map(self: *Self) !void {
    log.debug("view '{s}' mapped", .{self.getTitle()});

    if (self.foreign_toplevel_handle == null) {
        const handle = try wlr.ForeignToplevelHandleV1.create(server.foreign_toplevel_manager);
        self.foreign_toplevel_handle = handle;

        handle.events.request_activate.add(&self.foreign_activate);
        handle.events.request_fullscreen.add(&self.foreign_fullscreen);
        handle.events.request_close.add(&self.foreign_close);

        if (self.getTitle()) |s| handle.setTitle(s);
        if (self.getAppId()) |s| handle.setAppId(s);

        handle.outputEnter(self.output.wlr_output);
    }

    server.xdg_activation.events.request_activate.add(&self.request_activate);

    // Add the view to the stack of its output
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.attach(node, server.config.attach_mode);

    // Inform all seats that the view has been mapped so they can handle focus
    var it = server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) try seat_node.data.handleViewMap(self);

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

    // Inform all seats that the view has been unmapped so they can handle focus
    var it = server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) seat_node.data.handleViewUnmap(self);

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

/// Only honors the request if the view is already visible on the seat's
/// currently focused output. TODO: consider allowing this request to switch
/// output/tag focus.
fn handleForeignActivate(
    listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
    event: *wlr.ForeignToplevelHandleV1.event.Activated,
) void {
    const self = @fieldParentPtr(Self, "foreign_activate", listener);
    const seat = @intToPtr(*Seat, event.seat.data);
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

fn handleRequestActivate(
    listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    const self = @fieldParentPtr(Self, "request_activate", listener);
    if (fromWlrSurface(event.surface)) |view| {
        if (view.current.focus == 0) {
            view.pending.urgent = true;
            server.root.startTransaction();
        }
    }
}
