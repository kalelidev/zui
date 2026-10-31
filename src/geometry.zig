//! Geometry primitives shared by the layout engine and the renderer.
//!
//! Coordinate model:
//! - Units are logical pixels stored as `f32`.
//! - The origin is the top-left corner of the window; `x` grows to the right
//!   and `y` grows downwards.
//! - Values are not rounded during layout. Rounding to device pixels happens
//!   once, at render time, through `Rect.round`.
//!
//! Every type here is a plain value type: it owns no memory, allocates nothing,
//! and is safe to copy.

const std = @import("std");

/// A 2D offset in logical pixels.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Point = .{};

    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }

    pub fn isFinite(p: Point) bool {
        return std.math.isFinite(p.x) and std.math.isFinite(p.y);
    }
};

/// A width/height pair in logical pixels. Negative values are not meaningful;
/// use `isValid` to verify a value received from outside the framework.
pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub const zero: Size = .{};

    pub fn init(width: f32, height: f32) Size {
        return .{ .width = width, .height = height };
    }

    pub fn square(side: f32) Size {
        return .{ .width = side, .height = side };
    }

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }

    pub fn isValid(s: Size) bool {
        return std.math.isFinite(s.width) and std.math.isFinite(s.height) and
            s.width >= 0 and s.height >= 0;
    }
};

/// An axis-aligned rectangle described by its top-left corner and its size.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub const zero: Rect = .{};

    pub fn init(x: f32, y: f32, width: f32, height: f32) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn fromPointSize(pos: Point, extent: Size) Rect {
        return .{ .x = pos.x, .y = pos.y, .width = extent.width, .height = extent.height };
    }

    pub fn fromSize(extent: Size) Rect {
        return fromPointSize(.zero, extent);
    }

    pub fn origin(r: Rect) Point {
        return .{ .x = r.x, .y = r.y };
    }

    pub fn size(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }

    pub fn right(r: Rect) f32 {
        return r.x + r.width;
    }

    pub fn bottom(r: Rect) f32 {
        return r.y + r.height;
    }

    pub fn center(r: Rect) Point {
        return .{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
    }

    /// True when the rectangle has no area. Used instead of a sentinel value so
    /// that layout code never has to special-case empty results.
    pub fn isEmpty(r: Rect) bool {
        return r.width <= 0 or r.height <= 0;
    }

    pub fn isValid(r: Rect) bool {
        return std.math.isFinite(r.x) and std.math.isFinite(r.y) and
            Size.isValid(r.size());
    }

    pub fn offset(r: Rect, delta: Point) Rect {
        return .{ .x = r.x + delta.x, .y = r.y + delta.y, .width = r.width, .height = r.height };
    }

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.x < r.right() and p.y >= r.y and p.y < r.bottom();
    }

    /// Shrinks the rectangle on each side. The result may be empty, never
    /// negative-sized.
    pub fn inset(r: Rect, insets: EdgeInsets) Rect {
        const width = @max(0, r.width - insets.horizontal());
        const height = @max(0, r.height - insets.vertical());
        return .{
            .x = r.x + insets.left,
            .y = r.y + insets.top,
            .width = width,
            .height = height,
        };
    }

    /// Grows the rectangle on each side.
    pub fn outset(r: Rect, insets: EdgeInsets) Rect {
        return .{
            .x = r.x - insets.left,
            .y = r.y - insets.top,
            .width = r.width + insets.horizontal(),
            .height = r.height + insets.vertical(),
        };
    }

    /// Overlapping area of two rectangles; empty when they do not overlap.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) {
            return .{ .x = x0, .y = y0, .width = 0, .height = 0 };
        }
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    /// Snaps the rectangle to whole logical pixels. Rendering uses this so that
    /// subpixel layout results never produce blurry edges or gaps.
    pub fn round(r: Rect) Rect {
        const x0 = @round(r.x);
        const y0 = @round(r.y);
        const x1 = @round(r.right());
        const y1 = @round(r.bottom());
        return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
    }
};

/// Space reserved around or between content, in logical pixels.
pub const EdgeInsets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub const zero: EdgeInsets = .{};

    pub fn all(value: f32) EdgeInsets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    /// Vertical and horizontal shorthand, in that order.
    pub fn symmetric(vertical_amount: f32, horizontal_amount: f32) EdgeInsets {
        return .{
            .top = vertical_amount,
            .right = horizontal_amount,
            .bottom = vertical_amount,
            .left = horizontal_amount,
        };
    }

    pub fn horizontal(e: EdgeInsets) f32 {
        return e.left + e.right;
    }

    pub fn vertical(e: EdgeInsets) f32 {
        return e.top + e.bottom;
    }

    pub fn isValid(e: EdgeInsets) bool {
        return std.math.isFinite(e.top) and std.math.isFinite(e.right) and
            std.math.isFinite(e.bottom) and std.math.isFinite(e.left);
    }
};

/// Constraints passed down the component tree during measurement.
///
/// An infinite `max` means "unbounded on that axis", which happens inside a
/// scrollable container or when the window has no fixed size yet.
pub const Constraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),

    /// Unbounded on both axes.
    pub const unbounded: Constraints = .{};

    /// Both axes fixed to an exact size.
    pub fn tight(size: Size) Constraints {
        return .{
            .min_width = size.width,
            .max_width = size.width,
            .min_height = size.height,
            .max_height = size.height,
        };
    }

    /// Both axes free up to `size`.
    pub fn loose(size: Size) Constraints {
        return .{
            .min_width = 0,
            .max_width = size.width,
            .min_height = 0,
            .max_height = size.height,
        };
    }

    pub fn hasBoundedWidth(c: Constraints) bool {
        return std.math.isFinite(c.max_width);
    }

    pub fn hasBoundedHeight(c: Constraints) bool {
        return std.math.isFinite(c.max_height);
    }

    /// Clamps a measured size into the constraint range. A non-finite or
    /// negative measurement is rejected as a whole (it collapses to zero)
    /// instead of being snapped to a bound: `@min`/`@max` treat NaN as the
    /// other operand, which would silently turn a bad measurement into the
    /// largest allowed size.
    pub fn constrain(c: Constraints, size: Size) Size {
        if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height)) {
            return .zero;
        }
        if (size.width < 0 or size.height < 0) {
            return .zero;
        }
        return .{
            .width = std.math.clamp(size.width, c.min_width, c.max_width),
            .height = std.math.clamp(size.height, c.min_height, c.max_height),
        };
    }

    /// Removes the space taken by padding before measuring content.
    pub fn deflate(c: Constraints, insets: EdgeInsets) Constraints {
        const horizontal = insets.horizontal();
        const vertical = insets.vertical();
        return .{
            .min_width = @max(0, c.min_width - horizontal),
            .max_width = @max(0, c.max_width - horizontal),
            .min_height = @max(0, c.min_height - vertical),
            .max_height = @max(0, c.max_height - vertical),
        };
    }

    /// True when the range is ordered, non-negative and free of NaN. Infinite
    /// maximums are valid; infinite minimums are not.
    pub fn isValid(c: Constraints) bool {
        if (!std.math.isFinite(c.min_width) or !std.math.isFinite(c.min_height)) return false;
        if (std.math.isNan(c.max_width) or std.math.isNan(c.max_height)) return false;
        return c.min_width >= 0 and c.min_height >= 0 and
            c.min_width <= c.max_width and c.min_height <= c.max_height;
    }
};

/// Placement of content on a single axis. Layout primitives use it per axis,
/// which is enough for `Row`, `Column` and `Box` in the MVP.
pub const Alignment = enum {
    start,
    center,
    end,

    /// Offset of an item of `item` extent inside a slot of `slot` extent.
    /// Empty slots produce no offset rather than a negative one.
    pub fn offset(a: Alignment, slot: f32, item: f32) f32 {
        const remaining = slot - item;
        if (remaining <= 0) return 0;
        return switch (a) {
            .start => 0,
            .center => remaining / 2,
            .end => remaining,
        };
    }
};

pub const Axis = enum { horizontal, vertical };

test "size validity rejects negatives and NaN" {
    try std.testing.expect(Size.init(10, 20).isValid());
    try std.testing.expect(!Size.init(-1, 20).isValid());
    try std.testing.expect(!Size.init(std.math.nan(f32), 20).isValid());
    try std.testing.expect(!Size.init(1, std.math.inf(f32)).isValid());
}

test "rect derived edges and center" {
    const r = Rect.init(10, 20, 100, 50);
    try std.testing.expectEqual(@as(f32, 110), r.right());
    try std.testing.expectEqual(@as(f32, 70), r.bottom());
    try std.testing.expect(Point.eql(.{ .x = 60, .y = 45 }, r.center()));
}

test "rect contains is half-open at the far edges" {
    const r = Rect.init(0, 0, 10, 10);
    try std.testing.expect(r.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(r.contains(.{ .x = 9.5, .y = 9.5 }));
    try std.testing.expect(!r.contains(.{ .x = 10, .y = 5 }));
    try std.testing.expect(!r.contains(.{ .x = 5, .y = 10 }));
}

test "rect inset and outset are inverse for valid boxes" {
    const r = Rect.init(0, 0, 100, 40);
    const insets = EdgeInsets.symmetric(5, 10);
    const inner = r.inset(insets);
    try std.testing.expect(Rect.eql(Rect.init(10, 5, 80, 30), inner));

    const outer = inner.outset(insets);
    try std.testing.expect(Rect.eql(r, outer));
}

test "rect inset never produces a negative size" {
    const r = Rect.init(0, 0, 10, 10);
    const inner = r.inset(EdgeInsets.all(50));
    try std.testing.expectEqual(@as(f32, 0), inner.width);
    try std.testing.expectEqual(@as(f32, 0), inner.height);
    try std.testing.expect(inner.isEmpty());
}

test "rect intersect returns the overlap or an empty rect" {
    const a = Rect.init(0, 0, 100, 100);
    const b = Rect.init(50, 50, 100, 100);
    try std.testing.expect(Rect.eql(Rect.init(50, 50, 50, 50), a.intersect(b)));

    const far = Rect.init(500, 500, 10, 10);
    const none = a.intersect(far);
    try std.testing.expect(none.isEmpty());
    try std.testing.expectEqual(@as(f32, 0), none.width);
}

test "rect round snaps edges to whole pixels" {
    const r = Rect.init(10.4, 20.6, 30.3, 40.2);
    const rounded = r.round();
    try std.testing.expectEqual(@as(f32, 10), rounded.x);
    try std.testing.expectEqual(@as(f32, 21), rounded.y);
    // Edges are rounded first, then converted back to a size, so the result
    // never drifts by more than one pixel on each side.
    try std.testing.expectEqual(@as(f32, 31), rounded.width);
    try std.testing.expectEqual(@as(f32, 40), rounded.height);
}

test "rect round keeps a degenerate rect empty" {
    const r = Rect.init(10.2, 10.2, 0.1, 0.1);
    const rounded = r.round();
    try std.testing.expectEqual(@as(f32, 0), rounded.width);
    try std.testing.expectEqual(@as(f32, 0), rounded.height);
}

test "constraints tight fixes both axes" {
    const c = Constraints.tight(.{ .width = 200, .height = 100 });
    const measured = c.constrain(.{ .width = 50, .height = 500 });
    try std.testing.expectEqual(@as(f32, 200), measured.width);
    try std.testing.expectEqual(@as(f32, 100), measured.height);
    try std.testing.expect(c.hasBoundedWidth());
    try std.testing.expect(c.hasBoundedHeight());
}

test "constraints loose allows smaller content" {
    const c = Constraints.loose(.{ .width = 200, .height = 100 });
    const measured = c.constrain(.{ .width = 50, .height = 20 });
    try std.testing.expectEqual(@as(f32, 50), measured.width);
    try std.testing.expectEqual(@as(f32, 20), measured.height);
}

test "constraints unbounded reports unbounded axes and is valid" {
    try std.testing.expect(!Constraints.unbounded.hasBoundedWidth());
    try std.testing.expect(!Constraints.unbounded.hasBoundedHeight());
    try std.testing.expect(Constraints.unbounded.isValid());
}

test "constraints deflate removes padding from both bounds" {
    const c = Constraints.loose(.{ .width = 100, .height = 50 });
    const inner = c.deflate(EdgeInsets.symmetric(5, 10));
    try std.testing.expectEqual(@as(f32, 80), inner.max_width);
    try std.testing.expectEqual(@as(f32, 40), inner.max_height);
}

test "constraints deflate clamps to zero instead of going negative" {
    const c = Constraints.loose(.{ .width = 5, .height = 5 });
    const inner = c.deflate(EdgeInsets.all(50));
    try std.testing.expectEqual(@as(f32, 0), inner.max_width);
    try std.testing.expectEqual(@as(f32, 0), inner.max_height);
    try std.testing.expect(inner.isValid());
}

test "constraints reject an inverted range" {
    const bad = Constraints{ .min_width = 100, .max_width = 10 };
    try std.testing.expect(!bad.isValid());
}

test "constrain collapses non-finite measurements to zero" {
    const c = Constraints.loose(.{ .width = 100, .height = 100 });
    const measured = c.constrain(.{ .width = std.math.nan(f32), .height = 10 });
    try std.testing.expectEqual(@as(f32, 0), measured.width);
    try std.testing.expectEqual(@as(f32, 0), measured.height);
}

test "alignment offsets" {
    try std.testing.expectEqual(@as(f32, 0), Alignment.start.offset(100, 40));
    try std.testing.expectEqual(@as(f32, 30), Alignment.center.offset(100, 40));
    try std.testing.expectEqual(@as(f32, 60), Alignment.end.offset(100, 40));
}

test "alignment never returns a negative offset for oversized items" {
    try std.testing.expectEqual(@as(f32, 0), Alignment.center.offset(20, 40));
    try std.testing.expectEqual(@as(f32, 0), Alignment.end.offset(20, 40));
}

test "point helpers" {
    const p = Point.init(1.5, 2.5);
    try std.testing.expect(p.isFinite());
    try std.testing.expect(Point.eql(Point.init(2.5, 4.5), p.add(.{ .x = 1, .y = 2 })));
}

test "edge insets shorthand" {
    const e = EdgeInsets.symmetric(2, 4);
    try std.testing.expectEqual(@as(f32, 8), e.horizontal());
    try std.testing.expectEqual(@as(f32, 4), e.vertical());
    try std.testing.expect(e.isValid());
}
