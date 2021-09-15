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
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

const render = @import("render.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Layout = @import("Layout.zig");
const LayoutDemand = @import("LayoutDemand.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const OutputStatus = @import("OutputStatus.zig");

const State = struct {
    /// A bit field of focused tags
    tags: u32,

    /// Active layout, or null if views are un-arranged.
    ///
    /// If null, views which are manually moved or resized (with the pointer or
    /// or command) will not be automatically set to floating. Everything is
    /// already floating, so this would be an unexpected change of a views state
    /// the user will only notice once a layout affects the views. So instead we
    /// "snap back" all manually moved views the next time a layout is active.
    /// This is similar to dwms behvaviour. Note that this of course does not
    /// affect already floating views.
    layout: ?*Layout = null,
};

wlr_output: *wlr.Output,
damage: *wlr.OutputDamage,

/// All layer surfaces on the output, indexed by the layer enum.
layers: [4]std.TailQueue(LayerSurface) = [1]std.TailQueue(LayerSurface){.{}} ** 4,

/// The area left for views and other layer surfaces after applying the
/// exclusive zones of exclusive layer surfaces.
/// TODO: this should be part of the output's State
usable_box: Box,

/// The top of the stack is the "most important" view.
views: ViewStack(View) = .{},

/// The double-buffered state of the output.
current: State = State{ .tags = 1 << 0 },
pending: State = State{ .tags = 1 << 0 },

/// Remembered version of tags (from last run)
previous_tags: u32 = 1 << 0,

/// The currently active LayoutDemand
layout_demand: ?LayoutDemand = null,

/// List of all layouts
layouts: std.TailQueue(Layout) = .{},

/// The current layout namespace of the output. If null,
/// config.default_layout_namespace should be used instead.
/// Call handleLayoutNamespaceChange() after setting this.
layout_namespace: ?[]const u8 = null,

/// Bitmask that whitelists tags for newly spawned views
spawn_tagmask: u32 = std.math.maxInt(u32),

/// List of status tracking objects relaying changes to this output to clients.
status_trackers: std.SinglyLinkedList(OutputStatus) = .{},

destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleDestroy),
enable: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleEnable),
mode: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(handleMode),
frame: wl.Listener(*wlr.OutputDamage) = wl.Listener(*wlr.OutputDamage).init(handleFrame),
damage_destroy: wl.Listener(*wlr.OutputDamage) = wl.Listener(*wlr.OutputDamage).init(handleDamageDestroy),

pub fn init(self: *Self, wlr_output: *wlr.Output) !void {
    assert(!wlr_output.isNoop());

    // Some backends don't have modes. DRM+KMS does, and we need to set a mode
    // before we can use the output. The mode is a tuple of (width, height,
    // refresh rate), and each monitor supports only a specific set of modes. We
    // just pick the monitor's preferred mode, a more sophisticated compositor
    // would let the user configure it.
    if (wlr_output.preferredMode()) |mode| {
        wlr_output.setMode(mode);
        wlr_output.enable(true);
        try wlr_output.commit();
    }

    if (server.config.adaptive_sync == .enabled) {
        wlr_output.enableAdaptiveSync(true);
    }

    self.* = .{
        .wlr_output = wlr_output,
        .damage = try wlr.OutputDamage.create(wlr_output),
        .usable_box = undefined,
    };
    wlr_output.data = @ptrToInt(self);

    wlr_output.events.destroy.add(&self.destroy);
    wlr_output.events.enable.add(&self.enable);
    wlr_output.events.mode.add(&self.mode);

    self.damage.events.frame.add(&self.frame);
    self.damage.events.destroy.add(&self.damage_destroy);

    // Ensure that a cursor image at the output's scale factor is loaded
    // for each seat.
    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.cursor.xcursor_manager.load(wlr_output.scale) catch
            std.log.scoped(.cursor).err("failed to load xcursor theme at scale {}", .{wlr_output.scale});
    }

    const effective_resolution = self.getEffectiveResolution();
    self.usable_box = .{
        .x = 0,
        .y = 0,
        .width = effective_resolution.width,
        .height = effective_resolution.height,
    };

    self.setTitle();
}

pub fn getLayer(self: *Self, layer: zwlr.LayerShellV1.Layer) *std.TailQueue(LayerSurface) {
    return &self.layers[@intCast(usize, @enumToInt(layer))];
}

pub fn sendViewTags(self: Self) void {
    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendViewTags();
}

pub fn sendUrgentTags(self: Self) void {
    var urgent_tags: u32 = 0;

    var view_it = self.views.first;
    while (view_it) |node| : (view_it = node.next) {
        if (node.view.current.urgent) urgent_tags |= node.view.current.tags;
    }

    var it = self.status_trackers.first;
    while (it) |node| : (it = node.next) node.data.sendUrgentTags(urgent_tags);
}

pub fn arrangeFilter(view: *View, filter_tags: u32) bool {
    return !view.destroying and !view.pending.float and !view.pending.fullscreen and
        view.pending.tags & filter_tags != 0;
}

/// Start a layout demand with the currently active (pending) layout.
/// Note that this function does /not/ decide which layout shall be active. That
/// is done in two places: 1) When the user changed the layout namespace option
/// of this output and 2) when a new layout is added.
///
/// If no layout is active, all views will simply retain their current
/// dimensions. So without any active layouts, river will function like a simple
/// floating WM.
///
/// The changes of view dimensions are async. Therefore all transactions are
/// blocked until the layout demand has either finished or was aborted. Both
/// cases will start a transaction.
pub fn arrangeViews(self: *Self) void {
    if (self == &server.root.noop_output) return;

    // If there is already an active layout demand, discard it.
    if (self.layout_demand) |demand| {
        demand.deinit();
        self.layout_demand = null;
    }

    // We only need to do something if there is an active layout.
    if (self.pending.layout) |layout| {
        // If the usable area has a zero dimension, trying to arrange the layout
        // would cause an underflow and is pointless anyway.
        if (self.usable_box.width == 0 or self.usable_box.height == 0) return;

        // How many views will be part of the layout?
        var views: u32 = 0;
        var view_it = ViewStack(View).iter(self.views.first, .forward, self.pending.tags, arrangeFilter);
        while (view_it.next() != null) views += 1;

        // No need to arrange an empty output.
        if (views == 0) return;

        // Note that this is async. A layout demand will start a transaction
        // once its done.
        layout.startLayoutDemand(views);
    }
}

const ArrangeLayersTarget = enum { mapped, unmapped };

/// Arrange all layer surfaces of this output and adjust the usable area
/// If target is unmapped, this function is pure aside from the
/// wlr.LayerSurfaceV1.configure() calls made on umapped layer surfaces.
pub fn arrangeLayers(self: *Self, target: ArrangeLayersTarget) void {
    const effective_resolution = self.getEffectiveResolution();
    const full_box: Box = .{
        .x = 0,
        .y = 0,
        .width = effective_resolution.width,
        .height = effective_resolution.height,
    };

    // This box is modified as exclusive zones are applied
    var usable_box = full_box;

    const layers = [_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background };

    // Arrange all layer surfaces with exclusive zones, applying them to the
    // usable box along the way.
    for (layers) |layer| self.arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, true, target);

    // If the the usable_box has changed, we need to rearrange the output
    if (target == .mapped and !std.meta.eql(self.usable_box, usable_box)) {
        self.usable_box = usable_box;
        self.arrangeViews();
    }

    // Arrange the layers without exclusive zones
    for (layers) |layer| self.arrangeLayer(self.getLayer(layer).*, full_box, &usable_box, false, target);

    if (target == .unmapped) return;

    // Find the topmost layer surface in the top or overlay layers which
    // requests keyboard interactivity if any.
    const topmost_surface = outer: for (layers[0..2]) |layer| {
        // Iterate in reverse order since the last layer is rendered on top
        var it = self.getLayer(layer).last;
        while (it) |node| : (it = node.prev) {
            const layer_surface = &node.data;
            if (layer_surface.wlr_layer_surface.current.keyboard_interactive == .exclusive) {
                break :outer layer_surface;
            }
        }
    } else null;

    var it = server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;

        // Only grab focus of seats which have the output focused
        if (seat.focused_output != self) continue;

        if (topmost_surface) |to_focus| {
            // If we found a surface that requires focus, grab the focus of all
            // seats.
            seat.setFocusRaw(.{ .layer = to_focus });
        } else if (seat.focused == .layer) {
            // If the seat is currently focusing a layer without keyboard
            // interactivity, stop focusing that layer.
            if (seat.focused.layer.wlr_layer_surface.current.keyboard_interactive != .exclusive) {
                seat.setFocusRaw(.{ .none = {} });
                seat.focus(null);
            }
        }
    }
}

/// Arrange the layer surfaces of a given layer
fn arrangeLayer(
    self: *Self,
    layer: std.TailQueue(LayerSurface),
    full_box: Box,
    usable_box: *Box,
    exclusive: bool,
    target: ArrangeLayersTarget,
) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        const current_state = layer_surface.wlr_layer_surface.current;

        // If the value of exclusive_zone is greater than zero, then it exclusivly
        // occupies some area of the screen.
        if (exclusive != (current_state.exclusive_zone > 0)) continue;

        // If the exclusive zone is set to -1, this means the the client would like
        // to ignore any exclusive zones and use the full area of the output.
        const bounds = if (current_state.exclusive_zone == -1) &full_box else usable_box;

        var new_box: Box = undefined;

        // Horizontal alignment
        const horizontal_margin_size = current_state.margin.left + current_state.margin.right;
        if (horizontal_margin_size >= bounds.width) {
            // TODO find a better solution
            // We currently have not reached a conclusion on how to gracefully
            // handle this case yet, so we just close the surface. That will
            // cause the output to be re-arranged eventually, so we can just
            // exit here. Technically doing this is incorrect, but this case
            // should only ever be encountered very rarely and matches the
            // behavior of other compositors.
            std.log.scoped(.layer_shell).warn(
                "margins of layer surface '{s}' are too large to be reasonably handled. Closing.",
                .{layer_surface.wlr_layer_surface.namespace},
            );
            layer_surface.wlr_layer_surface.close();
            return;
        } else if (horizontal_margin_size + current_state.desired_width > bounds.width) {
            new_box.y = bounds.y;
            new_box.width = bounds.width - horizontal_margin_size;
        } else if (current_state.desired_width == 0) {
            std.debug.assert(current_state.anchor.right and current_state.anchor.left);
            new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
            new_box.width = bounds.width - (current_state.margin.left + current_state.margin.right);
        } else if (current_state.anchor.left) {
            new_box.x = bounds.x + @intCast(i32, current_state.margin.left);
            new_box.width = current_state.desired_width;
        } else if (current_state.anchor.right) {
            new_box.x = bounds.x + @intCast(i32, bounds.width - current_state.desired_width -
                current_state.margin.right);
            new_box.width = current_state.desired_width;
        } else {
            new_box.x = bounds.x + @intCast(i32, bounds.width / 2 - current_state.desired_width / 2);
            new_box.width = current_state.desired_width;
        }

        // Vertical alignment
        const vertical_margin_size = current_state.margin.bottom + current_state.margin.top;
        if (vertical_margin_size >= bounds.height) {
            // TODO find a better solution, see explanation above
            std.log.scoped(.layer_shell).warn(
                "margins of layer surface '{s}' are too large to be reasonably handled. Closing.",
                .{layer_surface.wlr_layer_surface.namespace},
            );
            layer_surface.wlr_layer_surface.close();
            return;
        } else if (vertical_margin_size + current_state.desired_height > bounds.height) {
            new_box.y = bounds.y;
            new_box.height = bounds.height - vertical_margin_size;
        } else if (current_state.desired_height == 0) {
            std.debug.assert(current_state.anchor.top and current_state.anchor.bottom);
            new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
            new_box.height = bounds.height - (current_state.margin.top + current_state.margin.bottom);
        } else if (current_state.anchor.top) {
            new_box.y = bounds.y + @intCast(i32, current_state.margin.top);
            new_box.height = current_state.desired_height;
        } else if (current_state.anchor.bottom) {
            new_box.y = bounds.y + @intCast(i32, bounds.height - current_state.desired_height -
                current_state.margin.bottom);
            new_box.height = current_state.desired_height;
        } else {
            new_box.y = bounds.y + @intCast(i32, bounds.height / 2 - current_state.desired_height / 2);
            new_box.height = current_state.desired_height;
        }

        // Apply the exclusive zone to the current bounds
        const edges = [4]struct {
            single: zwlr.LayerSurfaceV1.Anchor,
            triple: zwlr.LayerSurfaceV1.Anchor,
            to_increase: ?*i32,
            to_decrease: *u32,
            margin: u32,
        }{
            .{
                .single = .{ .top = true },
                .triple = .{ .top = true, .left = true, .right = true },
                .to_increase = &usable_box.y,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.top,
            },
            .{
                .single = .{ .bottom = true },
                .triple = .{ .bottom = true, .left = true, .right = true },
                .to_increase = null,
                .to_decrease = &usable_box.height,
                .margin = current_state.margin.bottom,
            },
            .{
                .single = .{ .left = true },
                .triple = .{ .left = true, .top = true, .bottom = true },
                .to_increase = &usable_box.x,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.left,
            },
            .{
                .single = .{ .right = true },
                .triple = .{ .right = true, .top = true, .bottom = true },
                .to_increase = null,
                .to_decrease = &usable_box.width,
                .margin = current_state.margin.right,
            },
        };

        for (edges) |edge| {
            if ((std.meta.eql(current_state.anchor, edge.single) or std.meta.eql(current_state.anchor, edge.triple)) and
                current_state.exclusive_zone + @intCast(i32, edge.margin) > 0)
            {
                const delta = current_state.exclusive_zone + @intCast(i32, edge.margin);
                if (edge.to_increase) |value| value.* += delta;
                edge.to_decrease.* -= @intCast(u32, delta);
                break;
            }
        }

        switch (target) {
            .mapped => {
                assert(layer_surface.wlr_layer_surface.mapped);
                layer_surface.box = new_box;
                layer_surface.wlr_layer_surface.configure(new_box.width, new_box.height);
            },
            .unmapped => if (!layer_surface.wlr_layer_surface.mapped) {
                layer_surface.wlr_layer_surface.configure(new_box.width, new_box.height);
            },
        }
    }
}

fn handleDamageDestroy(listener: *wl.Listener(*wlr.OutputDamage), wlr_output: *wlr.OutputDamage) void {
    const self = @fieldParentPtr(Self, "damage_destroy", listener);
    // The wlr.OutputDamage is only destroyed by wlroots when the output is
    // destroyed and is never destroyed manually by river.
    self.frame.link.remove();
    // Ensure that it is safe to call remove() again in handleDestroy()
    self.frame.link = .{ .prev = &self.frame.link, .next = &self.frame.link };
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    std.log.scoped(.server).debug("output '{s}' destroyed", .{mem.sliceTo(&self.wlr_output.name, 0)});

    // Remove the destroyed output from root if it wasn't already removed
    server.root.removeOutput(self);
    assert(self.views.first == null and self.views.last == null);
    for (self.layers) |layer| assert(layer.len == 0);
    assert(self.layouts.len == 0);

    var it = server.root.all_outputs.first;
    while (it) |all_node| : (it = all_node.next) {
        if (all_node.data == self) {
            server.root.all_outputs.remove(all_node);
            break;
        }
    }

    // Remove all listeners
    self.destroy.link.remove();
    self.enable.link.remove();
    self.frame.link.remove();
    self.mode.link.remove();

    // Free all memory and clean up the wlr.Output
    if (self.layout_demand) |demand| demand.deinit();
    if (self.layout_namespace) |namespace| util.gpa.free(namespace);

    self.wlr_output.data = undefined;

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    util.gpa.destroy(node);
}

fn handleEnable(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "enable", listener);

    // Add the output to root.outputs and the output layout if it has not
    // already been added.
    if (wlr_output.enabled) server.root.addOutput(self);
}

fn handleFrame(listener: *wl.Listener(*wlr.OutputDamage), wlr_output: *wlr.OutputDamage) void {
    // This function is called every time an output is ready to display a frame,
    // generally at the output's refresh rate (e.g. 60Hz).
    const self = @fieldParentPtr(Self, "frame", listener);
    render.renderOutput(self);
}

fn handleMode(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self = @fieldParentPtr(Self, "mode", listener);
    self.arrangeLayers(.mapped);
    self.arrangeViews();
    server.root.startTransaction();
}

pub fn getEffectiveResolution(self: *Self) struct { width: u32, height: u32 } {
    var width: c_int = undefined;
    var height: c_int = undefined;
    self.wlr_output.effectiveResolution(&width, &height);
    return .{
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
    };
}

fn setTitle(self: Self) void {
    var buf: ["river - ".len + self.wlr_output.name.len + 1]u8 = undefined;
    const title = fmt.bufPrintZ(&buf, "river - {s}", .{mem.sliceTo(&self.wlr_output.name, 0)}) catch unreachable;
    if (self.wlr_output.isWl()) {
        self.wlr_output.wlSetTitle(title);
    } else if (wlr.config.has_x11_backend and self.wlr_output.isX11()) {
        self.wlr_output.x11SetTitle(title);
    }
}

pub fn handleLayoutNamespaceChange(self: *Self) void {
    // The user changed the layout namespace of this output. Try to find a
    // matching layout.
    var it = self.layouts.first;
    self.pending.layout = while (it) |node| : (it = node.next) {
        if (mem.eql(u8, self.layoutNamespace(), node.data.namespace)) break &node.data;
    } else null;
    self.arrangeViews();
    server.root.startTransaction();
}

pub fn layoutNamespace(self: Self) []const u8 {
    return self.layout_namespace orelse server.config.default_layout_namespace;
}
