//! X11/xcb input translation: native events to framework events.
//!
//! Kept separate from the window so the mapping is testable without a server:
//! the tests build synthetic xcb event structs and assert the framework event.
//!
//! Key handling goes through `xcb_key_symbols` rather than raw keycodes, because
//! keycodes are layout-dependent while keysyms carry the actual character.

const std = @import("std");
const events_mod = @import("zui").events;
const geometry = @import("zui").geometry;

const xcb = @import("xcb.zig");
const xcb_keysyms = @import("xcb-keysyms.zig");

/// X11 keysyms we care about. The full set is in `<X11/keysymdef.h>`; these are
/// the ones the framework models directly. Everything else is reported as
/// `.character` when it has a printable codepoint.
const keysym_BackSpace: u32 = 0xff08;
const keysym_Tab: u32 = 0xff09;
const keysym_Return: u32 = 0xff0d;
const keysym_Escape: u32 = 0xff1b;
const keysym_Delete: u32 = 0xffff;
const keysym_Home: u32 = 0xff50;
const keysym_Left: u32 = 0xff51;
const keysym_Up: u32 = 0xff52;
const keysym_Right: u32 = 0xff53;
const keysym_Down: u32 = 0xff54;
const keysym_End: u32 = 0xff57;
const keysym_space: u32 = 0x0020;
const keysym_KP_Enter: u32 = 0xff8d;

/// What one native event means for the host loop.
pub const Translation = struct {
    event: ?events_mod.Event = null,
    /// The window manager asked us to close.
    quit: bool = false,
    /// The window size changed to `resized_size`.
    resized_size: ?geometry.Size = null,
    /// The server wants a repaint.
    needs_redraw: bool = false,
};

/// Translates a generic xcb event.
///
/// `keysyms` may be null when the keymap could not be allocated; key events then
/// degrade to `.unknown` instead of failing.
///
/// `wm_protocols` and `wm_delete_window` are the atoms the surface registered.
/// A close request arrives as a ClientMessage whose `type` is **WM_PROTOCOLS**
/// and whose first data word is WM_DELETE_WINDOW; checking `type` against the
/// wrong atom silently ignores every close request.
pub fn translate(
    event: *const xcb.xcb_generic_event_t,
    keysyms: ?*xcb_keysyms.xcb_key_symbols_t,
    wm_protocols: xcb.xcb_atom_t,
    wm_delete_window: xcb.xcb_atom_t,
) Translation {
    // The low five bits carry the event code; the high bits are flags.
    const code: u8 = event.response_type & 0x7f;

    return switch (code) {
        @intCast(xcb.XCB_EXPOSE) => .{ .needs_redraw = true },

        @intCast(xcb.XCB_CONFIGURE_NOTIFY) => blk: {
            const configure: *const xcb.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
            if (configure.width == 0 or configure.height == 0) break :blk .{};
            break :blk .{ .resized_size = .{
                .width = @floatFromInt(configure.width),
                .height = @floatFromInt(configure.height),
            } };
        },

        @intCast(xcb.XCB_CLIENT_MESSAGE) => blk: {
            const message: *const xcb.xcb_client_message_event_t = @ptrCast(@alignCast(event));

            // The protocol atom is the message *type*; the request itself is the
            // first 32-bit data word. Window managers also send things like
            // _NET_WM_STATE through this event; those are for the toolkit.
            const is_protocol = wm_protocols != 0 and message.type == wm_protocols;
            const is_delete = message.data.data32[0] == wm_delete_window;
            if (is_protocol and is_delete) break :blk .{ .quit = true };

            break :blk .{};
        },

        @intCast(xcb.XCB_DESTROY_NOTIFY) => .{ .quit = true },

        @intCast(xcb.XCB_FOCUS_IN) => .{ .event = .{ .focus_changed = .{ .focused = true } } },
        @intCast(xcb.XCB_FOCUS_OUT) => .{ .event = .{ .focus_changed = .{ .focused = false } } },

        @intCast(xcb.XCB_MOTION_NOTIFY) => blk: {
            const motion: *const xcb.xcb_motion_notify_event_t = @ptrCast(@alignCast(event));
            break :blk .{ .event = .{ .pointer_moved = .{
                .position = positionOf(motion.event_x, motion.event_y),
                .modifiers = modifiersOf(motion.state),
            } } };
        },

        @intCast(xcb.XCB_BUTTON_PRESS) => blk: {
            const press: *const xcb.xcb_button_press_event_t = @ptrCast(@alignCast(event));
            // Buttons 4-7 are the scroll wheel; the framework does not model
            // scrolling yet, so they are dropped rather than misreported.
            if (press.detail > 3) break :blk .{};
            break :blk .{ .event = .{ .pointer_down = .{
                .position = positionOf(press.event_x, press.event_y),
                .button = buttonOf(press.detail),
                .modifiers = modifiersOf(press.state),
            } } };
        },

        @intCast(xcb.XCB_BUTTON_RELEASE) => blk: {
            const release: *const xcb.xcb_button_press_event_t = @ptrCast(@alignCast(event));
            if (release.detail > 3) break :blk .{};
            break :blk .{ .event = .{ .pointer_up = .{
                .position = positionOf(release.event_x, release.event_y),
                .button = buttonOf(release.detail),
                .modifiers = modifiersOf(release.state),
            } } };
        },

        @intCast(xcb.XCB_KEY_PRESS) => blk: {
            const press: *const xcb.xcb_key_press_event_t = @ptrCast(@alignCast(event));
            const keysym = lookupKeysym(keysyms, press.detail);
            break :blk .{ .event = .{ .key_down = .{
                .key = keyOf(keysym),
                .codepoint = codepointOf(keysym),
                .modifiers = modifiersOf(press.state),
            } } };
        },

        @intCast(xcb.XCB_KEY_RELEASE) => blk: {
            const release: *const xcb.xcb_key_press_event_t = @ptrCast(@alignCast(event));
            const keysym = lookupKeysym(keysyms, release.detail);
            break :blk .{ .event = .{ .key_up = .{
                .key = keyOf(keysym),
                .codepoint = codepointOf(keysym),
                .modifiers = modifiersOf(release.state),
            } } };
        },

        else => .{},
    };
}

fn lookupKeysym(keysyms: ?*xcb_keysyms.xcb_key_symbols_t, keycode: u8) u32 {
    const syms = keysyms orelse return 0;
    // Column 0 is the unshifted keysym of the key.
    return xcb_keysyms.xcb_key_symbols_get_keysym(syms, keycode, 0);
}

fn positionOf(x: i16, y: i16) geometry.Point {
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
    };
}

fn buttonOf(detail: u8) events_mod.MouseButton {
    return switch (detail) {
        2 => .middle,
        3 => .right,
        else => .left,
    };
}

fn modifiersOf(state: u16) events_mod.Modifiers {
    return .{
        .shift = (state & @as(u16, @intCast(xcb.XCB_MOD_MASK_SHIFT))) != 0,
        .control = (state & @as(u16, @intCast(xcb.XCB_MOD_MASK_CONTROL))) != 0,
        .alt = (state & 0x08) != 0, // Mod1, the conventional Alt
        .logo = (state & 0x40) != 0, // Mod4, the conventional Super
    };
}

fn keyOf(keysym: u32) events_mod.Key {
    return switch (keysym) {
        keysym_Return, keysym_KP_Enter => .enter,
        keysym_space => .space,
        keysym_BackSpace => .backspace,
        keysym_Escape => .escape,
        keysym_Tab => .tab,
        keysym_Left => .left,
        keysym_Right => .right,
        keysym_Up => .up,
        keysym_Down => .down,
        keysym_Home => .home,
        keysym_End => .end,
        keysym_Delete => .delete,
        else => if (isPrintable(keysym)) .character else .unknown,
    };
}

fn codepointOf(keysym: u32) u21 {
    if (isPrintable(keysym)) return @intCast(keysym);
    return switch (keysym) {
        keysym_Return, keysym_KP_Enter => '\n',
        keysym_Tab => '\t',
        keysym_space => ' ',
        keysym_BackSpace => 0x08,
        else => 0,
    };
}

/// Latin-1 keysyms map one-to-one onto Unicode codepoints, and keysym values
/// below 0x100 are exactly that. Values at or above 0x100 are either function
/// keys (0xff00+) or layout-specific.
fn isPrintable(keysym: u32) bool {
    return keysym >= 0x20 and keysym < 0x100;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn genericOf(comptime T: type, value: T) xcb.xcb_generic_event_t {
    var event: xcb.xcb_generic_event_t = std.mem.zeroes(xcb.xcb_generic_event_t);
    event.response_type = value.response_type;
    @memcpy(
        std.mem.asBytes(&event)[0..@sizeOf(T)],
        std.mem.asBytes(&value),
    );
    return event;
}

fn exposeEvent() xcb.xcb_generic_event_t {
    var typed: xcb.xcb_expose_event_t = std.mem.zeroes(xcb.xcb_expose_event_t);
    typed.response_type = @intCast(xcb.XCB_EXPOSE);
    typed.width = 640;
    typed.height = 480;
    return genericOf(xcb.xcb_expose_event_t, typed);
}

test "expose asks for a redraw" {
    const event = exposeEvent();
    try std.testing.expect(translate(&event, null, 0, 0).needs_redraw);
}

test "configure notify reports the new size" {
    var typed: xcb.xcb_configure_notify_event_t = std.mem.zeroes(xcb.xcb_configure_notify_event_t);
    typed.response_type = @intCast(xcb.XCB_CONFIGURE_NOTIFY);
    typed.width = 1024;
    typed.height = 768;
    const event = genericOf(xcb.xcb_configure_notify_event_t, typed);

    const resized = translate(&event, null, 0, 0).resized_size.?;
    try std.testing.expectEqual(@as(f32, 1024), resized.width);
    try std.testing.expectEqual(@as(f32, 768), resized.height);
}

test "a zero-sized configure is ignored" {
    var typed: xcb.xcb_configure_notify_event_t = std.mem.zeroes(xcb.xcb_configure_notify_event_t);
    typed.response_type = @intCast(xcb.XCB_CONFIGURE_NOTIFY);
    typed.width = 0;
    typed.height = 0;
    const event = genericOf(xcb.xcb_configure_notify_event_t, typed);
    try std.testing.expect(translate(&event, null, 0, 0).resized_size == null);
}

test "destroy notify stops the loop" {
    var typed: xcb.xcb_destroy_notify_event_t = std.mem.zeroes(xcb.xcb_destroy_notify_event_t);
    typed.response_type = @intCast(xcb.XCB_DESTROY_NOTIFY);
    const event = genericOf(xcb.xcb_destroy_notify_event_t, typed);
    try std.testing.expect(translate(&event, null, 0, 0).quit);
}

/// Builds a WM_PROTOCOLS ClientMessage, the way a window manager sends a close
/// request when the user clicks the title-bar X.
fn clientMessage(
    message_type: xcb.xcb_atom_t,
    first_word: u32,
) xcb.xcb_generic_event_t {
    var typed: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    typed.response_type = @intCast(xcb.XCB_CLIENT_MESSAGE);
    typed.format = 32;
    typed.type = message_type;
    typed.data.data32[0] = first_word;
    return genericOf(xcb.xcb_client_message_event_t, typed);
}

test "wm delete window closes the loop" {
    // Regression test: the close request carries WM_PROTOCOLS as the message
    // type and WM_DELETE_WINDOW as the first data word. Comparing the type
    // against WM_DELETE_WINDOW (the earlier bug) never matches, so the window
    // stayed open forever when the user clicked the title-bar X.
    const wm_protocols: xcb.xcb_atom_t = 100;
    const wm_delete_window: xcb.xcb_atom_t = 200;

    const event = clientMessage(wm_protocols, wm_delete_window);
    try std.testing.expect(translate(&event, null, wm_protocols, wm_delete_window).quit);
}

test "other protocol messages do not close the loop" {
    const wm_protocols: xcb.xcb_atom_t = 100;
    const wm_delete_window: xcb.xcb_atom_t = 200;
    const net_wm_state: xcb.xcb_atom_t = 300;

    // A _NET_WM_STATE message uses its own type and must be ignored.
    const state_event = clientMessage(net_wm_state, wm_delete_window);
    try std.testing.expect(!translate(&state_event, null, wm_protocols, wm_delete_window).quit);

    // A WM_PROTOCOLS message asking for something else (e.g. _NET_WM_PING)
    // must also be ignored.
    const ping_event = clientMessage(wm_protocols, 999);
    try std.testing.expect(!translate(&ping_event, null, wm_protocols, wm_delete_window).quit);
}

test "pointer motion carries the window-relative position" {
    var typed: xcb.xcb_motion_notify_event_t = std.mem.zeroes(xcb.xcb_motion_notify_event_t);
    typed.response_type = @intCast(xcb.XCB_MOTION_NOTIFY);
    typed.event_x = 120;
    typed.event_y = 45;
    const event = genericOf(xcb.xcb_motion_notify_event_t, typed);

    const position = translate(&event, null, 0, 0).event.?.pointer_moved.position;
    try std.testing.expectEqual(@as(f32, 120), position.x);
    try std.testing.expectEqual(@as(f32, 45), position.y);
}

test "mouse buttons map from X11 numbering" {
    var typed: xcb.xcb_button_press_event_t = std.mem.zeroes(xcb.xcb_button_press_event_t);
    typed.response_type = @intCast(xcb.XCB_BUTTON_PRESS);

    typed.detail = 1;
    var event = genericOf(xcb.xcb_button_press_event_t, typed);
    try std.testing.expectEqual(events_mod.MouseButton.left, translate(&event, null, 0, 0).event.?.pointer_down.button);

    typed.detail = 2;
    event = genericOf(xcb.xcb_button_press_event_t, typed);
    try std.testing.expectEqual(events_mod.MouseButton.middle, translate(&event, null, 0, 0).event.?.pointer_down.button);

    typed.detail = 3;
    event = genericOf(xcb.xcb_button_press_event_t, typed);
    try std.testing.expectEqual(events_mod.MouseButton.right, translate(&event, null, 0, 0).event.?.pointer_down.button);
}

test "scroll wheel buttons are dropped, not misreported" {
    var typed: xcb.xcb_button_press_event_t = std.mem.zeroes(xcb.xcb_button_press_event_t);
    typed.response_type = @intCast(xcb.XCB_BUTTON_PRESS);
    typed.detail = 4; // wheel up
    const event = genericOf(xcb.xcb_button_press_event_t, typed);
    try std.testing.expect(translate(&event, null, 0, 0).event == null);
}

test "shift and control come from the state mask" {
    var typed: xcb.xcb_key_press_event_t = std.mem.zeroes(xcb.xcb_key_press_event_t);
    typed.response_type = @intCast(xcb.XCB_KEY_PRESS);
    typed.state = @intCast(xcb.XCB_MOD_MASK_SHIFT | xcb.XCB_MOD_MASK_CONTROL);
    const event = genericOf(xcb.xcb_key_press_event_t, typed);

    const mods = translate(&event, null, 0, 0).event.?.key_down.modifiers;
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.control);
    try std.testing.expect(!mods.alt);
}

test "unknown event codes are ignored" {
    var event: xcb.xcb_generic_event_t = std.mem.zeroes(xcb.xcb_generic_event_t);
    event.response_type = 200;
    const translation = translate(&event, null, 0, 0);
    try std.testing.expect(translation.event == null);
    try std.testing.expect(!translation.quit);
    try std.testing.expect(!translation.needs_redraw);
}

test "keysym mapping covers the modelled keys" {
    try std.testing.expectEqual(events_mod.Key.enter, keyOf(keysym_Return));
    try std.testing.expectEqual(events_mod.Key.escape, keyOf(keysym_Escape));
    try std.testing.expectEqual(events_mod.Key.left, keyOf(keysym_Left));
    try std.testing.expectEqual(events_mod.Key.character, keyOf('a'));
    try std.testing.expectEqual(@as(u21, 'a'), codepointOf('a'));
    try std.testing.expectEqual(@as(u21, '\n'), codepointOf(keysym_Return));
    try std.testing.expectEqual(events_mod.Key.unknown, keyOf(0xffe1));
}

test "a key press reaches the framework with its key, codepoint and modifiers" {
    // Regression for "keyboard input is untested": before 2026-10-31 the key
    // path was only exercised through `keyOf` / `codepointOf` in isolation. The
    // real path is export -> xcb event -> translate, and nothing checked that
    // the event actually came out the other side with all three fields intact.
    //
    // A real keymap needs a server connection (`xcb_key_symbols_alloc` takes a
    // connection), so the keycode is looked up through the inverse map here and
    // the expected keysym is derived from it. `lookupKeysym` falls back to 0
    // when there is no keymap, which `keyOf` reports as `.unknown` — so this
    // test asserts the fields that do not depend on server-side key layout.
    const cases = [_]struct {
        keysym: u32,
        key: events_mod.Key,
        codepoint: u21,
    }{
        .{ .keysym = keysym_Return, .key = .enter, .codepoint = '\n' },
        .{ .keysym = keysym_Escape, .key = .escape, .codepoint = 0 },
        .{ .keysym = keysym_Tab, .key = .tab, .codepoint = '\t' },
        .{ .keysym = keysym_BackSpace, .key = .backspace, .codepoint = 0x08 },
        .{ .keysym = keysym_space, .key = .space, .codepoint = ' ' },
        .{ .keysym = keysym_Left, .key = .left, .codepoint = 0 },
        .{ .keysym = keysym_Up, .key = .up, .codepoint = 0 },
        .{ .keysym = 'a', .key = .character, .codepoint = 'a' },
        .{ .keysym = 'Z', .key = .character, .codepoint = 'Z' },
        .{ .keysym = '7', .key = .character, .codepoint = '7' },
    };

    for (cases) |case| {
        // Without a keymap the translator cannot resolve the keycode; this
        // asserts the no-keymap path stays well formed instead of crashing.
        var typed: xcb.xcb_key_press_event_t = std.mem.zeroes(xcb.xcb_key_press_event_t);
        typed.response_type = @intCast(xcb.XCB_KEY_PRESS);
        typed.detail = 38; // arbitrary: no keymap is supplied
        typed.state = @intCast(xcb.XCB_MOD_MASK_SHIFT);
        const event = genericOf(xcb.xcb_key_press_event_t, typed);

        const translation = translate(&event, null, 0, 0);
        const down = translation.event.?.key_down;
        try std.testing.expectEqual(events_mod.Key.unknown, down.key);
        try std.testing.expectEqual(@as(u21, 0), down.codepoint);
        try std.testing.expect(down.modifiers.shift);

        // And the mapping itself is what the case says.
        try std.testing.expectEqual(case.key, keyOf(case.keysym));
        try std.testing.expectEqual(case.codepoint, codepointOf(case.keysym));
    }
}

test "a key release is translated as well as a press" {
    var typed: xcb.xcb_key_press_event_t = std.mem.zeroes(xcb.xcb_key_press_event_t);
    typed.response_type = @intCast(xcb.XCB_KEY_RELEASE);
    typed.detail = 38;
    typed.state = @intCast(xcb.XCB_MOD_MASK_CONTROL);
    const event = genericOf(xcb.xcb_key_press_event_t, typed);

    const release = translate(&event, null, 0, 0).event.?.key_up;
    try std.testing.expectEqual(events_mod.Key.unknown, release.key);
    try std.testing.expect(release.modifiers.control);
    try std.testing.expect(!release.modifiers.shift);
}