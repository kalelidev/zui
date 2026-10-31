//! Software renderer: an RGBA framebuffer plus the drawing primitives the MVP
//! needs.
//!
//! This is the *initial* backend. It exists to make the framework drawable and
//! testable without a GPU or a display server: every pixel it produces can be
//! asserted in a unit test. A later backend must implement the same small
//! surface (`clear`, `fillRect`, `strokeRect`, `drawText`) behind
//! `render.Renderer` without changing the public UI API.
//!
//! Pixel format: 8-bit RGBA, non-premultiplied, row-major, tightly packed.
//! Origin is top-left; `x` grows right, `y` grows down.
//!
//! Ownership: the framebuffer owns its pixel slice, allocated from the allocator
//! passed to `init` and released by `deinit`. Nothing here allocates per frame;
//! `resize` reallocates only when the dimensions actually change.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const text = @import("../text.zig");

pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Color = color.Color;

pub const Error = error{
    /// Width or height is negative, non-finite, or too large to represent.
    InvalidSize,
    OutOfMemory,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    width: u32 = 0,
    height: u32 = 0,
    /// `width * height` pixels, RGBA order.
    pixels: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, initial_size: Size) Error!Renderer {
        var renderer = Renderer{ .gpa = gpa };
        errdefer renderer.deinit();
        try renderer.resize(initial_size);
        return renderer;
    }

    pub fn deinit(renderer: *Renderer) void {
        if (renderer.pixels.len > 0) renderer.gpa.free(renderer.pixels);
        renderer.* = .{ .gpa = renderer.gpa };
    }

    pub fn size(renderer: Renderer) Size {
        return .{
            .width = @floatFromInt(renderer.width),
            .height = @floatFromInt(renderer.height),
        };
    }

    /// Changes the framebuffer dimensions, reallocating only when necessary.
    /// Contents are not preserved; the caller is expected to redraw the frame.
    pub fn resize(renderer: *Renderer, new_size: Size) Error!void {
        if (!std.math.isFinite(new_size.width) or !std.math.isFinite(new_size.height)) {
            return Error.InvalidSize;
        }
        if (new_size.width < 0 or new_size.height < 0) return Error.InvalidSize;

        const width: u32 = @intFromFloat(@round(new_size.width));
        const height: u32 = @intFromFloat(@round(new_size.height));

        // Guard the multiplication before it can overflow `usize`.
        const pixels_count = std.math.mul(usize, width, height) catch return Error.InvalidSize;
        const bytes = std.math.mul(usize, pixels_count, 4) catch return Error.InvalidSize;

        if (width == renderer.width and height == renderer.height and renderer.pixels.len == bytes) {
            return;
        }

        if (renderer.pixels.len > 0) renderer.gpa.free(renderer.pixels);
        renderer.pixels = &.{};
        renderer.width = 0;
        renderer.height = 0;

        if (bytes == 0) return;

        renderer.pixels = try renderer.gpa.alloc(u8, bytes);
        renderer.width = width;
        renderer.height = height;
    }

    /// Fills the whole framebuffer, ignoring alpha: a clear always writes.
    pub fn clear(renderer: *Renderer, fill: Color) void {
        const rgb = [4]u8{ fill.r, fill.g, fill.b, 255 };
        var index: usize = 0;
        while (index + 4 <= renderer.pixels.len) : (index += 4) {
            @memcpy(renderer.pixels[index..][0..4], &rgb);
        }
    }

    /// Fills an axis-aligned rectangle. The rectangle is rounded and clipped to
    /// the framebuffer, so off-screen or fractional input is safe.
    pub fn fillRect(renderer: *Renderer, rect: Rect, fill: Color) void {
        if (fill.isTransparent()) return;
        const clipped = renderer.clip(rect) orelse return;
        const x0: u32 = @intFromFloat(clipped.x);
        const y0: u32 = @intFromFloat(clipped.y);
        const x1: u32 = @intFromFloat(clipped.right());
        const y1: u32 = @intFromFloat(clipped.bottom());

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                renderer.blendPixel(x, y, fill);
            }
        }
    }

    /// Draws a filled rectangle inset by `insets`, i.e. a border of thickness
    /// `insets`. Handy for frames and focus rings.
    pub fn strokeRect(renderer: *Renderer, rect: Rect, border: geometry.EdgeInsets, fill: Color) void {
        const outer = rect.round();
        if (outer.isEmpty()) return;
        const inner = outer.inset(border);

        // Top and bottom bands.
        renderer.fillRect(.{ .x = outer.x, .y = outer.y, .width = outer.width, .height = border.top }, fill);
        renderer.fillRect(
            .{ .x = outer.x, .y = outer.bottom() - border.bottom, .width = outer.width, .height = border.bottom },
            fill,
        );
        // Left and right bands, between the two horizontal bands.
        renderer.fillRect(
            .{ .x = outer.x, .y = inner.y, .width = border.left, .height = inner.height },
            fill,
        );
        renderer.fillRect(
            .{ .x = outer.right() - border.right, .y = inner.y, .width = border.right, .height = inner.height },
            fill,
        );
    }

    /// Reads a pixel. Returns transparent black when out of bounds so tests do
    /// not need to guard every probe.
    pub fn getPixel(renderer: Renderer, x: u32, y: u32) Color {
        if (x >= renderer.width or y >= renderer.height) return Color.transparent;
        const index = (@as(usize, y) * renderer.width + x) * 4;
        return .{
            .r = renderer.pixels[index],
            .g = renderer.pixels[index + 1],
            .b = renderer.pixels[index + 2],
            .a = renderer.pixels[index + 3],
        };
    }

    fn blendPixel(renderer: *Renderer, x: u32, y: u32, fill: Color) void {
        if (x >= renderer.width or y >= renderer.height) return;
        const index = (@as(usize, y) * renderer.width + x) * 4;

        if (fill.isOpaque()) {
            renderer.pixels[index] = fill.r;
            renderer.pixels[index + 1] = fill.g;
            renderer.pixels[index + 2] = fill.b;
            renderer.pixels[index + 3] = 255;
            return;
        }

        // Source-over alpha blending on non-premultiplied channels.
        const src_a: f32 = @as(f32, @floatFromInt(fill.a)) / 255.0;
        const dst_a: f32 = @as(f32, @floatFromInt(renderer.pixels[index + 3])) / 255.0;
        const out_a = src_a + dst_a * (1.0 - src_a);
        if (out_a <= 0) {
            renderer.pixels[index + 3] = 0;
            return;
        }
        const channels = [3]u8{ fill.r, fill.g, fill.b };
        var channel: usize = 0;
        while (channel < 3) : (channel += 1) {
            const src: f32 = @as(f32, @floatFromInt(channels[channel])) / 255.0;
            const dst: f32 = @as(f32, @floatFromInt(renderer.pixels[index + channel])) / 255.0;
            const out = (src * src_a + dst * dst_a * (1.0 - src_a)) / out_a;
            renderer.pixels[index + channel] = @intFromFloat(@round(std.math.clamp(out * 255.0, 0, 255)));
        }
        renderer.pixels[index + 3] = @intFromFloat(@round(out_a * 255.0));
    }

    /// Draws `content` with the built-in bitmap font, starting at the top-left
    /// corner of `origin`. `\n` breaks lines. Characters without a glyph are
    /// skipped but still occupy a cell, matching `text.measure` exactly.
    ///
    /// The position is rounded to whole pixels: bitmap glyphs cannot be drawn at
    /// fractional offsets without blurring.
    pub fn drawText(renderer: *Renderer, origin: geometry.Point, content: []const u8, fill: Color, font_size: f32) void {
        if (fill.isTransparent() or content.len == 0) return;

        const scale = text.scaleFor(font_size);
        const cell_width: f32 = @floatFromInt(@as(u32, text.advance) * scale);
        const cell_height: f32 = @floatFromInt(@as(u32, text.line_height) * scale);

        var pen_x = @round(origin.x);
        var pen_y = @round(origin.y);

        var iterator = std.unicode.Utf8View.initUnchecked(content).iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                pen_x = @round(origin.x);
                pen_y += cell_height;
                continue;
            }
            if (text.glyphFor(codepoint)) |glyph| {
                renderer.blitGlyph(glyph, pen_x, pen_y, scale, fill);
            }
            pen_x += cell_width;
        }
    }

    fn blitGlyph(renderer: *Renderer, glyph: text.Glyph, pen_x: f32, pen_y: f32, scale: u8, fill: Color) void {
        var gy: u8 = 0;
        while (gy < text.glyph_height) : (gy += 1) {
            var gx: u8 = 0;
            while (gx < text.glyph_width) : (gx += 1) {
                if (!glyph.pixel(gx, gy)) continue;
                // Each font pixel becomes a scale x scale block.
                renderer.fillRect(
                    Rect.init(
                        pen_x + @as(f32, @floatFromInt(@as(u32, gx) * scale)),
                        pen_y + @as(f32, @floatFromInt(@as(u32, gy) * scale)),
                        @floatFromInt(scale),
                        @floatFromInt(scale),
                    ),
                    fill,
                );
            }
        }
    }

    /// Rounds and clips a rectangle to the framebuffer. Returns null when it has
    /// no visible area.
    fn clip(renderer: Renderer, rect: Rect) ?Rect {
        if (!rect.isValid()) return null;
        const rounded = rect.round();
        if (rounded.isEmpty()) return null;

        const fb = Rect{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(renderer.width),
            .height = @floatFromInt(renderer.height),
        };
        const visible = rounded.intersect(fb);
        if (visible.isEmpty()) return null;
        return visible;
    }
};

test "init allocates a zeroed-size framebuffer" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(4, 3));
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u32, 4), renderer.width);
    try std.testing.expectEqual(@as(u32, 3), renderer.height);
    try std.testing.expectEqual(@as(usize, 4 * 3 * 4), renderer.pixels.len);
}

test "clear fills every pixel with the given color" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(2, 2));
    defer renderer.deinit();

    renderer.clear(Color.fromRgb(0x102030));
    try std.testing.expect(Color.eql(Color.fromRgb(0x102030), renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.fromRgb(0x102030), renderer.getPixel(1, 1)));
}

test "clear ignores alpha and always writes an opaque pixel" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(1, 1));
    defer renderer.deinit();

    renderer.clear(Color.initAlpha(1, 2, 3, 0));
    const pixel = renderer.getPixel(0, 0);
    try std.testing.expectEqual(@as(u8, 255), pixel.a);
}

test "fillRect writes only inside its bounds" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(5, 5));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.fillRect(Rect.init(1, 1, 2, 2), Color.white);

    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(1, 1)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(2, 2)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(3, 1)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(1, 3)));
}

test "fillRect clips rectangles that hang off every edge" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(10, 10));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.fillRect(Rect.init(-5, -5, 20, 20), Color.white);
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(9, 9)));
}

test "fillRect with an off-screen rect draws nothing and does not crash" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(4, 4));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.fillRect(Rect.init(100, 100, 10, 10), Color.white);
    renderer.fillRect(Rect.init(-100, -100, 10, 10), Color.white);

    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(3, 3)));
}

test "fillRect ignores invalid and empty rectangles" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(4, 4));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.fillRect(Rect.init(0, 0, 0, 0), Color.white);
    renderer.fillRect(Rect.init(std.math.nan(f32), 0, 4, 4), Color.white);

    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
}

test "transparent fills are skipped" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(2, 2));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.fillRect(Rect.init(0, 0, 2, 2), Color.transparent);
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(0, 0)));
}

test "half-transparent fill blends against the background" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(1, 1));
    defer renderer.deinit();
    renderer.clear(Color.black);

    // 50% white over black lands near the midpoint.
    renderer.fillRect(Rect.init(0, 0, 1, 1), Color.initAlpha(255, 255, 255, 128));
    const pixel = renderer.getPixel(0, 0);
    try std.testing.expectEqual(@as(u8, 255), pixel.a);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(pixel.r)), 2);
}

test "strokeRect draws four bands and leaves the middle untouched" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(10, 10));
    defer renderer.deinit();
    renderer.clear(Color.black);

    renderer.strokeRect(
        Rect.init(0, 0, 10, 10),
        geometry.EdgeInsets.all(1),
        Color.white,
    );

    // Corners and edge midpoints are border.
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(0, 0)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(9, 0)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(0, 9)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(0, 5)));
    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(5, 0)));
    // The interior is not.
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(5, 5)));
    try std.testing.expect(Color.eql(Color.black, renderer.getPixel(1, 1)));
}

test "resize keeps the same allocation when the size does not change" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(3, 3));
    defer renderer.deinit();

    const before = renderer.pixels.ptr;
    try renderer.resize(Size.init(3, 3));
    try std.testing.expectEqual(before, renderer.pixels.ptr);

    try renderer.resize(Size.init(4, 4));
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), renderer.pixels.len);
}

test "resize to zero is allowed and clears storage" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(3, 3));
    defer renderer.deinit();

    try renderer.resize(Size.zero);
    try std.testing.expectEqual(@as(usize, 0), renderer.pixels.len);
    try std.testing.expectEqual(@as(u32, 0), renderer.width);

    renderer.clear(Color.white); // must not crash
    renderer.fillRect(Rect.init(0, 0, 1, 1), Color.white);
}

test "resize rejects negative and non-finite sizes" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(2, 2));
    defer renderer.deinit();

    try std.testing.expectError(Error.InvalidSize, renderer.resize(Size.init(-1, 2)));
    try std.testing.expectError(Error.InvalidSize, renderer.resize(Size.init(std.math.nan(f32), 2)));
    try std.testing.expectError(
        Error.InvalidSize,
        renderer.resize(Size.init(std.math.inf(f32), 2)),
    );
}

test "getPixel is bounds-safe" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(2, 2));
    defer renderer.deinit();
    renderer.clear(Color.white);

    try std.testing.expect(Color.eql(Color.white, renderer.getPixel(1, 1)));
    try std.testing.expect(renderer.getPixel(2, 0).isTransparent());
    try std.testing.expect(renderer.getPixel(0, 2).isTransparent());
}

test "renderer reports its size as a float Size" {
    var renderer = try Renderer.init(std.testing.allocator, Size.init(7, 5));
    defer renderer.deinit();

    const s = renderer.size();
    try std.testing.expectEqual(@as(f32, 7), s.width);
    try std.testing.expectEqual(@as(f32, 5), s.height);
}

test "init propagates allocation failure without leaking" {
    // fail_index = 0 makes the very first allocation fail, which is the one the
    // framebuffer needs.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();

    try std.testing.expectError(Error.OutOfMemory, Renderer.init(gpa, Size.init(64, 64)));
}

test "text module is reachable from the renderer" {
    try std.testing.expect(text.glyph_height > 0);
}
