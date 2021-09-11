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

const Seat = @import("Seat.zig");

pub const Direction = enum {
    next,
    previous,
};

pub const PhysicalDirection = enum {
    up,
    down,
    left,
    right,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

// TODO: this could be replaced with a comptime hashmap
// zig fmt: off
const str_to_impl_fn = [_]struct {
    name: []const u8,
    impl: fn (*std.mem.Allocator, *Seat, []const [:0]const u8, *?[]const u8) Error!void,
}{
    .{ .name = "attach-mode",            .impl = @import("command/attach_mode.zig").attachMode },
    .{ .name = "background-color",       .impl = @import("command/config.zig").backgroundColor },
    .{ .name = "border-color-focused",   .impl = @import("command/config.zig").borderColorFocused },
    .{ .name = "border-color-unfocused", .impl = @import("command/config.zig").borderColorUnfocused },
    .{ .name = "border-color-urgent",    .impl = @import("command/config.zig").borderColorUrgent },
    .{ .name = "border-width",           .impl = @import("command/config.zig").borderWidth },
    .{ .name = "close",                  .impl = @import("command/close.zig").close },
    .{ .name = "csd-filter-add",         .impl = @import("command/filter.zig").csdFilterAdd },
    .{ .name = "csd-filter-remove",      .impl = @import("command/filter.zig").csdFilterRemove },
    .{ .name = "declare-mode",           .impl = @import("command/declare_mode.zig").declareMode },
    .{ .name = "default-layout",         .impl = @import("command/layout.zig").defaultLayout },
    .{ .name = "enter-mode",             .impl = @import("command/enter_mode.zig").enterMode },
    .{ .name = "exit",                   .impl = @import("command/exit.zig").exit },
    .{ .name = "float-filter-add",       .impl = @import("command/filter.zig").floatFilterAdd },
    .{ .name = "float-filter-remove",    .impl = @import("command/filter.zig").floatFilterRemove },
    .{ .name = "focus-follows-cursor",   .impl = @import("command/focus_follows_cursor.zig").focusFollowsCursor },
    .{ .name = "focus-output",           .impl = @import("command/output.zig").focusOutput },
    .{ .name = "focus-view",             .impl = @import("command/focus_view.zig").focusView },
    .{ .name = "input",                  .impl = @import("command/input.zig").input },
    .{ .name = "list-input-configs",     .impl = @import("command/input.zig").listInputConfigs},
    .{ .name = "list-inputs",            .impl = @import("command/input.zig").listInputs },
    .{ .name = "map",                    .impl = @import("command/map.zig").map },
    .{ .name = "map-pointer",            .impl = @import("command/map.zig").mapPointer },
    .{ .name = "move",                   .impl = @import("command/move.zig").move },
    .{ .name = "output-layout",          .impl = @import("command/layout.zig").outputLayout },
    .{ .name = "resize",                 .impl = @import("command/move.zig").resize },
    .{ .name = "send-layout-cmd",        .impl = @import("command/layout.zig").sendLayoutCmd },
    .{ .name = "send-to-output",         .impl = @import("command/output.zig").sendToOutput },
    .{ .name = "set-cursor-warp",        .impl = @import("command/config.zig").setCursorWarp },
    .{ .name = "set-focused-tags",       .impl = @import("command/tags.zig").setFocusedTags },
    .{ .name = "set-position",           .impl = @import("command/move.zig").setPosition },
    .{ .name = "set-repeat",             .impl = @import("command/set_repeat.zig").setRepeat },
    .{ .name = "set-view-tags",          .impl = @import("command/tags.zig").setViewTags },
    .{ .name = "snap",                   .impl = @import("command/move.zig").snap },
    .{ .name = "spawn",                  .impl = @import("command/spawn.zig").spawn },
    .{ .name = "spawn-tagmask",          .impl = @import("command/tags.zig").spawnTagmask },
    .{ .name = "swap",                   .impl = @import("command/swap.zig").swap},
    .{ .name = "toggle-float",           .impl = @import("command/toggle_float.zig").toggleFloat },
    .{ .name = "toggle-focused-tags",    .impl = @import("command/tags.zig").toggleFocusedTags },
    .{ .name = "toggle-fullscreen",      .impl = @import("command/toggle_fullscreen.zig").toggleFullscreen },
    .{ .name = "toggle-view-tags",       .impl = @import("command/tags.zig").toggleViewTags },
    .{ .name = "focus-previous-tags",    .impl = @import("command/tags.zig").focusPreviousTags },
    .{ .name = "unmap",                  .impl = @import("command/map.zig").unmap },
    .{ .name = "unmap-pointer",          .impl = @import("command/map.zig").unmapPointer },
    .{ .name = "xcursor-theme",          .impl = @import("command/xcursor_theme.zig").xcursorTheme },
    .{ .name = "zoom",                   .impl = @import("command/zoom.zig").zoom },
};
// zig fmt: on

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NotEnoughArguments,
    TooManyArguments,
    Overflow,
    InvalidButton,
    InvalidCharacter,
    InvalidDirection,
    InvalidPhysicalDirection,
    InvalidOrientation,
    InvalidRgba,
    InvalidValue,
    UnknownOption,
    ConflictingOptions,
    OutOfMemory,
    Other,
};

/// Run a command for the given Seat. The `args` parameter is similar to the
/// classic argv in that the command to be run is passed as the first argument.
/// The optional slice passed as the out parameter must initially be set to
/// null. If the command produces output or Error.Other is returned, the slice
/// will be set to the output of the command or a failure message, respectively.
/// The caller is then responsible for freeing that slice, which will be
/// allocated using the provided allocator.
pub fn run(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    std.debug.assert(out.* == null);
    if (args.len == 0) return Error.NoCommand;

    const impl_fn = for (str_to_impl_fn) |definition| {
        if (std.mem.eql(u8, args[0], definition.name)) break definition.impl;
    } else return Error.UnknownCommand;

    try impl_fn(allocator, seat, args, out);
}

/// Return a short error message for the given error. Passing Error.Other is UB
pub fn errToMsg(err: Error) [:0]const u8 {
    return switch (err) {
        Error.NoCommand => "no command given",
        Error.UnknownCommand => "unknown command",
        Error.UnknownOption => "unknown option",
        Error.ConflictingOptions => "options conflict",
        Error.NotEnoughArguments => "not enough arguments",
        Error.TooManyArguments => "too many arguments",
        Error.Overflow => "value out of bounds",
        Error.InvalidButton => "invalid button",
        Error.InvalidCharacter => "invalid character in argument",
        Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
        Error.InvalidPhysicalDirection => "invalid direction. Must be 'up', 'down', 'left' or 'right'",
        Error.InvalidOrientation => "invalid orientation. Must be 'horizontal', or 'vertical'",
        Error.InvalidRgba => "invalid color format, must be hexadecimal 0xRRGGBB or 0xRRGGBBAA",
        Error.InvalidValue => "invalid value",
        Error.OutOfMemory => "out of memory",
        Error.Other => unreachable,
    };
}
