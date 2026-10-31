//! Counter example: interactive increment with a button.
//! Requires a graphical session (DISPLAY).
//! Run: zig build run-x11  OR  zig build run-sdl3
//!
//! Demonstrates: button click handling, state tracking, and
//! incremental recomposition (the tree rebuilds only what changed).
//
const std = @import("std");
const zui = @import("zui");
const platform = @import("platform");

const Node = zui.Node;
const Modifier = zui.Modifier;
const Color = zui.Color;
const EdgeInsets = zui.EdgeInsets;
const Size = zui.Size;
const Point = zui.Point;
const Key = zui.Key;

const window_width: c_int = 640;
const window_height: c_int = 420;

/// Persistent state across frames.
const State = struct {
    clicks: usize,
    btn_key: Key,
};

/// Every node the tree points at. The layout engine borrows these pointers, so
/// they must stay alive for the whole frame — which is why this struct lives in
/// `main` and not in the function that builds the tree.
const Interface = struct {
    btn: Node = undefined,
    column: Node = undefined,
    root: Node = undefined,
    body: [1]*const Node = undefined,

    /// Builds the UI tree for one frame. Returns a pointer into `ui`, valid as
    /// long as the caller keeps the struct alive.
    fn build(ui: *Interface, state: *State, size_value: Size) *const Node {
        const palette = zui.Theme.light.palette;

        // Button label alternates based on click count
        const label: []const u8 = if (state.clicks > 0) "Reset" else "Increment";

        const btn_mod = Modifier.none
            .withSize(200, 60)
            .withBackground(Color.fromRgb(0x2962FF))
            .withPadding(EdgeInsets.all(16));

        ui.btn = zui.Button.node(
            &ui.btn,
            state.btn_key,
            btn_mod,
            label,
            null,
            null,
        ).*;

        ui.body = .{&ui.btn};

        ui.column = zui.Column.node(
            &ui.column,
            Key.init(1),
            .{},
            &ui.body,
            24,
            .center,
            .center,
        ).*;

        ui.root = zui.Box.node(
            &ui.root,
            Key.init(0),
            Modifier.none
                .withSize(size_value.width, size_value.height)
                .withPadding(EdgeInsets.all(48))
                .withBackground(palette.background),
            &ui.column,
            .start,
            .start,
        ).*;

        return &ui.root;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Pick one backend: X11/xcb (default, no extra dep) or SDL3.
    // To use SDL3: zig build run-sdl3; to use X11: zig build run-x11
    var runtime = platform.x11.Runtime.init("ZUI Counter", window_width, window_height) catch |err| {
        std.debug.print(
            "cannot open X11 window ({s}): set DISPLAY\n",
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

    // Persistent state across frames stored in the gpa arena.
    var state: State = .{ .clicks = 0, .btn_key = Key.init(42) };
    // Owns every node the tree borrows. Declared here so the pointers stay
    // valid for the whole frame; building the tree in a helper that returns by
    // value would leave every child pointer dangling.
    var ui: Interface = .{};
    var dirty = true;

    while (runtime.running()) {
        // Drain queued events, then block waiting for the next one.
        while (runtime.pollEvent()) |event| {
            handleEvent(&runtime, event, &state, &dirty);
        }

        if (dirty) {
            dirty = false;
            const size_value = runtime.size();
            if (size_value.isValid() and size_value.width >= 1 and size_value.height >= 1) {
                const root = ui.build(&state, size_value);

                _ = try app.renderFrame(root);
                try app.present();
            }
        }

        // Wait for the next event instead of spinning; idle CPU = 0.
        if (runtime.running() and !dirty) {
            if (runtime.waitEvent()) |event| {
                handleEvent(&runtime, event, &state, &dirty);
            }
        }
    }

    std.debug.print("counter closed after {d} clicks\n", .{state.clicks});
}

/// Handle one event from the platform runtime.
fn handleEvent(
    runtime: *platform.x11.Runtime,
    event: zui.Event,
    state: *State,
    dirty: *bool,
) void {
    // Use if-else chain to avoid Zig switch syntax issues
    if (event == .pointer_moved) {
        // ignore
    } else if (event == .pointer_down) {
        // ignore
    } else if (event == .pointer_up) {
        // click happens on pointer up; increment counter
        state.clicks += 1;
        dirty.* = true;
    } else if (event == .resized) {
        // ignore
    } else if (event == .close_requested) {
        runtime.should_close = true;
    } else {
        // key_down, key_up, focus_changed - ignore
    }
}