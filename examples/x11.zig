//! X11/xcb example: a real window with no third-party dependency.
//!
//! Same interface as `examples/sdl3.zig`, driven by the xcb backend instead.
//! Compare the two `main` functions: the framework calls are identical, only the
//! imported backend differs. That is the point of the `Surface` abstraction.
//!
//! Requires an X server (`DISPLAY`). Without one this exits with
//! `ConnectionFailed`; the headless path is `zig build image`.
//!
//! Usage:
//!   zig build run-x11

const std = @import("std");
const zui = @import("zui");
const platform = @import("platform");

const Node = zui.Node;
const Modifier = zui.Modifier;
const Color = zui.Color;
const EdgeInsets = zui.EdgeInsets;
const Size = zui.Size;
const Point = zui.Point;

const window_width: u16 = 640;
const window_height: u16 = 420;

/// Every node the tree points at, plus the text buffer it borrows.
const Interface = struct {
    root: Node = undefined,
    title: Node = undefined,
    hint: Node = undefined,
    status: Node = undefined,
    column: Node = undefined,

    body: [3]*const Node = undefined,

    status_buffer: [96]u8 = undefined,
    status_len: usize = 0,

    fn build(ui: *Interface, pointer: Point, clicks: usize, size_value: Size) void {
        const palette = zui.Theme.light.palette;

        const wrote: []const u8 = std.fmt.bufPrint(
            &ui.status_buffer,
            "POINTER {d},{d}  CLICKS {d}",
            .{
                @as(i32, @intFromFloat(pointer.x)),
                @as(i32, @intFromFloat(pointer.y)),
                clicks,
            },
        ) catch &.{};
        ui.status_len = wrote.len;

        ui.title = zui.Text.node(
            &ui.title,
            zui.Key.init(1),
            .{},
            .{ .text = "ZUI + X11", .style = .{ .size = 28, .color = Color.fromRgb(0x1A1A1A), .weight = .bold } },
        ).*;

        ui.hint = zui.Text.node(
            &ui.hint,
            zui.Key.init(2),
            .{},
            .{ .text = "RAW XCB, MIT-SHM FRAME UPLOAD", .style = .{ .size = 14, .color = Color.fromRgb(0x666666) } },
        ).*;

        ui.status = zui.Text.node(
            &ui.status,
            zui.Key.init(3),
            .{},
            .{ .text = ui.status_buffer[0..ui.status_len], .style = .{ .size = 14, .color = Color.fromRgb(0x2196F3) } },
        ).*;

        ui.body = .{ &ui.title, &ui.hint, &ui.status };
        ui.column = zui.Column.node(
            &ui.column,
            zui.Key.init(4),
            .{},
            &ui.body,
            12,
            .start,
            .start,
        ).*;

        ui.root = zui.Box.node(
            &ui.root,
            zui.Key.init(5),
            Modifier.none
                .withSize(size_value.width, size_value.height)
                .withPadding(EdgeInsets.all(32))
                .withBackground(palette.background),
            &ui.column,
            .start,
            .start,
        ).*;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var runtime = platform.x11.Runtime.init("ZUI + X11", window_width, window_height) catch |err| {
        std.debug.print(
            "cannot open an X11 window ({s}).\n" ++
                "This example needs an X server (DISPLAY).\n" ++
                "The headless path is `zig build image`.\n",
            .{@errorName(err)},
        );
        return err;
    };
    defer runtime.deinit();

    var app = try zui.App.init(gpa, .{
        .surface_size = Size.init(@floatFromInt(window_width), @floatFromInt(window_height)),
        .theme = zui.Theme.light,
    });
    defer app.deinit();

    runtime.attach(&app);

    var ui: Interface = .{};
    var state = zui.DispatchState.empty;
    var pointer = Point.zero;
    var clicks: usize = 0;
    var dirty = true;

    while (runtime.running()) {
        // Drain everything already queued, then block for the next event. The
        // block happens inside the X connection, so an idle window uses no CPU.
        while (runtime.pollEvent()) |event| {
            handleEvent(&runtime, event, &pointer, &clicks);
            dirty = true;
        }

        if (runtime.takeRedraw()) dirty = true;

        if (dirty) {
            dirty = false;
            const size_value = runtime.size();
            if (size_value.isValid() and size_value.width >= 1 and size_value.height >= 1) {
                ui.build(pointer, clicks, size_value);

                const model = try app.renderFrame(&ui.root);
                if (state.hovered != null or state.pressed != null) {
                    _ = zui.events.dispatch(&state, model, .{ .pointer_moved = .{ .position = pointer } });
                }
                try app.present();
            }
        }

        // Nothing to repaint: wait for the server instead of spinning.
        if (runtime.running() and !dirty) {
            if (runtime.waitEvent()) |event| {
                handleEvent(&runtime, event, &pointer, &clicks);
                dirty = true;
            }
        }
    }

    std.debug.print("window closed after {d} clicks\n", .{clicks});
}

/// Applies one framework event to the example's little model.
fn handleEvent(
    runtime: *platform.x11.Runtime,
    event: zui.Event,
    pointer: *Point,
    clicks: *usize,
) void {
    switch (event) {
        .pointer_moved => |moved| pointer.* = moved.position,
        .pointer_down => |down| pointer.* = down.position,
        .pointer_up => |up| {
            pointer.* = up.position;
            clicks.* += 1;
        },
        .close_requested => runtime.should_close = true,
        else => {},
    }
}