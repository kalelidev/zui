//! Theme: typed colors, typography and spacing for the whole application.
//!
//! A `Theme` is a plain value. Components receive it by pointer during layout
//! and rendering; it is created once by the application and does not change
//! while a frame is being built, so no allocator is involved.

const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");

pub const Color = color.Color;
pub const Palette = color.Palette;

/// A font size and line height pair, in logical pixels.
pub const TextStyle = struct {
    size: f32 = 14,
    line_height: f32 = 20,
    weight: Weight = .regular,

    pub const Weight = enum { regular, medium, bold };

    pub const body: TextStyle = .{ .size = 14, .line_height = 20 };
    pub const title: TextStyle = .{ .size = 20, .line_height = 28, .weight = .medium };
    pub const caption: TextStyle = .{ .size = 12, .line_height = 16 };

    pub fn isValid(s: TextStyle) bool {
        return std.math.isFinite(s.size) and std.math.isFinite(s.line_height) and
            s.size > 0 and s.line_height >= s.size;
    }
};

/// Spacing scale. Components must use these steps instead of arbitrary values so
/// that interfaces stay visually consistent.
pub const Spacing = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,

    pub fn isValid(s: Spacing) bool {
        return s.xs >= 0 and s.xs <= s.sm and s.sm <= s.md and
            s.md <= s.lg and s.lg <= s.xl;
    }
};

pub const Theme = struct {
    palette: Palette = Palette.light,
    body: TextStyle = TextStyle.body,
    title: TextStyle = TextStyle.title,
    caption: TextStyle = TextStyle.caption,
    spacing: Spacing = .{},
    /// Radius used by rounded surfaces such as buttons.
    corner_radius: f32 = 6,
    /// Width of a hairline border, in logical pixels.
    border_width: f32 = 1,

    pub const light: Theme = .{};

    pub const dark: Theme = .{ .palette = Palette.dark };

    /// Same theme with the dark palette, keeping typography and spacing.
    pub fn toDark(t: Theme) Theme {
        var result = t;
        result.palette = Palette.dark;
        return result;
    }

    pub fn isValid(t: Theme) bool {
        return t.body.isValid() and t.title.isValid() and t.caption.isValid() and
            t.spacing.isValid() and std.math.isFinite(t.corner_radius) and
            t.corner_radius >= 0 and std.math.isFinite(t.border_width) and
            t.border_width >= 0;
    }
};

test "default themes are valid" {
    try std.testing.expect(Theme.light.isValid());
    try std.testing.expect(Theme.dark.isValid());
}

test "spacing scale is ordered" {
    const s = Spacing{};
    try std.testing.expect(s.xs < s.sm);
    try std.testing.expect(s.sm < s.md);
    try std.testing.expect(s.md < s.lg);
    try std.testing.expect(s.lg < s.xl);
}

test "text style rejects a line height smaller than the font size" {
    const bad = TextStyle{ .size = 20, .line_height = 10 };
    try std.testing.expect(!bad.isValid());
    try std.testing.expect(TextStyle.body.isValid());
}

test "toDark swaps only the palette" {
    const dark = Theme.light.toDark();
    try std.testing.expect(Color.eql(Palette.dark.background, dark.palette.background));
    try std.testing.expectEqual(Theme.light.spacing.md, dark.spacing.md);
    try std.testing.expectEqual(Theme.light.body.size, dark.body.size);
}

test "theme rejects an unordered spacing scale" {
    var t = Theme.light;
    t.spacing.sm = 100;
    try std.testing.expect(!t.isValid());
}
