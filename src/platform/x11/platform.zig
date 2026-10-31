//! X11/xcb backend: connection lifetime, window and the frame loop.
//!
//! Same contract as the SDL3 backend: `init`, `attach`, `pollEvent`, `deinit`.
//! Applications choose a backend by importing the module, so the two are
//! interchangeable from the caller's point of view.

const std = @import("std");
const app_mod = @import("zui").app;
const events_mod = @import("zui").events;
const geometry = @import("zui").geometry;

const xcb = @import("xcb.zig");
const xcb_keysyms = @import("xcb-keysyms.zig");
const surface_mod = @import("surface.zig");
const event_loop_mod = @import("event_loop.zig");

/// Each `translate-c` translation unit declares its own opaque
/// `struct_xcb_connection_t`, so the same handle is not assignment-compatible
/// across them. These casts are the only places that bridge the declarations.
fn keysymConnection(connection: *xcb.xcb_connection_t) *xcb_keysyms.xcb_connection_t {
    return @ptrCast(connection);
}

pub const Surface = surface_mod.Surface;
pub const Translation = event_loop_mod.Translation;

pub const Error = error{
    ConnectionFailed,
    ScreenNotFound,
    WindowCreationFailed,
    GraphicsContextFailed,
    ShmUnavailable,
    OutOfMemory,
    KeymapFailed,
};

pub const Runtime = struct {
    surface: *Surface,
    keysyms: ?*xcb_keysyms.xcb_key_symbols_t,
    should_close: bool = false,
    /// Set when the server wants a full repaint (expose, resize).
    needs_redraw: bool = true,

    pub fn init(title: []const u8, width: u16, height: u16) Error!Runtime {
        const surface = surface_mod.Surface.init(title, width, height) catch |err| {
            return switch (err) {
                error.ConnectionFailed => error.ConnectionFailed,
                error.ScreenNotFound => error.ScreenNotFound,
                error.WindowCreationFailed => error.WindowCreationFailed,
                error.GraphicsContextFailed => error.GraphicsContextFailed,
                error.ShmUnavailable => error.ShmUnavailable,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        errdefer surface.deinit();

        // Keymap translation requires a live connection, so it is allocated
        // here rather than in the surface. A failure is not fatal: keys degrade
        // to `.unknown` and pointer input still works.
        const keysyms = xcb_keysyms.xcb_key_symbols_alloc(keysymConnection(surface.connection));

        return .{ .surface = surface, .keysyms = keysyms };
    }

    pub fn deinit(runtime: *Runtime) void {
        if (runtime.keysyms) |syms| xcb_keysyms.xcb_key_symbols_free(syms);
        runtime.surface.deinit();
    }

    pub fn attach(runtime: *Runtime, app: *app_mod.App) void {
        app.attachSurface(runtime.surface.toSurface());
    }

    /// Returns the next framework event, or null when the queue is drained.
    ///
    /// X11 delivers resize and expose notifications out of band; they are
    /// reported through `needs_redraw` and as a `.resized` event so the caller
    /// can relayout without polling geometry.
    pub fn pollEvent(runtime: *Runtime) ?events_mod.Event {
        while (xcb.xcb_poll_for_event(runtime.surface.connection)) |native| {
            if (runtime.handleNative(native)) |event| return event;
        }
        return null;
    }

    /// Blocks until the server delivers an event, then returns it.
    ///
    /// This is what an idle application uses: the thread sleeps inside the X
    /// connection instead of spinning, so a window with no input costs no CPU.
    /// Returns null when the connection is gone or a close was requested.
    ///
    /// The `should_close` check is load-bearing. A close request arrives as a
    /// client message, which produces no framework event, so without this check
    /// the loop below would call `xcb_wait_for_event` again and block forever —
    /// the window disappears and the process never exits.
    pub fn waitEvent(runtime: *Runtime) ?events_mod.Event {
        while (!runtime.should_close) {
            const native = xcb.xcb_wait_for_event(runtime.surface.connection) orelse {
                runtime.should_close = true;
                return null;
            };
            if (runtime.handleNative(native)) |event| return event;
        }
        return null;
    }

    /// Applies the side effects of one native event and returns the framework
    /// event it produced, if any. `native` is freed before returning.
    fn handleNative(runtime: *Runtime, native: [*c]xcb.xcb_generic_event_t) ?events_mod.Event {
        defer std.c.free(native);

        const translation = event_loop_mod.translate(
            native,
            runtime.keysyms,
            runtime.surface.wm_protocols,
            runtime.surface.wm_delete_window,
        );

        if (translation.quit) runtime.should_close = true;
        if (translation.needs_redraw) runtime.needs_redraw = true;

        if (translation.resized_size) |size_value| {
            runtime.surface.width = @intFromFloat(size_value.width);
            runtime.surface.height = @intFromFloat(size_value.height);
            runtime.needs_redraw = true;
            return .{ .resized = .{ .size = size_value } };
        }

        return translation.event;
    }

    pub fn size(runtime: *Runtime) app_mod.Size {
        return runtime.surface.size();
    }

    pub fn running(runtime: *const Runtime) bool {
        return !runtime.should_close;
    }

    /// True when the frame buffer must be repainted.
    pub fn takeRedraw(runtime: *Runtime) bool {
        const needed = runtime.needs_redraw;
        runtime.needs_redraw = false;
        return needed;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "should_close defaults to false and starts dirty" {
    // No X server in this environment: only the default loop state is checked.
    const runtime: Runtime = .{ .surface = undefined, .keysyms = null };
    try std.testing.expect(!runtime.should_close);
    try std.testing.expect(runtime.running());
    try std.testing.expect(runtime.needs_redraw);
}

test "a pending close stops the loop instead of blocking again" {
    // Regression for a bug found on 2026-10-31 by closing the README example in
    // a real window manager: the process never exited.
    //
    // Cause: `waitEvent` looped on `xcb_wait_for_event` without consulting
    // `should_close`. A WM_DELETE_WINDOW client message sets the flag but emits
    // no framework event, so the loop fell straight back into the blocking call
    // and waited for an event that never comes. The window disappeared and the
    // process sat there forever.
    //
    // A real connection is required to call `xcb_wait_for_event`, so this test
    // pins the guard that now runs *before* the blocking call: with a close
    // already pending, `waitEvent` must return without touching the connection.
    var runtime: Runtime = .{ .surface = undefined, .keysyms = null };
    runtime.should_close = true;

    try std.testing.expect(!runtime.running());
    // `surface` is `undefined` here on purpose: if `waitEvent` reached the
    // connection this would crash, which is exactly the failure being guarded.
    try std.testing.expect(runtime.waitEvent() == null);
}