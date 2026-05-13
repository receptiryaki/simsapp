import Foundation

/// Keys we can synthesise into the simulator. Each maps to a HID
/// usage on the standard keyboard page (page 7). Covers the ASCII
/// printable subset plus the common control keys; that's enough to
/// type into a TextField, hit Return/Backspace, and navigate with
/// arrows / Escape / Tab.
///
/// Extending: add the case here and the `(page, usage)` mapping in
/// `hidUsage`. Apple's HID Usage Tables document page 7 in full;
/// we use the subset W3C `KeyboardEvent.code` exposes.
enum KeyboardKey: String, Sendable, Equatable, Hashable, CaseIterable {
    // letters
    case keyA, keyB, keyC, keyD, keyE, keyF, keyG, keyH, keyI, keyJ
    case keyK, keyL, keyM, keyN, keyO, keyP, keyQ, keyR, keyS, keyT
    case keyU, keyV, keyW, keyX, keyY, keyZ

    // top-row digits
    case digit1, digit2, digit3, digit4, digit5
    case digit6, digit7, digit8, digit9, digit0

    // common control keys
    case `return`
    case escape
    case backspace
    case tab
    case space

    // punctuation we'll get for free from any US layout
    case minus            // -
    case equal            // =
    case bracketLeft      // [
    case bracketRight     // ]
    case backslash        // \
    case semicolon        // ;
    case quote            // '
    case backquote        // `
    case comma            // ,
    case period           // .
    case slash            // /

    // arrows
    case arrowRight
    case arrowLeft
    case arrowDown
    case arrowUp

    /// HID page/usage. Page 7 = Keyboard/Keypad. Codes are from
    /// section 10 of Apple's HID Usage Tables (matches what
    /// W3C KeyboardEvent.code resolves to on every shipping iPhone).
    var hidUsage: HIDUsage {
        switch self {
        case .keyA: return HIDUsage(page: 7, usage: 0x04)
        case .keyB: return HIDUsage(page: 7, usage: 0x05)
        case .keyC: return HIDUsage(page: 7, usage: 0x06)
        case .keyD: return HIDUsage(page: 7, usage: 0x07)
        case .keyE: return HIDUsage(page: 7, usage: 0x08)
        case .keyF: return HIDUsage(page: 7, usage: 0x09)
        case .keyG: return HIDUsage(page: 7, usage: 0x0A)
        case .keyH: return HIDUsage(page: 7, usage: 0x0B)
        case .keyI: return HIDUsage(page: 7, usage: 0x0C)
        case .keyJ: return HIDUsage(page: 7, usage: 0x0D)
        case .keyK: return HIDUsage(page: 7, usage: 0x0E)
        case .keyL: return HIDUsage(page: 7, usage: 0x0F)
        case .keyM: return HIDUsage(page: 7, usage: 0x10)
        case .keyN: return HIDUsage(page: 7, usage: 0x11)
        case .keyO: return HIDUsage(page: 7, usage: 0x12)
        case .keyP: return HIDUsage(page: 7, usage: 0x13)
        case .keyQ: return HIDUsage(page: 7, usage: 0x14)
        case .keyR: return HIDUsage(page: 7, usage: 0x15)
        case .keyS: return HIDUsage(page: 7, usage: 0x16)
        case .keyT: return HIDUsage(page: 7, usage: 0x17)
        case .keyU: return HIDUsage(page: 7, usage: 0x18)
        case .keyV: return HIDUsage(page: 7, usage: 0x19)
        case .keyW: return HIDUsage(page: 7, usage: 0x1A)
        case .keyX: return HIDUsage(page: 7, usage: 0x1B)
        case .keyY: return HIDUsage(page: 7, usage: 0x1C)
        case .keyZ: return HIDUsage(page: 7, usage: 0x1D)
        case .digit1: return HIDUsage(page: 7, usage: 0x1E)
        case .digit2: return HIDUsage(page: 7, usage: 0x1F)
        case .digit3: return HIDUsage(page: 7, usage: 0x20)
        case .digit4: return HIDUsage(page: 7, usage: 0x21)
        case .digit5: return HIDUsage(page: 7, usage: 0x22)
        case .digit6: return HIDUsage(page: 7, usage: 0x23)
        case .digit7: return HIDUsage(page: 7, usage: 0x24)
        case .digit8: return HIDUsage(page: 7, usage: 0x25)
        case .digit9: return HIDUsage(page: 7, usage: 0x26)
        case .digit0: return HIDUsage(page: 7, usage: 0x27)
        case .return:    return HIDUsage(page: 7, usage: 0x28)
        case .escape:    return HIDUsage(page: 7, usage: 0x29)
        case .backspace: return HIDUsage(page: 7, usage: 0x2A)
        case .tab:       return HIDUsage(page: 7, usage: 0x2B)
        case .space:     return HIDUsage(page: 7, usage: 0x2C)
        case .minus:        return HIDUsage(page: 7, usage: 0x2D)
        case .equal:        return HIDUsage(page: 7, usage: 0x2E)
        case .bracketLeft:  return HIDUsage(page: 7, usage: 0x2F)
        case .bracketRight: return HIDUsage(page: 7, usage: 0x30)
        case .backslash:    return HIDUsage(page: 7, usage: 0x31)
        case .semicolon:    return HIDUsage(page: 7, usage: 0x33)
        case .quote:        return HIDUsage(page: 7, usage: 0x34)
        case .backquote:    return HIDUsage(page: 7, usage: 0x35)
        case .comma:        return HIDUsage(page: 7, usage: 0x36)
        case .period:       return HIDUsage(page: 7, usage: 0x37)
        case .slash:        return HIDUsage(page: 7, usage: 0x38)
        case .arrowRight: return HIDUsage(page: 7, usage: 0x4F)
        case .arrowLeft:  return HIDUsage(page: 7, usage: 0x50)
        case .arrowDown:  return HIDUsage(page: 7, usage: 0x51)
        case .arrowUp:    return HIDUsage(page: 7, usage: 0x52)
        }
    }
}

/// Modifier keys held while the main key fires. Each maps to the
/// LEFT variant on HID page 7; iOS doesn't differentiate left/right
/// for software-keyboard purposes.
enum KeyModifier: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case shift
    case control
    case option
    case command

    /// `Comparable` so we can sort a Set for deterministic
    /// down/up order — useful for log readability, not for iOS
    /// (which doesn't care about modifier ordering).
    static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var hidUsage: HIDUsage {
        switch self {
        case .control: return HIDUsage(page: 7, usage: 0xE0)  // left control
        case .shift:   return HIDUsage(page: 7, usage: 0xE1)  // left shift
        case .option:  return HIDUsage(page: 7, usage: 0xE2)  // left alt/option
        case .command: return HIDUsage(page: 7, usage: 0xE3)  // left GUI/command
        }
    }
}
