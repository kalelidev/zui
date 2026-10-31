//! Paint: turns a layout model into drawing calls.
//!
//! This is the bridge between `layout.zig` (geometry) and a renderer (pixels).
//! It walks the placed nodes in order and issues the primitives each component
//! needs. Keeping it separate means layout stays renderer-independent and the
//! renderer stays unaware of components, as `ARCHITECTURE.md` requires.
//!
//! Order: nodes are painted in the order `layout` produced them, which is
//! parents before children, so a child always draws over its parent's
//! background.
//!
//! Ownership: nothing here allocates; it only reads the model and the theme.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const component = @import("component.zig");
const layout = @import("layout.zig");
const theme_mod = @import("theme.zig");
const text = @import("text.zig");
const software = @import("render/software.zig");

pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const EdgeInsets = geometry.EdgeInsets;
pub const Color = color.Color;
pub const Theme = theme_mod.Theme;
pub const Model = layout.Model;
pub const Node = component.Node;
pub const Renderer = software.Renderer;

/// Paints `model` into `renderer` using `theme`.
pub fn paint(model: Model, renderer: *Renderer, theme: Theme) void {
    for (model.items) |item| {
        paintNode(item, renderer, theme);
    }
}

fn paintNode(item: layout.Placed, renderer: *Renderer, theme: Theme) void {
    const node = item.node;

    // Background and border come first: they belong to the border box, not to
    // the content box.
    if (node.modifier.background) |background| {
        renderer.fillRect(item.rect, background);
    }
    if (node.modifier.border_width > 0) {
        const border_color = node.modifier.border_color orelse theme.palette.border;
        renderer.strokeRect(item.rect, EdgeInsets.all(node.modifier.border_width), border_color);
    }

    switch (node.kind) {
        .spacer => {},
        .text => |content| {
            renderer.drawText(
                item.content.origin(),
                content.text,
                content.style.color orelse theme.palette.on_background,
                content.style.size,
            );
        },
        .button => |button| {
            // A button paints its own surface so it is visible without the
            // caller supplying a background modifier.
            renderer.fillRect(item.rect, theme.palette.primary);
            const label_color = if (button.enabled)
                theme.palette.on_primary
            else
                theme.palette.on_primary.withAlpha(128);

            // The label is centred inside the content box. `layout.zig` reserves
            // `button_padding` for it, so drawing at the content origin instead
            // would pin the text to the top-left corner.
            const label_size = text.measureSize(button.label, theme.body.size);
            const label_x = item.content.x + geometry.Alignment.center.offset(item.content.width, label_size.width);
            const label_y = item.content.y + geometry.Alignment.center.offset(item.content.height, label_size.height);
            renderer.drawText(
                geometry.Point.init(label_x, label_y),
                button.label,
                label_color,
                theme.body.size,
            );
        },
        // Containers and boxes draw nothing themselves; their children are
        // separate entries in the model.
        .box, .row, .column => {},
    }
}

test "painting a spacer leaves the framebuffer untouched" {
    var storage: Node = undefined;
    const spacer = component.Spacer.node(&storage, component.Key.none, geometry.Size.square(10));

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(spacer, geometry.Size.init(20, 20));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(20, 20));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(model, &renderer, Theme.light);
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
}

test "painting a box fills its background" {
    var box_storage: Node = undefined;
    const box = component.Box.node(
        &box_storage,
        component.Key.none,
        component.Modifier.none.withSize(10, 10).withBackground(Color.fromRgb(0xFF0000)),
        null,
        .start,
        .start,
    );

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(box, geometry.Size.init(20, 20));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(20, 20));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(model, &renderer, Theme.light);
    try std.testing.expect(Color.eql(Color.fromRgb(0xFF0000), renderer.getPixel(5, 5)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(15, 15)));
}

test "painting text puts ink inside the content box" {
    var storage: Node = undefined;
    const label = component.Text.node(
        &storage,
        component.Key.none,
        .{},
        .{ .text = "H", .style = .{ .size = 7, .color = Color.white } },
    );

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(label, geometry.Size.init(20, 20));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(20, 20));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(model, &renderer, Theme.light);

    // 'H' has ink in its left column; nothing paints outside the glyph cell.
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(19, 19)));
}

test "a button fills its box with the primary color" {
    var storage: Node = undefined;
    const button = component.Button.node(&storage, component.Key.none, .{}, "OK", null, null);

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(button, geometry.Size.init(100, 100));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(100, 100));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(model, &renderer, Theme.light);

    const corner = renderer.getPixel(0, 0);
    try std.testing.expect(Color.eql(Theme.light.palette.primary, corner));
}

test "a button centres its label instead of pinning it to the corner" {
    var storage: Node = undefined;
    const button = component.Button.node(&storage, component.Key.none, component.Modifier.none.withSize(80, 40), "I", null, null);

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(button, geometry.Size.init(100, 100));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(100, 100));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(model, &renderer, Theme.light);

    // 'I' is a narrow glyph with ink on its middle column. At 14px it must appear
    // near the horizontal centre of the 80px wide button, not at the left edge.
    const placed = model.find(button).?;
    const center_x: u32 = @intFromFloat(placed.rect.x + placed.rect.width / 2);

    var found_ink = false;
    var x = center_x - 6;
    while (x <= center_x + 6) : (x += 1) {
        var y: u32 = 0;
        while (y < 40) : (y += 1) {
            if (Color.eql(Theme.light.palette.on_primary, renderer.getPixel(x, y))) found_ink = true;
        }
    }
    try std.testing.expect(found_ink);

    // And the very first column inside the button stays background-free of ink
    // only if the label is not pinned there: assert the leftmost 8 px hold no
    // on_primary pixels at all.
    x = @intFromFloat(placed.rect.x);
    while (x < @as(u32, @intFromFloat(placed.rect.x)) + 8) : (x += 1) {
        var y: u32 = 0;
        while (y < 40) : (y += 1) {
            try std.testing.expect(!Color.eql(Theme.light.palette.on_primary, renderer.getPixel(x, y)));
        }
    }
}

test "paint is a no-op on an empty model" {
    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(4, 4));
    defer renderer.deinit();
    renderer.clear(Color.black);

    paint(.{ .items = &.{}, .size = geometry.Size.zero }, &renderer, Theme.light);
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
}

test "text metrics from layout match what the renderer advances" {
    // Guards the contract that measurement and painting share one source of
    // truth: a string measured at a size must not paint past its measured box.
    const content = "HELLO";
    const size = text.measureSize(content, 7);

    var storage: Node = undefined;
    const label = component.Text.node(
        &storage,
        component.Key.none,
        .{},
        .{ .text = content, .style = .{ .size = 7, .color = Color.white } },
    );

    var engine = layout.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(label, geometry.Size.init(200, 40));

    var renderer = try Renderer.init(std.testing.allocator, geometry.Size.init(200, 40));
    defer renderer.deinit();
    renderer.clear(Color.black);
    paint(model, &renderer, Theme.light);

    // The last column of the measured box may hold ink; one pixel past it may not.
    const last_x: u32 = @intFromFloat(size.width);
    var x = last_x + 1;
    while (x < 200) : (x += 1) {
        try std.testing.expect(Color.eql(Color.black, renderer.getPixel(x, 0)));
    }
}
