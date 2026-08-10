// GhosttyInput.swift
// Argus
//
// AppKit-to-Ghostty keyboard and mouse input translation.

import AppKit
import UniformTypeIdentifiers

// macOS virtual keycode and unshifted codepoint for the "v" key.
private let terminalControlVKeycode: UInt32 = 9
private let terminalControlVCodepoint: UInt32 = 0x76

private let ghosttyKeyMap: [UInt16: ghostty_input_key_e] = [
    // Main keyboard
    0: GHOSTTY_KEY_A,
    1: GHOSTTY_KEY_S,
    2: GHOSTTY_KEY_D,
    3: GHOSTTY_KEY_F,
    4: GHOSTTY_KEY_H,
    5: GHOSTTY_KEY_G,
    6: GHOSTTY_KEY_Z,
    7: GHOSTTY_KEY_X,
    8: GHOSTTY_KEY_C,
    9: GHOSTTY_KEY_V,
    10: GHOSTTY_KEY_INTL_BACKSLASH,
    11: GHOSTTY_KEY_B,
    12: GHOSTTY_KEY_Q,
    13: GHOSTTY_KEY_W,
    14: GHOSTTY_KEY_E,
    15: GHOSTTY_KEY_R,
    16: GHOSTTY_KEY_Y,
    17: GHOSTTY_KEY_T,
    18: GHOSTTY_KEY_DIGIT_1,
    19: GHOSTTY_KEY_DIGIT_2,
    20: GHOSTTY_KEY_DIGIT_3,
    21: GHOSTTY_KEY_DIGIT_4,
    22: GHOSTTY_KEY_DIGIT_6,
    23: GHOSTTY_KEY_DIGIT_5,
    24: GHOSTTY_KEY_EQUAL,
    25: GHOSTTY_KEY_DIGIT_9,
    26: GHOSTTY_KEY_DIGIT_7,
    27: GHOSTTY_KEY_MINUS,
    28: GHOSTTY_KEY_DIGIT_8,
    29: GHOSTTY_KEY_DIGIT_0,
    30: GHOSTTY_KEY_BRACKET_RIGHT,
    31: GHOSTTY_KEY_O,
    32: GHOSTTY_KEY_U,
    33: GHOSTTY_KEY_BRACKET_LEFT,
    34: GHOSTTY_KEY_I,
    35: GHOSTTY_KEY_P,
    36: GHOSTTY_KEY_ENTER,
    37: GHOSTTY_KEY_L,
    38: GHOSTTY_KEY_J,
    39: GHOSTTY_KEY_QUOTE,
    40: GHOSTTY_KEY_K,
    41: GHOSTTY_KEY_SEMICOLON,
    42: GHOSTTY_KEY_BACKSLASH,
    43: GHOSTTY_KEY_COMMA,
    44: GHOSTTY_KEY_SLASH,
    45: GHOSTTY_KEY_N,
    46: GHOSTTY_KEY_M,
    47: GHOSTTY_KEY_PERIOD,
    48: GHOSTTY_KEY_TAB,
    49: GHOSTTY_KEY_SPACE,
    50: GHOSTTY_KEY_BACKQUOTE,
    51: GHOSTTY_KEY_BACKSPACE,
    53: GHOSTTY_KEY_ESCAPE,

    // Modifier keys
    54: GHOSTTY_KEY_META_RIGHT,
    55: GHOSTTY_KEY_META_LEFT,
    56: GHOSTTY_KEY_SHIFT_LEFT,
    57: GHOSTTY_KEY_CAPS_LOCK,
    58: GHOSTTY_KEY_ALT_LEFT,
    59: GHOSTTY_KEY_CONTROL_LEFT,
    60: GHOSTTY_KEY_SHIFT_RIGHT,
    61: GHOSTTY_KEY_ALT_RIGHT,
    62: GHOSTTY_KEY_CONTROL_RIGHT,
    63: GHOSTTY_KEY_FN,

    // Function keys
    64: GHOSTTY_KEY_F17,
    79: GHOSTTY_KEY_F18,
    80: GHOSTTY_KEY_F19,
    90: GHOSTTY_KEY_F20,
    96: GHOSTTY_KEY_F5,
    97: GHOSTTY_KEY_F6,
    98: GHOSTTY_KEY_F7,
    99: GHOSTTY_KEY_F3,
    100: GHOSTTY_KEY_F8,
    101: GHOSTTY_KEY_F9,
    103: GHOSTTY_KEY_F11,
    105: GHOSTTY_KEY_F13,
    106: GHOSTTY_KEY_F16,
    107: GHOSTTY_KEY_F14,
    109: GHOSTTY_KEY_F10,
    111: GHOSTTY_KEY_F12,
    113: GHOSTTY_KEY_F15,
    118: GHOSTTY_KEY_F4,
    120: GHOSTTY_KEY_F2,
    122: GHOSTTY_KEY_F1,

    // Navigation keys
    114: GHOSTTY_KEY_HELP,
    115: GHOSTTY_KEY_HOME,
    116: GHOSTTY_KEY_PAGE_UP,
    117: GHOSTTY_KEY_DELETE,
    119: GHOSTTY_KEY_END,
    121: GHOSTTY_KEY_PAGE_DOWN,
    123: GHOSTTY_KEY_ARROW_LEFT,
    124: GHOSTTY_KEY_ARROW_RIGHT,
    125: GHOSTTY_KEY_ARROW_DOWN,
    126: GHOSTTY_KEY_ARROW_UP,

    // Numpad
    65: GHOSTTY_KEY_NUMPAD_DECIMAL,
    67: GHOSTTY_KEY_NUMPAD_MULTIPLY,
    69: GHOSTTY_KEY_NUMPAD_ADD,
    71: GHOSTTY_KEY_NUMPAD_CLEAR,
    75: GHOSTTY_KEY_NUMPAD_DIVIDE,
    76: GHOSTTY_KEY_NUMPAD_ENTER,
    78: GHOSTTY_KEY_NUMPAD_SUBTRACT,
    81: GHOSTTY_KEY_NUMPAD_EQUAL,
    82: GHOSTTY_KEY_NUMPAD_0,
    83: GHOSTTY_KEY_NUMPAD_1,
    84: GHOSTTY_KEY_NUMPAD_2,
    85: GHOSTTY_KEY_NUMPAD_3,
    86: GHOSTTY_KEY_NUMPAD_4,
    87: GHOSTTY_KEY_NUMPAD_5,
    88: GHOSTTY_KEY_NUMPAD_6,
    89: GHOSTTY_KEY_NUMPAD_7,
    91: GHOSTTY_KEY_NUMPAD_8,
    92: GHOSTTY_KEY_NUMPAD_9,

    // Context menu and media keys
    72: GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
    73: GHOSTTY_KEY_AUDIO_VOLUME_UP,
    74: GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
    110: GHOSTTY_KEY_CONTEXT_MENU
]

private let ghosttyMouseButtons: [ghostty_input_mouse_button_e] = [
    GHOSTTY_MOUSE_LEFT,
    GHOSTTY_MOUSE_RIGHT,
    GHOSTTY_MOUSE_MIDDLE,
    GHOSTTY_MOUSE_FOUR,
    GHOSTTY_MOUSE_FIVE,
    GHOSTTY_MOUSE_SIX,
    GHOSTTY_MOUSE_SEVEN,
    GHOSTTY_MOUSE_EIGHT,
    GHOSTTY_MOUSE_NINE,
    GHOSTTY_MOUSE_TEN,
    GHOSTTY_MOUSE_ELEVEN
]

func ghosttyKeyEvent(
    from event: NSEvent,
    action: ghostty_input_action_e
) -> ghostty_input_key_s {
    var keyInput = ghostty_input_key_s()
    keyInput.action = action
    keyInput.mods = ghosttyMods(from: event.modifierFlags)
    keyInput.consumed_mods = ghosttyConsumedMods(from: event.modifierFlags)
    keyInput.keycode = UInt32(event.keyCode)
    keyInput.unshifted_codepoint = ghosttyUnshiftedCodepoint(from: event)
    keyInput.composing = false
    keyInput.text = nil
    return keyInput
}

/// Key events that deliver Ctrl+V to the running terminal program when Cmd+V
/// is pressed with an image-only system clipboard.
///
/// Raw text injection cannot be used here: Ghostty's paste path replaces C0
/// bytes, including 0x16 (VLNEXT / Ctrl+V), with a space. Synthesising a key
/// event instead lets Ghostty encode Ctrl+V with whatever keyboard protocol
/// the running program negotiated (legacy 0x16 or Kitty CSI-u).
func terminalImagePasteKeyEvents(
    for event: NSEvent,
    pasteboard: NSPasteboard = .general
) -> [ghostty_input_key_s]? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard event.type == .keyDown,
        event.charactersIgnoringModifiers?.lowercased() == "v",
        modifiers == .command,
        pasteboard.string(forType: .string) == nil,
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    else { return nil }

    return [
        terminalControlVKeyEvent(action: GHOSTTY_ACTION_PRESS),
        terminalControlVKeyEvent(action: GHOSTTY_ACTION_RELEASE)
    ]
}

private func terminalControlVKeyEvent(
    action: ghostty_input_action_e
) -> ghostty_input_key_s {
    var keyInput = ghostty_input_key_s()
    keyInput.action = action
    keyInput.mods = GHOSTTY_MODS_CTRL
    keyInput.consumed_mods = GHOSTTY_MODS_NONE
    keyInput.keycode = terminalControlVKeycode
    keyInput.unshifted_codepoint = terminalControlVCodepoint
    keyInput.composing = false
    keyInput.text = nil
    return keyInput
}

func isModifierPress(event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    switch event.keyCode {
    case 56, 60:
        return flags.contains(.shift)
    case 59, 62:
        return flags.contains(.control)
    case 58, 61:
        return flags.contains(.option)
    case 54, 55:
        return flags.contains(.command)
    case 57:
        return flags.contains(.capsLock)
    case 63:
        return flags.contains(.function)
    default:
        return false
    }
}

func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
    guard ghosttyMouseButtons.indices.contains(buttonNumber) else {
        return GHOSTTY_MOUSE_UNKNOWN
    }
    return ghosttyMouseButtons[buttonNumber]
}

func ghosttyKey(from keyCode: UInt16) -> ghostty_input_key_e {
    ghosttyKeyMap[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
}

func ghosttyText(from event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }

    if characters.count == 1,
        let scalar = characters.unicodeScalars.first
    {
        if scalar.value < 0x20 {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return nil
        }
    }

    return characters
}

func ghosttyUnshiftedCodepoint(from event: NSEvent) -> UInt32 {
    guard event.type == .keyDown || event.type == .keyUp,
        let characters = event.characters(byApplyingModifiers: []),
        let codepoint = characters.unicodeScalars.first
    else { return 0 }
    return codepoint.value
}

func ghosttyConsumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    ghosttyMods(from: flags.subtracting([.control, .command]))
}

func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) {
        mods |= GHOSTTY_MODS_SHIFT.rawValue
    }
    if flags.contains(.control) {
        mods |= GHOSTTY_MODS_CTRL.rawValue
    }
    if flags.contains(.option) {
        mods |= GHOSTTY_MODS_ALT.rawValue
    }
    if flags.contains(.command) {
        mods |= GHOSTTY_MODS_SUPER.rawValue
    }
    if flags.contains(.capsLock) {
        mods |= GHOSTTY_MODS_CAPS.rawValue
    }
    if flags.contains(.numericPad) {
        mods |= GHOSTTY_MODS_NUM.rawValue
    }

    return ghostty_input_mods_e(rawValue: mods)
}
