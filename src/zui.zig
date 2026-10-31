//! ZUI public API.
//!
//! This file is the only entry point applications import. It re-exports the
//! types that are stable enough to be used directly and hides runtime,
//! renderer and platform details, which live in private modules.
//!
//! Keep this surface small: a new export is a compatibility commitment.

const std = @import("std");

pub const geometry = @import("geometry.zig");
pub const color = @import("color.zig");
pub const component = @import("component.zig");
pub const app = @import("app.zig");
pub const events = @import("events.zig");
pub const layout = @import("layout.zig");
pub const paint_mod = @import("paint.zig");
pub const text = @import("text.zig");
pub const render = struct {
    pub const software = @import("render/software.zig");
};

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const EdgeInsets = geometry.EdgeInsets;
pub const Constraints = geometry.Constraints;
pub const Alignment = geometry.Alignment;
pub const Axis = geometry.Axis;

pub const Color = color.Color;
pub const Palette = color.Palette;
pub const Theme = @import("theme.zig").Theme;

pub const Key = component.Key;
pub const Modifier = component.Modifier;
pub const Node = component.Node;
pub const NodeKind = component.NodeKind;
pub const TextContent = component.TextContent;
pub const Spacer = component.Spacer;
pub const Text = component.Text;
pub const Button = component.Button;
pub const Box = component.Box;
pub const Row = component.Row;
pub const Column = component.Column;

pub const LayoutEngine = layout.Engine;
pub const LayoutModel = layout.Model;
pub const LayoutOptions = layout.Options;
pub const Placed = layout.Placed;

pub const Renderer = render.software.Renderer;
pub const paint = paint_mod.paint;

pub const App = app.App;
pub const Surface = app.Surface;
pub const AppOptions = app.Options;
pub const AppStats = app.Stats;

pub const Event = events.Event;
/// Keyboard key. Distinct from `Key`, which is a component identity.
pub const InputKey = events.Key;
pub const MouseButton = events.MouseButton;
pub const Modifiers = events.Modifiers;
pub const DispatchState = events.State;
pub const DispatchOutcome = events.Outcome;

/// Version of the public API, independent from the package version. It is bumped
/// when an existing declaration changes in a way that can break consumers.
pub const api_version = "0.1.0";

test {
    // Pull in the tests of every module reachable from the public API so that
    // `zig build test` covers the whole package.
    std.testing.refAllDecls(@This());
    _ = @import("geometry.zig");
    _ = @import("color.zig");
    _ = @import("theme.zig");
    _ = @import("component.zig");
    _ = @import("layout.zig");
    _ = @import("text.zig");
    _ = @import("render/software.zig");
    _ = @import("paint.zig");
    _ = @import("app.zig");
    _ = @import("events.zig");
}

test "public api re-exports the value types" {
    const p = Point.init(1, 2);
    const s = Size.init(3, 4);
    const r = Rect.init(p.x, p.y, s.width, s.height);
    try std.testing.expectEqual(@as(f32, 4), r.right());
    try std.testing.expect(Color.white.isOpaque());
    try std.testing.expectEqual(@as(f32, 10), Constraints.tight(.{ .width = 10, .height = 10 }).max_width);
}
