//! The minimal ZUI application, extracted verbatim from README.md.
//!
//! This file exists so the snippet in the README is proven to compile and run
//! rather than merely look plausible. If the README changes, change this too.
//!
//! Run: zig build run-readme-example
const std = @import("std");
const zui = @import("zui");
const platform = @import("platform");

/// Every node the tree points at. The layout engine borrows these pointers, so
/// they must outlive the frame loop — this struct is the application's window.
const Ui = struct {
    root: zui.Node = undefined,
    column: zui.Node = undefined,
    title: zui.Node = undefined,
    body: zui.Node = undefined,
    children: [2]*const zui.Node = undefined,

    fn build(ui: *Ui) *const zui.Node {
        ui.title = zui.Text.node(&ui.title, zui.Key.init(1), .{}, .{
            .text = "Hello, ZUI",
            .style = .{ .size = 28, .color = zui.Color.fromRgb(0x1A1A1A), .weight = .bold },
        }).*;

        ui.body = zui.Text.node(&ui.body, zui.Key.init(2), .{}, .{
            .text = "A declarative native UI framework for Zig",
            .style = .{ .size = 14, .color = zui.Color.fromRgb(0x666666) },
        }).*;

        ui.children = .{ &ui.title, &ui.body };

        ui.column = zui.Column.node(&ui.column, zui.Key.init(3), .{}, &ui.children, 12, .start, .start).*;

        ui.root = zui.Box.node(
            &ui.root,
            zui.Key.init(0),
            zui.Modifier.none
                .withSize(480, 240)
                .withPadding(zui.EdgeInsets.all(32))
                .withBackground(zui.Theme.light.palette.background),
            &ui.column,
            .start,
            .start,
        ).*;

        return &ui.root;
    }
};

pub fn main(init: std.process.Init) !void {
    // 1. Open a window. This is the only platform-specific line: swap
    //    `platform.x11` for `platform.sdl3` and nothing else changes.
    var runtime = try platform.x11.Runtime.init("Hello, ZUI", 480, 240);
    defer runtime.deinit();

    // 2. Create the runtime that owns layout, the renderer and the theme.
    var app = try zui.App.init(init.gpa, .{
        .surface_size = zui.Size.init(480, 240),
        .theme = zui.Theme.light,
    });
    defer app.deinit();

    runtime.attach(&app);

    var ui: Ui = .{};

    // 3. Draw one frame, then redraw only when something asks for it.
    //
    //    Redrawing is not optional after a resize: the window is now a
    //    different size, so the surface must be repainted or the extra area
    //    stays blank/garbage. A minimized window reports a zero size, and
    //    `App` falls back to the last valid size instead of failing, but we
    //    still skip the frame: painting into a zero-area window is wasted work.
    const redraw = struct {
        fn now(app_ptr: *zui.App, ui_ptr: *Ui, size_value: zui.Size) !void {
            if (size_value.width < 1 or size_value.height < 1) return;
            _ = try app_ptr.draw(ui_ptr.build());
        }
    };
    try redraw.now(&app, &ui, runtime.size());

    // 4. Block on input. An idle window uses no CPU.
    while (runtime.running()) {
        // Drain what is already queued before blocking, so a burst of events is
        // handled in one pass and the loop cannot miss a pending close.
        var dirty = false;
        while (runtime.pollEvent()) |event| {
            dirty = handle(&runtime, event) or dirty;
        }

        if (runtime.running()) {
            const event = runtime.waitEvent() orelse break;
            dirty = handle(&runtime, event) or dirty;
        }

        // Repaint only when the visible result can have changed. Repainting on
        // every pointer move would burn CPU for nothing, which defeats the
        // point of a blocking loop. The surface size is read from the platform,
        // not from the renderer: the renderer learns the new size inside the
        // next frame.
        //
        // `takeRedraw` matters for a reason an event loop cannot see: the server
        // sends Expose when the window was obscured and is visible again — after
        // being minimized, covered, or moved off screen. Expose produces no
        // framework event, so without this check the restored window stays
        // black. It never fires while the window sits still.
        if (dirty or runtime.takeRedraw()) try redraw.now(&app, &ui, runtime.size());
    }
}

/// Applies one framework event. Returns true when the window must be repainted.
fn handle(runtime: *platform.x11.Runtime, event: zui.Event) bool {
    switch (event) {
        .close_requested => {
            runtime.should_close = true;
            return false;
        },
        // A resize makes the previous frame the wrong size, so it must be
        // repainted. This is the difference between a window that follows its
        // new geometry and one that stays frozen at the old size.
        .resized => return true,
        else => return false,
    }
}
