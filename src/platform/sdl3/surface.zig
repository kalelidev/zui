//! SDL3 surface: implements the runtime `Surface` vtable on top of an SDL3
//! window and renderer.
//!
//! This is the only module that touches SDL3 window/renderer/texture handles and
//! pixel formats. Everything above it talks to `app.zig`'s `Surface`, so the
//! framework core stays backend-agnostic (Decision 017).
//!
//! Frame path: the software renderer owns an RGBA framebuffer; `present` streams
//! those bytes into a `SDL_PIXELFORMAT_RGBA32` texture and blits it to the
//! window. `SDL_TEXTUREACCESS_STREAMING` is the intended use for a
//! once-per-frame upload from CPU memory.

const std = @import("std");
const app_mod = @import("zui").app;
const geometry = @import("zui").geometry;
const sdl = @import("sdl3.zig");

pub const Surface = struct {
    window: ?*sdl.SDL_Window,
    renderer: ?*sdl.SDL_Renderer,
    texture: [*c]sdl.SDL_Texture,
    width: c_int,
    height: c_int,

    pub const Error = error{
        OutOfMemory,
        WindowCreationFailed,
        RendererCreationFailed,
        TextureCreationFailed,
    };

    /// Creates a resizable window plus the renderer and streaming texture that
    /// receive the software framebuffer. `SDL_Init` must already have succeeded.
    pub fn init(title: [*c]const u8, width: c_int, height: c_int) Error!*Surface {
        // The window outlives every frame, so it cannot live on a caller's stack
        // frame: the allocator here is the process C allocator, matching SDL's
        // own lifetime model.
        const allocator = std.heap.c_allocator;
        const surface = try allocator.create(Surface);
        errdefer allocator.destroy(surface);

        surface.* = .{
            .window = null,
            .renderer = null,
            .texture = null,
            .width = width,
            .height = height,
        };

        surface.window = sdl.SDL_CreateWindow(
            title,
            width,
            height,
            sdl.SDL_WINDOW_RESIZABLE,
        );
        if (surface.window == null) return error.WindowCreationFailed;

        // A null driver name lets SDL pick the best available backend (GPU or
        // software) for this machine.
        surface.renderer = sdl.SDL_CreateRenderer(surface.window, null);
        if (surface.renderer == null) return error.RendererCreationFailed;

        surface.texture = sdl.SDL_CreateTexture(
            surface.renderer,
            sdl.SDL_PIXELFORMAT_RGBA32,
            sdl.SDL_TEXTUREACCESS_STREAMING,
            width,
            height,
        );
        if (surface.texture == null) return error.TextureCreationFailed;

        return surface;
    }

    /// Releases the texture, renderer, window and the surface allocation.
    pub fn deinit(surface: *Surface) void {
        if (surface.texture != null) sdl.SDL_DestroyTexture(surface.texture);
        if (surface.renderer) |renderer| sdl.SDL_DestroyRenderer(renderer);
        if (surface.window) |window| sdl.SDL_DestroyWindow(window);
        std.heap.c_allocator.destroy(surface);
    }

    /// The vtable handed to `app.zig`. Static: it never changes per instance.
    const vtable = app_mod.Surface.VTable{
        .get_size = getSizeThunk,
        .present = presentThunk,
    };

    pub fn toSurface(surface: *Surface) app_mod.Surface {
        return .{ .context = surface, .vtable = &vtable };
    }

    fn getSizeThunk(context: *anyopaque) app_mod.Size {
        const surface: *Surface = @ptrCast(@alignCast(context));
        return surface.size();
    }

    fn presentThunk(
        context: *anyopaque,
        pixels: []const u8,
        frame_size: app_mod.Size,
    ) app_mod.Surface.SurfaceError!void {
        const surface: *Surface = @ptrCast(@alignCast(context));
        try surface.present(pixels, frame_size);
    }

    pub fn size(surface: *const Surface) app_mod.Size {
        return .{
            .width = @floatFromInt(surface.width),
            .height = @floatFromInt(surface.height),
        };
    }

    /// Uploads one RGBA frame and shows it.
    pub fn present(
        surface: *Surface,
        pixels: []const u8,
        frame_size: app_mod.Size,
    ) app_mod.Surface.SurfaceError!void {
        if (pixels.len == 0) return app_mod.Surface.SurfaceError.PresentFailed;

        const width: c_int = @intFromFloat(@round(frame_size.width));
        const height: c_int = @intFromFloat(@round(frame_size.height));
        if (width <= 0 or height <= 0) return app_mod.Surface.SurfaceError.PresentFailed;

        // The texture is recreated when the window size changes; keeping the
        // check here means `resize` never has to be called by the runtime.
        if (width != surface.width or height != surface.height) {
            surface.resize(width, height) catch
                return app_mod.Surface.SurfaceError.PresentFailed;
        }

        const pitch: c_int = @intCast(@as(usize, @intCast(width)) * 4);
        if (!sdl.SDL_UpdateTexture(surface.texture, null, pixels.ptr, pitch)) {
            return app_mod.Surface.SurfaceError.PresentFailed;
        }

        _ = sdl.SDL_RenderClear(surface.renderer);
        _ = sdl.SDL_RenderTexture(surface.renderer, surface.texture, null, null);
        _ = sdl.SDL_RenderPresent(surface.renderer);
    }

    /// Recreates the streaming texture for a new window size.
    pub fn resize(surface: *Surface, width: c_int, height: c_int) Error!void {
        if (width <= 0 or height <= 0) return;

        if (surface.texture != null) sdl.SDL_DestroyTexture(surface.texture);
        surface.texture = null;

        surface.texture = sdl.SDL_CreateTexture(
            surface.renderer,
            sdl.SDL_PIXELFORMAT_RGBA32,
            sdl.SDL_TEXTUREACCESS_STREAMING,
            width,
            height,
        );
        if (surface.texture == null) return error.TextureCreationFailed;

        surface.width = width;
        surface.height = height;
    }

    /// Reads the size SDL currently reports for the window. Used when the window
    /// manager, not the application, performed the resize.
    pub fn syncSize(surface: *Surface) void {
        var width: c_int = 0;
        var height: c_int = 0;
        if (!sdl.SDL_GetWindowSize(surface.window, &width, &height)) return;
        if (width > 0 and height > 0) {
            surface.width = width;
            surface.height = height;
        }
    }

    pub fn show(surface: *Surface) void {
        _ = sdl.SDL_ShowWindow(surface.window);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "size conversion keeps the logical size" {
    var surface: Surface = .{
        .window = null,
        .renderer = null,
        .texture = null,
        .width = 800,
        .height = 600,
    };
    const size_value = surface.size();
    try std.testing.expectEqual(@as(f32, 800), size_value.width);
    try std.testing.expectEqual(@as(f32, 600), size_value.height);
    try std.testing.expect(size_value.isValid());
}

test "resize rejects non-positive sizes without touching SDL" {
    // Guard before any SDL call: an invalid size must not reach the API.
    var surface: Surface = .{
        .window = null,
        .renderer = null,
        .texture = null,
        .width = 10,
        .height = 10,
    };
    try surface.resize(0, 10);
    try surface.resize(10, -5);
    // Still the original size because both calls returned early.
    try std.testing.expectEqual(@as(c_int, 10), surface.width);
    try std.testing.expectEqual(@as(c_int, 10), surface.height);
}

test "vtable exposes the instance size through type erasure" {
    var surface: Surface = .{
        .window = null,
        .renderer = null,
        .texture = null,
        .width = 320,
        .height = 240,
    };
    const erased = surface.toSurface();
    const size_value = erased.size();
    try std.testing.expectEqual(@as(f32, 320), size_value.width);
    try std.testing.expectEqual(@as(f32, 240), size_value.height);
    _ = &surface;
}