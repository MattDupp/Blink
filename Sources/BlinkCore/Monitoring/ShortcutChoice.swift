import Foundation

/// The key combinations offered for "start a blink break from any app".
///
/// A short list of ready-made ones, not a key recorder: each holds three modifier keys
/// and the letter B, which no app and no menu of macOS is known to use, so a choice
/// rarely collides. When one does collide, macOS refuses it and the Settings window says
/// so (`ShortcutController`).
///
/// The numbers are the ones macOS's hot-key registration reads (Carbon's
/// `RegisterEventHotKey`, which needs no permission: unlike watching the keyboard, it is
/// told only that this one combination was pressed).
public enum ShortcutChoice: String, CaseIterable, Identifiable {
    case controlOptionCommandB
    case controlShiftCommandB
    case optionShiftCommandB
    case controlOptionShiftB

    public var id: String { rawValue }

    /// The virtual key code of B on every keyboard layout's physical key (`kVK_ANSI_B`).
    public var keyCode: UInt32 { 11 }

    /// Carbon's modifier bits: command 0x100, shift 0x200, option 0x800, control 0x1000.
    public var modifiers: UInt32 {
        switch self {
        case .controlOptionCommandB: return 0x1000 | 0x800 | 0x100
        case .controlShiftCommandB: return 0x1000 | 0x200 | 0x100
        case .optionShiftCommandB: return 0x800 | 0x200 | 0x100
        case .controlOptionShiftB: return 0x1000 | 0x800 | 0x200
        }
    }

    /// As menus write it: modifiers in the order control, option, shift, command.
    public var symbols: String {
        switch self {
        case .controlOptionCommandB: return "⌃⌥⌘B"
        case .controlShiftCommandB: return "⌃⇧⌘B"
        case .optionShiftCommandB: return "⌥⇧⌘B"
        case .controlOptionShiftB: return "⌃⌥⇧B"
        }
    }

    /// As VoiceOver should say it.
    public var spoken: String {
        switch self {
        case .controlOptionCommandB: return "Control Option Command B"
        case .controlShiftCommandB: return "Control Shift Command B"
        case .optionShiftCommandB: return "Option Shift Command B"
        case .controlOptionShiftB: return "Control Option Shift B"
        }
    }
}
