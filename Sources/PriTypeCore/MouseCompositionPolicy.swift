import Foundation

/// Decides whether an IMK mouse-down ends the active composition.
///
/// Marked text stays active for a click inside its own range. Direct insertion has
/// no marked range, so any click ends its live preedit tracking before the caret
/// moves. Pure policy keeps the SDK-specific mouse callback easy to regression-test.
enum MouseCompositionPolicy {
    static func shouldFinalize(
        characterIndex: Int,
        markedRange: NSRange,
        hasActiveComposition: Bool
    ) -> Bool {
        guard hasActiveComposition else { return false }
        guard markedRange.location != NSNotFound, markedRange.length > 0 else {
            return true
        }

        let (upperBound, overflow) = markedRange.location.addingReportingOverflow(markedRange.length)
        guard !overflow else { return true }
        return characterIndex < markedRange.location || characterIndex >= upperBound
    }
}
