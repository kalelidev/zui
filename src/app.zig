//! Application runtime: lifecycle and the frame loop.
//!
//! The runtime owns the long-lived objects an application needs — the layout
//! engine, the software renderer and the current theme — and drives one frame at
//! a time: layout, paint, present.
//!
//! Platform integration is deliberately *outside* this module. The runtime talks
//! to a `Surface`, a tiny vtable that abstracts "a place pixels can be shown".
//! That keeps the runtime independent from X11/SDL (Decision 010: the runtime
//! must not depend on the development runner, and platform details stay behind
//! an internal interface) and, more practically, lets the whole lifecycle be
//! tested headlessly on a machine with no display server.
//!
//! Lifecycle and ownership:
//! - `init` either returns a fully initialized runtime or releases whatever it
//!   had already acquired, so a failed startup leaves nothing behind.
//! - `deinit` releases the renderer framebuffer and the layout arena exactly
//!   once. Calling it twice is a bug; the value is poisoned afterwards.
//! - `renderFrame` borrows the node tree for the duration of the call only. The
//!   returned model is owned by the runtime and invalidated by the next frame.
//!
//! Threading: none. One runtime runs on the thread that created it, as
//! `ARCHITECTURE.md` prescribes for the initial implementation.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const component = @import("component.zig");
const layout_mod = @import("layout.zig");
const paint_mod = @import("paint.zig");
const theme_mod = @import("theme.zig");
const software = @import("render/software.zig");

pub const Size = geometry.Size;
pub const Color = color.Color;
pub const Node = component.Node;
pub const Theme = theme_mod.Theme;
pub const Renderer = software.Renderer;
pub const Model = layout_mod.Model;

/// A destination for finished frames.
///
/// Implementations live in the platform layer. The vtable is intentionally tiny:
/// the runtime needs to know how big the target is and to hand it pixels. Event
/// input travels the other way and is handled by the event system, not here.
pub const Surface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Current size of the drawing area in logical pixels.
        get_size: *const fn (context: *anyopaque) Size,
        /// Shows one finished RGBA frame. `pixels` is only valid during the call.
        present: *const fn (
            context: *anyopaque,
            pixels: []const u8,
            frame_size: Size,
        ) SurfaceError!void,
    };

    pub const SurfaceError = error{
        /// The window or display connection is gone; the runtime should stop.
        SurfaceLost,
        /// The frame could not be shown, but the surface is still usable.
        PresentFailed,
    };

    pub fn size(surface: Surface) Size {
        return surface.vtable.get_size(surface.context);
    }

    pub fn presentPixels(surface: Surface, pixels: []const u8, frame_size: Size) SurfaceError!void {
        return surface.vtable.present(surface.context, pixels, frame_size);
    }
};

pub const Error = software.Error || layout_mod.Error || Surface.SurfaceError || error{
    /// `present` was called before a surface was attached.
    SurfaceUnavailable,
};

pub const Options = struct {
    theme: Theme = Theme.light,
    /// Initial drawing area. The renderer is allocated for this size and resized
    /// on the first frame if the surface disagrees.
    surface_size: Size = Size.init(800, 600),
    layout: layout_mod.Options = .{},
};

/// Counters used by the application and by the benchmarks. Plain data, no
/// timestamps: measuring time is the caller's job so the runtime stays
/// deterministic in tests.
pub const Stats = struct {
    frames: usize = 0,
    /// Size of the most recently laid-out root.
    last_size: Size = Size.zero,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    theme: Theme,
    engine: layout_mod.Engine,
    renderer: Renderer,
    surface: ?Surface = null,
    stats: Stats = .{},

    /// Creates the runtime. On failure nothing is left allocated.
    pub fn init(gpa: std.mem.Allocator, options: Options) Error!App {
        var engine = layout_mod.Engine.init(gpa, options.layout);
        errdefer engine.deinit();

        // The renderer allocation is the only step that can fail with OOM, so it
        // runs last: everything acquired before it is already covered by an
        // errdefer.
        const renderer = try Renderer.init(gpa, options.surface_size);

        return .{
            .gpa = gpa,
            .theme = options.theme,
            .engine = engine,
            .renderer = renderer,
        };
    }

    /// Releases the framebuffer and the layout arena. Must be called exactly once.
    pub fn deinit(app: *App) void {
        app.engine.deinit();
        app.renderer.deinit();
        app.surface = null;
    }

    /// Connects the platform surface used by `present`. Passing a new surface
    /// replaces the previous one; the runtime does not own either of them.
    pub fn attachSurface(app: *App, surface: Surface) void {
        app.surface = surface;
    }

    pub fn setTheme(app: *App, theme: Theme) void {
        app.theme = theme;
    }

    /// Lays out `root` at the current drawing size, paints it and updates the
    /// frame counters. Does not present; call `present` for that.
    ///
    /// The returned model borrows runtime storage and is invalidated by the next
    /// call.
    pub fn renderFrame(app: *App, root: *const Node) Error!Model {
        const target = try app.frameSize();

        // Keep the framebuffer the same size as the drawing area. `resize` is a
        // no-op when the size did not change, so steady-state frames do not
        // touch the allocator.
        try app.renderer.resize(target);

        const model = try app.engine.layout(root, target);

        app.renderer.clear(app.theme.palette.background);
        paint_mod.paint(model, &app.renderer, app.theme);

        app.stats.frames += 1;
        app.stats.last_size = model.size;
        return model;
    }

    /// Hands the most recently rendered frame to the surface.
    pub fn present(app: *App) Error!void {
        const surface = app.surface orelse return error.SurfaceUnavailable;
        try surface.presentPixels(app.renderer.pixels, app.renderer.size());
    }

    /// Renders and presents in one step. This is what a platform event loop calls
    /// once per frame.
    pub fn draw(app: *App, root: *const Node) Error!Model {
        const model = try app.renderFrame(root);
        try app.present();
        return model;
    }

    /// Resizes the drawing area ahead of the next frame. The platform calls this
    /// when the window changes size; `renderFrame` would also pick the new size
    /// up from the surface, so calling it is an optimization, not a requirement.
    pub fn resize(app: *App, new_size: Size) Error!void {
        try app.renderer.resize(new_size);
    }

    /// Size the next frame will be laid out at: the surface size when one is
    /// attached, otherwise the current framebuffer size.
    fn frameSize(app: *App) Error!Size {
        if (app.surface) |surface| {
            const surface_size = surface.size();
            if (!surface_size.isValid()) return software.Error.InvalidSize;
            // A minimized or not-yet-mapped window may report zero; fall back to
            // the last known size instead of producing a zero-sized frame.
            if (surface_size.width > 0 and surface_size.height > 0) return surface_size;
        }
        const current = app.renderer.size();
        if (current.width == 0 or current.height == 0) return software.Error.InvalidSize;
        return current;
    }
};

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// A surface that records what it was given. Lives in the test block because it
/// is a test double: the real one belongs to the platform layer.
const RecordingSurface = struct {
    pixels: std.ArrayList(u8) = .empty,
    size_value: Size,
    present_count: usize = 0,
    fail_with: ?Surface.SurfaceError = null,
    /// Set when recording the frame failed, so the test can tell an allocation
    /// problem apart from a surface problem.
    record_error: ?std.mem.Allocator.Error = null,

    fn init(size_value: Size) RecordingSurface {
        return .{ .size_value = size_value };
    }

    fn deinit(self: *RecordingSurface, gpa: std.mem.Allocator) void {
        self.pixels.deinit(gpa);
    }

    fn surface(self: *RecordingSurface) Surface {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Surface.VTable{
        .get_size = getSize,
        .present = present,
    };

    fn getSize(context: *anyopaque) Size {
        const self: *RecordingSurface = @ptrCast(@alignCast(context));
        return self.size_value;
    }

    fn present(context: *anyopaque, pixels: []const u8, frame_size: Size) Surface.SurfaceError!void {
        const self: *RecordingSurface = @ptrCast(@alignCast(context));
        if (self.fail_with) |err| return err;
        self.present_count += 1;
        self.size_value = frame_size;
        self.pixels.resize(std.testing.allocator, pixels.len) catch |err| {
            self.record_error = err;
            return;
        };
        @memcpy(self.pixels.items, pixels);
    }
};

fn spacerNode(storage: *Node, side: f32) *const Node {
    return component.Spacer.node(storage, component.Key.none, Size.square(side));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init and deinit release everything" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(32, 24),
    });
    defer app.deinit();

    try std.testing.expectEqual(@as(u32, 32), app.renderer.width);
    try std.testing.expectEqual(@as(u32, 24), app.renderer.height);
    try std.testing.expect(app.surface == null);
    try std.testing.expectEqual(@as(usize, 0), app.stats.frames);
}

test "init failure releases the engine" {
    // The renderer allocation is the last step, so a failure there must not leak
    // the engine that was created before it.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();

    try std.testing.expectError(Error.OutOfMemory, App.init(gpa, .{
        .surface_size = Size.init(64, 64),
    }));
}

test "renderFrame clears to the theme background" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
        .theme = Theme.light,
    });
    defer app.deinit();

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);

    _ = try app.renderFrame(root);

    const background = app.theme.palette.background;
    try std.testing.expect(Color.eql(background, app.renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(background, app.renderer.getPixel(7, 7)));
}

test "renderFrame paints components over the background" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(20, 20),
    });
    defer app.deinit();

    var storage: Node = undefined;
    const root = component.Box.node(
        &storage,
        component.Key.none,
        component.Modifier.none.withSize(20, 20).withBackground(Color.fromRgb(0x00FF00)),
        null,
        .start,
        .start,
    );

    const model = try app.renderFrame(root);
    try std.testing.expectEqual(@as(f32, 20), model.size.width);
    try std.testing.expect(Color.eql(Color.fromRgb(0x00FF00), app.renderer.getPixel(10, 10)));
}

test "renderFrame counts frames and records the laid-out size" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(16, 16),
    });
    defer app.deinit();

    var storage: Node = undefined;
    const root = spacerNode(&storage, 6);

    _ = try app.renderFrame(root);
    _ = try app.renderFrame(root);

    try std.testing.expectEqual(@as(usize, 2), app.stats.frames);
    try std.testing.expectEqual(@as(f32, 6), app.stats.last_size.width);
}

test "present without a surface is reported, not ignored" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    _ = try app.renderFrame(root);

    try std.testing.expectError(error.SurfaceUnavailable, app.present());
}

test "draw renders and presents in one step" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    var recorder = RecordingSurface.init(Size.init(8, 8));
    defer recorder.deinit(std.testing.allocator);
    app.attachSurface(recorder.surface());

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    _ = try app.draw(root);

    try std.testing.expectEqual(@as(usize, 1), recorder.present_count);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), recorder.pixels.items.len);
}

test "an attached surface drives the frame size" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    // The surface disagrees with the renderer's initial size.
    var recorder = RecordingSurface.init(Size.init(40, 30));
    defer recorder.deinit(std.testing.allocator);
    app.attachSurface(recorder.surface());

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    _ = try app.renderFrame(root);

    try std.testing.expectEqual(@as(u32, 40), app.renderer.width);
    try std.testing.expectEqual(@as(u32, 30), app.renderer.height);
}

test "a zero-sized surface falls back to the last known size" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(12, 12),
    });
    defer app.deinit();

    // A minimized window reports zero; the frame must still be drawn so the
    // runtime does not crash or produce an invalid framebuffer.
    var recorder = RecordingSurface.init(Size.zero);
    defer recorder.deinit(std.testing.allocator);
    app.attachSurface(recorder.surface());

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    _ = try app.renderFrame(root);

    try std.testing.expectEqual(@as(u32, 12), app.renderer.width);
}

test "an invalid surface size is rejected" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    var recorder = RecordingSurface.init(Size.init(-5, 8));
    defer recorder.deinit(std.testing.allocator);
    app.attachSurface(recorder.surface());

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    try std.testing.expectError(Error.InvalidSize, app.renderFrame(root));
}

test "a present failure is propagated to the caller" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    var recorder = RecordingSurface.init(Size.init(8, 8));
    defer recorder.deinit(std.testing.allocator);
    recorder.fail_with = Surface.SurfaceError.SurfaceLost;
    app.attachSurface(recorder.surface());

    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);
    // The frame is still rendered; only the handoff fails.
    _ = try app.renderFrame(root);
    try std.testing.expectError(error.SurfaceLost, app.present());
}

test "an invalid node stops the frame with an explicit error" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();

    var storage: Node = undefined;
    const bad = component.Column.node(&storage, component.Key.none, .{}, &.{}, -1, .start, .start);

    try std.testing.expectError(Error.InvalidNode, app.renderFrame(bad));
    // A failed frame must not be counted as drawn.
    try std.testing.expectEqual(@as(usize, 0), app.stats.frames);
}

test "a node does not own its children, so a by-value return leaves them outside" {
    // Root cause of the bug found on 2026-10-31 in examples/counter.zig and
    // examples/benchmark.zig. A helper built the tree in function locals and
    // returned the root by value:
    //
    //     fn build() Node {
    //         var button: Node = undefined;
    //         ...
    //         return root.*;      // children still point at dead locals
    //     }
    //
    // The copied root is structurally valid, but `box.child` / `row.children`
    // still hold pointers into the frame that just returned. Laying that tree
    // out is undefined behaviour: it panicked in Debug and silently painted
    // garbage in ReleaseFast.
    //
    // This test pins the property that makes the mistake possible, without ever
    // dereferencing the dead frame (doing so would crash the test runner, which
    // is exactly what the bug does). If `Node` ever gains ownership of its
    // children — a deep copy or an arena — this assertion fails and the
    // documentation below must be revisited.
    const Wrong = struct {
        fn build() Node {
            var button: Node = undefined;
            const leaf = component.Button.node(
                &button,
                component.Key.init(1),
                .{},
                "Increment",
                null,
                null,
            );

            var children = [_]*const Node{leaf};
            var column: Node = undefined;
            const parent = component.Column.node(
                &column,
                component.Key.init(2),
                .{},
                &children,
                8,
                .start,
                .start,
            );

            var root_storage: Node = undefined;
            const root = component.Box.node(
                &root_storage,
                component.Key.init(3),
                .{},
                parent,
                .start,
                .start,
            );
            return root.*;
        }
    };

    const broken = Wrong.build();

    // The description itself copied fine.
    try std.testing.expect(broken.isValid());
    try std.testing.expectEqual(@as(usize, 1), broken.childCount());

    // But the child pointer refers to storage that is not part of `broken`:
    // a `Node` is a description, not an owner. That is the contract callers
    // must respect, and the reason the examples keep every node in a struct
    // that outlives the frame.
    const child_ptr = broken.boxChild().?;
    const child_addr = @intFromPtr(child_ptr);
    const root_addr = @intFromPtr(&broken);
    const node_size = @sizeOf(Node);
    try std.testing.expect(
        child_addr < root_addr or child_addr >= root_addr + node_size,
    );

    // The safe shape is exercised by the next test; this one deliberately does
    // not lay the tree out.
}

test "a node tree owned by the caller survives many frames" {
    // The correct shape: every node lives in one value the caller keeps for the
    // whole run. This is the pattern examples/image.zig uses, and the one
    // counter.zig and benchmark.zig were switched to after the 2026-10-31 bug.
    const Ui = struct {
        button: Node = undefined,
        column: Node = undefined,
        root: Node = undefined,
        children: [1]*const Node = undefined,

        fn build(ui: *@This()) *const Node {
            ui.button = component.Button.node(
                &ui.button,
                component.Key.init(1),
                .{},
                "Increment",
                null,
                null,
            ).*;
            ui.children = .{&ui.button};
            ui.column = component.Column.node(
                &ui.column,
                component.Key.init(2),
                .{},
                &ui.children,
                8,
                .start,
                .start,
            ).*;
            ui.root = component.Box.node(
                &ui.root,
                component.Key.init(3),
                .{},
                &ui.column,
                .start,
                .start,
            ).*;
            return &ui.root;
        }
    };

    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(64, 64),
    });
    defer app.deinit();

    var ui: Ui = .{};

    // Rebuilding the tree in place and laying it out repeatedly is what a real
    // frame loop does. If any pointer were dangling this would read freed stack
    // memory and the placement would drift or crash.
    const button_key = component.Key.init(1).value;

    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        const root = ui.build();
        const model = try app.renderFrame(root);
        try std.testing.expect(model.size.width > 0);

        // The button must still be reachable through the tree on every frame,
        // with the identity it was built with.
        const button = ui.root.boxChild().?.kind.column.children[0];
        try std.testing.expectEqual(button_key, button.key.value);
        try std.testing.expect(model.find(button) != null);
    }

    try std.testing.expectEqual(@as(usize, 100), app.stats.frames);
}

test "resize propagates renderer validation" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(8, 8),
    });
    defer app.deinit();

    try app.resize(Size.init(20, 10));
    try std.testing.expectEqual(@as(u32, 20), app.renderer.width);

    try std.testing.expectError(Error.InvalidSize, app.resize(Size.init(std.math.nan(f32), 10)));
}

test "setTheme changes what the next frame paints" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(4, 4),
        .theme = Theme.light,
    });
    defer app.deinit();

    app.setTheme(Theme.dark);

    var storage: Node = undefined;
    const root = spacerNode(&storage, 2);
    _ = try app.renderFrame(root);

    try std.testing.expect(Color.eql(Theme.dark.palette.background, app.renderer.getPixel(0, 0)));
}

test "a full frame with nested components keeps layout and paint in sync" {
    var app = try App.init(std.testing.allocator, .{
        .surface_size = Size.init(100, 60),
    });
    defer app.deinit();

    var title_storage: Node = undefined;
    const title = component.Text.node(
        &title_storage,
        component.Key.init(1),
        .{},
        // Deliberately not the theme background color: the assertion below checks
        // that ink landed, so the colors must differ.
        .{ .text = "ZUI", .style = .{ .size = 7, .color = Color.fromRgb(0x101010) } },
    );

    var button_storage: Node = undefined;
    const button = component.Button.node(&button_storage, component.Key.init(2), .{}, "OK", null, null);

    const children = [_]*const Node{ title, button };
    var column_storage: Node = undefined;
    const column = component.Column.node(&column_storage, component.Key.init(3), .{}, &children, 8, .start, .start);

    var box_storage: Node = undefined;
    const root = component.Box.node(
        &box_storage,
        component.Key.init(4),
        component.Modifier.none.withPadding(geometry.EdgeInsets.all(6)),
        column,
        .start,
        .start,
    );

    const model = try app.renderFrame(root);

    // Both leaves are in the model and inside the framebuffer.
    try std.testing.expect(model.find(title) != null);
    try std.testing.expect(model.find(button) != null);
    try std.testing.expect(model.find(title).?.rect.y < model.find(button).?.rect.y);
    try std.testing.expect(model.size.width <= 100);

    // Something was painted: the title's ink is not the background color.
    const title_rect = model.find(title).?.rect;
    const px: u32 = @intFromFloat(title_rect.x);
    const py: u32 = @intFromFloat(title_rect.y);
    try std.testing.expect(!Color.eql(Theme.light.palette.background, app.renderer.getPixel(px, py)));
}

test "the runtime can be restarted after deinit" {
    var storage: Node = undefined;
    const root = spacerNode(&storage, 4);

    var first = try App.init(std.testing.allocator, .{ .surface_size = Size.init(8, 8) });
    _ = try first.renderFrame(root);
    first.deinit();

    // A second runtime must not be affected by the first one's teardown.
    var second = try App.init(std.testing.allocator, .{ .surface_size = Size.init(4, 4) });
    defer second.deinit();
    _ = try second.renderFrame(root);
    try std.testing.expectEqual(@as(usize, 1), second.stats.frames);
}
