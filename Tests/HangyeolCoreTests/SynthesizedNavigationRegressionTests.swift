import CoreGraphics
import Testing
@testable import HangyeolCore

@Suite("Synthesized navigation during modifier suppression")
struct SynthesizedNavigationRegressionTests {
    @Test("An explicitly preserved synthetic shortcut retains Command and Shift",
          arguments: [false, true], [Int64(54), Int64(55)])
    func commandNavigationDuringHiddenToggle(selecting: Bool, toggleKeyCode: Int64) {
        let flags: CGEventFlags = selecting ? [.maskCommand, .maskShift] : .maskCommand
        let result = RightCommandSuppressor.hostVisibleModifierFlagsForTypingEvent(
            flags,
            pressedKeyCodes: [toggleKeyCode],
            hasSuppressedKeyCodes: false,
            additionallyHiding: toggleKeyCode,
            normalizingModifierKeyCode: toggleKeyCode,
            preservesSynthesizedModifiers: true
        )
        #expect(result.contains(.maskCommand))
        #expect(result.contains(.maskShift) == selecting)
    }

    @Test("Suppression alone does not erase an explicitly preserved synthetic shortcut",
          arguments: [false, true])
    func commandNavigationDuringSuppression(selecting: Bool) {
        let flags: CGEventFlags = selecting ? [.maskCommand, .maskShift] : .maskCommand
        let result = RightCommandSuppressor.hostVisibleModifierFlagsForTypingEvent(
            flags,
            pressedKeyCodes: [],
            hasSuppressedKeyCodes: true,
            additionallyHiding: nil,
            normalizingModifierKeyCode: 54,
            preservesSynthesizedModifiers: true
        )
        #expect(result.contains(.maskCommand))
        #expect(result.contains(.maskShift) == selecting)
    }
}
