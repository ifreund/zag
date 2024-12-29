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

const XkbBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

const WmState = struct {
    enabled: bool = false,
    // This is set for mappings with layout-pinning
    // If set, the layout with this index is always used to translate the given keycode
    layout: ?u32 = null,
};

seat: *Seat,
object: *river.XkbBindingV1,

keysym: xkb.Keysym,
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

/// Seat.xkb_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    client: *wl.Client,
    version: u32,
    id: u32,
    keysym: xkb.Keysym,
    modifiers: river.SeatV1.Modifiers,
) !void {
    const binding = try util.gpa.create(XkbBinding);
    errdefer util.gpa.destroy(binding);

    const xkb_binding_v1 = try river.XkbBindingV1.create(client, version, id);
    errdefer comptime unreachable;

    {
        var buffer: [64]u8 = undefined;
        _ = keysym.getName(&buffer, buffer.len);
        log.debug("new river_xkb_binding_v1: keysym: {d}({s}) modifiers: {d}", .{
            @intFromEnum(keysym),
            &buffer,
            @as(u32, @bitCast(modifiers)),
        });
    }

    binding.* = .{
        .seat = seat,
        .object = xkb_binding_v1,
        .keysym = keysym,
        .modifiers = modifiers,
        .link = undefined,
    };
    xkb_binding_v1.setHandler(*XkbBinding, handleRequest, handleDestroy, binding);

    seat.xkb_bindings.append(binding);
}

fn handleDestroy(_: *river.XkbBindingV1, binding: *XkbBinding) void {
    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.seat == binding.seat and device.wlr_device.type == .keyboard) {
                const keyboard: *Keyboard = @fieldParentPtr("device", device);
                for (keyboard.pressed.keys.slice()) |*key| {
                    if (key.consumer == .binding and key.consumer.binding == binding) {
                        key.consumer.binding = null;
                    }
                }
            }
        }
    }
    binding.link.remove();
    util.gpa.destroy(binding);
}

fn handleRequest(
    xkb_binding_v1: *river.XkbBindingV1,
    request: river.XkbBindingV1.Request,
    binding: *XkbBinding,
) void {
    assert(binding.object == xkb_binding_v1);
    switch (request) {
        .destroy => xkb_binding_v1.destroy(),
        .set_layout_override => |args| binding.uncommitted.layout = args.layout,
        .enable => binding.uncommitted.enabled = true,
        .disable => binding.uncommitted.enabled = false,
    }
}

pub fn pressed(binding: *XkbBinding) void {
    assert(!binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.pending.state_change == .none);
    binding.pending.state_change = .pressed;
    server.wm.dirtyPending();
}

pub fn released(binding: *XkbBinding) void {
    assert(binding.sent_pressed);
    // Input event processing should not continue after a press/release event
    // until that event is sent to the window manager in an update and acked.
    assert(binding.pending.state_change == .none);
    binding.pending.state_change = .released;
    server.wm.dirtyPending();
}

/// Compare binding with given keycode, modifiers and keyboard state
pub fn match(
    binding: *const XkbBinding,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    xkb_state: *xkb.State,
    method: enum { no_translate, translate },
) bool {
    if (!binding.committed.enabled) return false;

    const keymap = xkb_state.getKeymap();

    // If the binding has no pinned layout, use the active layout.
    // It doesn't matter if the index is out of range, since xkbcommon
    // will fall back to the active layout if so.
    const layout = binding.committed.layout orelse xkb_state.keyGetLayout(keycode);

    switch (method) {
        .no_translate => {
            // Get keysyms from the base layer, as if modifiers didn't change keysyms.
            // E.g. pressing `Super+Shift 1` does not translate to `Super Exclam`.
            const keysyms = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                0,
            );

            if (@as(u32, @bitCast(modifiers)) == @as(u32, @bitCast(binding.modifiers))) {
                for (keysyms) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
        .translate => {
            // Keysyms and modifiers as translated by xkb.
            // Modifiers used to translate the key are consumed.
            // E.g. pressing `Super+Shift 1` translates to `Super Exclam`.
            const keysyms_translated = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                xkb_state.keyGetLevel(keycode, layout),
            );

            const consumed = xkb_state.keyGetConsumedMods2(keycode, .xkb);
            const modifiers_translated = @as(u32, @bitCast(modifiers)) & ~consumed;

            if (modifiers_translated == @as(u32, @bitCast(binding.modifiers))) {
                for (keysyms_translated) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
    }

    return false;
}
