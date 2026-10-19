import AppKit

/// The modifier flags the fn shortcuts are compared with. Caps Lock is left out, so the
/// shortcuts keep working with Caps Lock on. Everything else stays: arrow, Home/End and
/// F-keys set .function together with .numericPad, and must not look like a fn press.
enum ShortcutModifiers {
    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    }
}
