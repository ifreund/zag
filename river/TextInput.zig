// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const TextInput = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");

const log = std.log.scoped(.text_input);

/// The Relay structure manages the communication between text_inputs
/// and input_method on a given seat.
pub const Relay = struct {
    seat: *Seat,

    /// List of all TextInput bound to the relay.
    /// Multiple wlr_text_input interfaces can be bound to a relay,
    /// but only one at a time can receive events.
    text_inputs: std.TailQueue(TextInput) = .{},

    input_method: ?*wlr.InputMethodV2 = null,

    new_text_input: wl.Listener(*wlr.TextInputV3) =
        wl.Listener(*wlr.TextInputV3).init(handleNewTextInput),

    // InputMethod
    new_input_method: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleNewInputMethod),
    input_method_commit: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodCommit),
    grab_keyboard: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboard),
    input_method_destroy: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodDestroy),

    grab_keyboard_destroy: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboardDestroy),

    pub fn init(self: *Relay, seat: *Seat) !void {
        self.* = .{
            .seat = seat,
        };

        server.text_input_manager.events.text_input.add(&self.new_text_input);
        server.input_method_manager.events.input_method.add(&self.new_input_method);
    }

    pub fn deinit(self: *Relay) void {
        self.new_text_input.link.remove();
        self.new_input_method.link.remove();
    }

    fn handleNewTextInput(
        listener: *wl.Listener(*wlr.TextInputV3),
        wlr_text_input: *wlr.TextInputV3,
    ) void {
        const self = @fieldParentPtr(Relay, "new_text_input", listener);
        if (self.seat.wlr_seat != wlr_text_input.seat) return;

        try TextInput.create(self, wlr_text_input);
    }

    fn handleNewInputMethod(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "new_input_method", listener);
        if (self.seat.wlr_seat != input_method.seat) return;

        // Only one input_method can be bound to a seat.
        if (self.input_method != null) {
            log.debug("attempted to connect second input method to a seat", .{});
            input_method.sendUnavailable();
            return;
        }

        self.input_method = input_method;

        if (self.input_method) |im| {
            im.events.commit.add(&self.input_method_commit);
            im.events.grab_keyboard.add(&self.grab_keyboard);
            im.events.destroy.add(&self.input_method_destroy);
            log.debug("new input method on seat {s}", .{self.seat.wlr_seat.name});
        }

        const text_input = self.getFocusableTextInput() orelse return;
        if (text_input.pending_focused_surface) |surface| {
            text_input.wlr_text_input.sendEnter(surface);
            text_input.setPendingFocusedSurface(null);
        }
    }

    fn handleInputMethodCommit(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "input_method_commit", listener);
        const text_input = self.getFocusedTextInput() orelse return;

        assert(input_method == self.input_method);

        if (mem.span(input_method.current.preedit.text).len != 0) {
            text_input.wlr_text_input.sendPreeditString(
                input_method.current.preedit.text,
                @intCast(u32, input_method.current.preedit.cursor_begin),
                @intCast(u32, input_method.current.preedit.cursor_end),
            );
        }

        if (mem.span(input_method.current.commit_text).len != 0) {
            text_input.wlr_text_input.sendCommitString(input_method.current.commit_text);
        }

        if (input_method.current.delete.before_length != 0 or
            input_method.current.delete.after_length != 0)
        {
            text_input.wlr_text_input.sendDeleteSurroundingText(
                input_method.current.delete.before_length,
                input_method.current.delete.after_length,
            );
        }

        text_input.wlr_text_input.sendDone();
    }

    fn handleInputMethodGrabKeyboard(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const self = @fieldParentPtr(Relay, "grab_keyboard", listener);

        const active_keyboard = self.seat.wlr_seat.getKeyboard() orelse return;
        keyboard_grab.setKeyboard(active_keyboard);
        keyboard_grab.sendModifiers(&active_keyboard.modifiers);

        keyboard_grab.events.destroy.add(&self.grab_keyboard_destroy);
    }

    fn handleInputMethodDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const self = @fieldParentPtr(Relay, "input_method_destroy", listener);

        assert(input_method == self.input_method);
        self.input_method = null;

        const text_input = self.getFocusedTextInput() orelse return;
        if (text_input.wlr_text_input.focused_surface) |surface| {
            text_input.setPendingFocusedSurface(surface);
        }
        text_input.wlr_text_input.sendLeave();
    }

    fn handleInputMethodGrabKeyboardDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const self = @fieldParentPtr(Relay, "grab_keyboard_destroy", listener);
        self.grab_keyboard_destroy.link.remove();

        if (keyboard_grab.keyboard) |keyboard| {
            keyboard_grab.input_method.seat.keyboardNotifyModifiers(&keyboard.modifiers);
        }
    }

    pub fn getFocusableTextInput(self: *Relay) ?*TextInput {
        var it = self.text_inputs.first;
        return while (it) |node| : (it = node.next) {
            const text_input = &node.data;
            if (text_input.pending_focused_surface != null) break text_input;
        } else null;
    }

    pub fn getFocusedTextInput(self: *Relay) ?*TextInput {
        var it = self.text_inputs.first;
        return while (it) |node| : (it = node.next) {
            const text_input = &node.data;
            if (text_input.wlr_text_input.focused_surface != null) break text_input;
        } else null;
    }

    pub fn disableTextInput(self: *Relay, text_input: *TextInput) void {
        const input_method = self.input_method orelse {
            log.debug("disable text input but input method is gone", .{});
            return;
        };
        input_method.sendDeactivate();
        self.sendInputMethodState(text_input.wlr_text_input);
    }

    pub fn sendInputMethodState(self: *Relay, wlr_text_input: *wlr.TextInputV3) void {
        const input_method = self.input_method orelse return;

        // surrounding_text
        if (wlr_text_input.active_features == 0) {
            if (wlr_text_input.current.surrounding.text) |text| {
                input_method.sendSurroundingText(
                    text,
                    wlr_text_input.current.surrounding.cursor,
                    wlr_text_input.current.surrounding.anchor,
                );
            }
        }

        input_method.sendTextChangeCause(wlr_text_input.current.text_change_cause);

        // content_type
        if (wlr_text_input.active_features == 1) {
            input_method.sendContentType(
                wlr_text_input.current.content_type.hint,
                wlr_text_input.current.content_type.purpose,
            );
        }

        input_method.sendDone();
    }

    /// Update the current focused surface. Surface must belong to the same seat.
    pub fn setSurfaceFocus(self: *Relay, wlr_surface: ?*wlr.Surface) void {
        var it = self.text_inputs.first;
        while (it) |node| : (it = node.next) {
            const text_input = &node.data;
            if (text_input.pending_focused_surface) |surface| {
                assert(text_input.wlr_text_input.focused_surface == null);
                if (wlr_surface != surface) {
                    text_input.setPendingFocusedSurface(null);
                }
            } else if (text_input.wlr_text_input.focused_surface) |surface| {
                assert(text_input.pending_focused_surface == null);
                if (wlr_surface != surface) {
                    text_input.relay.disableTextInput(text_input);
                    text_input.wlr_text_input.sendLeave();
                } else {
                    log.debug("IM relay setFocus already focused", .{});
                    continue;
                }
            }
            if (wlr_surface) |surface| {
                if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                    if (self.input_method != null) {
                        text_input.wlr_text_input.sendEnter(surface);
                    } else {
                        text_input.setPendingFocusedSurface(surface);
                    }
                }
            }
        }
    }
};

relay: *Relay,
wlr_text_input: *wlr.TextInputV3,

/// Surface stored for when text-input can't rececive an enter event immediately
/// after getting focus. Cleared once text-input receive the enter event.
pending_focused_surface: ?*wlr.Surface = null,

enable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleEnable),
commit: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleCommit),
disable: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDisable),
destroy: wl.Listener(*wlr.TextInputV3) =
    wl.Listener(*wlr.TextInputV3).init(handleDestroy),

pending_focused_surface_destroy: wl.Listener(*wlr.Surface) =
    wl.Listener(*wlr.Surface).init(handlePendingFocusedSurfaceDestroy),

pub fn create(relay: *Relay, wlr_text_input: *wlr.TextInputV3) !void {
    const node = util.gpa.create(std.TailQueue(TextInput).Node) catch return;
    node.data = .{
        .relay = relay,
        .wlr_text_input = wlr_text_input,
    };

    node.data.wlr_text_input.events.enable.add(&node.data.enable);
    node.data.wlr_text_input.events.commit.add(&node.data.commit);
    node.data.wlr_text_input.events.disable.add(&node.data.disable);
    node.data.wlr_text_input.events.destroy.add(&node.data.destroy);

    relay.text_inputs.append(node);
    log.debug("new text input on seat {s}", .{relay.seat.wlr_seat.name});
}

fn handleEnable(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "enable", listener);

    const input_method = self.relay.input_method orelse return;
    input_method.sendActivate();

    self.relay.sendInputMethodState(self.wlr_text_input);
}

fn handleCommit(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "commit", listener);
    if (self.relay.input_method == null) {
        log.debug("text input committed but input method is gone", .{});
        return;
    }
    self.relay.sendInputMethodState(self.wlr_text_input);
}

fn handleDisable(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "disable", listener);
    if (self.wlr_text_input.focused_surface == null) {
        log.debug("disabling text_input, but no longer focused", .{});
        return;
    }
    self.relay.disableTextInput(self);
}

fn handleDestroy(listener: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
    const self = @fieldParentPtr(TextInput, "destroy", listener);
    const node = @fieldParentPtr(std.TailQueue(TextInput).Node, "data", self);

    if (self.wlr_text_input.current_enabled) self.relay.disableTextInput(self);

    node.data.setPendingFocusedSurface(null);

    self.enable.link.remove();
    self.commit.link.remove();
    self.disable.link.remove();
    self.destroy.link.remove();

    self.relay.text_inputs.remove(node);
    util.gpa.destroy(node);
}

fn handlePendingFocusedSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const self = @fieldParentPtr(TextInput, "pending_focused_surface_destroy", listener);
    // TODO: Currently often wrong so cause panic, need to fix it before using assert.
    // assert(self.pending_focused_surface == surface);

    self.pending_focused_surface = null;
    self.pending_focused_surface_destroy.link.remove();
}

fn setPendingFocusedSurface(self: *TextInput, wlr_surface: ?*wlr.Surface) void {
    self.pending_focused_surface = wlr_surface;
    if (self.pending_focused_surface) |surface| {
        surface.events.destroy.add(&self.pending_focused_surface_destroy);
    }
}
