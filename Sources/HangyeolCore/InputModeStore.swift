import Foundation

/// Process-wide Korean/English mode shared by every IMK input session.
///
/// The libhangul composition engine is deliberately not stored here: preedit and
/// commit state belong to one client session, while the user's last selected mode
/// must survive controller, app, and input-field changes.
final class InputModeStore: @unchecked Sendable {
    private(set) var mode: InputMode

    init(initialMode: InputMode = .korean) {
        mode = initialMode
    }

    func setMode(_ mode: InputMode) {
        self.mode = mode
    }
}
