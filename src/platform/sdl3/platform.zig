//! SDL3 backend: initialization, window lifetime and event polling.
//!
//! The backend owns the SDL video subsystem, the window surface and the running
//! flag. Applications drive it with `init`, `pollEvent`, `present` and `deinit`
//! and never see an SDL type.

const std = @import("std");
const app_mod = @import("zui").app;
const events_mod = @import("zui").events;
const sdl = @import("sdl3.zig");
const surface_mod = @import("surface.zig");
const event_loop_mod = @import("event_loop.zig");

pub const Surface = surface_mod.Surface;
pub const Translation = event_loop_mod.Translation;

pub const Error = error{
    /// SDL could not initialize its video subsystem.
    SdlInitFailed,
    OutOfMemory,
    WindowCreationFailed,
    RendererCreationFailed,
    TextureCreationFailed,
};

/// Owns the SDL video subsystem and the window.
pub const Runtime = struct {
    surface: *Surface,
    /// Set once the platform asked the application to stop. The application is
    /// still free to keep running: this is a request, not an exit.
    should_close: bool = false,

    /// Starts SDL's video subsystem and opens the window.
    pub fn init(title: [*c]const u8, width: c_int, height: c_int) Error!Runtime {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInitFailed;

        // From here on every failure path must undo the SDL init.
        const surface = surface_mod.Surface.init(title, width, height) catch |err| {
            sdl.SDL_Quit();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.WindowCreationFailed => error.WindowCreationFailed,
                error.RendererCreationFailed => error.RendererCreationFailed,
                error.TextureCreationFailed => error.TextureCreationFailed,
            };
        };

        surface.show();

        return .{ .surface = surface };
    }

    /// Destroys the window and shuts SDL down. Call exactly once.
    pub fn deinit(runtime: *Runtime) void {
        runtime.surface.deinit();
        sdl.SDL_Quit();
    }

    /// Hands the platform surface to the application runtime so `present`
    /// reaches the window.
    pub fn attach(runtime: *Runtime, app: *app_mod.App) void {
        app.attachSurface(runtime.surface.toSurface());
    }

    /// Returns the next framework event, or null when the queue is drained.
    ///
    /// SDL events the framework does not model are skipped, not returned, so a
    /// caller looping until null sees only meaningful input. A close request is
    /// reported both as `.close_requested` and through `should_close`.
    pub fn pollEvent(runtime: *Runtime) ?events_mod.Event {
        var native: sdl.SDL_Event = undefined;

        while (sdl.SDL_PollEvent(&native)) {
            if (runtime.handleNative(&native)) |event| return event;
        }

        // The window manager may have resized the window while we were idle;
        // re-read the size so the next frame lays out at the right dimensions.
        runtime.surface.syncSize();
        return null;
    }

    /// Blocks until SDL delivers an event, then returns it.
    ///
    /// This is what an idle application uses: the thread sleeps inside SDL's
    /// event wait instead of spinning, so a window with no input costs no CPU.
    /// Returns null when the window is going away or a close was requested.
    ///
    /// The `should_close` check is load-bearing, for the same reason as in the
    /// X11 backend: a quit request translates to no framework event, so without
    /// it the loop would wait again and never let the caller observe the request.
    pub fn waitEvent(runtime: *Runtime) ?events_mod.Event {
        var native: sdl.SDL_Event = undefined;

        while (!runtime.should_close) {
            if (!sdl.SDL_WaitEvent(&native)) {
                runtime.should_close = true;
                return null;
            }
            if (runtime.handleNative(&native)) |event| return event;
        }
        return null;
    }

    /// Applies the side effects of one native event and returns the framework
    /// event it produced, if any.
    fn handleNative(runtime: *Runtime, native: *sdl.SDL_Event) ?events_mod.Event {
        const translation = event_loop_mod.translate(native);
        if (translation.quit) runtime.should_close = true;
        return translation.event;
    }

    pub fn size(runtime: *Runtime) app_mod.Size {
        return runtime.surface.size();
    }

    /// True while the platform has not asked to close.
    pub fn running(runtime: *const Runtime) bool {
        return !runtime.should_close;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "should_close defaults to false" {
    // A window cannot be created here (no display), so the observable default
    // the loop depends on is checked directly.
    const runtime: Runtime = .{ .surface = undefined };
    try std.testing.expect(!runtime.should_close);
    try std.testing.expect(runtime.running());
}