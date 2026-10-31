# ZUI

**A declarative native UI framework for Zig.**

Compose plain Zig values. Measure. Paint.  
No markup. No CSS. No hidden allocator.

```zig
// The interface is just Zig
const root = zui.Box.node(&storage.root, key, modifier, &child, .start, .start);
```

**Status:** Phase 1 complete · Pre-release  
Targets **Zig 0.17.0** on Linux (X11 + Wayland verified).

---

## Why ZUI

Most Zig UI options either pull in a markup language + CSS engine, hide allocation behind opaque containers, or require a runtime you can’t read in an afternoon.

ZUI takes the opposite stance:

- **Zig is the language of the interface** — components are functions that return values.
- **Ownership is explicit** — every allocating entry point takes an allocator. A `Node` is a description, not an owner.
- **The core links nothing** — `zig build test` runs on a machine with no display.
- **The renderer is small enough to audit** — software framebuffer, no GPU, no shaders.

## Features

- Declarative composition (`Box`, `Row`, `Column`, `Text`, `Button`, `Spacer`)
- Real layout engine (measure + place, padding, spacing, alignment, constraints)
- Stable component identity via caller-supplied `Key`s
- Software rendering (RGBA framebuffer)
- Two backends: raw xcb + MIT-SHM, or SDL3 (X11 / Wayland)
- Blocking event loop — idle windows use ~0 % CPU
- Typed theming (colors, text styles, spacing as values)

## Getting started

```bash
git clone <repository> zui
cd zui
zig build test          # 161 tests, no display needed
zig build               # six binaries in zig-out/bin
```

```bash
zig build run-x11       # pure xcb
zig build run-sdl3      # SDL3 (X11 or Wayland)
zig build run-counter
zig build image         # headless → PPM
```

Requires Zig 0.17.0. Windowed examples need either the xcb libraries or SDL3. The core itself needs neither.

## Usage

A complete application (`examples/readme.zig`):

```zig
const std = @import("std");
const zui = @import("zui");
const platform = @import("platform");

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
    var runtime = try platform.x11.Runtime.init("Hello, ZUI", 480, 240);
    defer runtime.deinit();

    var app = try zui.App.init(init.gpa, .{
        .surface_size = zui.Size.init(480, 240),
        .theme = zui.Theme.light,
    });
    defer app.deinit();

    runtime.attach(&app);
    var ui: Ui = .{};

    const redraw = struct {
        fn now(app_ptr: *zui.App, ui_ptr: *Ui, size: zui.Size) !void {
            if (size.width < 1 or size.height < 1) return;
            _ = try app_ptr.draw(ui_ptr.build());
        }
    };
    try redraw.now(&app, &ui, runtime.size());

    while (runtime.running()) {
        var dirty = false;
        while (runtime.pollEvent()) |event| {
            dirty = handle(&runtime, event) or dirty;
        }
        if (runtime.running()) {
            const event = runtime.waitEvent() orelse break;
            dirty = handle(&runtime, event) or dirty;
        }
        if (dirty or runtime.takeRedraw()) {
            try redraw.now(&app, &ui, runtime.size());
        }
    }
}

fn handle(runtime: *platform.x11.Runtime, event: zui.Event) bool {
    return switch (event) {
        .close_requested => {
            runtime.should_close = true;
            false
        },
        .resized => true,
        else => false,
    };
}
```

Nodes are nested by pointer into caller-owned storage. A `Node` describes a component and owns nothing — that is what makes rebuilding the tree every frame cheap. Keep the storage alive for the lifetime of the frame loop.

Swap `platform.x11` for `platform.sdl3` and nothing else changes.

## Architecture

```
  your application
        |
        v
  zui (public API)          src/zui.zig
        |
   +----+----+----+----+
   |    |    |    |    |
  app  layout paint text     runtime, measurement, rasterisation
   |    |
   +----+--> events          hit-testing, dispatch
        |
        v
  platform (separate module)   src/platform/{x11,sdl3}
        |
        v
  libxcb / SDL3
```

The split is intentional: the framework core can never accidentally depend on a display server. That is why `zig build test` is reliable in CI.

| Module | Responsibility |
| --- | --- |
| `geometry.zig` | `Point`, `Size`, `Rect`, `EdgeInsets`, `Constraints` |
| `color.zig` | RGBA color, palettes |
| `theme.zig` | Theme, text styles, spacing |
| `component.zig` | `Node`, `Key`, `Modifier` and the six components |
| `layout.zig` | Measure + place engine |
| `text.zig` | Built-in 5x7 bitmap font, UTF-8 measurement |
| `render/software.zig` | RGBA framebuffer, fills, strokes, glyphs |
| `paint.zig` | Bridges a layout model to renderer calls |
| `app.zig` | Runtime: lifecycle, frame loop, `Surface` vtable |
| `events.zig` | Event types, hit-testing, dispatch state |


## Supported platforms

| Platform          | Backend     | Status                                      |
|-------------------|-------------|---------------------------------------------|
| Linux / X11       | xcb + MIT-SHM | Verified (window, paint, click, resize, close) |
| Linux / Wayland   | SDL3        | Verified (native wayland driver)            |
| Linux / X11       | SDL3        | Verified                                    |
| macOS / Windows   | —           | Not evaluated                               |

Only Zig 0.17.0 is tested.

## Known limitations

- No reactive state or Hot Reload yet (Phase 2 / 3)
- Linux only
- ASCII text only (bitmap font)
- No scrolling, text input, images, or animations
- Fixed-size layouts (no weights)

## Supported components

| Component | Status | Notes |
| --- | --- | --- |
| `Text` | Working | ASCII only; lowercase folds to uppercase |
| `Button` | Working | Label, click handler, enabled flag |
| `Row` | Working | Fixed spacing; no weight distribution |
| `Column` | Working | Fixed spacing; no weight distribution |
| `Box` | Working | Single child, background, border, alignment |
| `Spacer` | Working | Fixed empty space; `null` measures as zero, not flexible |
| Scrollable | Planned | Not in the MVP |
| Text field | Planned | Phase 2 |
| Image | Planned | No resource loading yet |
| Checkbox / Slider / Tabs | Planned | Not in the MVP |
| Animations | Planned | Not in the MVP |

A child that does not fit its parent is clipped by the renderer rather than
shrunk. There are no weights yet, so layouts are fixed-size at this stage.

## Performance

Measured on the reference machine: Void Linux, AMD A6-9200 (2 cores), X.Org
24.1.13. Workload is a 640x420 interface of `Box` → `Column` → `Button`.

| Metric | Value |
| --- | --- |
| Layout + paint, ReleaseFast | **3.54 ms p50** (budget: 4 ms) |
| Layout + paint, Debug | 34.92 ms p50 — unoptimised, not representative |
| Present (MIT-SHM upload) | 1.84 ms |
| Startup to mapped window | 79–101 ms |
| Idle CPU | 0.20 % X11, 0.00 % Wayland |
| Release binary | 3.7 MB per example |

The 4 ms budget is met on idle hardware and is borderline under CPU contention;
`docs/BENCHMARKS.md` records the full distribution and the variance across five
runs rather than a single flattering number.

Benchmarks are only meaningful in a release build:

```bash
zig build run-benchmark -Doptimize=ReleaseFast
```

## Documentation

| Document                    | Contents                          |
|-----------------------------|-----------------------------------|
| `docs/PROJECT.md`           | Problem, solution, scope          |
| `docs/ARCHITECTURE.md`      | Layers and execution model        |
| `docs/RESOURCE-OWNERSHIP.md`| Who allocates and frees what      |
| `docs/ROADMAP.md`           | Three-phase plan                  |
| `docs/BENCHMARKS.md`        | Measured results                  |

## Contributing

Useful contributions right now: bug reports with a reproduction, tests for uncovered behavior, and portability work. Phase 2 (reactive state) needs a design discussion before code.

```bash
zig build test --summary all
zig build
```

Do not weaken or delete tests to make a build pass.

## License

Not yet declared. Treat the source as all-rights-reserved until a license file appears.

