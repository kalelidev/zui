//! Renders a fixed interface to a PPM image so the framework can be exercised
//! without a display server.
//!
//! This is the Task 16 "runnable example": it composes the real public API
//! (`Box`, `Column`, `Row`, `Text`, `Button`, `Spacer`) into an interface, lays it
//! out, paints it and writes the result to a file that any image viewer opens.
//!
//! Usage:
//!   zig build image -- out.ppm
//!
//! When the platform layer lands (Tasks 7–9) this program will gain a real window
//! backend; the interface description below is the part that must not change.
//!
//! Lifetime note: the framework *borrows* child arrays and node storage (see the
//! ownership notes in `component.zig`). Everything the tree points at therefore
//! lives in one `Frame` value owned by `main`, not in a builder function's stack
//! frame — a dangling child slice is a segfault, as an earlier version of this
//! file proved.

const std = @import("std");
const zui = @import("zui");

const Node = zui.Node;
const Modifier = zui.Modifier;
const Color = zui.Color;
const EdgeInsets = zui.EdgeInsets;
const Size = zui.Size;

const canvas_width: f32 = 480;
const canvas_height: f32 = 320;

/// All storage the interface needs, in one place so its lifetime is obvious.
const Frame = struct {
    root: Node = undefined,
    title: Node = undefined,
    subtitle: Node = undefined,
    decrement: Node = undefined,
    value: Node = undefined,
    increment: Node = undefined,
    controls_row: Node = undefined,
    column: Node = undefined,

    controls: [3]*const Node = undefined,
    body: [3]*const Node = undefined,

    fn build(frame: *Frame) *const Node {
        const palette = zui.Theme.light.palette;

        frame.title = zui.Text.node(
            &frame.title,
            zui.Key.init(1),
            .{},
            .{ .text = "ZUI", .style = .{ .size = 28, .color = Color.fromRgb(0x1A1A1A), .weight = .bold } },
        ).*;

        frame.subtitle = zui.Text.node(
            &frame.subtitle,
            zui.Key.init(2),
            .{},
            .{ .text = "DECLARATIVE UI IN ZIG", .style = .{ .size = 14, .color = Color.fromRgb(0x666666) } },
        ).*;

        frame.decrement = zui.Button.node(
            &frame.decrement,
            zui.Key.init(3),
            Modifier.none.withSize(48, 36),
            "-",
            null,
            null,
        ).*;

        frame.value = zui.Text.node(
            &frame.value,
            zui.Key.init(4),
            Modifier.none.withPadding(EdgeInsets.symmetric(0, 16)),
            .{ .text = "42", .style = .{ .size = 21, .color = Color.fromRgb(0x1A1A1A) } },
        ).*;

        frame.increment = zui.Button.node(
            &frame.increment,
            zui.Key.init(5),
            Modifier.none.withSize(48, 36),
            "+",
            null,
            null,
        ).*;

        frame.controls = .{ &frame.decrement, &frame.value, &frame.increment };
        frame.controls_row = zui.Row.node(
            &frame.controls_row,
            zui.Key.init(6),
            .{},
            &frame.controls,
            8,
            .start,
            .center,
        ).*;

        frame.body = .{ &frame.title, &frame.subtitle, &frame.controls_row };
        frame.column = zui.Column.node(
            &frame.column,
            zui.Key.init(7),
            .{},
            &frame.body,
            16,
            .start,
            .start,
        ).*;

        frame.root = zui.Box.node(
            &frame.root,
            zui.Key.init(8),
            Modifier.none
                .withSize(canvas_width, canvas_height)
                .withPadding(EdgeInsets.all(24))
                .withBackground(palette.background),
            &frame.column,
            .start,
            .start,
        ).*;

        return &frame.root;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // Default to a fixed name so the example is runnable with no arguments.
    const path = if (args.len > 1) args[1] else "zui-example.ppm";

    var app = try zui.App.init(init.gpa, .{
        .surface_size = Size.init(canvas_width, canvas_height),
        .theme = zui.Theme.light,
    });
    defer app.deinit();

    // `frame` outlives both the layout and the paint pass; this is what keeps the
    // borrowed child slices valid.
    var frame: Frame = .{};
    const root = frame.build();

    const model = try app.renderFrame(root);

    const io = init.io;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writePpm(&writer.interface, app.renderer);
    try writer.interface.flush();

    std.debug.print(
        "wrote {s} ({d}x{d}), root {d}x{d}\n",
        .{
            path,
            app.renderer.width,
            app.renderer.height,
            @as(u32, @intFromFloat(model.size.width)),
            @as(u32, @intFromFloat(model.size.height)),
        },
    );
}

/// Writes a binary PPM (P6). Alpha is dropped because PPM has no alpha channel:
/// every frame the runtime produces is already composited over the background.
fn writePpm(writer: *std.Io.Writer, renderer: zui.Renderer) !void {
    try writer.print("P6\n{d} {d}\n255\n", .{ renderer.width, renderer.height });

    const pixel_count = @as(usize, renderer.width) * renderer.height;
    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const base = index * 4;
        try writer.writeAll(&[3]u8{
            renderer.pixels[base],
            renderer.pixels[base + 1],
            renderer.pixels[base + 2],
        });
    }
}
