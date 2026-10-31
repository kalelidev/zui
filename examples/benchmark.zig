//! Benchmark harness: measures the cost of one full frame (layout + paint)
//! on a fixed UI tree. Runs N iterations, prints per-frame time and summary.
//! Requires a graphical session (DISPLAY).
//! Run: zig build run-benchmark
//
const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const platform = @import("platform");

const Node = zui.Node;
const Modifier = zui.Modifier;
const Color = zui.Color;
const EdgeInsets = zui.EdgeInsets;
const Size = zui.Size;
const Point = zui.Point;
const Key = zui.Key;

const ITERATIONS: u32 = 100;
const window_width: c_int = 640;
const window_height: c_int = 420;

/// Every node the benchmark tree points at. Kept alive by `main` for the whole
/// run; a helper that returned a `Node` by value would leave the children
/// dangling and the layout engine would read freed stack memory.
const Tree = struct {
    btn: Node = undefined,
    column: Node = undefined,
    root: Node = undefined,
    body: [1]*const Node = undefined,

    /// Fixed simple UI: box with a button. Re-built each frame with stable keys
    /// so identity survives recomposition.
    fn build(tree: *Tree) *const Node {
        const palette = zui.Theme.light.palette;

        const btn_mod = Modifier.none
            .withSize(200, 60)
            .withBackground(Color.fromRgb(0x2962FF))
            .withPadding(EdgeInsets.all(16));

        tree.btn = zui.Button.node(
            &tree.btn,
            Key.init(1),
            btn_mod,
            "Increment",
            null,
            null,
        ).*;

        tree.body = .{&tree.btn};

        tree.column = zui.Column.node(
            &tree.column,
            Key.init(2),
            .{},
            &tree.body,
            24,
            .center,
            .center,
        ).*;

        tree.root = zui.Box.node(
            &tree.root,
            Key.init(0),
            Modifier.none
                .withSize(640, 420)
                .withPadding(EdgeInsets.all(48))
                .withBackground(palette.background),
            &tree.column,
            .start,
            .start,
        ).*;

        return &tree.root;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var runtime = platform.x11.Runtime.init("ZUI Benchmark", window_width, window_height) catch |err| {
        std.debug.print("cannot open X11 window ({s})\n", .{@errorName(err)});
        return err;
    };
    defer runtime.deinit();

    var app = try zui.App.init(init.gpa, .{
        .surface_size = Size.init(640.0, 420.0),
        .theme = zui.Theme.light,
    });
    defer app.deinit();

    runtime.attach(&app);

    std.debug.print("Warming up...\n", .{});

    // The tree's storage is owned by `main` so the child pointers stay valid for
    // every frame of the run.
    var tree: Tree = .{};

    // Warm-up: a few frames to let the engine settle. No `waitEvent` here —
    // the benchmark is not interactive and blocking would stall before the
    // measurement starts.
    var warmup: u32 = 0;
    while (warmup < 5) : (warmup += 1) {
        while (runtime.pollEvent()) |_| {}
        if (!runtime.running()) break;
        const root = tree.build();
        _ = try app.renderFrame(root);
        try app.present();
    }

    std.debug.print("Starting {d}-frame benchmark...\n", .{ITERATIONS});

    // Two separate measurements, because they answer different questions:
    //   * layout+paint — the framework's own cost per frame.
    //   * present      — the cost of getting the frame onto the server.
    // Reporting one combined number would hide which half is slow.
    //
    // Samples are kept so percentiles can be reported. A mean alone is not
    // enough on a 2-core machine: one scheduler hiccup of 100 ms moves the mean
    // by a whole millisecond and flips the verdict between runs.
    var samples: [ITERATIONS]u64 = undefined;
    var measured: u32 = 0;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_present_ns: u64 = 0;
    var iter: u32 = 0;

    while (iter < ITERATIONS) : (iter += 1) {
        if (!(runtime.running())) break;

        // Drain any pending events. Non-blocking, so an idle window does not
        // stall the loop.
        while (runtime.pollEvent()) |_| {}

        const t0 = std.Io.Timestamp.now(io, .awake);

        const root = tree.build();
        _ = try app.renderFrame(root);

        const t1 = std.Io.Timestamp.now(io, .awake);

        try app.present();

        const t2 = std.Io.Timestamp.now(io, .awake);

        const ns: u64 = @intCast(@as(i64, @truncate(t0.durationTo(t1).nanoseconds)));
        total_present_ns += @intCast(@as(i64, @truncate(t1.durationTo(t2).nanoseconds)));

        total_ns += ns;
        if (ns < min_ns) min_ns = ns;
        if (ns > max_ns) max_ns = ns;
        samples[measured] = ns;
        measured += 1;
    }

    if (measured == 0) {
        std.debug.print("\nNo frames measured (window closed early).\n", .{});
        return;
    }

    std.mem.sort(u64, samples[0..measured], {}, std.sort.asc(u64));

    const mean_ns = total_ns / measured;
    const p50 = samples[measured * 50 / 100];
    const p95 = samples[@min(measured * 95 / 100, measured - 1)];
    const mean_present_ns = total_present_ns / measured;

    const mode = @tagName(builtin.mode);
    const release_like = builtin.mode != .debug;

    std.debug.print("\n=== Benchmark Results ===\n", .{});
    std.debug.print("Build mode: {s}", .{mode});
    if (!release_like) std.debug.print("  <-- unoptimised: numbers are NOT representative", .{});
    std.debug.print("\n", .{});
    std.debug.print("Workload: 640x420, Box > Column > Button, {d} frames after 5 warm-up\n", .{measured});
    std.debug.print("Layout + paint (framework cost per frame):\n", .{});
    std.debug.print("  Mean: {d:.2} ms\n", .{@as(f64, @floatFromInt(mean_ns)) / 1_000_000});
    std.debug.print("  p50:  {d:.2} ms\n", .{@as(f64, @floatFromInt(p50)) / 1_000_000});
    std.debug.print("  p95:  {d:.2} ms\n", .{@as(f64, @floatFromInt(p95)) / 1_000_000});
    std.debug.print("  Min:  {d:.2} ms\n", .{@as(f64, @floatFromInt(min_ns)) / 1_000_000});
    std.debug.print("  Max:  {d:.2} ms\n", .{@as(f64, @floatFromInt(max_ns)) / 1_000_000});
    std.debug.print("Present (frame upload):\n", .{});
    std.debug.print("  Mean: {d:.2} ms\n", .{@as(f64, @floatFromInt(mean_present_ns)) / 1_000_000});

    // The verdict uses p50, not the mean: the budget is about a typical frame,
    // and a single 100 ms scheduler hiccup must not decide it.
    std.debug.print("\nTarget budget: < 4 ms layout+paint (60 FPS = 16.67 ms/frame)\n", .{});
    std.debug.print("Verdict (p50): {s}\n", .{if (p50 < 4_000_000) "PASS" else "FAIL"});
    if (!release_like) {
        std.debug.print("\nNote: Debug builds are not performance-meaningful. Re-run with:\n", .{});
        std.debug.print("  zig build run-benchmark -Doptimize=ReleaseFast\n", .{});
    }

    // Done: exit immediately. Waiting for a close event would hang a headless
    // run and serves no purpose for a measurement.
}