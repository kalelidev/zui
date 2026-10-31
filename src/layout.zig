//! Layout engine: measurement and placement.
//!
//! The engine takes an immutable component description (`component.Node`) and
//! produces a *layout model*: the absolute rectangle of every node plus its
//! content box. Rendering consumes that model and never walks descriptions.
//!
//! Two phases:
//! 1. **Measure** — compute the intrinsic size of each node, top-down, carrying
//!    `Constraints`. Results are cached in a `Measured` tree so that placement
//!    never re-measures anything.
//! 2. **Place** — assign absolute rectangles, top-down, resolving padding,
//!    spacing and alignment.
//!
//! Ownership:
//! - The engine owns an arena and all `Measured`/`Placed` storage in it. Calling
//!   `layout` again resets the arena, so the returned `Model` (and every pointer
//!   into it) is valid only until the next `layout` or `deinit` call.
//! - Node descriptions and their strings are borrowed, never copied.
//!
//! Units and determinism:
//! - All arithmetic is `f32` in logical pixels; no rounding happens here.
//!   `Rect.round` is applied by the renderer.
//! - Measurement is pure: the same description and constraints always produce
//!   the same numbers, which the tests rely on.
//!
//! This engine intentionally implements only what the MVP components need. It is
//! not a general constraint solver; `Row`/`Column` measure children at their
//! intrinsic size rather than distributing weights, and a child that does not fit
//! is clipped by the renderer instead of being shrunk.

const std = @import("std");
const geometry = @import("geometry.zig");
const component = @import("component.zig");
const theme_mod = @import("theme.zig");

pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Constraints = geometry.Constraints;
pub const EdgeInsets = geometry.EdgeInsets;
pub const Alignment = geometry.Alignment;
pub const Axis = geometry.Axis;
pub const Node = component.Node;
pub const Theme = theme_mod.Theme;

pub const Error = error{
    /// The node (or one of its descendants) failed its own validity check.
    InvalidNode,
    OutOfMemory,
};

pub const Options = struct {
    theme: Theme = Theme.light,
    /// Inner padding around a button's label. It applies on top of the node's
    /// own `modifier.padding`, which always surrounds it.
    button_padding: EdgeInsets = EdgeInsets.symmetric(8, 16),
};

/// One node of the measured tree. Internal to the engine.
const Measured = struct {
    node: *const Node,
    size: Size,
    children: []const *Measured = &.{},
    /// Child of a `box`, kept separately because a box has at most one.
    box_child: ?*Measured = null,
    /// Size of the content box, i.e. the size without padding.
    content_size: Size = .zero,
};

/// Where a node ended up, in window coordinates.
pub const Placed = struct {
    node: *const Node,
    /// Border box, including padding.
    rect: Rect,
    /// Content box: `rect` shrunk by the node's padding.
    content: Rect,
};

pub const Model = struct {
    items: []const Placed,
    /// Size of the laid-out root.
    size: Size,

    /// Last placement for a node, or null when it was not part of the frame.
    /// Linear scan: models are small and this is only used by tests and by
    /// hit-testing during event dispatch.
    pub fn find(model: Model, node: *const Node) ?Placed {
        for (model.items) |item| {
            if (item.node == node) return item;
        }
        return null;
    }
};

pub const Engine = struct {
    /// Long-lived allocator for the engine itself.
    gpa: std.mem.Allocator,
    /// Per-layout storage, reset on every `layout` call.
    arena: std.heap.ArenaAllocator,
    options: Options,
    items: std.ArrayList(Placed) = .empty,

    pub fn init(gpa: std.mem.Allocator, options: Options) Engine {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .options = options,
        };
    }

    pub fn deinit(engine: *Engine) void {
        engine.items.deinit(engine.gpa);
        engine.arena.deinit();
        engine.* = undefined;
    }

    /// Measures and places `root` inside a viewport of `viewport_size`.
    ///
    /// The returned model borrows engine storage and is invalidated by the next
    /// `layout` or `deinit`.
    pub fn layout(engine: *Engine, root: *const Node, viewport_size: Size) Error!Model {
        // Reset per-frame storage. Keeping the arena's backing allocation means
        // steady-state frames do not hit the allocator at all.
        _ = engine.arena.reset(.retain_capacity);
        engine.items.clearRetainingCapacity();

        const constraints = Constraints.loose(viewport_size);
        const measured = try engine.measureNode(root, constraints);
        try engine.placeNode(measured, Rect.init(0, 0, measured.size.width, measured.size.height));

        return .{
            .items = engine.items.items,
            .size = measured.size,
        };
    }

    fn arenaAllocator(engine: *Engine) std.mem.Allocator {
        return engine.arena.allocator();
    }

    fn measureNode(engine: *Engine, node: *const Node, constraints: Constraints) Error!*Measured {
        if (!node.isValid()) return Error.InvalidNode;
        if (!constraints.isValid()) return Error.InvalidNode;

        const arena = engine.arenaAllocator();
        const measured = try arena.create(Measured);
        measured.* = .{ .node = node, .size = .zero };

        const padding = node.modifier.padding;
        const content_constraints = constraints.deflate(padding);

        var content_size: Size = .zero;

        switch (node.kind) {
            .spacer => |spacer| {
                content_size = spacer.size orelse Size.zero;
            },
            .text => |text| {
                content_size = text.measure();
            },
            .button => |button| {
                const label = component.TextContent{ .text = button.label };
                const label_size = label.measure();
                const inner = engine.options.button_padding;
                content_size = .{
                    .width = label_size.width + inner.horizontal(),
                    .height = label_size.height + inner.vertical(),
                };
            },
            .box => |box| {
                if (box.child) |child| {
                    const child_measured = try engine.measureNode(child, content_constraints);
                    measured.box_child = child_measured;
                    content_size = child_measured.size;
                }
            },
            .row => |row| {
                var siblings: std.ArrayList(*Measured) = .empty;
                defer siblings.deinit(arena);

                var total_width: f32 = 0;
                var max_height: f32 = 0;
                for (row.children) |child| {
                    // Children are measured at their intrinsic width so that a
                    // row reports the width its content actually wants; the row
                    // itself is then clamped into the incoming constraints.
                    const child_constraints = Constraints{
                        .min_width = 0,
                        .max_width = std.math.inf(f32),
                        .min_height = 0,
                        .max_height = content_constraints.max_height,
                    };
                    const child_measured = try engine.measureNode(child, child_constraints);
                    try siblings.append(arena, child_measured);
                    total_width += child_measured.size.width;
                    max_height = @max(max_height, child_measured.size.height);
                }
                if (row.children.len > 1) {
                    total_width += row.spacing * @as(f32, @floatFromInt(row.children.len - 1));
                }

                measured.children = try siblings.toOwnedSlice(arena);
                content_size = .{ .width = total_width, .height = max_height };
            },
            .column => |column| {
                var siblings: std.ArrayList(*Measured) = .empty;
                defer siblings.deinit(arena);

                var max_width: f32 = 0;
                var total_height: f32 = 0;
                for (column.children) |child| {
                    const child_constraints = Constraints{
                        .min_width = 0,
                        .max_width = content_constraints.max_width,
                        .min_height = 0,
                        .max_height = std.math.inf(f32),
                    };
                    const child_measured = try engine.measureNode(child, child_constraints);
                    try siblings.append(arena, child_measured);
                    max_width = @max(max_width, child_measured.size.width);
                    total_height += child_measured.size.height;
                }
                if (column.children.len > 1) {
                    total_height += column.spacing * @as(f32, @floatFromInt(column.children.len - 1));
                }

                measured.children = try siblings.toOwnedSlice(arena);
                content_size = .{ .width = max_width, .height = total_height };
            },
        }

        // An explicit size in the modifier wins over the intrinsic size, then
        // constraints have the final say so a component can never escape its
        // parent's box.
        var outer = Size{
            .width = content_size.width + padding.horizontal(),
            .height = content_size.height + padding.vertical(),
        };
        if (node.modifier.width) |width| outer.width = width;
        if (node.modifier.height) |height| outer.height = height;

        measured.size = constraints.constrain(outer);
        measured.content_size = .{
            .width = @max(0, measured.size.width - padding.horizontal()),
            .height = @max(0, measured.size.height - padding.vertical()),
        };
        return measured;
    }

    fn placeNode(engine: *Engine, measured: *const Measured, rect: Rect) Error!void {
        const node = measured.node;
        const content = rect.inset(node.modifier.padding);

        try engine.items.append(engine.gpa, .{ .node = node, .rect = rect, .content = content });

        switch (node.kind) {
            .spacer, .text, .button => {},
            .box => |box| {
                if (measured.box_child) |child| {
                    const x = content.x + box.alignment.offset(content.width, child.size.width);
                    const y = content.y + box.cross_alignment.offset(content.height, child.size.height);
                    try engine.placeNode(child, Rect.init(x, y, child.size.width, child.size.height));
                }
            },
            .row => |row| {
                if (measured.children.len == 0) return;

                var total_width: f32 = 0;
                for (measured.children) |child| {
                    total_width += child.size.width;
                }
                if (measured.children.len > 1) {
                    total_width += row.spacing * @as(f32, @floatFromInt(measured.children.len - 1));
                }

                // Surplus space inside the content box is handed to the main-axis
                // alignment, matching how Compose arranges children.
                var cursor = content.x + row.alignment.offset(content.width, total_width);

                for (measured.children, 0..) |child, index| {
                    if (index > 0) cursor += row.spacing;
                    const y = content.y + row.cross_alignment.offset(content.height, child.size.height);
                    try engine.placeNode(child, Rect.init(cursor, y, child.size.width, child.size.height));
                    cursor += child.size.width;
                }
            },
            .column => |column| {
                if (measured.children.len == 0) return;

                var total_height: f32 = 0;
                for (measured.children) |child| {
                    total_height += child.size.height;
                }
                if (measured.children.len > 1) {
                    total_height += column.spacing * @as(f32, @floatFromInt(measured.children.len - 1));
                }

                var cursor = content.y + column.alignment.offset(content.height, total_height);

                for (measured.children, 0..) |child, index| {
                    if (index > 0) cursor += column.spacing;
                    const x = content.x + column.cross_alignment.offset(content.width, child.size.width);
                    try engine.placeNode(child, Rect.init(x, cursor, child.size.width, child.size.height));
                    cursor += child.size.height;
                }
            },
        }
    }
};

test "spacer measures its declared size plus padding" {
    var child: Node = undefined;
    var storage: Node = undefined;
    const spacer = component.Spacer.node(&child, component.Key.none, Size.square(10));
    const padded = component.Box.node(
        &storage,
        component.Key.none,
        component.Modifier.none.withPadding(EdgeInsets.all(4)),
        spacer,
        .start,
        .start,
    );

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(padded, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 18), model.size.width);
    try std.testing.expectEqual(@as(f32, 18), model.size.height);
    try std.testing.expectEqual(@as(f32, 10), model.items[1].rect.width);
}

test "row sums child widths and spacing" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    var c_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.init(1), Size.init(10, 10));
    const b = component.Spacer.node(&b_storage, component.Key.init(2), Size.init(20, 30));
    const c = component.Spacer.node(&c_storage, component.Key.init(3), Size.init(5, 10));
    const children = [_]*const Node{ a, b, c };

    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &children, 4, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(row, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 43), model.size.width); // 10 + 4 + 20 + 4 + 5
    try std.testing.expectEqual(@as(f32, 30), model.size.height);
}

test "row places children left to right with spacing" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.none, Size.init(10, 10));
    const b = component.Spacer.node(&b_storage, component.Key.none, Size.init(20, 10));
    const children = [_]*const Node{ a, b };

    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &children, 6, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(row, Size.init(500, 500));
    const a_rect = model.find(a).?.rect;
    const b_rect = model.find(b).?.rect;
    try std.testing.expectEqual(@as(f32, 0), a_rect.x);
    try std.testing.expectEqual(@as(f32, 16), b_rect.x); // 10 + 6
}

test "column stacks children vertically" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.none, Size.init(10, 10));
    const b = component.Spacer.node(&b_storage, component.Key.none, Size.init(30, 20));
    const children = [_]*const Node{ a, b };

    var column_storage: Node = undefined;
    const column = component.Column.node(&column_storage, component.Key.none, .{}, &children, 5, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(column, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 30), model.size.width);
    try std.testing.expectEqual(@as(f32, 35), model.size.height); // 10 + 5 + 20
    try std.testing.expectEqual(@as(f32, 15), model.find(b).?.rect.y);
}

test "empty containers measure as zero instead of failing" {
    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &.{}, 8, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(row, Size.init(100, 100));
    try std.testing.expectEqual(@as(f32, 0), model.size.width);
    try std.testing.expectEqual(@as(f32, 0), model.size.height);
    try std.testing.expectEqual(@as(usize, 1), model.items.len);
}

test "box centers its child inside the content box" {
    var child_storage: Node = undefined;
    const child = component.Spacer.node(&child_storage, component.Key.none, Size.init(20, 20));

    var box_storage: Node = undefined;
    const box = component.Box.node(
        &box_storage,
        component.Key.none,
        component.Modifier.none.withSize(100, 50),
        child,
        .center,
        .center,
    );

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(box, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 100), model.size.width);
    try std.testing.expectEqual(@as(f32, 50), model.size.height);

    const child_rect = model.find(child).?.rect;
    try std.testing.expectEqual(@as(f32, 40), child_rect.x); // (100 - 20) / 2
    try std.testing.expectEqual(@as(f32, 15), child_rect.y); // (50 - 20) / 2
}

test "box aligns its child to the end and bottom" {
    var child_storage: Node = undefined;
    const child = component.Spacer.node(&child_storage, component.Key.none, Size.init(20, 20));

    var box_storage: Node = undefined;
    const box = component.Box.node(
        &box_storage,
        component.Key.none,
        component.Modifier.none.withSize(100, 50),
        child,
        .end,
        .end,
    );

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(box, Size.init(500, 500));
    const child_rect = model.find(child).?.rect;
    try std.testing.expectEqual(@as(f32, 80), child_rect.x);
    try std.testing.expectEqual(@as(f32, 30), child_rect.y);
}

test "explicit width clamps a row wider than its parent" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.none, Size.init(80, 10));
    const b = component.Spacer.node(&b_storage, component.Key.none, Size.init(80, 10));
    const children = [_]*const Node{ a, b };

    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &children, 0, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    // The viewport is narrower than the content, so the row is clamped.
    const model = try engine.layout(row, Size.init(100, 100));
    try std.testing.expectEqual(@as(f32, 100), model.size.width);
    // Children keep their intrinsic size; the renderer clips the overflow.
    try std.testing.expectEqual(@as(f32, 80), model.find(b).?.rect.width);
}

test "modifier size overrides intrinsic content size" {
    var storage: Node = undefined;
    const text = component.Text.node(
        &storage,
        component.Key.none,
        component.Modifier.none.withSize(50, 30),
        .{ .text = "hello" },
    );

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(text, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 50), model.size.width);
    try std.testing.expectEqual(@as(f32, 30), model.size.height);
}

test "content rect excludes padding" {
    var child_storage: Node = undefined;
    const child = component.Spacer.node(&child_storage, component.Key.none, Size.square(10));

    var box_storage: Node = undefined;
    const box = component.Box.node(
        &box_storage,
        component.Key.none,
        component.Modifier.none.withPadding(EdgeInsets.symmetric(2, 3)),
        child,
        .start,
        .start,
    );

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(box, Size.init(500, 500));
    const box_placed = model.find(box).?;
    try std.testing.expectEqual(@as(f32, 16), box_placed.rect.width);
    try std.testing.expectEqual(@as(f32, 14), box_placed.rect.height);
    try std.testing.expectEqual(@as(f32, 3), box_placed.content.x);
    try std.testing.expectEqual(@as(f32, 2), box_placed.content.y);
    try std.testing.expectEqual(@as(f32, 10), box_placed.content.width);
}

test "nested column inside row keeps absolute coordinates" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.none, Size.init(10, 10));
    const b = component.Spacer.node(&b_storage, component.Key.none, Size.init(10, 10));
    const inner_children = [_]*const Node{ a, b };

    var inner_storage: Node = undefined;
    const inner = component.Column.node(&inner_storage, component.Key.none, .{}, &inner_children, 2, .start, .start);

    var outer_children_storage: Node = undefined;
    const outer_children = [_]*const Node{inner};
    const outer = component.Row.node(&outer_children_storage, component.Key.none, .{}, &outer_children, 0, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(outer, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 22), model.size.height);
    try std.testing.expectEqual(@as(f32, 0), model.find(a).?.rect.y);
    try std.testing.expectEqual(@as(f32, 12), model.find(b).?.rect.y);
}

test "button reserves space for its label plus inner padding" {
    var storage: Node = undefined;
    const button = component.Button.node(&storage, component.Key.none, .{}, "OK", null, null);

    var engine = Engine.init(std.testing.allocator, .{
        .button_padding = EdgeInsets.symmetric(4, 6),
    });
    defer engine.deinit();

    const model = try engine.layout(button, Size.init(500, 500));
    const label = component.TextContent{ .text = "OK" };
    try std.testing.expectEqual(label.measure().width + 12, model.size.width);
    try std.testing.expectEqual(label.measure().height + 8, model.size.height);
}

test "invalid node is rejected instead of producing geometry" {
    var bad_storage: Node = undefined;
    const bad = component.Column.node(&bad_storage, component.Key.none, .{}, &.{}, -1, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    try std.testing.expectError(Error.InvalidNode, engine.layout(bad, Size.init(100, 100)));
}

test "invalid constraints are rejected" {
    var storage: Node = undefined;
    const spacer = component.Spacer.node(&storage, component.Key.none, Size.square(4));

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    try std.testing.expectError(
        Error.InvalidNode,
        engine.layout(spacer, Size.init(-10, 10)),
    );
}

test "layout is deterministic across runs" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = component.Spacer.node(&a_storage, component.Key.none, Size.init(7, 3));
    const b = component.Spacer.node(&b_storage, component.Key.none, Size.init(11, 5));
    const children = [_]*const Node{ a, b };

    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &children, 3, .center, .end);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const first = try engine.layout(row, Size.init(200, 100));
    const first_size = first.size;
    const first_x = first.find(b).?.rect.x;
    const first_y = first.find(b).?.rect.y;

    const second = try engine.layout(row, Size.init(200, 100));
    try std.testing.expectEqual(first_size.width, second.size.width);
    try std.testing.expectEqual(first_size.height, second.size.height);
    try std.testing.expectEqual(first_x, second.find(b).?.rect.x);
    try std.testing.expectEqual(first_y, second.find(b).?.rect.y);
}

test "model records every node once" {
    var leaf_storage: Node = undefined;
    const leaf = component.Text.node(&leaf_storage, component.Key.none, .{}, .{ .text = "zui" });

    var box_storage: Node = undefined;
    const box = component.Box.node(&box_storage, component.Key.none, .{}, leaf, .start, .start);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(box, Size.init(100, 100));
    try std.testing.expectEqual(@as(usize, 2), model.items.len);
    try std.testing.expect(model.find(leaf) != null);
    try std.testing.expect(model.find(box) != null);
}

test "cross axis alignment centres a short child" {
    var short_storage: Node = undefined;
    var tall_storage: Node = undefined;
    const short = component.Spacer.node(&short_storage, component.Key.none, Size.init(10, 10));
    const tall = component.Spacer.node(&tall_storage, component.Key.none, Size.init(10, 30));
    const children = [_]*const Node{ tall, short };

    var row_storage: Node = undefined;
    const row = component.Row.node(&row_storage, component.Key.none, .{}, &children, 0, .start, .center);

    var engine = Engine.init(std.testing.allocator, .{});
    defer engine.deinit();

    const model = try engine.layout(row, Size.init(500, 500));
    try std.testing.expectEqual(@as(f32, 10), model.find(short).?.rect.y);
}
