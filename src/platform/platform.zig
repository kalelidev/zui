//! Platform backends.
//!
//! Two backends ship side by side and expose the same API shape (`Runtime` with
//! `init`, `attach`, `pollEvent`, `size`, `running`, `deinit`):
//!
//!   * `sdl3` — SDL3 3.4.18. Handles X11 and Wayland behind one API, picks the
//!     available renderer at runtime, and is the default for Phase 1.
//!   * `x11`  — MIT-SHM over raw xcb. No third-party dependency at all; useful on
//!     X11-only systems and where SDL must not be shipped.
//!
//! A program imports exactly one of them. Nothing above this module may import
//! `sdl3.zig`, `xcb.zig` or any other binding directly.

const std = @import("std");

pub const sdl3 = @import("sdl3/platform.zig");
pub const x11 = @import("x11/platform.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("sdl3/surface.zig");
    _ = @import("sdl3/event_loop.zig");
    _ = @import("sdl3/platform.zig");
    _ = @import("x11/surface.zig");
    _ = @import("x11/event_loop.zig");
    _ = @import("x11/platform.zig");
}