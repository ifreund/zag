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

const PointerBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const c = @import("c.zig");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

const WmState = struct {
    enabled: bool = false,
};

seat: *Seat,
object: *river.PointerBindingV1,

button: u32,
modifiers: river.SeatV1.Modifiers,

pending: struct {
    state_change: enum {
        none,
        pressed,
        released,
    } = .none,
} = .{},
uncommitted: WmState = .{},
committed: WmState = .{},

/// This bit of state is used to ensure that multiple simultaneous
/// presses across multiple keyboards do not cause multiple press
/// events to be sent to the window manager.
sent_pressed: bool = false,

/// Seat.pointer_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    client: *wl.Client,
    version: u32,
    id: u32,
    button: u32,
    modifiers: river.SeatV1.Modifiers,
) !void {
    const binding = try util.gpa.create(PointerBinding);
    errdefer util.gpa.destroy(binding);

    const pointer_binding_v1 = try river.PointerBindingV1.create(client, version, id);
    errdefer comptime unreachable;

    log.debug("new river_pointer_binding_v1: button: {d}({?s}) modifiers: {d}", .{
        button,
        c.libevdev_event_code_get_name(c.EV_KEY, button),
        @as(u32, @bitCast(modifiers)),
    });

    binding.* = .{
        .seat = seat,
        .object = pointer_binding_v1,
        .button = button,
        .modifiers = modifiers,
        .link = undefined,
    };
    pointer_binding_v1.setHandler(*PointerBinding, handleRequest, handleDestroy, binding);

    seat.pointer_bindings.append(binding);
}

fn handleDestroy(_: *river.PointerBindingV1, binding: *PointerBinding) void {
    if (binding.seat.cursor.pressed.getPtr(binding.button)) |value_ptr| {
        // It is possible for the window manager to create duplicate pointer bindings.
        if (value_ptr.* == binding) {
            value_ptr.* = null;
        }
    }

    binding.link.remove();
    util.gpa.destroy(binding);
}

fn handleRequest(
    pointer_binding_v1: *river.PointerBindingV1,
    request: river.PointerBindingV1.Request,
    binding: *PointerBinding,
) void {
    assert(binding.object == pointer_binding_v1);
    switch (request) {
        .destroy => pointer_binding_v1.destroy(),
        .enable => binding.uncommitted.enabled = true,
        .disable => binding.uncommitted.enabled = false,
    }
}

pub fn pressed(binding: *PointerBinding) void {
    assert(!binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.pending.state_change == .none);
    binding.pending.state_change = .pressed;
    server.wm.dirtyPending();
}

pub fn released(binding: *PointerBinding) void {
    assert(binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.pending.state_change == .none);
    binding.pending.state_change = .released;
    server.wm.dirtyPending();
}

pub fn match(
    binding: *const PointerBinding,
    button: u32,
    modifiers: wlr.Keyboard.ModifierMask,
) bool {
    if (!binding.committed.enabled) return false;

    return button == binding.button and
        @as(u32, @bitCast(modifiers)) == @as(u32, @bitCast(binding.modifiers));
}
