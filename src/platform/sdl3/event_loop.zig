//! SDL3 input translation: turns native SDL3 events into framework events.
//!
//! Nothing above this module knows about SDL keycodes or event structs. The
//! translation is deliberately a pure function of the native event so it can be
//! unit-tested without a display: the tests below build synthetic `SDL_Event`
//! values and assert the framework event that comes out.

const std = @import("std");
const events_mod = @import("zui").events;
const geometry = @import("zui").geometry;
const sdl = @import("sdl3.zig");

/// One framework event plus whether the platform wants the loop to stop.
pub const Translation = struct {
    event: ?events_mod.Event = null,
    /// Set when SDL reported that the window is going away.
    quit: bool = false,
};

/// Translates one SDL3 event.
///
/// Events the framework does not model yet (joysticks, tablets, text editing)
/// map to an empty translation rather than an error: an unknown event must never
/// stop the loop.
pub fn translate(event: *const sdl.SDL_Event) Translation {
    const event_type: u32 = event.type;

    return switch (event_type) {
        sdl.SDL_EVENT_QUIT,
        sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        sdl.SDL_EVENT_TERMINATING,
        => .{ .quit = true },

        sdl.SDL_EVENT_WINDOW_RESIZED,
        sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        => blk: {
            // `data1`/`data2` are the new width and height in pixels.
            const width = event.window.data1;
            const height = event.window.data2;
            if (width <= 0 or height <= 0) break :blk .{};
            break :blk .{ .event = .{ .resized = .{
                .size = .{
                    .width = @floatFromInt(width),
                    .height = @floatFromInt(height),
                },
            } } };
        },

        sdl.SDL_EVENT_WINDOW_FOCUS_GAINED => .{ .event = .{ .focus_changed = .{ .focused = true } } },
        sdl.SDL_EVENT_WINDOW_FOCUS_LOST => .{ .event = .{ .focus_changed = .{ .focused = false } } },

        sdl.SDL_EVENT_MOUSE_MOTION => .{ .event = .{ .pointer_moved = .{
            .position = positionOf(event.motion.x, event.motion.y),
            .modifiers = modifiersOf(event.motion.state),
        } } },

        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .event = .{ .pointer_down = .{
            .position = positionOf(event.button.x, event.button.y),
            .button = buttonOf(event.button.button),
            .modifiers = .none,
        } } },

        sdl.SDL_EVENT_MOUSE_BUTTON_UP => .{ .event = .{ .pointer_up = .{
            .position = positionOf(event.button.x, event.button.y),
            .button = buttonOf(event.button.button),
            .modifiers = .none,
        } } },

        sdl.SDL_EVENT_KEY_DOWN => .{ .event = .{ .key_down = .{
            .key = keyOf(event.key.key),
            .codepoint = codepointOf(event.key.key),
            .modifiers = keyModifiersOf(event.key.mod),
            .repeat = event.key.repeat,
        } } },

        sdl.SDL_EVENT_KEY_UP => .{ .event = .{ .key_up = .{
            .key = keyOf(event.key.key),
            .codepoint = codepointOf(event.key.key),
            .modifiers = keyModifiersOf(event.key.mod),
        } } },

        else => .{},
    };
}

fn positionOf(x: f32, y: f32) geometry.Point {
    return .{ .x = x, .y = y };
}

fn buttonOf(button: u8) events_mod.MouseButton {
    // SDL numbers buttons 1-based: left, middle, right.
    return switch (button) {
        2 => .middle,
        3 => .right,
        else => .left,
    };
}

/// Maps an SDL keycode onto the framework's key set. Printable keys are reported
/// as `.character`; the codepoint travels in `key_down.codepoint`.
fn keyOf(keycode: sdl.SDL_Keycode) events_mod.Key {
    return switch (keycode) {
        sdl.SDLK_RETURN, sdl.SDLK_KP_ENTER => .enter,
        sdl.SDLK_SPACE => .space,
        sdl.SDLK_BACKSPACE => .backspace,
        sdl.SDLK_ESCAPE => .escape,
        sdl.SDLK_TAB => .tab,
        sdl.SDLK_LEFT => .left,
        sdl.SDLK_RIGHT => .right,
        sdl.SDLK_UP => .up,
        sdl.SDLK_DOWN => .down,
        sdl.SDLK_HOME => .home,
        sdl.SDLK_END => .end,
        sdl.SDLK_DELETE => .delete,
        else => if (isPrintable(keycode)) .character else .unknown,
    };
}

/// The Unicode codepoint of a key, or 0 when it has no textual representation.
fn codepointOf(keycode: sdl.SDL_Keycode) u21 {
    if (isPrintable(keycode)) return @intCast(keycode);
    return switch (keycode) {
        sdl.SDLK_RETURN, sdl.SDLK_KP_ENTER => '\n',
        sdl.SDLK_TAB => '\t',
        sdl.SDLK_SPACE => ' ',
        else => 0,
    };
}

/// SDL3 keycodes for printable ASCII equal their codepoint.
fn isPrintable(keycode: sdl.SDL_Keycode) bool {
    return keycode >= 0x20 and keycode < 0x7f;
}

fn keyModifiersOf(mod: sdl.SDL_Keymod) events_mod.Modifiers {
    return .{
        .shift = (mod & sdl.SDL_KMOD_SHIFT) != 0,
        .control = (mod & sdl.SDL_KMOD_CTRL) != 0,
        .alt = (mod & sdl.SDL_KMOD_ALT) != 0,
        .logo = (mod & sdl.SDL_KMOD_GUI) != 0,
    };
}

/// Mouse events carry the button state, not the modifier flags. Only the
/// keyboard-driven modifiers reach pointer events, so map the button mask we
/// know and leave the rest clear.
fn modifiersOf(state: sdl.SDL_MouseButtonFlags) events_mod.Modifiers {
    _ = state;
    return .none;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn emptyEvent(event_type: u32) sdl.SDL_Event {
    var event: sdl.SDL_Event = undefined;
    @memset(std.mem.asBytes(&event), 0);
    event.type = event_type;
    return event;
}

test "quit and close both request a stop" {
    const quit = emptyEvent(@intCast(sdl.SDL_EVENT_QUIT));
    try std.testing.expect(translate(&quit).quit);

    const close = emptyEvent(@intCast(sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED));
    try std.testing.expect(translate(&close).quit);
}

test "resize carries the new pixel size" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_WINDOW_RESIZED));
    event.window.data1 = 1024;
    event.window.data2 = 768;

    const translation = translate(&event);
    try std.testing.expect(!translation.quit);
    const resized = translation.event.?.resized;
    try std.testing.expectEqual(@as(f32, 1024), resized.size.width);
    try std.testing.expectEqual(@as(f32, 768), resized.size.height);
}

test "a zero-sized resize is ignored" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_WINDOW_RESIZED));
    event.window.data1 = 0;
    event.window.data2 = 0;
    try std.testing.expect(translate(&event).event == null);
}

test "key down reports a character with its codepoint" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_KEY_DOWN));
    event.key.key = 'a';
    event.key.repeat = true;

    const translation = translate(&event);
    const key_down = translation.event.?.key_down;
    try std.testing.expectEqual(events_mod.Key.character, key_down.key);
    try std.testing.expectEqual(@as(u21, 'a'), key_down.codepoint);
    try std.testing.expect(key_down.repeat);
}

test "named keys map to their framework key" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_KEY_DOWN));
    event.key.key = sdl.SDLK_RETURN;
    try std.testing.expectEqual(events_mod.Key.enter, translate(&event).event.?.key_down.key);

    event.key.key = sdl.SDLK_ESCAPE;
    try std.testing.expectEqual(events_mod.Key.escape, translate(&event).event.?.key_down.key);

    event.key.key = sdl.SDLK_LEFT;
    try std.testing.expectEqual(events_mod.Key.left, translate(&event).event.?.key_down.key);
}

test "modifiers are translated from the SDL mask" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_KEY_DOWN));
    event.key.key = 's';
    event.key.mod = sdl.SDL_KMOD_LCTRL | sdl.SDL_KMOD_LSHIFT;

    const mods = translate(&event).event.?.key_down.modifiers;
    try std.testing.expect(mods.control);
    try std.testing.expect(mods.shift);
    try std.testing.expect(!mods.alt);
}

test "mouse buttons map one-based SDL numbering" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_MOUSE_BUTTON_DOWN));
    event.button.button = 1;
    try std.testing.expectEqual(events_mod.MouseButton.left, translate(&event).event.?.pointer_down.button);

    event.button.button = 2;
    try std.testing.expectEqual(events_mod.MouseButton.middle, translate(&event).event.?.pointer_down.button);

    event.button.button = 3;
    try std.testing.expectEqual(events_mod.MouseButton.right, translate(&event).event.?.pointer_down.button);
}

test "pointer position is passed through unchanged" {
    var event = emptyEvent(@intCast(sdl.SDL_EVENT_MOUSE_MOTION));
    event.motion.x = 120.5;
    event.motion.y = 40.25;

    const position = translate(&event).event.?.pointer_moved.position;
    try std.testing.expectEqual(@as(f32, 120.5), position.x);
    try std.testing.expectEqual(@as(f32, 40.25), position.y);
}

test "unmodelled events are dropped without stopping the loop" {
    var event = emptyEvent(65001);
    const translation = translate(&event);
    try std.testing.expect(translation.event == null);
    try std.testing.expect(!translation.quit);
}