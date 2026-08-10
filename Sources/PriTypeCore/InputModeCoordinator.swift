import Foundation

/// Coordinates PriType-owned language toggles.
///
/// Custom toggle keys must not select the real macOS ABC input source. Doing so
/// hands the active text session to another input source and reintroduces
/// first-key races. This coordinator keeps the custom toggle path inside
/// PriType: key monitor -> controller -> composer.
public final class InputModeCoordinator: @unchecked Sendable {
    public static let shared = InputModeCoordinator()

    public enum ToggleSource: Sendable {
        case customKey
        case iokitFallback

        var diagnosticLabel: StaticString {
            switch self {
            case .customKey: "event_tap"
            case .iokitFallback: "iokit"
            }
        }
    }

    private init() {}

    public func requestToggle(source: ToggleSource) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.requestToggle(source: source)
            }
            return
        }

        guard !ConfigurationManager.shared.capsLockInputSourceSwitchEnabled else {
            DebugLogger.event("toggle.ignored", metadata: [
                .state("source", source.diagnosticLabel),
                .state("reason", "caps_lock_owns_switching")
            ])
            return
        }

        guard let controller = PriTypeInputController.sharedController else {
            DebugLogger.event("toggle.ignored", metadata: [
                .state("source", source.diagnosticLabel),
                .state("reason", "no_active_controller")
            ])
            return
        }

        controller.performPriTypeModeTransition(source: source)
    }
}
