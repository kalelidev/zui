//! Colors and the typed palette used by the theme.
//!
//! Colors are stored as non-premultiplied 8-bit sRGB channels plus an alpha
//! channel. That matches what theme authors write by hand and what platform
//! backends expect, so no conversion is needed on the common path.
//!
//! `Color` is a plain value type: it owns no memory and is safe to copy and
//! compare.

const std = @import("std");

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub fn init(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn initAlpha(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Builds a color from a packed `0xRRGGBB` value, as used in design specs.
    pub fn fromRgb(hex: u24) Color {
        return .{
            .r = @truncate(hex >> 16),
            .g = @truncate(hex >> 8),
            .b = @truncate(hex),
            .a = 255,
        };
    }

    /// Builds a color from a packed `0xRRGGBBAA` value.
    pub fn fromRgba(hex: u32) Color {
        return .{
            .r = @truncate(hex >> 24),
            .g = @truncate(hex >> 16),
            .b = @truncate(hex >> 8),
            .a = @truncate(hex),
        };
    }

    /// Packs the color as `0xRRGGBBAA`.
    pub fn toRgba(c: Color) u32 {
        return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | c.a;
    }

    /// Returns the same color with a different alpha.
    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// Fully opaque means the color hides whatever is behind it, which lets the
    /// renderer skip blending for the common case.
    pub fn isOpaque(c: Color) bool {
        return c.a == 255;
    }

    pub fn isTransparent(c: Color) bool {
        return c.a == 0;
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.toRgba() == b.toRgba();
    }
};

/// Theme color roles. Keeping roles rather than raw values in component
/// properties lets a theme change every component at once.
pub const Palette = struct {
    background: Color = Color.white,
    surface: Color = Color.fromRgb(0xF5F5F5),
    primary: Color = Color.fromRgb(0x2962FF),
    on_primary: Color = Color.white,
    on_background: Color = Color.black,
    on_surface: Color = Color.black,
    border: Color = Color.fromRgb(0xE0E0E0),

    pub const light: Palette = .{};

    pub const dark: Palette = .{
        .background = Color.fromRgb(0x121212),
        .surface = Color.fromRgb(0x1E1E1E),
        .primary = Color.fromRgb(0x82B1FF),
        .on_primary = Color.fromRgb(0x121212),
        .on_background = Color.white,
        .on_surface = Color.white,
        .border = Color.fromRgb(0x2C2C2C),
    };
};

test "rgb and rgba packing round-trip" {
    const c = Color.fromRgb(0x1A2B3C);
    try std.testing.expectEqual(@as(u8, 0x1A), c.r);
    try std.testing.expectEqual(@as(u8, 0x2B), c.g);
    try std.testing.expectEqual(@as(u8, 0x3C), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);

    const semi = Color.fromRgba(0x1A2B3C80);
    try std.testing.expectEqual(@as(u32, 0x1A2B3C80), semi.toRgba());
    try std.testing.expect(!semi.isOpaque());
}

test "transparent and opacity predicates" {
    try std.testing.expect(Color.transparent.isTransparent());
    try std.testing.expect(!Color.transparent.isOpaque());
    try std.testing.expect(Color.white.isOpaque());
    try std.testing.expect(!Color.white.isTransparent());
}

test "withAlpha keeps the rgb channels" {
    const c = Color.init(10, 20, 30).withAlpha(128);
    try std.testing.expectEqual(@as(u8, 10), c.r);
    try std.testing.expectEqual(@as(u8, 20), c.g);
    try std.testing.expectEqual(@as(u8, 30), c.b);
    try std.testing.expectEqual(@as(u8, 128), c.a);
}

test "color equality is by value" {
    try std.testing.expect(Color.eql(Color.init(1, 2, 3), Color.init(1, 2, 3)));
    try std.testing.expect(!Color.eql(Color.init(1, 2, 3), Color.init(1, 2, 4)));
    try std.testing.expect(!Color.eql(Color.init(1, 2, 3), Color.initAlpha(1, 2, 3, 254)));
}

test "palettes use opaque colors for reading surfaces" {
    try std.testing.expect(Palette.light.background.isOpaque());
    try std.testing.expect(Palette.light.on_background.isOpaque());
    try std.testing.expect(Palette.dark.background.isOpaque());
    try std.testing.expect(Palette.dark.on_background.isOpaque());
}

test "dark palette differs from light palette" {
    try std.testing.expect(!Color.eql(Palette.light.background, Palette.dark.background));
    try std.testing.expect(!Color.eql(Palette.light.on_background, Palette.dark.on_background));
}
