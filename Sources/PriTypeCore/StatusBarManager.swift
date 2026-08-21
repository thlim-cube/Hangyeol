import Cocoa

/// Receives input-mode changes without owning composition state.
public protocol StatusBarUpdating: AnyObject {
    func setMode(_ mode: InputMode)
}

/// Source-compatible shell for callers that used the former PriType menu-bar item.
///
/// PriType now relies on macOS's input-source menu and intentionally creates no
/// separate status item. The public surface remains so existing `PriTypeCore`
/// clients do not need to change.
public final class StatusBarManager: NSObject, StatusBarUpdating, NSMenuDelegate, @unchecked Sendable {
    public static let shared = StatusBarManager()

    private override init() {
        super.init()
    }

    @MainActor
    public func setup() {}

    @MainActor
    public func menuWillOpen(_ menu: NSMenu) {}

    public func setMode(_ mode: InputMode) {}

    @MainActor
    public func remove() {}
}
