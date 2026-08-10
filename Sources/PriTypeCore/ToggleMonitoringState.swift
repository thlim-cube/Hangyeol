import Foundation
import CoreGraphics

/// 전환키 감시를 실제로 소유한 시스템 backend입니다.
enum ToggleMonitorBackend: String, Equatable, Sendable {
    case eventTap
    case iokit
}

/// 전환키 감시가 완전하게 동작하지 못하는 이유입니다.
enum ToggleMonitorIssue: Equatable, Sendable {
    case accessibilityPermissionRequired
    case unsupportedIOKitToggleBinding(String)
    case unsupportedIOKitHanjaBinding(String)
    case iokitOpenFailed(Int32)
}

/// 설정 화면과 상태 표시가 사용할 수 있는 전환키 감시 상태입니다.
enum ToggleMonitorStatus: Equatable, Sendable {
    case stopped
    case starting(ToggleMonitorBackend)
    case running(backend: ToggleMonitorBackend, limitations: [ToggleMonitorIssue])
    case transitioning(from: ToggleMonitorBackend, to: ToggleMonitorBackend)
    case unavailable(ToggleMonitorIssue)
}

extension Notification.Name {
    /// `ToggleMonitorStatusStore.status`가 바뀔 때 게시됩니다.
    static let toggleMonitorStatusChanged = Notification.Name("PriTypeToggleMonitorStatusChanged")
}

/// CGEventTap과 IOKit이 동시에 활성화되지 않도록 시작 권한과 현재 상태를 관리합니다.
final class ToggleMonitorStatusStore: @unchecked Sendable {
    static let shared = ToggleMonitorStatusStore()

    private let lock = NSLock()
    private var storedStatus: ToggleMonitorStatus = .stopped

    var status: ToggleMonitorStatus {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    init() {}

    /// backend 시작을 예약합니다. 다른 backend가 시작 중이거나 실행 중이면 거부합니다.
    @discardableResult
    func reserveStart(_ backend: ToggleMonitorBackend) -> Bool {
        let nextStatus: ToggleMonitorStatus?

        lock.lock()
        switch storedStatus {
        case .stopped, .unavailable:
            nextStatus = .starting(backend)
        case .transitioning(from: .eventTap, to: .iokit) where backend == .iokit:
            nextStatus = .starting(.iokit)
        case .starting, .running, .transitioning:
            nextStatus = nil
        }
        if let nextStatus {
            storedStatus = nextStatus
        }
        lock.unlock()

        if let nextStatus {
            publish(nextStatus)
            return true
        }
        return false
    }

    func markRunning(_ backend: ToggleMonitorBackend, limitations: [ToggleMonitorIssue] = []) {
        let nextStatus = ToggleMonitorStatus.running(backend: backend, limitations: limitations)

        lock.lock()
        guard case .starting(let reservedBackend) = storedStatus,
              reservedBackend == backend else {
            lock.unlock()
            return
        }
        storedStatus = nextStatus
        lock.unlock()
        publish(nextStatus)
    }

    /// event tap 자원이 해제된 뒤 IOKit 인계를 한 번만 시작합니다.
    @discardableResult
    func beginEventTapHandoff() -> Bool {
        let nextStatus = ToggleMonitorStatus.transitioning(from: .eventTap, to: .iokit)

        lock.lock()
        switch storedStatus {
        case .starting(.eventTap), .running(backend: .eventTap, limitations: _):
            storedStatus = nextStatus
            lock.unlock()
            publish(nextStatus)
            return true
        case .stopped, .starting(.iokit), .running(backend: .iokit, limitations: _),
             .transitioning, .unavailable:
            lock.unlock()
            return false
        }
    }

    func failStart(_ backend: ToggleMonitorBackend, issue: ToggleMonitorIssue) {
        markUnavailable(backend, issue: issue)
    }

    func markUnavailable(_ backend: ToggleMonitorBackend, issue: ToggleMonitorIssue) {
        let nextStatus = ToggleMonitorStatus.unavailable(issue)

        lock.lock()
        let ownsStatus: Bool
        switch storedStatus {
        case .starting(let startingBackend):
            ownsStatus = startingBackend == backend
        case .running(backend: let runningBackend, limitations: _):
            ownsStatus = runningBackend == backend
        default:
            ownsStatus = false
        }
        guard ownsStatus else {
            lock.unlock()
            return
        }
        storedStatus = nextStatus
        lock.unlock()
        publish(nextStatus)
    }

    func updateLimitations(_ limitations: [ToggleMonitorIssue], for backend: ToggleMonitorBackend) {
        let nextStatus = ToggleMonitorStatus.running(backend: backend, limitations: limitations)

        lock.lock()
        guard case .running(backend: let runningBackend, limitations: _) = storedStatus,
              runningBackend == backend,
              storedStatus != nextStatus else {
            lock.unlock()
            return
        }
        storedStatus = nextStatus
        lock.unlock()
        publish(nextStatus)
    }

    func markStopped(_ backend: ToggleMonitorBackend) {
        lock.lock()
        let shouldStop: Bool
        switch storedStatus {
        case .starting(let startingBackend):
            shouldStop = startingBackend == backend
        case .running(backend: let runningBackend, limitations: _):
            shouldStop = runningBackend == backend
        default:
            shouldStop = false
        }
        if shouldStop {
            storedStatus = .stopped
        }
        lock.unlock()

        if shouldStop {
            publish(.stopped)
        }
    }

    private func publish(_ status: ToggleMonitorStatus) {
        NotificationCenter.default.post(
            name: .toggleMonitorStatusChanged,
            object: self,
            userInfo: ["status": status]
        )
    }
}

enum TapDisableAction: Equatable {
    case reenable(attempt: Int)
    case handoff
    case ignore
}

/// 시간 간격을 포함한 tap disable 누적과 단 한 번의 인계를 결정합니다.
struct TapDisableTracker {
    let maximumRetryCount: Int
    let resetInterval: TimeInterval

    private(set) var disableCount = 0
    private var lastDisableTime: TimeInterval?
    private var handedOff = false

    init(maximumRetryCount: Int = 3, resetInterval: TimeInterval = 60) {
        self.maximumRetryCount = maximumRetryCount
        self.resetInterval = resetInterval
    }

    mutating func recordDisable(at time: TimeInterval) -> TapDisableAction {
        guard !handedOff else { return .ignore }

        if let lastDisableTime, time - lastDisableTime > resetInterval {
            disableCount = 0
        }
        lastDisableTime = time
        disableCount += 1

        guard disableCount >= maximumRetryCount else {
            return .reenable(attempt: disableCount)
        }

        handedOff = true
        return .handoff
    }

    mutating func reset() {
        disableCount = 0
        lastDisableTime = nil
        handedOff = false
    }
}

enum SuppressedKeyAction: Equatable {
    case passThrough
    case suppress
    case triggerAndSuppress
}

enum ShortcutBindingRoute: Equatable {
    case toggle
    case hanja
}

/// Key Recorder가 저장하는 modifier snapshot과 동일한 규칙으로
/// 한/영 전환과 한자 단축키 중 하나만 선택합니다.
enum ShortcutBindingRouter {
    private static let recordedModifierMask = CGEventFlags([
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift
    ])

    static func conflicts(_ lhs: KeyBinding, _ rhs: KeyBinding) -> Bool {
        lhs.keyCode == rhs.keyCode
            && normalizedModifiers(lhs.modifiers) == normalizedModifiers(rhs.modifiers)
    }

    static func routeRegularKey(
        keyCode: Int64,
        modifiers: UInt64,
        toggleBinding: KeyBinding,
        hanjaBinding: KeyBinding,
        priTypeToggleEnabled: Bool
    ) -> ShortcutBindingRoute? {
        if priTypeToggleEnabled,
           matchesRegularKey(toggleBinding, keyCode: keyCode, modifiers: modifiers) {
            return .toggle
        }
        if matchesRegularKey(hanjaBinding, keyCode: keyCode, modifiers: modifiers) {
            return .hanja
        }
        return nil
    }

    static func routeModifierKey(
        keyCode: Int64,
        toggleBinding: KeyBinding,
        hanjaBinding: KeyBinding,
        priTypeToggleEnabled: Bool
    ) -> ShortcutBindingRoute? {
        if priTypeToggleEnabled, matchesModifierKey(toggleBinding, keyCode: keyCode) {
            return .toggle
        }
        if matchesModifierKey(hanjaBinding, keyCode: keyCode) {
            return .hanja
        }
        return nil
    }

    private static func matchesRegularKey(
        _ binding: KeyBinding,
        keyCode: Int64,
        modifiers: UInt64
    ) -> Bool {
        !binding.isModifierKey
            && binding.keyCode == keyCode
            && normalizedModifiers(binding.modifiers) == normalizedModifiers(modifiers)
    }

    private static func matchesModifierKey(_ binding: KeyBinding, keyCode: Int64) -> Bool {
        binding.isModifierKey
            && binding.isModifierOnly
            && binding.keyCode == keyCode
    }

    private static func normalizedModifiers(_ modifiers: UInt64) -> UInt64 {
        CGEventFlags(rawValue: modifiers).intersection(recordedModifierMask).rawValue
    }
}

/// Event tap에서 IMK client를 조회하지 않고 판단할 수 있는 마지막 client 상태입니다.
/// 활성화/field 전환 경계의 `.unknown`은 regular 한자키를 host로 통과시킵니다.
enum HanjaShortcutSessionState: Equatable, Sendable {
    case unknown
    case secure
    case nonsecure
}

/// Main-thread IMK 판정 결과를 event-tap thread에 내용 없이 전달합니다.
final class HanjaShortcutSessionStateStore: @unchecked Sendable {
    static let shared = HanjaShortcutSessionStateStore()

    private let lock = NSLock()
    private var storedState: HanjaShortcutSessionState

    var state: HanjaShortcutSessionState {
        lock.withLock { storedState }
    }

    init(initialState: HanjaShortcutSessionState = .unknown) {
        storedState = initialState
    }

    func update(_ state: HanjaShortcutSessionState) {
        lock.withLock {
            storedState = state
        }
    }

    /// Publish only for the process-active controller. Identity is checked in the
    /// same operation used by every controller lifecycle path, so a late callback
    /// cannot accidentally bypass an ad-hoc caller-side guard.
    func update<Owner: AnyObject>(
        _ state: HanjaShortcutSessionState,
        from owner: Owner,
        activeOwner: Owner?
    ) {
        guard let activeOwner, owner === activeOwner else { return }
        update(state)
    }
}

/// Modifier-only 한자키에는 입력 문자가 없으므로 기존 전역 단축키 계약을 유지합니다.
/// 반면 regular/combo 한자키는 현재 field가 nonsecure로 확인된 경우에만 소비합니다.
enum HanjaShortcutSuppressionPolicy {
    static func allowsSuppression(
        binding: KeyBinding,
        sessionState: HanjaShortcutSessionState
    ) -> Bool {
        if binding.isModifierKey && binding.isModifierOnly {
            return true
        }
        return sessionState == .nonsecure
    }
}

/// regular/combo 바인딩의 최초 down, repeat, up을 하나의 route 쌍으로 묶습니다.
struct RegularKeyPressState {
    private var suppressedKeyCodes: Set<Int64> = []
    private var passedThroughKeyCodes: Set<Int64> = []
    private var pendingSuppressedUpKeyCodes: Set<Int64> = []

    var trackedKeyCodes: Set<Int64> {
        suppressedKeyCodes.union(passedThroughKeyCodes)
    }

    mutating func keyDown(
        keyCode: Int64,
        isRepeat: Bool,
        matchesBinding: Bool,
        suppressionAllowed: Bool = true
    ) -> SuppressedKeyAction {
        if !isRepeat {
            // A fresh down starts a new pair even if the disabled tap has not
            // delivered the previous pair's stale suppressed up yet.
            pendingSuppressedUpKeyCodes.remove(keyCode)
        }
        if suppressedKeyCodes.contains(keyCode) {
            return .suppress
        }
        if pendingSuppressedUpKeyCodes.contains(keyCode) {
            return .suppress
        }
        if passedThroughKeyCodes.contains(keyCode) {
            return .passThrough
        }
        // A repeat without an owned initial down may belong to a cycle that already
        // reached the host. Fail open and keep its remaining repeat/up events on
        // that route even if the shortcut starts matching mid-hold.
        if isRepeat {
            passedThroughKeyCodes.insert(keyCode)
            return .passThrough
        }
        guard matchesBinding else { return .passThrough }
        guard suppressionAllowed else {
            passedThroughKeyCodes.insert(keyCode)
            return .passThrough
        }

        suppressedKeyCodes.insert(keyCode)
        return .triggerAndSuppress
    }

    mutating func keyUp(keyCode: Int64) -> SuppressedKeyAction {
        if suppressedKeyCodes.remove(keyCode) != nil {
            return .suppress
        }
        if pendingSuppressedUpKeyCodes.remove(keyCode) != nil {
            return .suppress
        }
        passedThroughKeyCodes.remove(keyCode)
        return .passThrough
    }

    /// Event tap 재활성화 중 놓친 release를 현재 물리 상태로 교정합니다.
    /// 이미 down을 소비한 released key의 지연 up은 한 번 더 소비하되,
    /// passed-through pair에는 별도의 release tombstone을 만들지 않습니다.
    mutating func resynchronize(pressedKeyCodes physicalKeyCodes: Set<Int64>) {
        let releasedSuppressedKeyCodes = suppressedKeyCodes.subtracting(physicalKeyCodes)
        pendingSuppressedUpKeyCodes.formUnion(releasedSuppressedKeyCodes)
        suppressedKeyCodes.formIntersection(physicalKeyCodes)
        passedThroughKeyCodes.formIntersection(physicalKeyCodes)
    }

    mutating func reset() {
        suppressedKeyCodes.removeAll()
        passedThroughKeyCodes.removeAll()
        pendingSuppressedUpKeyCodes.removeAll()
    }
}

enum ReleaseToggleAction: Equatable {
    case none
    case pressed
    case repeatIgnored
    case chorded
    case released(shouldToggle: Bool)
}

/// IOKit fallback의 modifier-only 키를 release에서 한 번만 전환합니다.
struct ReleaseTogglePressState {
    private(set) var isDown = false
    private var usedWithOtherKey = false

    mutating func handle(usage: UInt32, pressed: Bool, toggleUsage: UInt32) -> ReleaseToggleAction {
        if usage == toggleUsage {
            if pressed {
                guard !isDown else { return .repeatIgnored }
                isDown = true
                usedWithOtherKey = false
                return .pressed
            }

            guard isDown else { return .none }
            let shouldToggle = !usedWithOtherKey
            reset()
            return .released(shouldToggle: shouldToggle)
        }

        guard isDown, pressed else { return .none }
        usedWithOtherKey = true
        return .chorded
    }

    mutating func reset() {
        isDown = false
        usedWithOtherKey = false
    }
}

/// IOKit modifier press 하나의 DEBUG 지연 trace를 물리 down부터 release까지 보존합니다.
struct IOKitToggleTraceLifecycle {
    private(set) var hasPendingTrace = false

    #if DEBUG
    private var pendingTrace: ToggleLatencyTrace?
    #endif

    mutating func begin() {
        cancel()
        hasPendingTrace = true

        #if DEBUG
        pendingTrace = ToggleLatencyTrace.begin(source: .iokitFallback)
        #endif
    }

    mutating func finish() -> ToggleLatencyTrace? {
        guard hasPendingTrace else { return nil }
        hasPendingTrace = false

        #if DEBUG
        defer { pendingTrace = nil }
        return pendingTrace
        #else
        // Release builds retain only the no-op trace API and perform no timing work.
        return ToggleLatencyTrace.begin(source: .iokitFallback)
        #endif
    }

    mutating func cancel() {
        guard hasPendingTrace else { return }
        hasPendingTrace = false

        #if DEBUG
        pendingTrace?.mark(.ignored)
        pendingTrace = nil
        #endif
    }
}

enum ModifierKeyTransition: Equatable {
    case down
    case up
    case unknown
}

/// `flagsChanged`의 side keyCode와 현재 물리 키 상태를 함께 보존합니다.
struct ModifierKeyPressState {
    private(set) var pressedKeyCodes: Set<Int64> = []
    private var suppressedKeyCodes: Set<Int64> = []

    mutating func observe(keyCode: Int64, physicalKeyIsDown: Bool) -> ModifierKeyTransition {
        if physicalKeyIsDown {
            return pressedKeyCodes.insert(keyCode).inserted ? .down : .unknown
        }

        return pressedKeyCodes.remove(keyCode) == nil ? .unknown : .up
    }

    /// Event tap 시작/재활성화 중 놓친 down/up을 현재 물리 상태로 교정합니다.
    mutating func resynchronize(pressedKeyCodes physicalKeyCodes: Set<Int64>) {
        pressedKeyCodes = physicalKeyCodes
        suppressedKeyCodes.formIntersection(physicalKeyCodes)
    }

    mutating func suppressUntilRelease(keyCode: Int64) {
        suppressedKeyCodes.insert(keyCode)
    }

    mutating func consumeSuppressedRelease(keyCode: Int64) -> Bool {
        suppressedKeyCodes.remove(keyCode) != nil
    }

    func isSuppressed(keyCode: Int64) -> Bool {
        suppressedKeyCodes.contains(keyCode)
    }

    func hasPressedSibling(of keyCode: Int64, sharingKeyCodes: Set<Int64>) -> Bool {
        !pressedKeyCodes.intersection(sharingKeyCodes.subtracting([keyCode])).isEmpty
    }

    mutating func reset() {
        pressedKeyCodes.removeAll()
        suppressedKeyCodes.removeAll()
    }
}
