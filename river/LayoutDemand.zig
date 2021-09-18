// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
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
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Layout = @import("Layout.zig");
const Box = @import("Box.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.layout);

const Error = error{ViewDimensionMismatch};

const timeout_ms = 200;

serial: u32,
/// Number of views for which dimensions have not been pushed.
/// This will go negative if the client pushes too many dimensions.
views: i32,
/// Proposed view dimensions
view_boxen: []Box,
timeout_timer: *wl.EventSource,

pub fn init(layout: *Layout, views: u32) !Self {
    const event_loop = server.wl_server.getEventLoop();
    const timeout_timer = try event_loop.addTimer(*Layout, handleTimeout, layout);
    errdefer timeout_timer.remove();
    try timeout_timer.timerUpdate(timeout_ms);

    return Self{
        .serial = server.wl_server.nextSerial(),
        .views = @intCast(i32, views),
        .view_boxen = try util.gpa.alloc(Box, views),
        .timeout_timer = timeout_timer,
    };
}

pub fn deinit(self: *const Self) void {
    self.timeout_timer.remove();
    util.gpa.free(self.view_boxen);
}

/// Destroy the LayoutDemand on timeout.
/// All further responses to the event will simply be ignored.
fn handleTimeout(layout: *Layout) callconv(.C) c_int {
    log.notice(
        "layout demand for layout '{s}' on output '{s}' timed out",
        .{ layout.namespace, mem.sliceTo(&layout.output.wlr_output.name, 0) },
    );
    layout.output.layout_demand.?.deinit();
    layout.output.layout_demand = null;

    server.root.notifyLayoutDemandDone();

    return 0;
}

/// Push a set of proposed view dimensions and position to the list
pub fn pushViewDimensions(self: *Self, output: *Output, x: i32, y: i32, width: u32, height: u32) void {
    // The client pushed too many dimensions
    if (self.views < 0) return;

    // Here we apply the offset to align the coords with the origin of the
    // usable area and shrink the dimensions to accomodate the border size.
    const border_width = server.config.border_width;
    self.view_boxen[self.view_boxen.len - @intCast(usize, self.views)] = .{
        .x = x + output.usable_box.x + @intCast(i32, border_width),
        .y = y + output.usable_box.y + @intCast(i32, border_width),
        .width = if (width > 2 * border_width) width - 2 * border_width else width,
        .height = if (height > 2 * border_width) height - 2 * border_width else height,
    };

    self.views -= 1;
}

/// Apply the proposed layout to the output
pub fn apply(self: *Self, layout: *Layout) void {
    const output = layout.output;

    // Whether the layout demand succeeds or fails, we are done with it and
    // need to clean up
    defer {
        output.layout_demand.?.deinit();
        output.layout_demand = null;
        server.root.notifyLayoutDemandDone();
    }

    // Check that the number of proposed dimensions is correct.
    if (self.views != 0) {
        log.err(
            "proposed dimension count ({}) does not match view count ({}), aborting layout demand",
            .{ -self.views + @intCast(i32, self.view_boxen.len), self.view_boxen.len },
        );
        layout.layout.postError(
            .count_mismatch,
            "number of proposed view dimensions must match number of views",
        );
        return;
    }

    // Apply proposed layout to views
    var it = ViewStack(View).iter(output.views.first, .forward, output.pending.tags, Output.arrangeFilter);
    var i: u32 = 0;
    while (it.next()) |view| : (i += 1) {
        view.pending.box = self.view_boxen[i];
        view.applyConstraints();
    }
    assert(i == self.view_boxen.len);
    assert(output.pending.layout == layout);
}
