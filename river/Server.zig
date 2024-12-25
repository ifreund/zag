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

const Server = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const c = @import("c.zig");
const util = @import("util.zig");

const Config = @import("Config.zig");
const IdleInhibitManager = @import("IdleInhibitManager.zig");
const InputManager = @import("InputManager.zig");
const LockManager = @import("LockManager.zig");
const Output = @import("Output.zig");
const OutputManager = @import("OutputManager.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const TabletTool = @import("TabletTool.zig");
const WindowManager = @import("WindowManager.zig");
const XdgDecoration = @import("XdgDecoration.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.server);

wl_server: *wl.Server,

sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,

backend: *wlr.Backend,
session: ?*wlr.Session,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,

security_context_manager: *wlr.SecurityContextManagerV1,

shm: *wlr.Shm,
drm: ?*wlr.Drm = null,
linux_dmabuf: ?*wlr.LinuxDmabufV1 = null,
single_pixel_buffer_manager: *wlr.SinglePixelBufferManagerV1,

viewporter: *wlr.Viewporter,
fractional_scale_manager: *wlr.FractionalScaleManagerV1,
compositor: *wlr.Compositor,
subcompositor: *wlr.Subcompositor,
cursor_shape_manager: *wlr.CursorShapeManagerV1,

xdg_shell: *wlr.XdgShell,
xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
xdg_activation: *wlr.XdgActivationV1,

data_device_manager: *wlr.DataDeviceManager,
primary_selection_manager: *wlr.PrimarySelectionDeviceManagerV1,
data_control_manager: *wlr.DataControlManagerV1,

export_dmabuf_manager: *wlr.ExportDmabufManagerV1,
screencopy_manager: *wlr.ScreencopyManagerV1,

foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,

scene: Scene,
input_manager: InputManager,
om: OutputManager,
config: Config,
idle_inhibit_manager: IdleInhibitManager,
lock_manager: LockManager,
wm: WindowManager,

xwayland: if (build_options.xwayland) ?*wlr.Xwayland else void = if (build_options.xwayland) null,
new_xsurface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void =
    if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface).init(handleNewXwaylandSurface),

new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) =
    wl.Listener(*wlr.XdgToplevel).init(handleNewXdgToplevel),
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) =
    wl.Listener(*wlr.XdgToplevelDecorationV1).init(handleNewToplevelDecoration),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) =
    wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(handleRequestActivate),
request_set_cursor_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) =
    wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape).init(handleRequestSetCursorShape),

pub fn init(server: *Server, runtime_xwayland: bool) !void {
    // We intentionally don't try to prevent memory leaks on error in this function
    // since river will exit during initialization anyway if there is an error.
    // This keeps the code simpler and more readable.

    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();

    var session: ?*wlr.Session = undefined;
    const backend = try wlr.Backend.autocreate(loop, &session);
    const renderer = try wlr.Renderer.autocreate(backend);

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

    server.* = .{
        .wl_server = wl_server,
        .sigint_source = try loop.addSignal(*wl.Server, posix.SIG.INT, terminate, wl_server),
        .sigterm_source = try loop.addSignal(*wl.Server, posix.SIG.TERM, terminate, wl_server),

        .backend = backend,
        .session = session,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),

        .security_context_manager = try wlr.SecurityContextManagerV1.create(wl_server),

        .shm = try wlr.Shm.createWithRenderer(wl_server, 1, renderer),
        .single_pixel_buffer_manager = try wlr.SinglePixelBufferManagerV1.create(wl_server),

        .viewporter = try wlr.Viewporter.create(wl_server),
        .fractional_scale_manager = try wlr.FractionalScaleManagerV1.create(wl_server, 1),
        .compositor = compositor,
        .subcompositor = try wlr.Subcompositor.create(wl_server),
        .cursor_shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 1),

        .xdg_shell = try wlr.XdgShell.create(wl_server, 5),
        .xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server),
        .xdg_activation = try wlr.XdgActivationV1.create(wl_server),

        .data_device_manager = try wlr.DataDeviceManager.create(wl_server),
        .primary_selection_manager = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server),
        .data_control_manager = try wlr.DataControlManagerV1.create(wl_server),

        .export_dmabuf_manager = try wlr.ExportDmabufManagerV1.create(wl_server),
        .screencopy_manager = try wlr.ScreencopyManagerV1.create(wl_server),

        .foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(wl_server),

        .config = try Config.init(),

        .scene = undefined,
        .om = undefined,
        .input_manager = undefined,
        .idle_inhibit_manager = undefined,
        .lock_manager = undefined,
        .wm = undefined,
    };

    if (renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
        // wl_drm is a legacy interface and all clients should switch to linux_dmabuf.
        // However, enough widely used clients still rely on wl_drm that the pragmatic option
        // is to keep it around for the near future.
        // TODO remove wl_drm support
        server.drm = try wlr.Drm.create(wl_server, renderer);

        server.linux_dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer);
    }

    if (build_options.xwayland and runtime_xwayland) {
        server.xwayland = try wlr.Xwayland.create(wl_server, compositor, false);
        server.xwayland.?.events.new_surface.add(&server.new_xsurface);
    }

    try server.wm.init();
    try server.scene.init();
    try server.om.init();
    try server.input_manager.init();
    try server.idle_inhibit_manager.init();
    try server.lock_manager.init();

    server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
    server.xdg_decoration_manager.events.new_toplevel_decoration.add(&server.new_toplevel_decoration);
    server.xdg_activation.events.request_activate.add(&server.request_activate);
    server.cursor_shape_manager.events.request_set_shape.add(&server.request_set_cursor_shape);

    wl_server.setGlobalFilter(*Server, globalFilter, server);
}

/// Free allocated memory and clean up. Note: order is important here
pub fn deinit(server: *Server) void {
    server.sigint_source.remove();
    server.sigterm_source.remove();

    server.new_xdg_toplevel.link.remove();
    server.new_toplevel_decoration.link.remove();
    server.request_activate.link.remove();
    server.request_set_cursor_shape.link.remove();

    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            server.new_xsurface.link.remove();
            xwayland.destroy();
        }
    }

    server.wl_server.destroyClients();

    server.backend.destroy();

    // The scene graph needs to be destroyed after the backend but before the renderer
    // Output destruction requires the scene graph to still be around while the scene
    // graph may require the renderer to still be around to destroy textures it seems.
    server.scene.wlr_scene.tree.node.destroy();

    server.renderer.destroy();
    server.allocator.destroy();

    server.om.deinit();
    server.input_manager.deinit();
    server.idle_inhibit_manager.deinit();
    server.lock_manager.deinit();

    server.wl_server.destroy();

    server.config.deinit();
}

/// Create the socket, start the backend, and setup the environment
pub fn start(server: Server) !void {
    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);
    try server.backend.start();
    // TODO: don't use libc's setenv
    if (c.setenv("WAYLAND_DISPLAY", socket.ptr, 1) < 0) return error.SetenvError;
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (c.setenv("DISPLAY", xwayland.display_name, 1) < 0) return error.SetenvError;
        }
    }
}

fn globalFilter(client: *const wl.Client, global: *const wl.Global, server: *Server) bool {
    // Only expose the xwalyand_shell_v1 global to the Xwayland process.
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (global == xwayland.shell_v1.global) {
                if (xwayland.server) |xwayland_server| {
                    return client == xwayland_server.client;
                }
                return false;
            }
        }
    }

    // User-configurable allow/block lists are TODO
    if (server.security_context_manager.lookupClient(client) != null) {
        const allowed = server.allowlist(global);
        const blocked = server.blocklist(global);
        assert(allowed != blocked);
        return allowed;
    } else {
        return true;
    }
}

/// Returns true if the global is allowlisted for security contexts
fn allowlist(server: *Server, global: *const wl.Global) bool {
    if (server.drm) |drm| if (global == drm.global) return true;
    if (server.linux_dmabuf) |linux_dmabuf| if (global == linux_dmabuf.global) return true;

    // We must use the getInterface() approach for dynamically created globals
    // such as wl_output and wl_seat since the wl_global_create() function will
    // advertise the global to clients and invoke this filter before returning
    // the new global pointer.
    //
    // For other globals I like the current pointer comparison approach as it
    // should catch river accidentally exposing multiple copies of e.g. wl_shm
    // with an assertion failure.
    return global.getInterface() == wl.Output.getInterface() or
        global.getInterface() == wl.Seat.getInterface() or
        global == server.shm.global or
        global == server.single_pixel_buffer_manager.global or
        global == server.viewporter.global or
        global == server.fractional_scale_manager.global or
        global == server.compositor.global or
        global == server.subcompositor.global or
        global == server.cursor_shape_manager.global or
        global == server.xdg_shell.global or
        global == server.xdg_decoration_manager.global or
        global == server.xdg_activation.global or
        global == server.data_device_manager.global or
        global == server.primary_selection_manager.global or
        global == server.om.presentation.global or
        global == server.om.xdg_output_manager.global or
        global == server.input_manager.relative_pointer_manager.global or
        global == server.input_manager.pointer_constraints.global or
        global == server.input_manager.text_input_manager.global or
        global == server.input_manager.tablet_manager.global or
        global == server.input_manager.pointer_gestures.global or
        global == server.idle_inhibit_manager.wlr_manager.global;
}

/// Returns true if the global is blocked for security contexts
fn blocklist(server: *Server, global: *const wl.Global) bool {
    return global == server.security_context_manager.global or
        global == server.foreign_toplevel_manager.global or
        global == server.screencopy_manager.global or
        global == server.export_dmabuf_manager.global or
        global == server.data_control_manager.global or
        global == server.om.wlr_output_manager.global or
        global == server.om.power_manager.global or
        global == server.om.gamma_control_manager.global or
        global == server.input_manager.idle_notifier.global or
        global == server.input_manager.virtual_pointer_manager.global or
        global == server.input_manager.virtual_keyboard_manager.global or
        global == server.input_manager.input_method_manager.global or
        global == server.lock_manager.wlr_manager.global;
}

/// Handle SIGINT and SIGTERM by gracefully stopping the server
fn terminate(_: c_int, wl_server: *wl.Server) c_int {
    wl_server.terminate();
    return 0;
}

fn handleNewXdgToplevel(_: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    log.debug("new xdg_toplevel", .{});

    XdgToplevel.create(xdg_toplevel) catch {
        log.err("out of memory", .{});
        xdg_toplevel.resource.postNoMemory();
        return;
    };
}

fn handleNewToplevelDecoration(
    _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    wlr_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    XdgDecoration.init(wlr_decoration);
}

fn handleNewXwaylandSurface(_: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
    log.debug(
        "new xwayland surface: title='{?s}', class='{?s}', override redirect={}",
        .{ xwayland_surface.title, xwayland_surface.class, xwayland_surface.override_redirect },
    );

    if (xwayland_surface.override_redirect) {
        _ = XwaylandOverrideRedirect.create(xwayland_surface) catch {
            log.err("out of memory", .{});
            return;
        };
    } else {
        _ = XwaylandWindow.create(xwayland_surface) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn handleRequestActivate(
    _: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    const node_data = SceneNodeData.fromSurface(event.surface) orelse return;
    switch (node_data.data) {
        .window => |_| {}, // XXX
        else => |tag| {
            log.info("ignoring xdg-activation-v1 activate request of {s} surface", .{@tagName(tag)});
        },
    }
}

fn handleRequestSetCursorShape(
    _: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape),
    event: *wlr.CursorShapeManagerV1.event.RequestSetShape,
) void {
    const seat: *Seat = @ptrFromInt(event.seat_client.seat.data);

    if (event.tablet_tool) |wp_tool| {
        assert(event.device_type == .tablet_tool);

        const tool = TabletTool.get(event.seat_client.seat, wp_tool.wlr_tool) catch return;

        if (tool.allowSetCursor(event.seat_client, event.serial)) {
            const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
            tool.wlr_cursor.setXcursor(seat.cursor.xcursor_manager, name);
        }
    } else {
        assert(event.device_type == .pointer);

        const focused_client = event.seat_client.seat.pointer_state.focused_client;

        // This can be sent by any client, so we check to make sure this one is
        // actually has pointer focus first.
        if (focused_client == event.seat_client) {
            const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
            seat.cursor.setXcursor(name);
        }
    }
}
