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

const std = @import("std");

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const PhysicalDirection = @import("../command.zig").PhysicalDirection;
const Orientation = @import("../command.zig").Orientation;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const Box = @import("../Box.zig");

pub fn move(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const delta = try std.fmt.parseInt(i32, args[2], 10);
    const direction = std.meta.stringToEnum(PhysicalDirection, args[1]) orelse
        return Error.InvalidPhysicalDirection;

    const view = getView(seat) orelse return;
    switch (direction) {
        .up => view.move(0, -delta),
        .down => view.move(0, delta),
        .left => view.move(-delta, 0),
        .right => view.move(delta, 0),
    }

    apply(view);
}

pub fn setPosition(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const x = try std.fmt.parseInt(i32, args[1], 10);
    const y = try std.fmt.parseInt(i32, args[2], 10);

    const view = getView(seat) orelse return;
    view.setPosition(x, y);
    apply(view);
}

pub fn snap(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(PhysicalDirection, args[1]) orelse
        return Error.InvalidPhysicalDirection;

    const view = getView(seat) orelse return;
    const border_width = @intCast(i32, server.config.border_width);
    const output_box = view.output.getEffectiveResolution();
    switch (direction) {
        .up => view.pending.box.y = border_width,
        .down => view.pending.box.y =
            @intCast(i32, output_box.height - view.pending.box.height) - border_width,
        .left => view.pending.box.x = border_width,
        .right => view.pending.box.x =
            @intCast(i32, output_box.width - view.pending.box.width) - border_width,
    }

    apply(view);
}

pub fn resize(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const delta = try std.fmt.parseInt(i32, args[2], 10);
    const orientation = std.meta.stringToEnum(Orientation, args[1]) orelse
        return Error.InvalidOrientation;

    const view = getView(seat) orelse return;
    const border_width = @intCast(i32, server.config.border_width);
    const output_box = view.output.getEffectiveResolution();
    switch (orientation) {
        .horizontal => {
            var real_delta: i32 = @intCast(i32, view.pending.box.width);
            if (delta > 0) {
                view.pending.box.width += @intCast(u32, delta);
            } else {
                // Prevent underflow
                view.pending.box.width -=
                    std.math.min(view.pending.box.width, @intCast(u32, -1 * delta));
            }
            view.applyConstraints();
            // Do not grow bigger than the output
            view.pending.box.width = std.math.min(
                view.pending.box.width,
                output_box.width - @intCast(u32, 2 * border_width),
            );
            real_delta -= @intCast(i32, view.pending.box.width);
            view.move(@divFloor(real_delta, 2), 0);
        },
        .vertical => {
            var real_delta: i32 = @intCast(i32, view.pending.box.height);
            if (delta > 0) {
                view.pending.box.height += @intCast(u32, delta);
            } else {
                // Prevent underflow
                view.pending.box.height -=
                    std.math.min(view.pending.box.height, @intCast(u32, -1 * delta));
            }
            view.applyConstraints();
            // Do not grow bigger than the output
            view.pending.box.height = std.math.min(
                view.pending.box.height,
                output_box.height - @intCast(u32, 2 * border_width),
            );
            real_delta -= @intCast(i32, view.pending.box.height);
            view.move(0, @divFloor(real_delta, 2));
        },
    }

    apply(view);
}

fn apply(view: *View) void {
    // Set the view to floating but keep the position and dimensions, if their
    // dimensions are set by a layout client. If however the views are
    // unarranged, leave them as non-floating so the next active layout can
    // affect them.
    if (view.output.current.layout != null)
        view.pending.float = true;

    view.float_box = view.pending.box;

    view.applyPending();
}

fn getView(seat: *Seat) ?*View {
    if (seat.focused != .view) return null;
    const view = seat.focused.view;

    // Do not touch fullscreen views
    if (view.pending.fullscreen) return null;

    return view;
}
