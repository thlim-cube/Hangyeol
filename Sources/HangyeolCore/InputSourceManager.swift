import Foundation
import Carbon

public struct InputSourceCleanupResult: Sendable {
    public let hasCurrentHangyeolRegistration: Bool
    public let didChange: Bool
}

public struct InputSourceInstallationResult: Sendable {
    public let registrationStatus: OSStatus
    public let firstEnableFailure: OSStatus?
    public let selectionStatus: OSStatus?
    public let isReady: Bool
}

internal struct InputSourceCleanupPlan {
    let enabledSources: [[String: Any]]
    let selectedSources: [[String: Any]]
    let historySources: [[String: Any]]
    let result: InputSourceCleanupResult
}

internal struct InputSourceInstallationCandidate: Equatable {
    let inputSourceID: String
    let inputModeID: String?
    let inputSourceType: String
    let isEnabled: Bool
    let isEnableCapable: Bool
    let isSelectCapable: Bool
}

internal struct InputSourceInstallationPlan {
    let candidatesToEnable: [InputSourceInstallationCandidate]
    let enabledMode: InputSourceInstallationCandidate?
    let hasRequiredCandidates: Bool
    let isEnabled: Bool
}

private final class InputSourceChangeMonitor: @unchecked Sendable {
    private let center = DistributedNotificationCenter.default()
    private var observerTokens: [NSObjectProtocol] = []
    private var didObserveChange = false

    init() {
        let notificationNames = [
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        ]
        observerTokens = notificationNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.didObserveChange = true
            }
        }
    }

    deinit {
        observerTokens.forEach(center.removeObserver)
    }

    func waitForChange(until deadline: Date) -> Bool {
        let timeoutTimer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
        RunLoop.current.add(timeoutTimer, forMode: .default)
        defer { timeoutTimer.invalidate() }

        while !didObserveChange && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
        let observedChange = didObserveChange
        didObserveChange = false
        return observedChange
    }
}

// MARK: - InputSourceManager

/// Manages macOS input-source queries, installer registration, and stale
/// preference cleanup.
///
/// Custom Hangyeol language toggles must not call `TISSelectInputSource`.
/// Runtime mode switching is coordinated by `InputModeCoordinator` and
/// `HangyeolInputController`; this type stays off the typing hot path.
///
/// ## Usage
/// ```swift
/// let sources = InputSourceManager.shared.getEnabledKeyboardInputSources()
/// let isABCEnabled = InputSourceManager.shared.isABCEnabled()
/// ```
public final class InputSourceManager: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// Shared instance
    public static let shared = InputSourceManager()
    
    private init() {}
    
    // MARK: - Constants
    
    /// Keyboard Layout ID for ABC (252)
    public static let abcKeyboardLayoutID = 252

    private static let hangyeolBundleID = ProductIdentity.bundleID
    private static let hangyeolKoreanInputMode = ProductIdentity.inputModeID
    private static let currentHangyeolInputModes: Set<String> = [
        hangyeolKoreanInputMode
    ]
    
    // MARK: - TIS API Methods
    
    /// Get a list of all enabled keyboard input sources using TIS API
    public func getEnabledKeyboardInputSources() -> [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true
        ]
        
        guard let sourceList = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return result
        }
        
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
               let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
                result.append((id: id, name: name))
            }
        }
        
        return result
    }
    
    /// Check if ABC is enabled via TIS API
    public func isABCEnabled() -> Bool {
        let sources = getEnabledKeyboardInputSources()
        return sources.contains { $0.name == "ABC" || $0.id.contains("ABC") }
    }
    
    /// Check if US is enabled via TIS API  
    public func isUSEnabled() -> Bool {
        let sources = getEnabledKeyboardInputSources()
        return sources.contains { $0.id.contains("US") || $0.name == "U.S." }
    }

    /// Remove stale legacy entries without enabling or selecting input sources.
    ///
    /// This intentionally does not enable Hangyeol itself. Calling
    /// `TISEnableInputSource` for the running input method can make macOS show
    /// an "add input source" confirmation again on startup.
    @discardableResult
    public func cleanupStaleInputSources() -> InputSourceCleanupResult {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else {
            DebugLogger.log("InputSourceManager: failed to open HIToolbox defaults")
            return Self.cleanupPlan(
                enabledSources: [],
                selectedSources: [],
                historySources: []
            ).result
        }

        let originalEnabledSources = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        let originalSelectedSources = defaults.array(forKey: "AppleSelectedInputSources") as? [[String: Any]] ?? []
        let originalHistorySources = defaults.array(forKey: "AppleInputSourceHistory") as? [[String: Any]] ?? []
        let plan = Self.cleanupPlan(
            enabledSources: originalEnabledSources,
            selectedSources: originalSelectedSources,
            historySources: originalHistorySources
        )

        if !Self.inputSourcesEqual(plan.enabledSources, originalEnabledSources) {
            defaults.set(plan.enabledSources, forKey: "AppleEnabledInputSources")
        }
        if !Self.inputSourcesEqual(plan.selectedSources, originalSelectedSources) {
            defaults.set(plan.selectedSources, forKey: "AppleSelectedInputSources")
        }
        if !Self.inputSourcesEqual(plan.historySources, originalHistorySources) {
            defaults.set(plan.historySources, forKey: "AppleInputSourceHistory")
        }

        guard plan.result.didChange else {
            DebugLogger.log("InputSourceManager: stale Hangyeol input-source cleanup already current")
            return plan.result
        }

        defaults.synchronize()
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        DebugLogger.log("InputSourceManager: cleaned stale Hangyeol input-source entries")
        return plan.result
    }

    /// Register and enable the installed Hangyeol bundle in the current GUI
    /// user's TIS domain. This is installer-only and must stay off app startup
    /// and the typing hot path.
    @discardableResult
    public func prepareInstalledInputSource(
        at appURL: URL,
        selectIfUnconfigured: Bool,
        restorePreviousSelection: Bool
    ) -> InputSourceInstallationResult {
        let changeMonitor = InputSourceChangeMonitor()
        let cleanupResult = cleanupStaleInputSources()
        let registrationStatus = TISRegisterInputSource(appURL as CFURL)
        let discoveredRecords = installationRecords(
            waitingUntil: { $0.hasRequiredCandidates },
            changeMonitor: changeMonitor
        )
        let discoveryPlan = Self.installationPlan(from: discoveredRecords.map(\.candidate))

        var firstEnableFailure: OSStatus?
        // TIS may hand the installer a cached `isEnabled=true` record from the
        // replaced bundle. Reassert both identities so the new registration is
        // persisted instead of disappearing when the system cache refreshes.
        for candidate in discoveryPlan.candidatesToEnable {
            guard let source = discoveredRecords.first(where: {
                $0.candidate.inputSourceID == candidate.inputSourceID
            })?.source else {
                firstEnableFailure = firstEnableFailure ?? OSStatus(paramErr)
                continue
            }

            let status = TISEnableInputSource(source)
            if status != noErr {
                firstEnableFailure = firstEnableFailure ?? status
            }
        }

        let enabledRecords = installationRecords(
            waitingUntil: { $0.isEnabled },
            changeMonitor: changeMonitor
        )
        let enabledPlan = Self.installationPlan(from: enabledRecords.map(\.candidate))

        let shouldSelect = Self.shouldSelectInstalledInputSource(
            selectIfUnconfigured: selectIfUnconfigured,
            hasCurrentRegistration: cleanupResult.hasCurrentHangyeolRegistration,
            restorePreviousSelection: restorePreviousSelection
        )
        var selectionStatus: OSStatus?
        if shouldSelect, let enabledMode = enabledPlan.enabledMode {
            guard let modeSource = enabledRecords.first(where: {
                $0.candidate.inputSourceID == enabledMode.inputSourceID
            })?.source else {
                selectionStatus = OSStatus(paramErr)
                return InputSourceInstallationResult(
                    registrationStatus: registrationStatus,
                    firstEnableFailure: firstEnableFailure,
                    selectionStatus: selectionStatus,
                    isReady: false
                )
            }
            selectionStatus = TISSelectInputSource(modeSource)
            if selectionStatus == noErr && !isHangyeolSelected() {
                _ = changeMonitor.waitForChange(
                    until: Date().addingTimeInterval(Self.postInstallSettlementTimeout)
                )
            }
        }

        let selectionSucceeded = !shouldSelect
            || (selectionStatus == noErr && isHangyeolSelected())
        return InputSourceInstallationResult(
            registrationStatus: registrationStatus,
            firstEnableFailure: firstEnableFailure,
            selectionStatus: selectionStatus,
            isReady: registrationStatus == noErr
                && firstEnableFailure == nil
                && enabledPlan.isEnabled
                && selectionSucceeded
        )
    }

    internal static func installationPlan(
        from candidates: [InputSourceInstallationCandidate]
    ) -> InputSourceInstallationPlan {
        let orderedCandidates = installationCandidates(from: candidates)
        let parent = orderedCandidates.first { installationRole(of: $0) == 0 }
        let mode = orderedCandidates.first { installationRole(of: $0) == 1 }
        return InputSourceInstallationPlan(
            candidatesToEnable: orderedCandidates,
            enabledMode: mode?.isEnabled == true ? mode : nil,
            hasRequiredCandidates: parent != nil && mode != nil,
            isEnabled: parent?.isEnabled == true && mode?.isEnabled == true
        )
    }

    internal static func settleInstallationState<State>(
        initial: State,
        isSettled: (State) -> Bool,
        waitForChange: () -> Bool,
        reload: () -> State
    ) -> State {
        var state = initial
        while !isSettled(state) {
            let observedChange = waitForChange()
            state = reload()
            if !observedChange {
                break
            }
        }
        return state
    }

    internal static func installationCandidates(
        from candidates: [InputSourceInstallationCandidate]
    ) -> [InputSourceInstallationCandidate] {
        candidates
            .filter { installationRole(of: $0) != nil && $0.isEnableCapable }
            .sorted {
                (installationRole(of: $0) ?? Int.max)
                    < (installationRole(of: $1) ?? Int.max)
            }
    }

    internal static func shouldSelectInstalledInputSource(
        selectIfUnconfigured: Bool,
        hasCurrentRegistration: Bool,
        restorePreviousSelection: Bool
    ) -> Bool {
        restorePreviousSelection || (selectIfUnconfigured && !hasCurrentRegistration)
    }

    private struct InputSourceInstallationRecord {
        let source: TISInputSource
        let candidate: InputSourceInstallationCandidate
    }

    private static let postInstallSettlementTimeout: TimeInterval = 10

    private func installationRecords(
        waitingUntil condition: (InputSourceInstallationPlan) -> Bool,
        changeMonitor: InputSourceChangeMonitor
    ) -> [InputSourceInstallationRecord] {
        let deadline = Date().addingTimeInterval(Self.postInstallSettlementTimeout)
        return Self.settleInstallationState(
            initial: hangyeolInstallationRecords(),
            isSettled: { records in
                condition(Self.installationPlan(from: records.map(\.candidate)))
            },
            waitForChange: {
                changeMonitor.waitForChange(until: deadline)
            },
            reload: {
                hangyeolInstallationRecords()
            }
        )
    }

    private func isHangyeolSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        return Self.stringProperty(kTISPropertyInputModeID, from: source)
            == Self.hangyeolKoreanInputMode
    }

    private func hangyeolInstallationRecords() -> [InputSourceInstallationRecord] {
        let filter = [
            kTISPropertyBundleID as String: Self.hangyeolBundleID
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
            as? [TISInputSource] else {
            return []
        }

        return sources.compactMap { source in
            guard let inputSourceID = Self.stringProperty(
                kTISPropertyInputSourceID,
                from: source
            ), let inputSourceType = Self.stringProperty(
                kTISPropertyInputSourceType,
                from: source
            ) else {
                return nil
            }
            return InputSourceInstallationRecord(
                source: source,
                candidate: InputSourceInstallationCandidate(
                    inputSourceID: inputSourceID,
                    inputModeID: Self.stringProperty(kTISPropertyInputModeID, from: source),
                    inputSourceType: inputSourceType,
                    isEnabled: Self.boolProperty(kTISPropertyInputSourceIsEnabled, from: source),
                    isEnableCapable: Self.boolProperty(
                        kTISPropertyInputSourceIsEnableCapable,
                        from: source
                    ),
                    isSelectCapable: Self.boolProperty(
                        kTISPropertyInputSourceIsSelectCapable,
                        from: source
                    )
                )
            )
        }
    }

    private static func installationRole(
        of candidate: InputSourceInstallationCandidate
    ) -> Int? {
        if candidate.inputSourceID == hangyeolBundleID,
           candidate.inputSourceType == kTISTypeKeyboardInputMethodModeEnabled as String,
           !candidate.isSelectCapable {
            return 0
        }
        if candidate.inputModeID == hangyeolKoreanInputMode,
           candidate.inputSourceType == kTISTypeKeyboardInputMode as String,
           candidate.isSelectCapable {
            return 1
        }
        return nil
    }

    private static func stringProperty(
        _ key: CFString,
        from source: TISInputSource
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(
        _ key: CFString,
        from source: TISInputSource
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return false
        }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }

    internal static func cleanupPlan(
        enabledSources: [[String: Any]],
        selectedSources: [[String: Any]],
        historySources: [[String: Any]]
    ) -> InputSourceCleanupPlan {
        let sanitizedEnabledSources = sanitizedInputSources(
            enabledSources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )
        let sanitizedSelectedSources = sanitizedInputSources(
            selectedSources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )
        let sanitizedHistorySources = sanitizedInputSources(
            historySources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )
        let hasCurrentRegistration = [
            sanitizedEnabledSources,
            sanitizedSelectedSources,
            sanitizedHistorySources
        ].contains { hasCurrentHangyeolRegistration(in: $0) }

        let result = InputSourceCleanupResult(
            hasCurrentHangyeolRegistration: hasCurrentRegistration,
            didChange: !inputSourcesEqual(sanitizedEnabledSources, enabledSources)
                || !inputSourcesEqual(sanitizedSelectedSources, selectedSources)
                || !inputSourcesEqual(sanitizedHistorySources, historySources)
        )
        return InputSourceCleanupPlan(
            enabledSources: sanitizedEnabledSources,
            selectedSources: sanitizedSelectedSources,
            historySources: sanitizedHistorySources,
            result: result
        )
    }

    internal static func hasCurrentHangyeolRegistration(in sources: [[String: Any]]) -> Bool {
        sources.contains { source in
            guard (source["Bundle ID"] as? String) == hangyeolBundleID else {
                return false
            }
            guard let inputMode = source["Input Mode"] as? String else {
                return true
            }
            return currentHangyeolInputModes.contains(inputMode)
        }
    }

    private static func inputSourcesEqual(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        (lhs as NSArray).isEqual(to: rhs)
    }

    internal static func sanitizedInputSources(
        _ sources: [[String: Any]],
        removeAppleKoreanInputModes: Bool,
        allowsHangyeolParentEntry: Bool
    ) -> [[String: Any]] {
        var seen = Set<String>()

        return sources.compactMap { source in
            if shouldRemoveInputSource(
                source,
                removeAppleKoreanInputModes: removeAppleKoreanInputModes,
                allowsHangyeolParentEntry: allowsHangyeolParentEntry
            ) {
                return nil
            }

            let key = inputSourceIdentity(source)
            guard seen.insert(key).inserted else {
                return nil
            }

            return source
        }
    }

    private static func shouldRemoveInputSource(
        _ source: [String: Any],
        removeAppleKoreanInputModes: Bool,
        allowsHangyeolParentEntry: Bool
    ) -> Bool {
        if (source["Bundle ID"] as? String) == Legacy2xIdentity.bundleID {
            return true
        }

        if (source["Bundle ID"] as? String) == hangyeolBundleID {
            let inputMode = source["Input Mode"] as? String
            guard let inputMode else {
                return !allowsHangyeolParentEntry
            }
            if !currentHangyeolInputModes.contains(inputMode) {
                return true
            }
            return false
        }

        if removeAppleKoreanInputModes,
           Self.appleKoreanInputMethodBundleIDs.contains(source["Bundle ID"] as? String ?? ""),
           source["InputSourceKind"] as? String == "Input Mode" {
            return true
        }

        return false
    }

    private static let appleKoreanInputMethodBundleIDs: Set<String> = [
        "com.apple.inputmethod.Korean",
        "com.apple.inputmethod.ironwood"
    ]

    private static func inputSourceIdentity(_ source: [String: Any]) -> String {
        [
            source["InputSourceKind"] as? String ?? "",
            source["Bundle ID"] as? String ?? "",
            source["Input Mode"] as? String ?? "",
            "\(source["KeyboardLayout ID"] as? Int ?? Int.min)",
            source["KeyboardLayout Name"] as? String ?? ""
        ].joined(separator: "\u{1F}")
    }
}
