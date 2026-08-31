import Foundation
import Carbon
import HangyeolInstallerSupport

public struct InputSourceCleanupResult: Sendable {
    public let hasCurrentHangyeolRegistration: Bool
    public let didChange: Bool
}

public struct InputSourceInstallationStatus: Sendable {
    public let hasRequiredCandidates: Bool
    public let isEnabled: Bool

    public var isReady: Bool {
        hasRequiredCandidates && isEnabled
    }
}

internal struct InputSourceCleanupPlan {
    let enabledSources: [[String: Any]]
    let selectedSources: [[String: Any]]
    let historySources: [[String: Any]]
    let result: InputSourceCleanupResult
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
    private static let installerIdentity = InstallerInputSourceIdentity(
        bundleID: ProductIdentity.bundleID,
        modeID: ProductIdentity.inputModeID
    )
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

    /// Returns the TIS view visible to the current process. Installer readiness
    /// must call this from a process other than the one that requested
    /// activation so an uncommitted caller-local cache cannot pass the check.
    public func installedInputSourceStatus() -> InputSourceInstallationStatus {
        let installedRoster = InputSourceLifecycleRules.roster(
            from: hangyeolInstallationRecords(
                includeAllInstalled: true
            ).map(\.candidate),
            identity: Self.installerIdentity
        )
        let enabledRoster = InputSourceLifecycleRules.roster(
            from: hangyeolInstallationRecords(
                includeAllInstalled: false
            ).map(\.candidate),
            identity: Self.installerIdentity
        )
        return InputSourceInstallationStatus(
            hasRequiredCandidates: installedRoster.hasUniquePair,
            isEnabled: enabledRoster.isEnabled
        )
    }

    /// Executes exactly one installer TIS phase. The installer coordinator runs
    /// every action and verifier in a separate signed process so a caller-local
    /// TIS cache can never satisfy its own success check.
    public func runInstallerPhase(
        _ phase: InstallerActivationPhase,
        fallbackSourceID: String? = nil,
        appURL: URL
    ) -> Int32 {
        switch phase {
        case .register:
            _ = cleanupStaleInputSources()
            let status = TISRegisterInputSource(appURL as CFURL)
            print("installer: register status=\(status) path=\(appURL.path)")
            return status == noErr
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .verifyInstalled:
            let roster = installationRoster(includeAllInstalled: true)
            print(
                "installer: verify-installed parent=\(roster.parentCount) "
                    + "mode=\(roster.modeCount) ready=\(roster.hasUniquePair)"
            )
            return roster.hasUniquePair
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .enableParent:
            guard let record = uniqueRecord(
                role: .parent,
                includeAllInstalled: true
            ) else {
                return InstallerPhaseExit.retryable
            }
            let status = TISEnableInputSource(record.source)
            print("installer: enable-parent status=\(status)")
            return status == noErr
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .verifyParent:
            let roster = installationRoster(includeAllInstalled: false)
            let ready = roster.parentCount == 1
                && roster.parent?.isEnabled == true
            print("installer: verify-parent ready=\(ready)")
            return ready
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .enableMode:
            let enabledRoster = installationRoster(includeAllInstalled: false)
            guard enabledRoster.parentCount == 1,
                  enabledRoster.parent?.isEnabled == true,
                  let record = uniqueRecord(
                    role: .mode,
                    includeAllInstalled: true
                  ) else {
                return InstallerPhaseExit.retryable
            }
            let status = TISEnableInputSource(record.source)
            print("installer: enable-mode status=\(status)")
            return status == noErr
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .verifyMode:
            let roster = installationRoster(includeAllInstalled: false)
            print("installer: verify-mode ready=\(roster.isEnabled)")
            return roster.isEnabled
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .selectMode:
            guard installationRoster(includeAllInstalled: false).isEnabled,
                  let record = uniqueRecord(
                    role: .mode,
                    includeAllInstalled: false
                  ) else {
                return InstallerPhaseExit.retryable
            }
            let status = TISSelectInputSource(record.source)
            print("installer: select-mode status=\(status)")
            return status == noErr
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .verifySelected:
            let selected = isHangyeolSelected()
            print("installer: verify-selected ready=\(selected)")
            return selected
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .disableTemporaryFallback:
            guard isHangyeolSelected(),
                  let fallbackSourceID,
                  let record = fallbackRecord(sourceID: fallbackSourceID) else {
                return InstallerPhaseExit.failed
            }
            if record.candidate.isEnabled {
                let status = TISDisableInputSource(record.source)
                print(
                    "installer: disable-temporary-fallback status=\(status)"
                )
            }
            let removed = removeEnabledKeyboardLayout(
                matching: fallbackSourceID
            )
            print(
                "installer: disable-temporary-fallback removed-from-enabled=\(removed)"
            )
            return removed
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable

        case .verifyTemporaryFallbackDisabled:
            guard installationRoster(includeAllInstalled: false).isEnabled,
                  isHangyeolSelected(),
                  fallbackSourceID != nil else {
                return InstallerPhaseExit.failed
            }
            let disabled = !isEnabledKeyboardLayoutPresent(
                matching: fallbackSourceID!
            )
            print(
                "installer: verify-temporary-fallback-disabled ready=\(disabled)"
            )
            return disabled
                ? InstallerPhaseExit.success
                : InstallerPhaseExit.retryable
        }
    }

    private struct InputSourceInstallationRecord {
        let source: TISInputSource
        let candidate: InstallerInputSourceCandidate
    }

    private func installationRoster(
        includeAllInstalled: Bool
    ) -> InstallerInputSourceRoster {
        InputSourceLifecycleRules.roster(
            from: hangyeolInstallationRecords(
                includeAllInstalled: includeAllInstalled
            ).map(\.candidate),
            identity: Self.installerIdentity
        )
    }

    private func uniqueRecord(
        role: InstallerInputSourceRole,
        includeAllInstalled: Bool
    ) -> InputSourceInstallationRecord? {
        let matches = hangyeolInstallationRecords(
            includeAllInstalled: includeAllInstalled
        ).filter {
            InputSourceLifecycleRules.role(
                of: $0.candidate,
                identity: Self.installerIdentity
            ) == role
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isHangyeolSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue(),
              let record = Self.installationRecord(for: source) else {
            return false
        }
        return Self.installerIdentity.owns(record.candidate)
            && InputSourceLifecycleRules.role(
                of: record.candidate,
                identity: Self.installerIdentity
            ) == .mode
    }

    private func fallbackRecord(
        sourceID: String
    ) -> InputSourceInstallationRecord? {
        let filter = [
            kTISPropertyInputSourceID as String: sourceID
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(
            filter,
            true
        )?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        let records = sources.compactMap(Self.installationRecord(for:))
            .filter { $0.candidate.sourceID == sourceID }
        guard records.count == 1 else { return nil }
        let safe = InputSourceLifecycleRules.safeFallbackCandidates(
            from: [records[0].candidate],
            identity: Self.installerIdentity
        )
        return safe.count == 1 ? records[0] : nil
    }

    private func isEnabledKeyboardLayoutPresent(matching sourceID: String) -> Bool {
        enabledKeyboardLayouts().contains { Self.keyboardLayout($0, matches: sourceID) }
    }

    @discardableResult
    private func removeEnabledKeyboardLayout(matching sourceID: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else {
            return false
        }
        let original = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        let filtered = Self.removingKeyboardLayout(original, matching: sourceID)
        guard !Self.inputSourcesEqual(filtered, original) else {
            return true
        }
        defaults.set(filtered, forKey: "AppleEnabledInputSources")
        defaults.synchronize()
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        return true
    }

    private func enabledKeyboardLayouts() -> [[String: Any]] {
        UserDefaults(suiteName: "com.apple.HIToolbox")?
            .array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
    }

    internal static func removingKeyboardLayout(
        _ sources: [[String: Any]],
        matching sourceID: String
    ) -> [[String: Any]] {
        sources.filter { !keyboardLayout($0, matches: sourceID) }
    }

    internal static func keyboardLayout(
        _ source: [String: Any],
        matches sourceID: String
    ) -> Bool {
        if (source["InputSourceKind"] as? String) != "Keyboard Layout" {
            return false
        }
        if sourceID == "com.apple.keylayout.ABC" {
            let layoutID = source["KeyboardLayout ID"] as? Int
                ?? (source["KeyboardLayout ID"] as? NSNumber)?.intValue
            return (source["KeyboardLayout Name"] as? String) == "ABC"
                || layoutID == abcKeyboardLayoutID
        }
        if let layoutName = sourceID.split(separator: ".").last {
            return (source["KeyboardLayout Name"] as? String) == String(layoutName)
        }
        return false
    }

    private func hangyeolInstallationRecords(
        includeAllInstalled: Bool
    ) -> [InputSourceInstallationRecord] {
        let filter = [
            kTISPropertyBundleID as String: Self.hangyeolBundleID
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(
            filter,
            includeAllInstalled
        )?.takeRetainedValue()
            as? [TISInputSource] else {
            return []
        }

        return sources.compactMap(Self.installationRecord(for:))
    }

    private static func installationRecord(
        for source: TISInputSource
    ) -> InputSourceInstallationRecord? {
        guard let inputSourceID = stringProperty(
            kTISPropertyInputSourceID,
            from: source
        ), let inputSourceType = stringProperty(
            kTISPropertyInputSourceType,
            from: source
        ) else {
            return nil
        }
        return InputSourceInstallationRecord(
            source: source,
            candidate: InstallerInputSourceCandidate(
                sourceID: inputSourceID,
                bundleID: stringProperty(kTISPropertyBundleID, from: source),
                modeID: stringProperty(kTISPropertyInputModeID, from: source),
                kind: installerSourceKind(inputSourceType),
                isEnabled: boolProperty(
                    kTISPropertyInputSourceIsEnabled,
                    from: source
                ),
                isEnableCapable: boolProperty(
                    kTISPropertyInputSourceIsEnableCapable,
                    from: source
                ),
                isSelectCapable: boolProperty(
                    kTISPropertyInputSourceIsSelectCapable,
                    from: source
                ),
                isASCIICapable: boolProperty(
                    kTISPropertyInputSourceIsASCIICapable,
                    from: source
                )
            )
        )
    }

    private static func installerSourceKind(
        _ sourceType: String
    ) -> InstallerInputSourceKind {
        if sourceType == kTISTypeKeyboardInputMethodModeEnabled as String {
            return .inputMethodParent
        }
        if sourceType == kTISTypeKeyboardInputMode as String {
            return .inputMode
        }
        return .other
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
        if (source["Bundle ID"] as? String) == Misordered3xIdentity.bundleID
            || (source["Bundle ID"] as? String) == Legacy3xIdentity.bundleID
            || (source["Bundle ID"] as? String) == Legacy2xIdentity.bundleID {
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
