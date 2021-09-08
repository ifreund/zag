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

const std = @import("std");
const util = @import("../util.zig");

const server = &@import("../main.zig").server;

const Seat = @import("../Seat.zig");
const Config = @import("../Config.zig");

const Error = @import("../command.zig").Error;

pub fn resetConfig(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len > 1) return Error.TooManyArguments;

    // Create new config. If unsuccessful, the current config and state remain as is.
    var new_config = try Config.init();
    server.config.deinit();
    server.config = new_config;

    // Return all seats to normal mode, unless they are currently in locked mode.
    {
        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            // "locked" mode always has the id 1, "normal" the id 0.
            if (node.data.mode_id != 1) node.data.mode_id = 0;
            node.data.prev_mode_id = 0;
        }
    }

    // Reset layout namespace and spawn tag mask of all outputs.
    {
        var it = server.root.outputs.first;
        while (it) |node| : (it = node.next) {
            if (node.data.layout_namespace) |namespace| {
                util.gpa.free(namespace);
                node.data.layout_namespace = null;
            }

            // The global layout namespace was also reset, so we need to call
            // this for all outputs.
            node.data.handleLayoutNamespaceChange();

            node.data.spawn_tagmask = std.math.maxInt(u32);
        }
    }
}
