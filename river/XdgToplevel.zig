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

const std = @import("std");
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const Seat = @import("Seat.zig");
const Subsurface = @import("Subsurface.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");
const Cursor = @import("Cursor.zig");

const log = std.log.scoped(.xdg_shell);

/// The view this xdg toplevel implements
view: *View,

/// The corresponding wlroots object
xdg_surface: *wlr.XdgSurface,

// Listeners that are always active over the view's lifetime
destroy: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleDestroy),
map: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleMap),
unmap: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Listeners that are only active while the view is mapped
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
request_fullscreen: wl.Listener(*wlr.XdgToplevel.event.SetFullscreen) =
    wl.Listener(*wlr.XdgToplevel.event.SetFullscreen).init(handleRequestFullscreen),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
    wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
    wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
set_title: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleSetTitle),
set_app_id: wl.Listener(*wlr.XdgSurface) = wl.Listener(*wlr.XdgSurface).init(handleSetAppId),

pub fn init(self: *Self, view: *View, xdg_surface: *wlr.XdgSurface) void {
    self.* = .{ .view = view, .xdg_surface = xdg_surface };
    xdg_surface.data = @ptrToInt(self);

    // Add listeners that are active over the view's entire lifetime
    xdg_surface.events.destroy.add(&self.destroy);
    xdg_surface.events.map.add(&self.map);
    xdg_surface.events.unmap.add(&self.unmap);
    xdg_surface.events.new_popup.add(&self.new_popup);
    xdg_surface.surface.events.new_subsurface.add(&self.new_subsurface);

    Subsurface.handleExisting(xdg_surface.surface, .{ .xdg_toplevel = self });
}

pub fn deinit(self: *Self) void {
    if (self.view.surface != null) {
        // Remove listeners that are active for the entire lifetime of the view
        self.destroy.link.remove();
        self.map.link.remove();
        self.unmap.link.remove();
        self.new_popup.link.remove();
        self.new_subsurface.link.remove();

        Subsurface.destroySubsurfaces(self.xdg_surface.surface);
        XdgPopup.destroyPopups(self.xdg_surface);
    }
}

/// Returns true if a configure must be sent to ensure that the pending
/// dimensions are applied.
pub fn needsConfigure(self: Self) bool {
    const server_pending = &self.xdg_surface.role_data.toplevel.server_pending;
    const state = &self.view.pending;

    // Checking server_pending is sufficient here since it will be either in
    // sync with the current dimensions or be the dimensions sent with the
    // most recent configure. In both cases server_pending has the values we
    // want to check against.
    // Furthermore, we avoid a special case for newly mapped views which we
    // have not yet configured by setting server_pending.width/height to the
    // initial width/height of the view in handleMap().
    return state.box.width != server_pending.width or
        state.box.height != server_pending.height;
}

/// Send a configure event, applying the pending state of the view.
pub fn configure(self: Self) void {
    const toplevel = self.xdg_surface.role_data.toplevel;
    const state = &self.view.pending;
    self.view.pending_serial = toplevel.setSize(state.box.width, state.box.height);
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xdg_surface.role_data.toplevel.sendClose();
}

pub fn setActivated(self: Self, activated: bool) void {
    _ = self.xdg_surface.role_data.toplevel.setActivated(activated);
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    _ = self.xdg_surface.role_data.toplevel.setFullscreen(fullscreen);
}

pub fn setResizing(self: Self, resizing: bool) void {
    _ = self.xdg_surface.role_data.toplevel.setResizing(resizing);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    const view = self.view;
    return self.xdg_surface.surfaceAt(
        ox - @intToFloat(f64, view.current.box.x - view.surface_box.x),
        oy - @intToFloat(f64, view.current.box.y - view.surface_box.y),
        sx,
        sy,
    );
}

/// Return the current title of the toplevel if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xdg_surface.role_data.toplevel.title;
}

/// Return the current app_id of the toplevel if any .
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xdg_surface.role_data.toplevel.app_id;
}

/// Return bounds on the dimensions of the toplevel.
pub fn getConstraints(self: Self) View.Constraints {
    const state = &self.xdg_surface.role_data.toplevel.current;
    return .{
        .min_width = std.math.max(state.min_width, View.min_size),
        .max_width = if (state.max_width > 0) state.max_width else std.math.maxInt(u32),
        .min_height = std.math.max(state.min_height, View.min_size),
        .max_height = if (state.max_height > 0) state.max_height else std.math.maxInt(u32),
    };
}

fn handleDestroy(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    self.deinit();
    self.view.surface = null;
}

/// Called when the xdg surface is mapped, or ready to display on-screen.
fn handleMap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;
    const toplevel = self.xdg_surface.role_data.toplevel;

    // Add listeners that are only active while mapped
    self.xdg_surface.surface.events.commit.add(&self.commit);
    toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    toplevel.events.request_move.add(&self.request_move);
    toplevel.events.request_resize.add(&self.request_resize);
    toplevel.events.set_title.add(&self.set_title);
    toplevel.events.set_app_id.add(&self.set_app_id);

    // Use the view's initial size centered on the output as the default
    // floating dimensions
    var initial_box: wlr.Box = undefined;
    self.xdg_surface.getGeometry(&initial_box);
    view.float_box.width = @intCast(u32, initial_box.width);
    view.float_box.height = @intCast(u32, initial_box.height);
    view.float_box.x = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.width) -
        @intCast(i32, view.float_box.width), 2));
    view.float_box.y = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.height) -
        @intCast(i32, view.float_box.height), 2));

    // We initialize these to avoid special-casing newly mapped views in
    // the check preformed in needsConfigure().
    toplevel.server_pending.width = @intCast(u32, initial_box.width);
    toplevel.server_pending.height = @intCast(u32, initial_box.height);

    view.surface = self.xdg_surface.surface;
    view.surface_box = Box.fromWlrBox(initial_box);

    // Also use the view's  "natural" size as the initial regular dimensions,
    // for the case that it does not get arranged by a lyaout.
    view.pending.box = view.float_box;

    const state = &toplevel.current;
    const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height);

    if (toplevel.parent != null or has_fixed_size) {
        // If the toplevel has a parent or has a fixed size make it float
        view.current.float = true;
        view.pending.float = true;
        view.pending.box = view.float_box;
    } else {
        // Make views with app_ids listed in the float filter float
        if (toplevel.app_id) |app_id| {
            if (server.config.float_filter.contains(mem.span(app_id))) {
                view.current.float = true;
                view.pending.float = true;
                view.pending.box = view.float_box;
            }
        }
    }

    // If the toplevel has an app_id which is not configured to use client side
    // decorations, inform it that it is tiled.
    if (toplevel.app_id != null and server.config.csd_filter.contains(mem.span(toplevel.app_id.?))) {
        view.draw_borders = false;
    } else {
        _ = toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    view.map() catch {
        log.crit("out of memory", .{});
        xdg_surface.resource.getClient().postNoMemory();
    };
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    // Remove listeners that are only active while mapped
    self.commit.link.remove();
    self.request_fullscreen.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.set_title.link.remove();
    self.set_app_id.link.remove();

    self.view.unmap();
}

/// Called when the surface is comitted
fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    const view = self.view;

    var wlr_box: wlr.Box = undefined;
    self.xdg_surface.getGeometry(&wlr_box);
    const new_box = Box.fromWlrBox(wlr_box);

    // If we have sent a configure changing the size
    if (view.pending_serial) |s| {
        // Update the stored dimensions of the surface
        view.surface_box = new_box;

        if (s == self.xdg_surface.configure_serial) {
            // If this commit is in response to our configure and the
            // transaction code is tracking this configure, notify it.
            // Otherwise, apply the pending state immediately.
            view.pending_serial = null;
            if (view.shouldTrackConfigure()) {
                server.root.notifyConfigured();
            } else {
                const self_tags_changed = view.pending.tags != view.current.tags;
                view.current = view.pending;
                if (self_tags_changed) view.output.sendViewTags();

                // This is necessary if this view was part of a transaction that didn't get completed
                // before some change occured that caused shouldTrackConfigure() to return false.
                view.dropSavedBuffers();

                view.output.damage.addWhole();
                server.input_manager.updateCursorState();
            }
        } else {
            // If the client has not yet acked our configure, we need to send a
            // frame done event so that it commits another buffer. These
            // buffers won't be rendered since we are still rendering our
            // stashed buffer from when the transaction started.
            view.sendFrameDone();
        }
    } else {
        view.output.damage.addWhole();
        // TODO: handle unexpected change in dimensions
        if (!std.meta.eql(view.surface_box, new_box))
            log.err("view changed size unexpectedly", .{});
        view.surface_box = new_box;
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);
    XdgPopup.create(wlr_xdg_popup, .{ .xdg_toplevel = self });
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const self = @fieldParentPtr(Self, "new_subsurface", listener);
    Subsurface.create(new_wlr_subsurface, .{ .xdg_toplevel = self });
}

/// Called when the client asks to be fullscreened. We always honor the request
/// for now, perhaps it should be denied in some cases in the future.
fn handleRequestFullscreen(
    listener: *wl.Listener(*wlr.XdgToplevel.event.SetFullscreen),
    event: *wlr.XdgToplevel.event.SetFullscreen,
) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    self.view.pending.fullscreen = event.fullscreen;
    self.view.applyPending();
}

/// Called when the client asks to be moved via the cursor, for example when the
/// user drags CSD titlebars.
fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const self = @fieldParentPtr(Self, "request_move", listener);
    const seat = @intToPtr(*Seat, event.seat.seat.data);
    if ((self.view.pending.float or self.view.output.current.layout == null) and !self.view.pending.fullscreen)
        seat.cursor.enterMode(.move, self.view, null);
}

/// Called when the client asks to be resized via the cursor.
fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const self = @fieldParentPtr(Self, "request_resize", listener);
    const seat = @intToPtr(*Seat, event.seat.seat.data);
    if ((self.view.pending.float or self.view.output.current.layout == null) and !self.view.pending.fullscreen)
        seat.cursor.enterMode(.resize, self.view, Cursor.ResizeDirection.fromWlrEdges(event.edges) catch {
            log.err("Client requested resize with invalid edge values. The request will be ignored.", .{});
            return;
        });
}

/// Called when the client sets / updates its title
fn handleSetTitle(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

/// Called when the client sets / updates its app_id
fn handleSetAppId(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
    const self = @fieldParentPtr(Self, "set_app_id", listener);
    self.view.notifyAppId();
}
