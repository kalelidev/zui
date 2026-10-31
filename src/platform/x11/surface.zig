//! X11/xcb surface: window, graphics context and a shared-memory frame path.
//!
//! Rendering uses MIT-SHM when the server offers it: the software renderer
//! writes straight into a shared segment and `xcb_shm_put_image` copies it
//! server-side, so a full frame never crosses the socket as protocol data. When
//! SHM is unavailable the surface falls back to `xcb_put_image` over the normal
//! request stream, which is slower but works everywhere.
//!
//! Only this module knows about windows, GCs and pixel formats. Everything above
//! talks to `zui.app.Surface`.

const std = @import("std");
const app_mod = @import("zui").app;
const geometry = @import("zui").geometry;

const xcb = @import("xcb.zig");
const xcb_shm = @import("xcb-shm.zig");

/// System V shared memory. `std.c` does not declare these in Zig 0.17.0, so the
/// prototypes are spelled out here; they are stable POSIX/System V ABI and come
/// straight from `<sys/shm.h>`.
extern "c" fn shmget(key: c_int, size: usize, shmflg: c_int) c_int;
extern "c" fn shmat(shmid: c_int, shmaddr: ?*const anyopaque, shmflg: c_int) ?*anyopaque;
extern "c" fn shmdt(shmaddr: *const anyopaque) c_int;
extern "c" fn shmctl(shmid: c_int, cmd: c_int, buf: ?*anyopaque) c_int;

/// `IPC_PRIVATE` and the two flags used below, from `<sys/ipc.h>`.
const IPC_PRIVATE: c_int = 0;
const IPC_CREAT: c_int = 0o1000;
const IPC_RMID: c_int = 0;

/// Each `translate-c` translation unit declares its own opaque
/// `struct_xcb_connection_t`, so pointers are not assignment-compatible across
/// them even though they are the same handle at runtime. This cast is the single
/// place that bridges the two declarations.
fn shmConnection(connection: *xcb.xcb_connection_t) *xcb_shm.xcb_connection_t {
    return @ptrCast(connection);
}

pub const Surface = struct {
    connection: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    window: xcb.xcb_window_t,
    gc: xcb.xcb_gcontext_t,
    /// Atom whose client message asks the window manager to close us; also used
    /// as the WM_DELETE_WINDOW protocol value.
    wm_protocols: xcb.xcb_atom_t,
    wm_delete_window: xcb.xcb_atom_t,
    depth: u8,
    width: u16,
    height: u16,

    /// Byte offset of each channel inside one 32-bit pixel, derived from the
    /// visual's masks. The X server does not use RGBA memory order on every
    /// visual: a depth-24 TrueColor visual commonly has `red_mask = 0xff0000`,
    /// which means the server reads each word as BGRX. Copying an RGBA buffer
    /// straight through therefore swaps red and blue. `present` uses these
    /// offsets to build the pixel the server expects.
    channel_offsets: ChannelOffsets = .{ .r = 0, .g = 1, .b = 2 },
    /// True when the visual already matches the renderer's RGBA byte order, so
    /// `present` can copy the buffer without repacking. This is the common case
    /// on big-endian-oriented visuals and keeps the fast path intact.
    native_rgba: bool = false,

    shm: ?SharedMemory = null,
    /// False when the server refused MIT-SHM; frames then go through
    /// `xcb_put_image`.
    shm_available: bool = false,

    pub const SharedMemory = struct {
        segment_id: c_int,
        addr: [*]u8,
        bytes: usize,
        seg: xcb_shm.xcb_shm_seg_t,
    };

    /// Byte position of each colour channel within one 32-bit pixel word, as
    /// the server will interpret it.
    pub const ChannelOffsets = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const Error = error{
        ConnectionFailed,
        ScreenNotFound,
        WindowCreationFailed,
        GraphicsContextFailed,
        ShmUnavailable,
        OutOfMemory,
    };

    /// Connects to the X server named by `DISPLAY` and creates a resizable
    /// window with the event mask the runtime needs.
    pub fn init(title: []const u8, width: u16, height: u16) Error!*Surface {
        const allocator = std.heap.c_allocator;
        const surface = try allocator.create(Surface);
        errdefer allocator.destroy(surface);

        // A null display name means "use $DISPLAY".
        const connection = xcb.xcb_connect(null, null) orelse return error.ConnectionFailed;
        errdefer xcb.xcb_disconnect(connection);

        if (xcb.xcb_connection_has_error(connection) != 0) return error.ConnectionFailed;

        const setup = xcb.xcb_get_setup(connection);
        if (setup == null) return error.ConnectionFailed;

        const iterator = xcb.xcb_setup_roots_iterator(setup);
        // `data` is a C pointer ([*c]); coerce to an optional single-item
        // pointer so a null screen is rejected instead of dereferenced.
        const maybe_screen: ?*xcb.xcb_screen_t = iterator.data;
        const screen = maybe_screen orelse return error.ScreenNotFound;

        const window = xcb.xcb_generate_id(connection);

        // Ask for exactly the input the runtime consumes. StructureNotify gives
        // us CONFIGURE_NOTIFY (resize) and DESTROY_NOTIFY; Exposure tells us when
        // we must repaint.
        const event_mask: u32 = @intCast(
            xcb.XCB_EVENT_MASK_EXPOSURE |
                xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                xcb.XCB_EVENT_MASK_KEY_PRESS |
                xcb.XCB_EVENT_MASK_KEY_RELEASE |
                xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                xcb.XCB_EVENT_MASK_POINTER_MOTION |
                xcb.XCB_EVENT_MASK_FOCUS_CHANGE,
        );

        const value_mask: u32 = @intCast(xcb.XCB_CW_EVENT_MASK);
        const values = [_]u32{event_mask};

        _ = xcb.xcb_create_window(
            connection,
            screen.root_depth,
            window,
            screen.root,
            0,
            0,
            width,
            height,
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            value_mask,
            &values,
        );

        const gc = xcb.xcb_generate_id(connection);
        _ = xcb.xcb_create_gc(connection, gc, window, 0, null);

        surface.* = .{
            .connection = connection,
            .screen = screen,
            .window = window,
            .gc = gc,
            .wm_protocols = 0,
            .wm_delete_window = 0,
            .depth = screen.root_depth,
            .width = width,
            .height = height,
        };

        surface.resolveChannelOrder();
        surface.setTitle(title);
        surface.setCloseProtocol();

        _ = xcb.xcb_map_window(connection, window);
        _ = xcb.xcb_flush(connection);

        surface.tryEnableShm();

        return surface;
    }

    pub fn deinit(surface: *Surface) void {
        surface.disableShm();
        _ = xcb.xcb_destroy_window(surface.connection, surface.window);
        xcb.xcb_disconnect(surface.connection);
        std.heap.c_allocator.destroy(surface);
    }

    // -- pixel format -------------------------------------------------------

    /// Walks the screen's allowed depths looking for the visual the window was
    /// created with, then derives where each colour channel sits in a pixel.
    ///
    /// The masks are little-endian bit masks. For the common depth-24 TrueColor
    /// visual (`red_mask = 0xff0000`, `green = 0xff00`, `blue = 0xff`) the red
    /// channel occupies bits 16..23, which the server places at byte offset 2,
    /// i.e. memory order BGRX. Because the software renderer produces RGBA, the
    /// surface has to put R at offset 2 and B at offset 0.
    fn resolveChannelOrder(surface: *Surface) void {
        const setup = xcb.xcb_get_setup(surface.connection);
        if (setup == null) return;

        var screen_iter = xcb.xcb_setup_roots_iterator(setup);
        while (screen_iter.rem > 0) : (xcb.xcb_screen_next(&screen_iter)) {
            const screen = screen_iter.data;
            if (screen == null) continue;
            if (screen.*.root_visual != surface.screen.root_visual) continue;

            var depth_iter = xcb.xcb_screen_allowed_depths_iterator(screen);
            while (depth_iter.rem > 0) : (xcb.xcb_depth_next(&depth_iter)) {
                const depth = depth_iter.data;
                if (depth == null) continue;
                if (depth.*.depth != surface.depth) continue;

                var visual_iter = xcb.xcb_depth_visuals_iterator(depth);
                while (visual_iter.rem > 0) : (xcb.xcb_visualtype_next(&visual_iter)) {
                    const visual = visual_iter.data;
                    if (visual == null) continue;
                    if (visual.*.visual_id != surface.screen.root_visual) continue;

                    surface.applyMasks(visual.*.red_mask, visual.*.green_mask, visual.*.blue_mask);
                    return;
                }
            }
        }

        // No visual description found: assume the standard little-endian BGRX
        // layout. Guessing here is safe because the fallback is exactly what
        // most X servers use for depth 24.
        surface.applyMasks(0xff0000, 0xff00, 0xff);
    }

    /// Converts a little-endian channel mask into the byte offset the server
    /// will use for that channel.
    fn offsetOfMask(mask: u32) ?u8 {
        if (mask == 0) return null;
        const shift: u5 = @intCast(@ctz(mask));
        return @intCast(shift / 8);
    }

    fn applyMasks(surface: *Surface, red: u32, green: u32, blue: u32) void {
        const r = offsetOfMask(red) orelse 0;
        const g = offsetOfMask(green) orelse 1;
        const b = offsetOfMask(blue) orelse 2;
        surface.channel_offsets = .{ .r = r, .g = g, .b = b };
        // RGBA in memory means R at 0, G at 1, B at 2 (alpha at 3 is ignored by
        // the server for depth 24).
        surface.native_rgba = (r == 0 and g == 1 and b == 2);
    }

    /// Repacks an RGBA frame into the byte order the server expects.
    fn repackRgba(offsets: ChannelOffsets, source: []const u8, dest: []u8) void {
        var i: usize = 0;
        while (i + 3 < source.len) : (i += 4) {
            dest[i + offsets.r] = source[i];
            dest[i + offsets.g] = source[i + 1];
            dest[i + offsets.b] = source[i + 2];
        }
    }

    // -- window properties --------------------------------------------------

    fn internAtom(surface: *Surface, name: []const u8) xcb.xcb_atom_t {
        const cookie = xcb.xcb_intern_atom(
            surface.connection,
            0,
            @intCast(name.len),
            name.ptr,
        );
        const reply = xcb.xcb_intern_atom_reply(surface.connection, cookie, null);
        if (reply == null) return 0;

        const atom = reply.*.atom;
        std.c.free(reply);
        return atom;
    }

    fn setTitle(surface: *Surface, title: []const u8) void {
        const net_wm_name = surface.internAtom("_NET_WM_NAME");
        const utf8_string = surface.internAtom("UTF8_STRING");
        if (net_wm_name != 0 and utf8_string != 0) {
            _ = xcb.xcb_change_property(
                surface.connection,
                xcb.XCB_PROP_MODE_REPLACE,
                surface.window,
                net_wm_name,
                utf8_string,
                8,
                @intCast(title.len),
                title.ptr,
            );
        }

        // WM_NAME as well: older window managers and tools read only this one.
        _ = xcb.xcb_change_property(
            surface.connection,
            xcb.XCB_PROP_MODE_REPLACE,
            surface.window,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );
    }

    /// Registers WM_DELETE_WINDOW so the window manager sends us a client
    /// message instead of killing the connection when the user closes the
    /// window.
    fn setCloseProtocol(surface: *Surface) void {
        surface.wm_protocols = surface.internAtom("WM_PROTOCOLS");
        surface.wm_delete_window = surface.internAtom("WM_DELETE_WINDOW");
        if (surface.wm_protocols == 0 or surface.wm_delete_window == 0) return;

        const protocol = [_]xcb.xcb_atom_t{surface.wm_delete_window};
        _ = xcb.xcb_change_property(
            surface.connection,
            xcb.XCB_PROP_MODE_REPLACE,
            surface.window,
            surface.wm_protocols,
            4, // XA_ATOM
            32,
            protocol.len,
            &protocol,
        );
    }

    // -- shared memory ------------------------------------------------------

    fn tryEnableShm(surface: *Surface) void {
        // The server must advertise MIT-SHM and support the version we use.
        const cookie = xcb_shm.xcb_shm_query_version(shmConnection(surface.connection));
        const reply = xcb_shm.xcb_shm_query_version_reply(shmConnection(surface.connection), cookie, null);
        if (reply == null) return;

        const supported = reply.*.shared_pixmaps;
        std.c.free(reply);
        if (supported == 0) return;

        surface.shm_available = true;
        surface.ensureShm(std.math.maxInt(u16) / 4, surface.height) catch {
            surface.shm_available = false;
        };
    }

    fn ensureShm(surface: *Surface, width: u16, height: u16) Error!void {
        const bytes = @as(usize, width) * @as(usize, height) * 4;
        if (surface.shm) |shm| {
            if (shm.bytes >= bytes) return;
        }
        surface.disableShm();

        const segment_id = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0o600);
        if (segment_id < 0) return error.ShmUnavailable;
        errdefer _ = shmctl(segment_id, IPC_RMID, null);

        const addr = shmat(segment_id, null, 0) orelse return error.ShmUnavailable;

        const seg = xcb.xcb_generate_id(surface.connection);
        _ = xcb_shm.xcb_shm_attach(shmConnection(surface.connection), seg, @intCast(segment_id), 0);

        surface.shm = .{
            .segment_id = segment_id,
            .addr = @ptrCast(addr),
            .bytes = bytes,
            .seg = seg,
        };
    }

    fn disableShm(surface: *Surface) void {
        if (surface.shm) |shm| {
            _ = xcb_shm.xcb_shm_detach(shmConnection(surface.connection), shm.seg);
            _ = shmdt(shm.addr);
            _ = shmctl(shm.segment_id, IPC_RMID, null);
            surface.shm = null;
        }
    }

    // -- Surface vtable -----------------------------------------------------

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

    /// Uploads one RGBA frame and flushes it to the server.
    pub fn present(
        surface: *Surface,
        pixels: []const u8,
        frame_size: app_mod.Size,
    ) app_mod.Surface.SurfaceError!void {
        const width: u16 = @intFromFloat(std.math.clamp(frame_size.width, 1, 65535));
        const height: u16 = @intFromFloat(std.math.clamp(frame_size.height, 1, 65535));
        const expected = @as(usize, width) * @as(usize, height) * 4;
        if (pixels.len < expected) return app_mod.Surface.SurfaceError.PresentFailed;

        if (width != surface.width or height != surface.height) {
            surface.width = width;
            surface.height = height;
        }

        if (surface.shm) |shm| {
            surface.ensureShm(width, height) catch return app_mod.Surface.SurfaceError.PresentFailed;
            const target = surface.shm orelse return app_mod.Surface.SurfaceError.PresentFailed;
            _ = shm;

            // Depth 24 with an RGBA layout: the server ignores the alpha byte,
            // but not the RGB order. A visual with `red_mask = 0xff0000` reads
            // each word as BGRX, so the buffer is repacked unless the visual
            // already matches RGBA.
            if (surface.native_rgba) {
                @memcpy(target.addr[0..expected], pixels[0..expected]);
            } else {
                Surface.repackRgba(surface.channel_offsets, pixels[0..expected], target.addr[0..expected]);
            }

            _ = xcb_shm.xcb_shm_put_image(
                shmConnection(surface.connection),
                surface.window,
                surface.gc,
                width,
                height,
                0,
                0,
                width,
                height,
                0,
                0,
                surface.depth,
                2, // ZPixmap
                0,
                target.seg,
                0,
            );
        } else {
            // The non-SHM path needs a buffer in server byte order too. It uses
            // the caller's pixels directly when the visual happens to match, and
            // a scratch buffer repacked from the layout arena otherwise.
            var scratch: ?[]u8 = null;
            defer if (scratch) |buffer| std.heap.c_allocator.free(buffer);

            var payload: []const u8 = pixels[0..expected];
            if (!surface.native_rgba) {
                const buffer = std.heap.c_allocator.alloc(u8, expected) catch
                    return app_mod.Surface.SurfaceError.PresentFailed;
                Surface.repackRgba(surface.channel_offsets, pixels[0..expected], buffer);
                scratch = buffer;
                payload = buffer;
            }

            _ = xcb.xcb_put_image(
                surface.connection,
                2, // format: ZPixmap
                surface.window,
                surface.gc,
                width,
                height,
                0, // dst_x
                0, // dst_y
                0, // left_pad
                surface.depth,
                @intCast(expected),
                payload.ptr,
            );
        }

        _ = xcb.xcb_flush(surface.connection);
    }

    /// Reads the current window geometry from the server.
    pub fn syncSize(surface: *Surface) void {
        const cookie = xcb.xcb_get_geometry(surface.connection, surface.window);
        const reply = xcb.xcb_get_geometry_reply(surface.connection, cookie, null);
        if (reply == null) return;

        const width = reply.*.width;
        const height = reply.*.height;
        std.c.free(reply);

        if (width > 0 and height > 0) {
            surface.width = width;
            surface.height = height;
        }
    }

    pub fn show(surface: *Surface) void {
        _ = xcb.xcb_map_window(surface.connection, surface.window);
        _ = xcb.xcb_flush(surface.connection);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "size conversion keeps the logical size" {
    var surface: Surface = .{
        .connection = undefined,
        .screen = undefined,
        .window = 0,
        .gc = 0,
        .wm_protocols = 0,
        .wm_delete_window = 0,
        .depth = 24,
        .width = 640,
        .height = 480,
    };
    const size_value = surface.size();
    try std.testing.expectEqual(@as(f32, 640), size_value.width);
    try std.testing.expectEqual(@as(f32, 480), size_value.height);
    try std.testing.expect(size_value.isValid());
}

test "vtable exposes the instance size through type erasure" {
    var surface: Surface = .{
        .connection = undefined,
        .screen = undefined,
        .window = 0,
        .gc = 0,
        .wm_protocols = 0,
        .wm_delete_window = 0,
        .depth = 24,
        .width = 320,
        .height = 200,
    };
    const erased = surface.toSurface();
    try std.testing.expectEqual(@as(f32, 320), erased.size().width);
    try std.testing.expectEqual(@as(f32, 200), erased.size().height);
    _ = &surface;
}