// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const View = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const ForeignToplevelHandle = @import("ForeignToplevelHandle.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = @import("XwaylandView.zig");

const log = std.log.scoped(.view);

pub const Constraints = struct {
    min_width: u31 = 1,
    max_width: u31 = math.maxInt(u31),
    min_height: u31 = 1,
    max_height: u31 = math.maxInt(u31),
};

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland_view: if (build_options.xwayland) XwaylandView else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the view.
    /// The toplevel could simply be set to undefined instead, but using a
    /// tag like this gives us better safety checks.
    none,
};

pub const State = struct {
    /// The output-relative coordinates of the view and dimensions requested by river.
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// Number of seats currently focusing the view
    focus: u32 = 0,

    fullscreen: bool = false,
    urgent: bool = false,
    ssd: bool = false,
    resizing: bool = false,

    /// Modify the x/y of the given state by delta_x/delta_y, clamping to the
    /// bounds of the output.
    pub fn move(state: *State, delta_x: i32, delta_y: i32) void {
        const border_width = if (state.ssd) server.config.border_width else 0;

        const output_width = math.maxInt(i32);
        const output_height = math.maxInt(i32);

        const max_x = output_width - state.box.width - border_width;
        state.box.x += delta_x;
        state.box.x = @max(state.box.x, border_width);
        state.box.x = @min(state.box.x, max_x);
        state.box.x = @max(state.box.x, 0);

        const max_y = output_height - state.box.height - border_width;
        state.box.y += delta_y;
        state.box.y = @max(state.box.y, border_width);
        state.box.y = @min(state.box.y, max_y);
        state.box.y = @max(state.box.y, 0);
    }

    pub fn clampToOutput(state: *State) void {
        const output = state.output orelse return;

        var output_width: i32 = undefined;
        var output_height: i32 = undefined;
        output.wlr_output.effectiveResolution(&output_width, &output_height);

        const border_width = if (state.ssd) server.config.border_width else 0;
        state.box.width = @min(state.box.width, output_width - (2 * border_width));
        state.box.height = @min(state.box.height, output_height - (2 * border_width));

        state.move(0, 0);
    }
};

/// The implementation of this view
impl: Impl,

/// Link for Root.views
link: wl.list.Link,

tree: *wlr.SceneTree,
surface_tree: *wlr.SceneTree,
saved_surface_tree: *wlr.SceneTree,
/// Order is left, right, top, bottom
borders: [4]*wlr.SceneRect,
popup_tree: *wlr.SceneTree,

/// Bounds on the width/height of the view, set by the toplevel/xwayland_view implementation.
constraints: Constraints = .{},

mapped: bool = false,
/// This is true if the View is involved in the currently inflight transaction.
inflight_transaction: bool = false,
/// This indicates that the view should be destroyed when the current
/// transaction completes. See View.destroy()
destroying: bool = false,

/// The state of the view that is directly acted upon/modified through user input.
///
/// Pending state will be copied to the inflight state and communicated to clients
/// to be applied as a single atomic transaction across all clients as soon as any
/// in progress transaction has been completed.
///
/// Any time pending state is modified Root.applyPending() must be called
/// before yielding back to the event loop.
pending: State = .{},
pending_render_list_link: wl.list.Link,

/// The state most recently sent to the layout generator and clients.
/// This state is immutable until all clients have replied and the transaction
/// is completed, at which point this inflight state is copied to current.
inflight: State = .{},
inflight_render_list_link: wl.list.Link,

/// The current state represented by the scene graph.
current: State = .{},

/// The floating dimensions the view, saved so that they can be restored if the
/// view returns to floating mode.
float_box: wlr.Box = undefined,

/// This state exists purely to allow for more intuitive behavior when
/// exiting fullscreen if there is no active layout.
post_fullscreen_box: wlr.Box = undefined,

foreign_toplevel_handle: ForeignToplevelHandle = .{},

/// Connector name of the output this view occupied before an evacuation.
output_before_evac: ?[]const u8 = null,

pub fn create(impl: Impl) error{OutOfMemory}!*View {
    assert(impl != .none);

    const view = try util.gpa.create(View);
    errdefer util.gpa.destroy(view);

    const tree = try server.root.hidden.tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.root.hidden.tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    view.* = .{
        .impl = impl,
        .link = undefined,
        .tree = tree,
        .surface_tree = try tree.createSceneTree(),
        .saved_surface_tree = try tree.createSceneTree(),
        .borders = .{
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
            try tree.createSceneRect(0, 0, &server.config.border_color),
        },
        .popup_tree = popup_tree,

        .pending_render_list_link = undefined,
        .inflight_render_list_link = undefined,
    };

    server.root.views.prepend(view);
    server.root.hidden.pending.render_list.prepend(view);
    server.root.hidden.inflight.render_list.prepend(view);

    view.tree.node.setEnabled(false);
    view.popup_tree.node.setEnabled(false);
    view.saved_surface_tree.node.setEnabled(false);

    try SceneNodeData.attach(&view.tree.node, .{ .view = view });
    try SceneNodeData.attach(&view.popup_tree.node, .{ .view = view });

    return view;
}

/// If saved buffers of the view are currently in use by a transaction,
/// mark this view for destruction when the transaction completes. Otherwise
/// destroy immediately.
pub fn destroy(view: *View, when: enum { lazy, assert }) void {
    assert(view.impl == .none);
    assert(!view.mapped);

    view.destroying = true;

    // If there are still saved buffers, then this view needs to be kept
    // around until the current transaction completes. This function will be
    // called again in Root.commitTransaction()
    if (!view.saved_surface_tree.node.enabled) {
        view.tree.node.destroy();
        view.popup_tree.node.destroy();

        view.link.remove();
        view.pending_render_list_link.remove();
        view.inflight_render_list_link.remove();

        if (view.output_before_evac) |name| util.gpa.free(name);

        util.gpa.destroy(view);
    } else {
        switch (when) {
            .lazy => {},
            .assert => unreachable,
        }
    }
}

/// The change in x/y position of the view during resize cannot be determined
/// until the size of the buffer actually committed is known. Clients are permitted
/// by the protocol to take a size smaller than that requested by the compositor in
/// order to maintain an aspect ratio or similar (mpv does this for example).
pub fn resizeUpdatePosition(view: *View, width: i32, height: i32) void {
    assert(view.inflight.resizing);

    const data = blk: {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;
            if (cursor.inflight_mode == .resize and cursor.inflight_mode.resize.view == view) {
                break :blk cursor.inflight_mode.resize;
            }
        } else {
            // The view resizing state should never be set when the view is
            // not the target of an interactive resize.
            unreachable;
        }
    };

    if (data.edges.left) {
        view.inflight.box.x += view.current.box.width - width;
        view.pending.box.x = view.inflight.box.x;
    }

    if (data.edges.top) {
        view.inflight.box.y += view.current.box.height - height;
        view.pending.box.y = view.inflight.box.y;
    }
}

pub fn commitTransaction(view: *View) void {
    assert(view.inflight_transaction);
    view.inflight_transaction = false;

    view.foreign_toplevel_handle.update();

    view.dropSavedSurfaceTree();

    switch (view.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }

                    // The transaction has timed out for the xdg toplevel, which means a commit
                    // in response to the configure with the inflight width/height has not yet
                    // been made. It may seem that we should therefore leave the current.box
                    // width/height unchanged. However, this would in fact cause visual glitches.
                    //
                    // We must update the dimensions to the current geometry of the
                    // xdg toplevel here in order to handle the following series of events:
                    //
                    // 0. initial state: client has dimensions X
                    // 1. transaction A sends a configure of size Y
                    // 2. transaction A times out - saved surfaces are dropped
                    // 3. transaction B sends a configure of size Z
                    // 4. client commits buffer of size Y
                    // 5. transaction B times out - saved surfaces are dropped
                    //
                    // If we did not use the current geometry of the toplevel at this point
                    // we would be rendering the SSD border at initial size X but the surface
                    // would be rendered at size Y.
                    if (view.inflight.resizing) {
                        view.resizeUpdatePosition(toplevel.geometry.width, toplevel.geometry.height);
                    }

                    view.current = view.inflight;
                    view.current.box.width = toplevel.geometry.width;
                    view.current.box.height = toplevel.geometry.height;
                },
                .idle, .committed => {
                    toplevel.configure_state = .idle;
                    view.current = view.inflight;
                },
                .timed_out, .timed_out_acked => unreachable,
            }
        },
        .xwayland_view => |xwayland_view| {
            if (view.inflight.resizing) {
                view.resizeUpdatePosition(
                    xwayland_view.xwayland_surface.width,
                    xwayland_view.xwayland_surface.height,
                );
            }

            view.inflight.box.width = xwayland_view.xwayland_surface.width;
            view.inflight.box.height = xwayland_view.xwayland_surface.height;
            view.pending.box.width = xwayland_view.xwayland_surface.width;
            view.pending.box.height = xwayland_view.xwayland_surface.height;

            view.current = view.inflight;
        },
        // This may seem pointless at first glance, but is in fact necessary
        // to prevent an assertion failure in Root.commitTransaction() as that
        // function assumes that the inflight tags/output will be applied by
        // View.commitTransaction() even for views being destroyed.
        .none => view.current = view.inflight,
    }

    view.updateSceneState();
}

pub fn updateSceneState(view: *View) void {
    const box = &view.current.box;
    view.tree.node.setPosition(box.x, box.y);
    view.popup_tree.node.setPosition(box.x, box.y);

    {
        const config = &server.config;
        const border_width: c_int = config.border_width;
        const border_color = &config.border_color;

        // Order is left, right, top, bottom
        // left and right borders include the corners, top and bottom do not.
        var border_boxes = [4]wlr.Box{
            .{
                .x = -border_width,
                .y = -border_width,
                .width = border_width,
                .height = box.height + 2 * border_width,
            },
            .{
                .x = box.width,
                .y = -border_width,
                .width = border_width,
                .height = box.height + 2 * border_width,
            },
            .{
                .x = 0,
                .y = -border_width,
                .width = box.width,
                .height = border_width,
            },
            .{
                .x = 0,
                .y = box.height,
                .width = box.width,
                .height = border_width,
            },
        };

        for (&view.borders, &border_boxes) |border, *border_box| {
            border.node.setEnabled(view.current.ssd and !view.current.fullscreen);
            border.node.setPosition(border_box.x, border_box.y);
            border.setSize(border_box.width, border_box.height);
            border.setColor(border_color);
        }
    }
}

/// Returns true if the configure should be waited for by the transaction system.
pub fn configure(view: *View) bool {
    assert(view.mapped and !view.destroying);
    switch (view.impl) {
        .toplevel => |*toplevel| return toplevel.configure(),
        .xwayland_view => |*xwayland_view| return xwayland_view.configure(),
        .none => unreachable,
    }
}

/// Returns null if the view is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland views that are not currently mapped.
pub fn rootSurface(view: View) ?*wlr.Surface {
    return switch (view.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.surface,
        .none => null,
    };
}

pub fn sendFrameDone(view: View) void {
    assert(view.mapped and !view.destroying);

    var now: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    view.rootSurface().?.sendFrameDone(&now);
}

pub fn dropSavedSurfaceTree(view: *View) void {
    if (!view.saved_surface_tree.node.enabled) return;

    var it = view.saved_surface_tree.children.safeIterator(.forward);
    while (it.next()) |node| node.destroy();

    view.saved_surface_tree.node.setEnabled(false);
    view.surface_tree.node.setEnabled(true);
}

pub fn saveSurfaceTree(view: *View) void {
    assert(!view.saved_surface_tree.node.enabled);
    assert(view.saved_surface_tree.children.empty());

    view.surface_tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, view.saved_surface_tree);

    view.surface_tree.node.setEnabled(false);
    view.saved_surface_tree.node.setEnabled(true);
}

fn saveSurfaceTreeIter(
    buffer: *wlr.SceneBuffer,
    sx: c_int,
    sy: c_int,
    saved_surface_tree: *wlr.SceneTree,
) void {
    const saved = saved_surface_tree.createSceneBuffer(buffer.buffer) catch {
        log.err("out of memory", .{});
        return;
    };
    saved.node.setPosition(sx, sy);
    saved.setDestSize(buffer.dst_width, buffer.dst_height);
    saved.setSourceBox(&buffer.src_box);
    saved.setTransform(buffer.transform);
}

pub fn close(view: View) void {
    switch (view.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.close(),
        .none => {},
    }
}

pub fn destroyPopups(view: View) void {
    switch (view.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland_view, .none => {},
    }
}

/// Return the current title of the view if any.
pub fn getTitle(view: View) ?[*:0]const u8 {
    assert(!view.destroying);
    return switch (view.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.title,
        .none => unreachable,
    };
}

/// Return the current app_id of the view if any.
pub fn getAppId(view: View) ?[*:0]const u8 {
    assert(!view.destroying);
    return switch (view.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.class,
        .none => unreachable,
    };
}

/// Clamp the width/height of the box to the constraints of the view
pub fn applyConstraints(view: *View, box: *wlr.Box) void {
    box.width = math.clamp(box.width, view.constraints.min_width, view.constraints.max_width);
    box.height = math.clamp(box.height, view.constraints.min_height, view.constraints.max_height);
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(view: *View) !void {
    log.debug("view '{?s}' mapped", .{view.getTitle()});

    assert(!view.mapped and !view.destroying);
    view.mapped = true;

    view.foreign_toplevel_handle.map();

    view.float_box = view.pending.box;

    server.root.applyPending();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(view: *View) void {
    log.debug("view '{?s}' unmapped", .{view.getTitle()});

    if (!view.saved_surface_tree.node.enabled) view.saveSurfaceTree();

    {
        view.pending_render_list_link.remove();
        server.root.hidden.pending.render_list.prepend(view);
    }

    assert(view.mapped and !view.destroying);
    view.mapped = false;

    view.foreign_toplevel_handle.unmap();

    server.root.applyPending();
}

pub fn notifyTitle(view: *const View) void {
    if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (view.getTitle()) |title| wlr_handle.setTitle(title);
    }
}

pub fn notifyAppId(view: View) void {
    if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        if (view.getAppId()) |app_id| wlr_handle.setAppId(app_id);
    }
}
