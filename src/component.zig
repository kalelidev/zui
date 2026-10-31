//! Component descriptions: the declarative part of the UI.
//!
//! A `Node` is an immutable description of one element of the interface. It is
//! created by application code during composition, compared against the
//! previous description of the same identity, and then handed to the layout
//! engine. It owns no layout or rendering data: geometry lives in the layout
//! tree so that a description can be rebuilt cheaply.
//!
//! Ownership rules:
//! - The caller owns the storage of a `Node` (`build` is available for that).
//! - String content is borrowed. The caller must keep it alive while the node is
//!   in use, which in practice means the string is a literal or lives in the
//!   application's own state for the duration of a frame.
//! - Child pointers are borrowed as well; the layout tree copies whatever it
//!   needs into its own storage.
//!
//! Identity:
//! - `Key` is a caller-supplied stable identity. Two descriptions with the same
//!   key in the same parent position represent the same component instance, so
//!   compatible state survives recomposition.
//! - Keys must not be derived from memory addresses; use a counter, an index from
//!   stable data, or a domain identifier.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");

pub const Rect = geometry.Rect;
pub const EdgeInsets = geometry.EdgeInsets;
pub const Constraints = geometry.Constraints;
pub const Size = geometry.Size;
pub const Alignment = geometry.Alignment;
pub const Axis = geometry.Axis;
pub const Color = color.Color;

/// Stable component identity, scoped to a position in the tree.
pub const Key = struct {
    value: u64 = 0,

    pub const none: Key = .{ .value = 0 };

    pub fn init(value: u64) Key {
        return .{ .value = value };
    }

    pub fn isNone(k: Key) bool {
        return k.value == 0;
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.value == b.value;
    }
};

/// Visual and behavioural properties shared by every component.
pub const Modifier = struct {
    padding: EdgeInsets = .{},
    /// Space reserved outside the component when it is placed by a parent.
    margin: EdgeInsets = .{},
    width: ?f32 = null,
    height: ?f32 = null,
    background: ?Color = null,
    border_color: ?Color = null,
    border_width: f32 = 0,

    pub const none: Modifier = .{};

    pub fn withPadding(m: Modifier, insets: EdgeInsets) Modifier {
        var result = m;
        result.padding = insets;
        return result;
    }

    pub fn withBackground(m: Modifier, background: Color) Modifier {
        var result = m;
        result.background = background;
        return result;
    }

    pub fn withSize(m: Modifier, width: f32, height: f32) Modifier {
        var result = m;
        result.width = width;
        result.height = height;
        return result;
    }

    /// A modifier is usable when its numbers are finite and non-negative. Invalid
    /// modifiers are rejected at the API boundary instead of corrupting layout.
    pub fn isValid(m: Modifier) bool {
        if (!m.padding.isValid() or !m.margin.isValid()) return false;
        if (m.border_width < 0 or !std.math.isFinite(m.border_width)) return false;
        if (m.width) |w| {
            if (!std.math.isFinite(w) or w < 0) return false;
        }
        if (m.height) |h| {
            if (!std.math.isFinite(h) or h < 0) return false;
        }
        return true;
    }
};

/// Text content, borrowed from the caller.
pub const TextContent = struct {
    text: []const u8,
    style: TextStyle = .{},

    pub const TextStyle = struct {
        size: f32 = 14,
        line_height: f32 = 20,
        color: ?Color = null,
        weight: Weight = .regular,

        pub const Weight = enum { regular, medium, bold };
    };

    /// Approximate advance width of the text. The real measurement is provided by
    /// the text engine; until then this is the deterministic estimate used by
    /// layout, documented as such rather than presented as exact.
    pub fn measure(content: TextContent) Size {
        const scale = content.style.size / 2.0;
        const width = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(content.text) catch content.text.len)) * scale;
        return .{ .width = width, .height = content.style.line_height };
    }
};

/// The kind of a node, with its own properties. The union is tagged so that
/// layout and rendering can switch on it without extra type information.
pub const NodeKind = union(enum) {
    /// Leaf that only reserves space.
    spacer: struct {
        size: ?Size = null,
    },
    /// Leaf that draws text.
    text: TextContent,
    /// Box with a background and optional border, containing one child.
    box: struct {
        child: ?*const Node = null,
        alignment: Alignment = .start,
        cross_alignment: Alignment = .start,
    },
    /// Horizontal container.
    row: struct {
        children: []const *const Node = &.{},
        spacing: f32 = 0,
        alignment: Alignment = .start,
        cross_alignment: Alignment = .start,
    },
    /// Vertical container.
    column: struct {
        children: []const *const Node = &.{},
        spacing: f32 = 0,
        alignment: Alignment = .start,
        cross_alignment: Alignment = .start,
    },
    /// Interactive control that draws a label and reports clicks.
    button: struct {
        label: []const u8,
        enabled: bool = true,
        on_click: ?*const fn (?*anyopaque) void = null,
        context: ?*anyopaque = null,
    },
};

pub const Node = struct {
    key: Key = Key.none,
    modifier: Modifier = .{},
    kind: NodeKind,

    /// Builds a node in caller-provided storage. Kept as a helper so that call
    /// sites do not need to spell out the struct literal for temporary nodes.
    pub fn build(storage: *Node, key: Key, modifier: Modifier, kind: NodeKind) *const Node {
        storage.* = .{ .key = key, .modifier = modifier, .kind = kind };
        return storage;
    }

    /// A node is valid when its modifier is valid and the properties of its kind
    /// are consistent. Invalid nodes are reported rather than silently drawn.
    pub fn isValid(node: Node) bool {
        if (!node.modifier.isValid()) return false;
        return switch (node.kind) {
            .spacer => |s| if (s.size) |extent| extent.isValid() else true,
            // Empty strings are allowed: a component may legitimately render no
            // text yet, for example while data loads. They measure as zero width.
            .text => true,
            .box => true,
            .row => |r| isValidContainer(r.spacing, r.children),
            .column => |c| isValidContainer(c.spacing, c.children),
            .button => true,
        };
    }

    fn isValidContainer(spacing: f32, items: []const *const Node) bool {
        if (!std.math.isFinite(spacing) or spacing < 0) return false;
        for (items) |child| {
            if (!child.isValid()) return false;
        }
        return true;
    }

    /// The children of a container in visual order. Leaves and `box` yield an
    /// empty slice: a box holds at most one child, reached through `boxChild`.
    /// Keeping them apart avoids fabricating a one-element slice whose storage
    /// would outlive the union field it points into.
    pub fn children(node: Node) []const *const Node {
        return switch (node.kind) {
            .row => |r| r.children,
            .column => |c| c.children,
            .spacer, .text, .button, .box => &.{},
        };
    }

    /// The single child of a `box`, or null for every other kind.
    pub fn boxChild(node: Node) ?*const Node {
        return switch (node.kind) {
            .box => |b| b.child,
            else => null,
        };
    }

    /// Number of direct children, counting a box's single child.
    pub fn childCount(node: Node) usize {
        return switch (node.kind) {
            .spacer, .text, .button => 0,
            .box => |b| if (b.child != null) 1 else 0,
            .row => |r| r.children.len,
            .column => |c| c.children.len,
        };
    }

    /// Spacing applied between children by the container.
    pub fn childSpacing(node: Node) f32 {
        return switch (node.kind) {
            .row => |r| r.spacing,
            .column => |c| c.spacing,
            else => 0,
        };
    }
};

pub const Spacer = struct {
    pub fn node(storage: *Node, key: Key, size: ?Size) *const Node {
        return Node.build(storage, key, .{}, .{ .spacer = .{ .size = size } });
    }
};

pub const Text = struct {
    pub fn node(storage: *Node, key: Key, modifier: Modifier, content: TextContent) *const Node {
        return Node.build(storage, key, modifier, .{ .text = content });
    }
};

pub const Button = struct {
    pub const ClickHandler = *const fn (?*anyopaque) void;

    pub fn node(
        storage: *Node,
        key: Key,
        modifier: Modifier,
        label: []const u8,
        on_click: ?ClickHandler,
        context: ?*anyopaque,
    ) *const Node {
        return Node.build(storage, key, modifier, .{
            .button = .{ .label = label, .on_click = on_click, .context = context },
        });
    }
};

pub const Box = struct {
    pub fn node(
        storage: *Node,
        key: Key,
        modifier: Modifier,
        child: ?*const Node,
        alignment: Alignment,
        cross_alignment: Alignment,
    ) *const Node {
        return Node.build(storage, key, modifier, .{
            .box = .{ .child = child, .alignment = alignment, .cross_alignment = cross_alignment },
        });
    }
};

pub const Row = struct {
    pub fn node(
        storage: *Node,
        key: Key,
        modifier: Modifier,
        children: []const *const Node,
        spacing: f32,
        alignment: Alignment,
        cross_alignment: Alignment,
    ) *const Node {
        return Node.build(storage, key, modifier, .{
            .row = .{
                .children = children,
                .spacing = spacing,
                .alignment = alignment,
                .cross_alignment = cross_alignment,
            },
        });
    }
};

pub const Column = struct {
    pub fn node(
        storage: *Node,
        key: Key,
        modifier: Modifier,
        children: []const *const Node,
        spacing: f32,
        alignment: Alignment,
        cross_alignment: Alignment,
    ) *const Node {
        return Node.build(storage, key, modifier, .{
            .column = .{
                .children = children,
                .spacing = spacing,
                .alignment = alignment,
                .cross_alignment = cross_alignment,
            },
        });
    }
};

test "keys distinguish instances and detect the absent key" {
    try std.testing.expect(Key.none.isNone());
    try std.testing.expect(!Key.init(1).isNone());
    try std.testing.expect(Key.eql(Key.init(7), Key.init(7)));
    try std.testing.expect(!Key.eql(Key.init(7), Key.init(8)));
}

test "text measurement is deterministic and grows with length" {
    const short = TextContent{ .text = "ab" };
    const long = TextContent{ .text = "abcd" };
    try std.testing.expectEqual(short.measure().width * 2, long.measure().width);
    try std.testing.expectEqual(short.measure().height, long.measure().height);
    try std.testing.expectEqual(short.measure().width, short.measure().width);
}

test "text measurement counts codepoints, not bytes" {
    const ascii = TextContent{ .text = "ae" };
    // "áé" is four bytes but two codepoints, so it measures like "ae".
    const accented = TextContent{ .text = "áé" };
    try std.testing.expectEqual(ascii.measure().width, accented.measure().width);
}

test "childCount reports the direct children of every kind" {
    var leaf_storage: Node = undefined;
    const leaf = Text.node(&leaf_storage, Key.none, .{}, .{ .text = "x" });
    try std.testing.expectEqual(@as(usize, 0), leaf.childCount());

    var text_storage: Node = undefined;
    const button = Button.node(&text_storage, Key.none, .{}, "ok", null, null);
    try std.testing.expectEqual(@as(usize, 0), button.childCount());
}

test "row exposes its children in order and its spacing" {
    var a_storage: Node = undefined;
    var b_storage: Node = undefined;
    const a = Spacer.node(&a_storage, Key.init(1), Size.square(4));
    const b = Spacer.node(&b_storage, Key.init(2), Size.square(4));
    const children = [_]*const Node{ a, b };

    var row_storage: Node = undefined;
    const row = Row.node(&row_storage, Key.init(3), .{}, &children, 6, .start, .start);

    try std.testing.expectEqual(@as(usize, 2), row.children().len);
    try std.testing.expect(row.children()[0] == a);
    try std.testing.expect(row.children()[1] == b);
    try std.testing.expectEqual(@as(f32, 6), row.childSpacing());
    try std.testing.expect(row.isValid());
}

test "column reports its spacing and rejects negative spacing" {
    var child_storage: Node = undefined;
    const child = Spacer.node(&child_storage, Key.none, null);
    const children = [_]*const Node{child};

    var ok_storage: Node = undefined;
    const ok = Column.node(&ok_storage, Key.none, .{}, &children, 8, .center, .end);
    try std.testing.expectEqual(@as(f32, 8), ok.childSpacing());
    try std.testing.expect(ok.isValid());

    var bad_storage: Node = undefined;
    const bad = Column.node(&bad_storage, Key.none, .{}, &children, -1, .start, .start);
    try std.testing.expect(!bad.isValid());
}

test "box exposes its single child through boxChild" {
    var child_storage: Node = undefined;
    const child = Spacer.node(&child_storage, Key.none, null);

    var with_storage: Node = undefined;
    const with_child = Box.node(&with_storage, Key.none, .{}, child, .center, .center);
    try std.testing.expectEqual(@as(usize, 0), with_child.children().len);
    try std.testing.expectEqual(@as(usize, 1), with_child.childCount());
    try std.testing.expect(with_child.boxChild().? == child);

    var empty_storage: Node = undefined;
    const empty = Box.node(&empty_storage, Key.none, .{}, null, .start, .start);
    try std.testing.expectEqual(@as(usize, 0), empty.children().len);
    try std.testing.expectEqual(@as(usize, 0), empty.childCount());
    try std.testing.expect(empty.boxChild() == null);
}

test "button keeps its label, handler and enabled flag" {
    const Handler = struct {
        fn onClick(_: ?*anyopaque) void {}
    };

    var storage: Node = undefined;
    const button = Button.node(&storage, Key.init(5), .{}, "Save", Handler.onClick, null);

    try std.testing.expectEqualStrings("Save", button.kind.button.label);
    try std.testing.expect(button.kind.button.enabled);
    try std.testing.expect(button.kind.button.on_click != null);
    try std.testing.expectEqual(@as(usize, 0), button.children().len);
    try std.testing.expect(button.isValid());
}

test "modifier validity rejects negative padding and bad sizes" {
    try std.testing.expect(Modifier.none.isValid());
    try std.testing.expect(Modifier.none.withSize(10, 10).isValid());
    try std.testing.expect(!Modifier.none.withSize(-1, 10).isValid());
    try std.testing.expect(!Modifier.none.withSize(std.math.nan(f32), 10).isValid());

    var bad_border = Modifier.none;
    bad_border.border_width = -2;
    try std.testing.expect(!bad_border.isValid());

    var bad_padding = Modifier.none;
    bad_padding.padding.top = std.math.nan(f32);
    try std.testing.expect(!bad_padding.isValid());
}

test "modifier builders do not mutate the original" {
    const base = Modifier.none;
    const padded = base.withPadding(EdgeInsets.all(4));
    try std.testing.expectEqual(@as(f32, 0), base.padding.top);
    try std.testing.expectEqual(@as(f32, 4), padded.padding.top);
    try std.testing.expect(base.background == null);
    try std.testing.expect(base.width == null);
}

test "a node with an invalid child is invalid" {
    var bad_child_storage: Node = undefined;
    const bad_child = Column.node(&bad_child_storage, Key.none, .{}, &.{}, -5, .start, .start);
    const children = [_]*const Node{bad_child};

    var parent_storage: Node = undefined;
    const parent = Row.node(&parent_storage, Key.none, .{}, &children, 0, .start, .start);
    try std.testing.expect(!parent.isValid());
}

test "text node is valid and has no children" {
    var storage: Node = undefined;
    const node = Text.node(&storage, Key.none, .{}, .{ .text = "hello" });
    try std.testing.expect(node.isValid());
    try std.testing.expectEqual(@as(usize, 0), node.children().len);
}
