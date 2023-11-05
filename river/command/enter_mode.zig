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

const std = @import("std");
const flags = @import("flags");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

/// Switch to the given mode
pub fn enterMode(
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "oneshot", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };

    if (result.args.len < 1) return Error.NotEnoughArguments;
    if (result.args.len > 1) return Error.TooManyArguments;

    if (seat.mode_id == 1) {
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "manually exiting mode 'locked' is not allowed",
            .{},
        );
        return Error.Other;
    }

    const target_mode = result.args[0];
    const mode_id = server.config.mode_to_id.get(target_mode) orelse {
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "cannot enter non-existant mode '{s}'",
            .{target_mode},
        );
        return Error.Other;
    };

    if (mode_id == 1) {
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "manually entering mode 'locked' is not allowed",
            .{},
        );
        return Error.Other;
    } else if (mode_id == 0 and result.flags.oneshot) {
        out.* = try std.fmt.allocPrint(
            util.gpa,
            "'-oneshot' is invalid for 'normal' mode",
            .{},
        );
        return Error.Other;
    }

    seat.enterMode(mode_id, if (result.flags.oneshot)
        .oneshot
    else
        .continuous);
}
