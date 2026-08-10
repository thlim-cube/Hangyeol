import Foundation

/// Decides whether an IMK mouse-down ends the active composition.
///
/// Marked text stays active for a click inside its own range. Direct insertion has
/// no marked range, so any click ends its live preedit tracking before the caret
/// moves. Pure policy keeps the SDK-specific mouse callback easy to regression-test.
enum MouseCompositionState: Equatable {
    case inactive
    case active
    case staleMarkedFallback
}

enum MouseCompositionPolicy {
    static func shouldFinalize(
        characterIndex: Int,
        markedRange: NSRange,
        state: MouseCompositionState
    ) -> Bool {
        switch state {
        case .inactive:
            return false
        case .staleMarkedFallback:
            return true
        case .active:
            break
        }
        guard markedRange.location != NSNotFound, markedRange.length > 0 else {
            return true
        }

        let (upperBound, overflow) = markedRange.location.addingReportingOverflow(markedRange.length)
        guard !overflow else { return true }
        return characterIndex < markedRange.location || characterIndex >= upperBound
    }
}
