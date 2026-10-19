import AppKit
import XCTest

final class ShortcutModifiersTests: XCTestCase {
    func testCapsLockDoesNotChangeTheShortcut() {
        XCTAssertEqual(ShortcutModifiers.normalized([.function, .shift, .capsLock]), [.function, .shift])
        XCTAssertEqual(ShortcutModifiers.normalized([.function, .control, .capsLock]), [.function, .control])
    }

    func testHeldArrowKeyPlusShiftIsNoFnShortcut() {
        // macOS tags arrow keys with .function and .numericPad.
        XCTAssertNotEqual(ShortcutModifiers.normalized([.function, .numericPad, .shift]), [.function, .shift])
        XCTAssertNotEqual(ShortcutModifiers.normalized([.function, .numericPad, .shift, .capsLock]), [.function, .shift])
    }
}
