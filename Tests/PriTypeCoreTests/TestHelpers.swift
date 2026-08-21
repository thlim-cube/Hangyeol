import Testing
import Cocoa
import InputMethodKit
@testable import PriTypeCore

// MARK: - Shared Test Helpers

/// Mock implementation of StatusBarUpdating for tests
final class MockStatusBar: StatusBarUpdating {
    var currentMode: InputMode = .korean
    var modeChanges: [InputMode] = []
    
    func setMode(_ mode: InputMode) {
        currentMode = mode
        modeChanges.append(mode)
    }
}

/// Mock implementation of ConfigurationProviding for tests
final class MockConfiguration: ConfigurationProviding, @unchecked Sendable {
    var keyboardId: String = PriTypeConfig.defaultKeyboardId
    var toggleKey: ToggleKey = .rightCommand
    var rightCommandAsToggle: Bool { true }
    var controlSpaceAsToggle: Bool { false }
    var capsLockInputSourceSwitchEnabled: Bool { false }
    var capsLockProducesDoubleConsonants: Bool = true
    var doubleSpacePeriodEnabled: Bool { true }
    var autoCapitalizationEnabled: Bool { true }
    var smartQuoteSubstitutionEnabled: Bool { true }
    var smartDashSubstitutionEnabled: Bool { true }
    var englishTextConvenienceFallbackEnabled: Bool = false
    var experimentalDirectInsertion: Bool = false
}

extension InputSession {
    convenience init(
        client: IMKTextInput,
        context: ClientContext,
        composer: HangulComposer,
        invalidateHanjaShortcutSessionState: @escaping () -> Void = {},
        retireActiveControllerAfterFocusLoss: @escaping (InputSession) -> Void = { _ in }
    ) {
        self.init(
            client: client,
            context: context,
            composer: composer,
            experimentalDirectInsertion: { false },
            invalidateHanjaShortcutSessionState: invalidateHanjaShortcutSessionState,
            retireActiveControllerAfterFocusLoss: retireActiveControllerAfterFocusLoss
        )
    }
}

/// Mock implementation of HangulComposerDelegate for tests
final class MockComposerDelegate: HangulComposerDelegate {
    var insertedTexts: [String] = []
    var markedText: String = ""
    var fullText: String = ""
    /// Ordered log of delegate calls across insertText/setMarkedText, e.g.
    /// ["insert:아", "mark:나"]. Used to assert the commit-before-mark invariant.
    var orderedCalls: [String] = []
    var backspaceCompositionUpdateDepth = 0
    var backspaceCompositionUpdateCallCount = 0
    var markedTextDuringBackspaceUpdates: [String] = []
    var shouldPassThroughBackspaceAfterClearingComposition = false
    var insertTextSucceeds = true
    var replaceTextBeforeCursorSucceeds = true
    var hostKeySchedulingSucceeds = true
    var scheduledHostKeyCodes: [UInt16] = []
    var scheduledHostKeyModifierFlags: [UInt] = []
    var passThroughBackspaceAfterClearingCompositionCallCount = 0
    
    func insertText(_ text: String) {
        _ = tryInsertText(text)
    }

    func tryInsertText(_ text: String) -> Bool {
        guard insertTextSucceeds else { return false }
        insertedTexts.append(text)
        orderedCalls.append("insert:\(text)")
        markedText = ""
        fullText.append(text)
        return true
    }

    func setMarkedText(_ text: String) {
        orderedCalls.append("mark:\(text)")
        markedText = text
        if backspaceCompositionUpdateDepth > 0 {
            markedTextDuringBackspaceUpdates.append(text)
        }
    }

    func beginBackspaceCompositionUpdate() {
        backspaceCompositionUpdateDepth += 1
        backspaceCompositionUpdateCallCount += 1
    }

    func endBackspaceCompositionUpdate() {
        backspaceCompositionUpdateDepth -= 1
    }

    func prepareForSystemBackspaceAfterClearingComposition() -> Bool {
        passThroughBackspaceAfterClearingCompositionCallCount += 1
        guard shouldPassThroughBackspaceAfterClearingComposition else {
            return false
        }
        markedText = ""
        return true
    }
    
    func textBeforeCursor(length: Int) -> String? {
        if fullText.isEmpty { return "" }
        let count = fullText.count
        let start = max(0, count - length)
        let startIndex = fullText.index(fullText.startIndex, offsetBy: start)
        return String(fullText[startIndex...])
    }
    
    func replaceTextBeforeCursor(length: Int, with text: String) {
        _ = tryReplaceTextBeforeCursor(length: length, with: text)
    }

    func tryReplaceTextBeforeCursor(length: Int, with text: String) -> Bool {
        guard replaceTextBeforeCursorSucceeds else { return false }
        guard fullText.count >= length else { return false }
        fullText.removeLast(length)
        fullText.append(text)
        return true
    }

    func tryScheduleHostKey(keyCode: UInt16, modifierFlags: UInt) -> Bool {
        guard hostKeySchedulingSucceeds else { return false }
        orderedCalls.append(
            keyCode == KeyCode.forwardDelete
                ? "schedule:forward-delete"
                : "schedule:return"
        )
        scheduledHostKeyCodes.append(keyCode)
        scheduledHostKeyModifierFlags.append(modifierFlags)
        return true
    }

    func deliverScheduledReturns() {
        let returnCount = scheduledHostKeyCodes.filter {
            $0 == KeyCode.return || $0 == KeyCode.numpadEnter
        }.count
        fullText.append(String(repeating: "\n", count: returnCount))
        scheduledHostKeyCodes = []
        scheduledHostKeyModifierFlags = []
    }
    
    func reset() {
        insertedTexts = []
        markedText = ""
        fullText = ""
        orderedCalls = []
        backspaceCompositionUpdateDepth = 0
        backspaceCompositionUpdateCallCount = 0
        markedTextDuringBackspaceUpdates = []
        shouldPassThroughBackspaceAfterClearingComposition = false
        insertTextSucceeds = true
        replaceTextBeforeCursorSucceeds = true
        hostKeySchedulingSucceeds = true
        scheduledHostKeyCodes = []
        scheduledHostKeyModifierFlags = []
        passThroughBackspaceAfterClearingCompositionCallCount = 0
    }
}

/// Factory for creating NSEvent instances in tests
enum TestEventFactory {
    static func keyEvent(
        char: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown,
        timestamp: TimeInterval = 0,
        isARepeat: Bool = false
    ) -> NSEvent? {
        return NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: char,
            charactersIgnoringModifiers: char,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }
}
