const std = @import("std");
const c = @import("c.zig").c;

const Output = @import("output.zig").Output;
const Server = @import("server.zig").Server;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

/// Responsible for all windowing operations
pub const Root = struct {
    const Self = @This();

    server: *Server,

    wlr_output_layout: *c.wlr_output_layout,
    outputs: std.TailQueue(Output),

    // Must stay ordered, first N views in list are the masters
    views: std.TailQueue(View),
    unmapped_views: std.TailQueue(View),

    focused_view: ?*View,

    /// Number of views in "master" section of the screen.
    master_count: u32,

    /// Percentage of the total screen that the master section takes up.
    master_factor: f64,

    // Number of pending configures sent in the current transaction.
    // A value of 0 means there is no current transaction.
    pending_count: u32,

    pub fn init(self: *Self, server: *Server) !void {
        self.server = server;

        // Create an output layout, which a wlroots utility for working with an
        // arrangement of screens in a physical layout.
        self.wlr_output_layout = c.wlr_output_layout_create() orelse
            return error.CantCreateWlrOutputLayout;
        errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

        self.outputs = std.TailQueue(Output).init();

        self.views = std.TailQueue(View).init();
        self.unmapped_views = std.TailQueue(View).init();

        self.focused_view = null;

        self.master_count = 1;
        self.master_factor = 0.6;

        self.pending_count = 0;
    }

    pub fn destroy(self: *Self) void {
        c.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    pub fn addOutput(self: *Self, wlr_output: *c.wlr_output) void {
        // TODO: Handle failure
        const node = self.outputs.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_output) catch unreachable;
        self.outputs.append(node);
    }

    pub fn addView(self: *Self, wlr_xdg_surface: *c.wlr_xdg_surface) void {
        const node = self.views.allocateNode(self.server.allocator) catch unreachable;
        node.data.init(self, wlr_xdg_surface);
        self.unmapped_views.prepend(node);
    }

    /// Finds the topmost view under the output layout coordinates lx, ly
    /// returns the view if found, and a pointer to the wlr_surface as well as the surface coordinates
    pub fn viewAt(self: *Self, lx: f64, ly: f64, surface: *?*c.wlr_surface, sx: *f64, sy: *f64) ?*View {
        var it = self.views.last;
        while (it) |node| : (it = node.prev) {
            if (node.data.isAt(lx, ly, surface, sx, sy)) {
                return &node.data;
            }
        }
        return null;
    }

    /// Focus the next view in the stack, wrapping if needed. Does nothing
    /// if there is only one view in the stack.
    pub fn focusNextView(self: *Self) void {
        if (self.focused_view) |current_focus| {
            // If there is a currently focused view, focus the next view in the stack.
            const node = @fieldParentPtr(std.TailQueue(View).Node, "data", current_focus);
            if (node.next) |next_node| {
                const view = &next_node.data;
                view.focus(view.wlr_xdg_surface.surface);
                return;
            }
        }
        // There is either no currently focused view or the last view in the
        // stack is focused and we need to wrap.
        if (self.views.first) |first_node| {
            const view = &first_node.data;
            view.focus(view.wlr_xdg_surface.surface);
        }
    }

    /// Focus the previous view in the stack, wrapping if needed. Does nothing
    /// if there is only one view in the stack.
    pub fn focusPrevView(self: *Self) void {
        if (self.focused_view) |current_focus| {
            // If there is a currently focused view, focus the previous view in the stack.
            const node = @fieldParentPtr(std.TailQueue(View).Node, "data", current_focus);
            if (node.prev) |prev_node| {
                const view = &prev_node.data;
                view.focus(view.wlr_xdg_surface.surface);
                return;
            }
        }
        // There is either no currently focused view or the first view in the
        // stack is focused and we need to wrap.
        if (self.views.last) |last_node| {
            const view = &last_node.data;
            view.focus(view.wlr_xdg_surface.surface);
        }
    }

    pub fn arrange(self: *Self) void {
        if (self.views.len == 0) {
            return;
        }

        const slave_count = if (self.master_count > self.views.len) 0 else @intCast(u32, self.views.len) - self.master_count;

        // This can't return null if we pass null as the reference
        const output_box: *c.wlr_box = c.wlr_output_layout_get_box(self.wlr_output_layout, null);
        var master_column_width: u32 = undefined;
        var slave_column_width: u32 = undefined;
        if (self.master_count > 0 and slave_count > 0) {
            // If both master and slave views are present
            master_column_width = @floatToInt(u32, @round(@intToFloat(f64, output_box.width) * self.master_factor));
            slave_column_width = @intCast(u32, output_box.width) - master_column_width;
        } else if (self.master_count > 0) {
            master_column_width = @intCast(u32, output_box.width);
            slave_column_width = 0;
        } else {
            slave_column_width = @intCast(u32, output_box.width);
            master_column_width = 0;
        }

        var i: u32 = 0;
        var it = self.views.first;
        while (it) |node| : ({
            i += 1;
            it = node.next;
        }) {
            if (i < self.master_count) {
                const view = &node.data;

                // Add the remainder to the first master to ensure every pixel of height is used
                const master_height = @divTrunc(@intCast(u32, output_box.height), self.master_count);
                const master_height_rem = @intCast(u32, output_box.height) % self.master_count;

                view.pending_state.x = 0;
                view.pending_state.y = @intCast(i32, i * master_height +
                    if (i > 0) master_height_rem else 0);

                view.pending_state.width = master_column_width;
                view.pending_state.height = master_height +
                    if (i == 0) master_height_rem else 0;
            } else {
                const view = &node.data;

                // Add the remainder to the first slave to ensure every pixel of height is used
                const slave_height = @divTrunc(@intCast(u32, output_box.height), slave_count);
                const slave_height_rem = @intCast(u32, output_box.height) % slave_count;

                view.pending_state.x = @intCast(i32, master_column_width);
                view.pending_state.y = @intCast(i32, (i - self.master_count) * slave_height +
                    if (i > self.master_count) slave_height_rem else 0);

                view.pending_state.width = slave_column_width;
                view.pending_state.height = slave_height +
                    if (i == self.master_count) slave_height_rem else 0;
            }
        }

        self.startTransaction();
    }

    /// Initiate an atomic change to the layout. This change will not be
    /// applied until all affected clients ack a configure and commit a buffer.
    fn startTransaction(self: *Self) void {
        std.debug.assert(self.pending_count == 0);

        var it = self.views.first;
        while (it) |node| : (it = node.next) {
            const view = &node.data;
            if (view.needsConfigure()) {
                view.configurePending();
                self.pending_count += 1;

                // We save the current buffer, so we can send an early
                // frame done event to give the client a head start on
                // redrawing.
                view.sendFrameDone();
            }
            view.stashBuffer();
        }

        // TODO: start a timer and handle timeout waiting for all clients to ack
    }

    pub fn notifyConfigured(self: *Self) void {
        self.pending_count -= 1;
        if (self.pending_count == 0) {
            self.commitTransaction();
        }
    }

    /// Apply the pending state and drop stashed buffers. This means that
    /// the next frame drawn will be the post-transaction state of the
    /// layout. Must only be called after all clients have configured for
    /// the new layout.
    fn commitTransaction(self: *Self) void {
        // TODO: apply damage properly
        var it = self.views.first;
        while (it) |node| : (it = node.next) {
            const view = &node.data;

            // TODO: handle views that timed out
            view.current_state = view.pending_state;
            view.dropStashedBuffer();
        }
    }
};
