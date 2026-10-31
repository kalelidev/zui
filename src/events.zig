//! Events: input events, hit-testing and dispatch.
//!
//! Platform backends translate their native input into the types here; nothing
//! below the platform layer knows about X11 or SDL keycodes. Dispatch is
//! synchronous and deterministic: an event walks the placed nodes from the
//! deepest match outwards, so tests can assert exact ordering.
//!
//! Coordinate model: pointer positions are in logical pixels relative to the
//! window origin, the same space the layout engine produces.
//!
//! Ownership: events are plain values. Callbacks are borrowed function pointers
//! plus an opaque context pointer owned by the application; the framework never
//! takes ownership of the context and never frees it.

const std = @import("std");
const geometry = @import("geometry.zig");
const component = @import("component.zig");
const layout_mod = @import("layout.zig");

pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Node = component.Node;
pub const Model = layout_mod.Model;

/// Keyboard keys the framework understands. This is a small, stable subset:
/// a platform backend maps its native codes onto these values, and adding a key
/// here is an additive change.
pub const Key = enum {
    unknown,
    character,
    enter,
    space,
    backspace,
    escape,
    tab,
    left,
    right,
    up,
    down,
    home,
    end,
    delete,
};

pub const MouseButton = enum { left, right, middle };

pub const Modifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    /// Command on macOS, Super elsewhere. Kept generic on purpose.
    logo: bool = false,

    pub const none: Modifiers = .{};

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return a.shift == b.shift and a.control == b.control and
            a.alt == b.alt and a.logo == b.logo;
    }
};

pub const Event = union(enum) {
    /// The pointer moved to `position`.
    pointer_moved: struct {
        position: Point,
        modifiers: Modifiers = .none,
    },
    /// A button went down at `position`.
    pointer_down: struct {
        position: Point,
        button: MouseButton,
        modifiers: Modifiers = .none,
    },
    /// A button went up at `position`.
    pointer_up: struct {
        position: Point,
        button: MouseButton,
        modifiers: Modifiers = .none,
    },
    /// The window gained or lost focus.
    focus_changed: struct {
        focused: bool,
    },
    key_down: struct {
        key: Key,
        /// Set when `key` is `.character`.
        codepoint: u21 = 0,
        modifiers: Modifiers = .none,
        /// True when the platform reports this as an auto-repeat.
        repeat: bool = false,
    },
    key_up: struct {
        key: Key,
        codepoint: u21 = 0,
        modifiers: Modifiers = .none,
    },
    /// The window was resized by the platform.
    resized: struct {
        size: Size,
    },
    /// The platform asked the application to close.
    close_requested: void,
};

/// What the runtime should do after dispatching an event.
pub const Outcome = struct {
    /// The event changed application state, so a new frame is needed.
    needs_redraw: bool = false,
    /// The application asked to exit.
    should_close: bool = false,
};

/// Result of a hit test.
pub const Hit = struct {
    node: *const Node,
    rect: Rect,
};

/// Finds the deepest node containing `position`.
///
/// The model is ordered parents-before-children, so the last match in that order
/// is the visually topmost one. Nodes that cannot receive pointer input are
/// skipped, which keeps a click from landing on a background `Box` when a
/// `Button` sits on top of it.
pub fn hitTest(model: Model, position: Point) ?Hit {
    var best: ?Hit = null;
    for (model.items) |item| {
        if (!item.rect.contains(position)) continue;
        if (!acceptsPointer(item.node)) continue;
        best = .{ .node = item.node, .rect = item.rect };
    }
    return best;
}

fn acceptsPointer(node: *const Node) bool {
    return switch (node.kind) {
        // A button is the only interactive primitive in the MVP.
        .button => |button| button.enabled,
        // Text and spacers are inert; hit-testing them would make a click on a
        // label fall through to nothing instead of the surrounding button.
        .text, .spacer => false,
        .box, .row, .column => true,
    };
}

/// Tracks the interaction state dispatch needs across events.
pub const State = struct {
    /// Node currently under the pointer.
    hovered: ?*const Node = null,
    /// Node that received the last pointer-down, i.e. the click target.
    pressed: ?*const Node = null,
    /// Whether the window currently has keyboard focus.
    focused: bool = true,

    pub const empty: State = .{};
};

/// Dispatches one event against a laid-out model.
///
/// Returns what the runtime should do next. Callback errors are the
/// application's concern; the framework cannot recover from them and does not
/// swallow them, so handlers are plain `void` functions.
pub fn dispatch(state: *State, model: Model, event: Event) Outcome {
    var outcome = Outcome{};

    switch (event) {
        .close_requested => outcome.should_close = true,

        .resized => outcome.needs_redraw = true,

        .focus_changed => |focus| {
            state.focused = focus.focused;
            if (!focus.focused) {
                // Losing focus cancels an in-progress press so a click cannot
                // complete after the pointer left the window.
                state.pressed = null;
            }
        },

        .pointer_moved => |moved| {
            const hit = hitTest(model, moved.position);
            const new_hovered = if (hit) |h| h.node else null;
            if (new_hovered != state.hovered) {
                state.hovered = new_hovered;
                outcome.needs_redraw = true;
            }
        },

        .pointer_down => |down| {
            const hit = hitTest(model, down.position);
            state.pressed = if (hit) |h| h.node else null;
            if (state.pressed != null) outcome.needs_redraw = true;
        },

        .pointer_up => |up| {
            const hit = hitTest(model, up.position);
            const released_on = if (hit) |h| h.node else null;

            // A click completes only when press and release land on the same
            // node, matching every desktop toolkit.
            if (state.pressed != null and state.pressed == released_on) {
                if (invokeClick(state.pressed.?)) outcome.needs_redraw = true;
            }
            if (state.pressed != null) outcome.needs_redraw = true;
            state.pressed = null;
        },

        // Keyboard events are delivered to the focused node once focus
        // management and text input land (Phase 2). The MVP has no keyboard
        // target, so these events mark nothing to redraw.
        .key_down, .key_up => {},
    }

    return outcome;
}

fn invokeClick(node: *const Node) bool {
    switch (node.kind) {
        .button => |button| {
            if (!button.enabled) return false;
            if (button.on_click) |handler| {
                handler(button.context);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Builds a small tree: a padded box containing one button.
const Fixture = struct {
    button_storage: Node = undefined,
    box_storage: Node = undefined,
    root: *const Node = undefined,
    engine: layout_mod.Engine = undefined,
    model: Model = undefined,

    fn init(self: *Fixture, gpa: std.mem.Allocator, handler: ?component.Button.ClickHandler, context: ?*anyopaque) !void {
        self.button_storage = undefined;
        const button = component.Button.node(
            &self.button_storage,
            component.Key.init(1),
            component.Modifier.none.withSize(40, 20),
            "OK",
            handler,
            context,
        );
        self.box_storage = undefined;
        self.root = component.Box.node(
            &self.box_storage,
            component.Key.init(2),
            component.Modifier.none.withSize(100, 100).withPadding(geometry.EdgeInsets.all(10)),
            button,
            .start,
            .start,
        );
        self.engine = layout_mod.Engine.init(gpa, .{});
        self.model = try self.engine.layout(self.root, Size.init(200, 200));
    }

    fn deinit(self: *Fixture) void {
        self.engine.deinit();
    }

    fn buttonRect(self: *Fixture) Rect {
        return self.model.find(&self.button_storage).?.rect;
    }
};

test "hitTest finds the topmost interactive node" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    const button_rect = fixture.buttonRect();
    const hit = hitTest(fixture.model, button_rect.center()).?;
    try std.testing.expect(hit.node == &fixture.button_storage);
}

test "hitTest falls back to the container outside the button" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    // Inside the box padding but outside the button.
    const hit = hitTest(fixture.model, Point.init(5, 5)).?;
    try std.testing.expect(hit.node == &fixture.box_storage);
}

test "hitTest returns null outside every node" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    try std.testing.expect(hitTest(fixture.model, Point.init(500, 500)) == null);
}

test "text and spacers are not pointer targets" {
    var text_storage: Node = undefined;
    const label = component.Text.node(&text_storage, component.Key.none, component.Modifier.none.withSize(50, 20), .{ .text = "HI" });

    var engine = layout_mod.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(label, Size.init(100, 100));

    // The text occupies area but is inert, so a click finds nothing.
    try std.testing.expect(hitTest(model, Point.init(5, 5)) == null);
}

test "a disabled button is not a pointer target" {
    var storage: Node = undefined;
    const disabled = component.Button.node(&storage, component.Key.none, component.Modifier.none.withSize(30, 30), "NO", null, null);
    // Rebuild with enabled = false.
    var node = disabled.*;
    node.kind.button.enabled = false;
    const root: *const Node = &node;

    var engine = layout_mod.Engine.init(std.testing.allocator, .{});
    defer engine.deinit();
    const model = try engine.layout(root, Size.init(100, 100));

    try std.testing.expect(hitTest(model, Point.init(5, 5)) == null);
}

test "a click inside the button runs its handler once" {
    const Counter = struct {
        calls: usize = 0,
        fn onClick(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };

    var counter = Counter{};
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, Counter.onClick, &counter);
    defer fixture.deinit();

    var state = State.empty;
    const center = fixture.buttonRect().center();

    _ = dispatch(&state, fixture.model, .{ .pointer_down = .{ .position = center, .button = .left } });
    const outcome = dispatch(&state, fixture.model, .{ .pointer_up = .{ .position = center, .button = .left } });

    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expect(outcome.needs_redraw);
    try std.testing.expect(state.pressed == null);
}

test "a release outside the pressed button does not click" {
    const Counter = struct {
        calls: usize = 0,
        fn onClick(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };

    var counter = Counter{};
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, Counter.onClick, &counter);
    defer fixture.deinit();

    var state = State.empty;
    _ = dispatch(&state, fixture.model, .{
        .pointer_down = .{ .position = fixture.buttonRect().center(), .button = .left },
    });
    // Released on the surrounding box: press and release disagree.
    _ = dispatch(&state, fixture.model, .{
        .pointer_up = .{ .position = Point.init(5, 5), .button = .left },
    });

    try std.testing.expectEqual(@as(usize, 0), counter.calls);
}

test "losing focus cancels a pending press" {
    const Counter = struct {
        calls: usize = 0,
        fn onClick(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };

    var counter = Counter{};
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, Counter.onClick, &counter);
    defer fixture.deinit();

    var state = State.empty;
    const center = fixture.buttonRect().center();
    _ = dispatch(&state, fixture.model, .{ .pointer_down = .{ .position = center, .button = .left } });
    _ = dispatch(&state, fixture.model, .{ .focus_changed = .{ .focused = false } });
    _ = dispatch(&state, fixture.model, .{ .pointer_up = .{ .position = center, .button = .left } });

    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expect(!state.focused);
}

test "hovering only redraws when the target changes" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    var state = State.empty;
    const center = fixture.buttonRect().center();

    const enter = dispatch(&state, fixture.model, .{ .pointer_moved = .{ .position = center } });
    try std.testing.expect(enter.needs_redraw);
    try std.testing.expect(state.hovered == &fixture.button_storage);

    // Same target: nothing to redraw.
    const stay = dispatch(&state, fixture.model, .{ .pointer_moved = .{ .position = center } });
    try std.testing.expect(!stay.needs_redraw);

    const leave = dispatch(&state, fixture.model, .{ .pointer_moved = .{ .position = Point.init(5, 5) } });
    try std.testing.expect(leave.needs_redraw);
    try std.testing.expect(state.hovered == &fixture.box_storage);
}

test "close and resize events map to the expected outcome" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    var state = State.empty;

    const resize = dispatch(&state, fixture.model, .{ .resized = .{ .size = Size.init(50, 50) } });
    try std.testing.expect(resize.needs_redraw);
    try std.testing.expect(!resize.should_close);

    const close = dispatch(&state, fixture.model, .{ .close_requested = {} });
    try std.testing.expect(close.should_close);
}

test "keyboard events are accepted without a target" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    var state = State.empty;
    const outcome = dispatch(&state, fixture.model, .{
        .key_down = .{ .key = .character, .codepoint = 'a' },
    });
    try std.testing.expect(!outcome.needs_redraw);
    try std.testing.expect(!outcome.should_close);
}

test "a button without a handler is harmless" {
    var fixture: Fixture = .{};
    try fixture.init(std.testing.allocator, null, null);
    defer fixture.deinit();

    var state = State.empty;
    const center = fixture.buttonRect().center();
    _ = dispatch(&state, fixture.model, .{ .pointer_down = .{ .position = center, .button = .left } });
    const outcome = dispatch(&state, fixture.model, .{ .pointer_up = .{ .position = center, .button = .left } });

    try std.testing.expect(!outcome.should_close);
    try std.testing.expect(state.pressed == null);
}

test "modifier equality" {
    try std.testing.expect(Modifiers.eql(.none, .none));
    try std.testing.expect(!Modifiers.eql(.{ .shift = true }, .none));
}
