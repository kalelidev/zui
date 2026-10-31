//! Text: font data, glyph lookup and measurement.
//!
//! ZUI ships a built-in bitmap font so that the initial backend can draw text
//! with no external dependency and identical results on every machine. The font
//! is a 5x7 cell with one column of spacing, scaled by an integer factor.
//!
//! This module is the single source of truth for text metrics: the layout engine
//! and the renderer both call `measure` and `scaleFor`, so a measured string
//! always occupies exactly the pixels the renderer paints.
//!
//! Known limitation (MVP): only uppercase letters, digits and a small set of
//! punctuation are defined. Lowercase letters are drawn as their uppercase
//! forms, and characters outside the set are skipped while still advancing the
//! cursor, so text never overlaps itself. Replacing this with a real scalable
//! font is Future Phase A work (see `docs/ROADMAP.md`).
//!
//! Ownership: everything here is static data plus pure functions. Nothing
//! allocates and nothing needs cleanup.

const std = @import("std");
const geometry = @import("geometry.zig");

pub const Size = geometry.Size;
pub const Point = geometry.Point;

/// Size of one glyph cell, in font pixels before scaling.
pub const glyph_width: u8 = 5;
pub const glyph_height: u8 = 7;
/// Horizontal distance between the start of two consecutive glyphs.
pub const advance: u8 = 6;
/// Vertical distance between two baselines.
pub const line_height: u8 = 9;

/// One glyph as seven rows; bits 0..4 of each row are the columns, left to right.
pub const Glyph = struct {
    rows: [glyph_height]u8,

    pub fn pixel(glyph: Glyph, x: u8, y: u8) bool {
        if (x >= glyph_width or y >= glyph_height) return false;
        return (glyph.rows[y] & (@as(u8, 1) << @intCast(x))) != 0;
    }

    /// True when the glyph paints nothing, e.g. the space character.
    pub fn isEmpty(glyph: Glyph) bool {
        for (glyph.rows) |row| {
            if (row != 0) return false;
        }
        return true;
    }
};

/// A glyph defined as seven 5-character rows, where `#` is ink. Declaring the
/// shapes as art keeps the table reviewable; the bitmasks are built at compile
/// time by `parseArt`.
const Definition = struct {
    codepoint: u21,
    art: [glyph_height][]const u8,
};

const definitions = [_]Definition{
    .{ .codepoint = ' ', .art = .{ ".....", ".....", ".....", ".....", ".....", ".....", "....." } },

    .{ .codepoint = 'A', .art = .{ ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    .{ .codepoint = 'B', .art = .{ "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." } },
    .{ .codepoint = 'C', .art = .{ ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###." } },
    .{ .codepoint = 'D', .art = .{ "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." } },
    .{ .codepoint = 'E', .art = .{ "#####", "#....", "#....", "####.", "#....", "#....", "#####" } },
    .{ .codepoint = 'F', .art = .{ "#####", "#....", "#....", "####.", "#....", "#....", "#...." } },
    .{ .codepoint = 'G', .art = .{ ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###." } },
    .{ .codepoint = 'H', .art = .{ "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    .{ .codepoint = 'I', .art = .{ ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    .{ .codepoint = 'J', .art = .{ "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.." } },
    .{ .codepoint = 'K', .art = .{ "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" } },
    .{ .codepoint = 'L', .art = .{ "#....", "#....", "#....", "#....", "#....", "#....", "#####" } },
    .{ .codepoint = 'M', .art = .{ "#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#" } },
    .{ .codepoint = 'N', .art = .{ "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#" } },
    .{ .codepoint = 'O', .art = .{ ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    .{ .codepoint = 'P', .art = .{ "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." } },
    .{ .codepoint = 'Q', .art = .{ ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" } },
    .{ .codepoint = 'R', .art = .{ "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" } },
    .{ .codepoint = 'S', .art = .{ ".####", "#....", "#....", ".###.", "....#", "....#", "####." } },
    .{ .codepoint = 'T', .art = .{ "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." } },
    .{ .codepoint = 'U', .art = .{ "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    .{ .codepoint = 'V', .art = .{ "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.." } },
    .{ .codepoint = 'W', .art = .{ "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#" } },
    .{ .codepoint = 'X', .art = .{ "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" } },
    .{ .codepoint = 'Y', .art = .{ "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." } },
    .{ .codepoint = 'Z', .art = .{ "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" } },

    .{ .codepoint = '0', .art = .{ ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." } },
    .{ .codepoint = '1', .art = .{ "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    .{ .codepoint = '2', .art = .{ ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" } },
    .{ .codepoint = '3', .art = .{ "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###." } },
    .{ .codepoint = '4', .art = .{ "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#." } },
    .{ .codepoint = '5', .art = .{ "#####", "#....", "####.", "....#", "....#", "#...#", ".###." } },
    .{ .codepoint = '6', .art = .{ "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." } },
    .{ .codepoint = '7', .art = .{ "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." } },
    .{ .codepoint = '8', .art = .{ ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###." } },
    .{ .codepoint = '9', .art = .{ ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." } },

    .{ .codepoint = '.', .art = .{ ".....", ".....", ".....", ".....", ".....", ".##..", ".##.." } },
    .{ .codepoint = ',', .art = .{ ".....", ".....", ".....", ".....", ".##..", ".##..", ".#..." } },
    .{ .codepoint = ':', .art = .{ ".....", ".##..", ".##..", ".....", ".##..", ".##..", "....." } },
    .{ .codepoint = ';', .art = .{ ".....", ".##..", ".##..", ".....", ".##..", ".##..", ".#..." } },
    .{ .codepoint = '!', .art = .{ "..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.." } },
    .{ .codepoint = '?', .art = .{ ".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.." } },
    .{ .codepoint = '-', .art = .{ ".....", ".....", ".....", "#####", ".....", ".....", "....." } },
    .{ .codepoint = '+', .art = .{ ".....", "..#..", "..#..", "#####", "..#..", "..#..", "....." } },
    .{ .codepoint = '/', .art = .{ "....#", "...#.", "...#.", "..#..", ".#...", ".#...", "#...." } },
    .{ .codepoint = '(', .art = .{ "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#." } },
    .{ .codepoint = ')', .art = .{ ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..." } },
    .{ .codepoint = '\'', .art = .{ "..#..", "..#..", ".....", ".....", ".....", ".....", "....." } },
    .{ .codepoint = '"', .art = .{ ".#.#.", ".#.#.", ".....", ".....", ".....", ".....", "....." } },
    .{ .codepoint = '=', .art = .{ ".....", ".....", "#####", ".....", "#####", ".....", "....." } },
    .{ .codepoint = '_', .art = .{ ".....", ".....", ".....", ".....", ".....", ".....", "#####" } },
    .{ .codepoint = '<', .art = .{ "...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#." } },
    .{ .codepoint = '>', .art = .{ ".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..." } },
    .{ .codepoint = '#', .art = .{ ".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#." } },
    .{ .codepoint = '%', .art = .{ "##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##" } },
    .{ .codepoint = '*', .art = .{ ".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....." } },
    .{ .codepoint = '&', .art = .{ ".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#" } },
    .{ .codepoint = '@', .art = .{ ".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###." } },
    .{ .codepoint = '$', .art = .{ "..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.." } },
    .{ .codepoint = '|', .art = .{ "..#..", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." } },
    .{ .codepoint = '~', .art = .{ ".....", ".....", ".#...", "#.#.#", "...#.", ".....", "....." } },
    .{ .codepoint = '^', .art = .{ "..#..", ".#.#.", "#...#", ".....", ".....", ".....", "....." } },
    .{ .codepoint = '`', .art = .{ ".#...", "..#..", ".....", ".....", ".....", ".....", "....." } },
    .{ .codepoint = '[', .art = .{ ".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###." } },
    .{ .codepoint = ']', .art = .{ ".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###." } },
    .{ .codepoint = '{', .art = .{ "..##.", ".#...", ".#...", "#....", ".#...", ".#...", "..##." } },
    .{ .codepoint = '}', .art = .{ ".##..", "...#.", "...#.", "....#", "...#.", "...#.", ".##.." } },
    .{ .codepoint = '\\', .art = .{ "#....", ".#...", ".#...", "..#..", "...#.", "...#.", "....#" } },
};

/// Parses one art row into a column bitmask. Available at comptime only.
fn parseRow(comptime row: []const u8) u8 {
    var mask: u8 = 0;
    for (row, 0..) |cell, index| {
        if (cell == '#') mask |= @as(u8, 1) << @intCast(index);
    }
    return mask;
}

fn parseArt(comptime art: [glyph_height][]const u8) Glyph {
    var rows: [glyph_height]u8 = undefined;
    for (art, 0..) |row, index| {
        if (row.len != glyph_width) {
            @compileError("glyph rows must be exactly " ++ std.fmt.comptimePrint("{d}", .{glyph_width}) ++ " characters wide");
        }
        rows[index] = parseRow(row);
    }
    return .{ .rows = rows };
}

/// Glyph table indexed by ASCII value. Entries that are not defined stay empty,
/// which the lookup function distinguishes from the space character.
const table: [128]?Glyph = blk: {
    @setEvalBranchQuota(20000);
    var result: [128]?Glyph = @splat(null);
    for (definitions) |definition| {
        if (definition.codepoint > 127) @compileError("font table only covers ASCII");
        result[definition.codepoint] = parseArt(definition.art);
    }
    break :blk result;
};

/// Glyph for a codepoint, or null when the font has no shape for it.
/// Lowercase ASCII is folded to uppercase so ordinary labels still render.
pub fn glyphFor(codepoint: u21) ?Glyph {
    if (codepoint > 127) return null;
    if (table[codepoint]) |glyph| return glyph;
    if (codepoint >= 'a' and codepoint <= 'z') {
        return table[std.ascii.toUpper(@intCast(codepoint))];
    }
    return null;
}

/// Integer scale factor for a logical font size. Bitmap glyphs only scale by
/// whole numbers; fractional scaling would blur the shapes.
pub fn scaleFor(font_size: f32) u8 {
    if (!std.math.isFinite(font_size) or font_size <= 0) return 1;
    const raw = @round(font_size / @as(f32, @floatFromInt(glyph_height)));
    const clamped = std.math.clamp(raw, 1, 8);
    return @intFromFloat(clamped);
}

/// Metrics of a piece of text at a given logical font size.
pub const Metrics = struct {
    size: Size,
    scale: u8,
    /// Number of visible lines, at least one.
    lines: usize,
};

/// Measures `content`, honouring `\n` as a hard line break. Width is the widest
/// line; height covers every line.
pub fn measure(content: []const u8, font_size: f32) Metrics {
    const scale = scaleFor(font_size);
    const scale_f: f32 = @floatFromInt(scale);

    var max_columns: usize = 0;
    var columns: usize = 0;
    var lines: usize = 1;

    var iterator = std.unicode.Utf8View.initUnchecked(content).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            max_columns = @max(max_columns, columns);
            columns = 0;
            lines += 1;
            continue;
        }
        // Undefined codepoints still advance: the renderer skips them, so the
        // cursor has to move to keep measurement and painting in agreement.
        columns += 1;
    }
    max_columns = @max(max_columns, columns);

    const width: f32 = if (max_columns == 0)
        0
    else
        @as(f32, @floatFromInt(max_columns * advance - (advance - glyph_width))) * scale_f;

    const height: f32 = @as(f32, @floatFromInt(@as(u32, line_height) * @as(u32, @intCast(lines)))) * scale_f;

    return .{
        .size = .{ .width = width, .height = height },
        .scale = scale,
        .lines = lines,
    };
}

/// Convenience wrapper matching the shape `component.zig` needs.
pub fn measureSize(content: []const u8, font_size: f32) Size {
    return measure(content, font_size).size;
}

test "glyph table is built from the art definitions" {
    const a = glyphFor('A').?;
    try std.testing.expect(!a.isEmpty());
    // 'A' has ink in the top middle column and none in the top-left corner.
    try std.testing.expect(a.pixel(2, 0));
    try std.testing.expect(!a.pixel(0, 0));
    // Its middle bar spans the full width.
    try std.testing.expect(a.pixel(0, 3));
    try std.testing.expect(a.pixel(4, 3));
}

test "every defined glyph paints at least one pixel except space" {
    for (definitions) |definition| {
        const glyph = glyphFor(definition.codepoint).?;
        if (definition.codepoint == ' ') {
            try std.testing.expect(glyph.isEmpty());
        } else {
            try std.testing.expect(!glyph.isEmpty());
        }
    }
}

test "glyph art has glyph_height rows of glyph_width columns" {
    // The compile-time check inside parseArt already enforces the row width; the
    // test guards against the check being bypassed by a future table change.
    for (definitions) |definition| {
        try std.testing.expectEqual(@as(usize, glyph_height), definition.art.len);
        for (definition.art) |row| {
            try std.testing.expectEqual(@as(usize, glyph_width), row.len);
        }
    }
}

test "lowercase folds to uppercase" {
    const lower = glyphFor('a').?;
    const upper = glyphFor('A').?;
    try std.testing.expectEqual(upper.rows, lower.rows);
}

test "unknown codepoints have no glyph" {
    try std.testing.expect(glyphFor(0x2603) == null); // snowman
    try std.testing.expect(glyphFor(200) == null);
}

test "glyph pixel accessor is bounds-safe" {
    const glyph = glyphFor('A').?;
    try std.testing.expect(!glyph.pixel(glyph_width, 0));
    try std.testing.expect(!glyph.pixel(0, glyph_height));
}

test "scaleFor grows with the font size and stays integral" {
    try std.testing.expectEqual(@as(u8, 1), scaleFor(7));
    try std.testing.expectEqual(@as(u8, 2), scaleFor(14));
    try std.testing.expectEqual(@as(u8, 3), scaleFor(21));
    // Nonsense sizes fall back to 1 rather than producing a zero-size glyph.
    try std.testing.expectEqual(@as(u8, 1), scaleFor(0));
    try std.testing.expectEqual(@as(u8, 1), scaleFor(-5));
    try std.testing.expectEqual(@as(u8, 1), scaleFor(std.math.nan(f32)));
}

test "measure counts characters and applies the trailing-gap rule" {
    // One character is exactly glyph_width wide, with no trailing spacing.
    const one = measure("A", 7);
    try std.testing.expectEqual(@as(f32, @floatFromInt(glyph_width)), one.size.width);

    // Two characters add one advance, not two.
    const two = measure("AB", 7);
    try std.testing.expectEqual(@as(f32, @floatFromInt(glyph_width + advance)), two.size.width);
}

test "measure scales both axes" {
    const single = measure("AB", 7);
    const doubled = measure("AB", 14);
    try std.testing.expectEqual(single.size.width * 2, doubled.size.width);
    try std.testing.expectEqual(single.size.height * 2, doubled.size.height);
}

test "empty text measures as zero width but one line high" {
    const metrics = measure("", 7);
    try std.testing.expectEqual(@as(f32, 0), metrics.size.width);
    try std.testing.expectEqual(@as(f32, @floatFromInt(line_height)), metrics.size.height);
    try std.testing.expectEqual(@as(usize, 1), metrics.lines);
}

test "newlines add lines and width comes from the longest one" {
    const metrics = measure("AB\nABCD", 7);
    try std.testing.expectEqual(@as(usize, 2), metrics.lines);
    try std.testing.expectEqual(@as(f32, @floatFromInt(3 * advance + glyph_width)), metrics.size.width);
    try std.testing.expectEqual(@as(f32, @floatFromInt(2 * line_height)), metrics.size.height);
}

test "undefined codepoints still advance the cursor" {
    // The snowman has no glyph, but it occupies a cell so neighbours do not
    // overlap, and measurement must agree with rendering.
    const metrics = measure("A\u{2603}B", 7);
    try std.testing.expectEqual(@as(f32, @floatFromInt(2 * advance + glyph_width)), metrics.size.width);
}

test "measureSize matches measure" {
    try std.testing.expect(Size.eql(measure("HELLO", 14).size, measureSize("HELLO", 14)));
}

test "metrics agree with the constants they advertise" {
    try std.testing.expect(advance > glyph_width);
    try std.testing.expect(line_height > glyph_height);
}
