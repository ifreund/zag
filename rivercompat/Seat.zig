// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2024 The River Developers
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

const Seat = @This();

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Window = @import("Window.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBinding = @import("XkbBinding.zig");

const gpa = std.heap.c_allocator;

wm: *WindowManager,
seat_v1: *river.SeatV1,
focused: ?*Window = null,

pub fn create(wm: *WindowManager, seat_v1: *river.SeatV1) void {
    const seat = gpa.create(Seat) catch @panic("OOM");
    seat.* = .{
        .wm = wm,
        .seat_v1 = seat_v1,
    };
    seat_v1.setListener(*Seat, handleEvent, seat);

    XkbBinding.create(seat, xkb.Keysym.n, .{ .mod1 = true });
}

pub fn focus(seat: *Seat, target: ?*Window) void {
    if (target) |window| {
        seat.seat_v1.focusWindow(window.window_v1);
        seat.focused = window;

        window.link.remove();
        seat.wm.windows.prepend(window);

        window.node_v1.placeTop();
    } else {
        seat.seat_v1.clearFocus();
    }
}

pub fn focusNext(seat: *Seat) void {
    if (seat.focused != null) {
        if (seat.wm.windows.length() >= 2) {
            seat.focus(seat.wm.windows.last().?);
        }
    } else if (seat.wm.windows.first()) |top| {
        seat.focus(top);
    }
}

fn handleEvent(seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.seat_v1 == seat_v1);
    switch (event) {
        .removed => {
            seat_v1.destroy();
            gpa.destroy(seat);
        },
        .pointer_enter => {},
        .pointer_leave => {},
        .pointer_activity => {},
        .window_interaction => |args| {
            const window_v1 = args.window orelse return;
            const window: *Window = @ptrCast(@alignCast(window_v1.getUserData()));
            seat.focus(window);
        },
    }
}
