import Cocoa
import InputMethodKit

/// Synthetic IMK client for session/finalize contract tests. It models only text,
/// selection, and marked-range effects and never touches a real application.
final class FakeIMKTextInput: NSObject, IMKTextInput {
    var document = ""
    var markedText = ""
    var selectedRangeValue = NSRange(location: 0, length: 0)
    var markedRangeValue = NSRange(location: NSNotFound, length: 0)
    var bundleID = "com.example.synthetic"
    var insertCalls: [(String, NSRange)] = []
    var markCalls: [String] = []
    var firstRectValue = NSRect.zero
    var onInsertText: (() -> Void)?
    var onAttributedSubstring: (() -> Void)?
    var onSelectedRange: (() -> Void)?
    var attributedSubstringUnavailable = false

    private func plainString(_ value: Any?) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = plainString(string)
        insertCalls.append((text, replacementRange))

        if replacementRange.location == NSNotFound {
            if !text.isEmpty { document.append(text) }
        } else if replacementRange.length > 0,
                  replacementRange.location <= document.utf16.count {
            var units = Array(document.utf16)
            let end = min(units.count, replacementRange.location + replacementRange.length)
            units.replaceSubrange(replacementRange.location..<end, with: Array(text.utf16))
            document = String(decoding: units, as: UTF16.self)
        } else if !text.isEmpty {
            document.append(text)
        }

        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
        selectedRangeValue = NSRange(location: document.utf16.count, length: 0)
        onInsertText?()
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let text = plainString(string)
        markCalls.append(text)
        markedText = text
        if text.isEmpty {
            markedRangeValue = NSRange(location: NSNotFound, length: 0)
        } else {
            let location = selectedRangeValue.location == NSNotFound ? 0 : selectedRangeValue.location
            markedRangeValue = NSRange(location: location, length: text.utf16.count)
        }
    }

    func selectedRange() -> NSRange {
        let result = selectedRangeValue
        onSelectedRange?()
        return result
    }
    func markedRange() -> NSRange { markedRangeValue }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard !attributedSubstringUnavailable else { return nil }
        let result: NSAttributedString?
        if range == markedRangeValue,
           range.location != NSNotFound,
           range.length == markedText.utf16.count {
            result = NSAttributedString(string: markedText)
        } else {
            let (end, overflow) = range.location.addingReportingOverflow(range.length)
            if range.location != NSNotFound,
               !overflow,
               end <= document.utf16.count {
                let units = Array(document.utf16)[range.location..<end]
                result = NSAttributedString(string: String(decoding: units, as: UTF16.self))
            } else {
                result = nil
            }
        }
        onAttributedSubstring?()
        return result
    }
    func length() -> Int { document.utf16.count }
    func characterIndex(
        for point: NSPoint,
        tracking mappingMode: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>!
    ) -> Int { selectedRangeValue.location }
    func attributes(
        forCharacterIndex index: Int,
        lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!
    ) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { bundleID }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "synthetic-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        attributedSubstring(from: range)?.string
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
        firstRectValue
    }
}
