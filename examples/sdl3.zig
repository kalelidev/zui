//! SDL3 example: a real window running the framework's frame loop.
//!
//! What this demonstrates:
//!   * `platform.sdl3.Runtime` opens a window and hands its surface to `App`.
//!   * `App.draw` lays out, paints and presents one frame.
//!   * Native input reaches `events.dispatch`, which tracks hover/press state.
//!
//! Requires a graphical session (`DISPLAY` or `WAYLAND_DISPLAY`). Without one
//! `SDL_Init` fails and this program exits with an error, by design: the
//! headless path is `zig build image` / `zig build render`.
//!
//! Usage:
//!   zig build run-sdl3

const std = @import("std");
const zui = @import("zui");
const platform = @import("platform");

const Node = zui.Node;
const Modifier = zui.Modifier;
const Color = zui.Color;
const EdgeInsets = zui.EdgeInsets;
const Size = zui.Size;
const Point = zui.Point;

const window_width: c_int = 640;
const window_height: c_int = 420;

/// Every node the tree points at, plus the text buffers it borrows. The
/// framework borrows child slices and node storage, so this must outlive the
/// frame loop.
const Interface = struct {
    root: Node = undefined,
    title: Node = undefined,
    hint: Node = undefined,
    status: Node = undefined,
    column: Node = undefined,
    row: Node = undefined,

    body: [3]*const Node = undefined,
    row_body: [2]*const Node = undefined,

    status_buffer: [96]u8 = undefined,
    status_len: usize = 0,

    /// Rebuilds the tree for the current pointer position and click count.
    fn build(ui: *Interface, pointer: Point, clicks: usize, size_value: Size) void {
        const palette = zui.Theme.light.palette;

        // A pointer to the slice is what `catch` needs: the error path clears it.
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
            .{ .text = "ZUI + SDL3", .style = .{ .size = 28, .color = Color.fromRgb(0x1A1A1A), .weight = .bold } },
        ).*;

        ui.hint = zui.Text.node(
            &ui.hint,
            zui.Key.init(2),
            .{},
            .{ .text = "NATIVE WINDOW, SOFTWARE FRAMEBUFFER", .style = .{ .size = 14, .color = Color.fromRgb(0x666666) } },
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

        ui.row_body = .{ &ui.column, &ui.title };
        ui.row = zui.Row.node(
            &ui.row,
            zui.Key.init(5),
            .{},
            &ui.row_body,
            24,
            .start,
            .start,
        ).*;

        ui.root = zui.Box.node(
            &ui.root,
            zui.Key.init(6),
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

    var runtime = platform.sdl3.Runtime.init("ZUI + SDL3", window_width, window_height) catch |err| {
        std.debug.print(
            "cannot open a window ({s}).\n" ++
                "This example needs a graphical session (DISPLAY or WAYLAND_DISPLAY).\n" ++
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
        // Drain what is already queued, then block inside SDL for the next
        // event. An idle window therefore uses no CPU.
        while (runtime.pollEvent()) |event| {
            handleEvent(&runtime, event, &pointer, &clicks, &dirty);
        }

        if (dirty) {
            dirty = false;
            const size_value = runtime.size();
            if (size_value.isValid() and size_value.width >= 1 and size_value.height >= 1) {
                ui.build(pointer, clicks, size_value);

                const model = try app.renderFrame(&ui.root);
                // Input is dispatched against the frame that was just laid out,
                // so hit-testing uses the geometry the user is looking at.
                if (state.hovered != null or state.pressed != null) {
                    _ = zui.events.dispatch(&state, model, .{ .pointer_moved = .{ .position = pointer } });
                }
                try app.present();
            }
        }

        // Nothing to repaint: wait for input instead of spinning.
        if (runtime.running() and !dirty) {
            if (runtime.waitEvent()) |event| {
                handleEvent(&runtime, event, &pointer, &clicks, &dirty);
            }
        }
    }

    std.debug.print("window closed after {d} clicks\n", .{clicks});
}

/// Applies one framework event to the example's little model.
fn handleEvent(
    runtime: *platform.sdl3.Runtime,
    event: zui.Event,
    pointer: *Point,
    clicks: *usize,
    dirty: *bool,
) void {
    switch (event) {
        .pointer_moved => |moved| pointer.* = moved.position,
        .pointer_down => |down| pointer.* = down.position,
        .pointer_up => |up| {
            pointer.* = up.position;
            clicks.* += 1;
        },
        .resized => |resized| {
            // Keep the renderer's framebuffer in step before the next frame.
            _ = resized;
        },
        .close_requested => runtime.should_close = true,
        else => {},
    }
    dirty.* = true;
}