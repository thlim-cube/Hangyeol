import Testing
@testable import HangyeolCore

@Suite("InputSourceManager")
struct InputSourceManagerTests {
    private let hangyeolParent: [String: Any] = [
        "Bundle ID": "com.thlim.inputmethod.Hangyeol",
        "InputSourceKind": "Keyboard Input Method"
    ]

    private let currentHangyeolMode: [String: Any] = [
        "Bundle ID": "com.thlim.inputmethod.Hangyeol",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.thlim.inputmethod.Hangyeol"
    ]

    private let retiredHangyeolMode: [String: Any] = [
        "Bundle ID": "com.thlim.inputmethod.Hangyeol",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.thlim.inputmethod.Hangyeol.english"
    ]

    @Test("Keeps Hangyeol parent and Korean mode while removing retired English mode")
    func keepsHangyeolParentAndKoreanModeOnly() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.thlim.inputmethod.Hangyeol"
            ],
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.thlim.inputmethod.Hangyeol.english"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 2)
        #expect(sanitized.contains { $0["Input Mode"] == nil })  // parent
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.thlim.inputmethod.Hangyeol" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.thlim.inputmethod.Hangyeol.english" })
    }

    @Test("Keeps Hangyeol parent and removes stale child modes from selected and history sources")
    func keepsHangyeolParentAndRemovesStaleChildModesFromSelectedAndHistorySources() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.thlim.inputmethod.Hangyeol"
            ],
            [
                "Bundle ID": "com.thlim.inputmethod.Hangyeol",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.thlim.inputmethod.Hangyeol.korean"
            ],
            [
                "Bundle ID": "com.apple.PressAndHold",
                "InputSourceKind": "Non Keyboard Input Method"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 3)
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.thlim.inputmethod.Hangyeol" && $0["Input Mode"] == nil })
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.thlim.inputmethod.Hangyeol" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.thlim.inputmethod.Hangyeol.korean" })
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.apple.PressAndHold" })
    }

    @Test("Recognizes an existing install from selected or history sources")
    func recognizesExistingInstallOutsideEnabledSources() {
        #expect(!InputSourceManager.hasCurrentHangyeolRegistration(in: []))
        #expect(InputSourceManager.hasCurrentHangyeolRegistration(in: [hangyeolParent]))
        #expect(InputSourceManager.hasCurrentHangyeolRegistration(in: [currentHangyeolMode]))
    }

    @Test("Retired child modes do not make a stale install current")
    func retiredModeIsNotCurrentRegistration() {
        #expect(!InputSourceManager.hasCurrentHangyeolRegistration(in: [retiredHangyeolMode]))
    }

    @Test("Removes the 2.x product registration during 3.0 migration")
    func removesLegacy2xRegistration() {
        let legacySource: [String: Any] = [
            "Bundle ID": Legacy2xIdentity.bundleID,
            "InputSourceKind": "Input Mode",
            "Input Mode": Legacy2xIdentity.bundleID
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            [legacySource, currentHangyeolMode],
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 1)
        #expect(InputSourceManager.hasCurrentHangyeolRegistration(in: sanitized))
    }

    @Test("Removes the retired com.meapri registration after the identifier change")
    func removesLegacy3xRegistration() {
        let legacySource: [String: Any] = [
            "Bundle ID": "com.meapri.hangyeol.inputmethod",
            "InputSourceKind": "Input Mode",
            "Input Mode": "com.meapri.hangyeol.inputmethod"
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            [legacySource, currentHangyeolMode],
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 1)
        #expect(InputSourceManager.hasCurrentHangyeolRegistration(in: sanitized))
    }

    @Test("Removes the misordered com.thlim 3.0 registration")
    func removesMisordered3xRegistration() {
        let legacySource: [String: Any] = [
            "Bundle ID": Misordered3xIdentity.bundleID,
            "InputSourceKind": "Input Mode",
            "Input Mode": Misordered3xIdentity.bundleID
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            [legacySource, currentHangyeolMode],
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 1)
        #expect(InputSourceManager.hasCurrentHangyeolRegistration(in: sanitized))
    }

    @Test("Cleanup plan detects current registration across every HIToolbox collection")
    func cleanupPlanUsesAllHIToolboxCollections() {
        let plan = InputSourceManager.cleanupPlan(
            enabledSources: [retiredHangyeolMode],
            selectedSources: [currentHangyeolMode],
            historySources: [hangyeolParent, hangyeolParent]
        )

        #expect(plan.result.hasCurrentHangyeolRegistration)
        #expect(plan.enabledSources.isEmpty)
        #expect(plan.selectedSources.count == 1)
        #expect(plan.historySources.count == 1)
        #expect(plan.result.didChange)
    }

    @Test("Authoritative status requires both registered candidates to be enabled")
    func authoritativeStatusRequiresCompleteActivation() {
        let ready = InputSourceInstallationStatus(
            hasRequiredCandidates: true,
            isEnabled: true
        )
        let missingMode = InputSourceInstallationStatus(
            hasRequiredCandidates: false,
            isEnabled: true
        )
        let awaitingConsent = InputSourceInstallationStatus(
            hasRequiredCandidates: true,
            isEnabled: false
        )

        #expect(ready.isReady)
        #expect(!missingMode.isReady)
        #expect(!awaitingConsent.isReady)
    }
}
