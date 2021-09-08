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
const mem = std.mem;
const wl = @import("wayland").server.wl;
const util = @import("../util.zig");

const server = &@import("../main.zig").server;

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

pub fn outputLayout(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const output = seat.focused_output;
    const old_layout_namespace = output.layout_namespace;
    output.layout_namespace = try util.gpa.dupe(u8, args[1]);
    if (old_layout_namespace) |namespace| util.gpa.free(namespace);
    output.handleLayoutNamespaceChange();
}

pub fn defaultLayout(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const old_default_layout_namespace = server.config.default_layout_namespace;
    server.config.default_layout_namespace = try util.gpa.dupe(u8, args[1]);
    util.gpa.free(old_default_layout_namespace);

    var it = server.root.all_outputs.first;
    while (it) |node| : (it = node.next) {
        const output = node.data;
        if (output.layout_namespace == null) output.handleLayoutNamespaceChange();
    }
}

/// riverctl send-layout-cmd rivertile "mod-main-count 1"
/// riverctl send-layout-cmd rivertile "mod-main-factor -0.1"
/// riverctl send-layout-cmd rivertile "main-location top"
pub fn sendLayoutCmd(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    const output = seat.focused_output;
    const target_namespace = args[1];

    var it = output.layouts.first;
    const layout = while (it) |node| : (it = node.next) {
        const layout = &node.data;
        if (mem.eql(u8, layout.namespace, target_namespace)) break layout;
    } else return;

    layout.layout.sendUserCommand(args[2]);

    output.arrangeViews();
}
