import Testing
@testable import PriTypeCore

@Suite("InputSourceManager")
struct InputSourceManagerTests {
    private let priTypeParent: [String: Any] = [
        "Bundle ID": "com.pritype.inputmethod.v2",
        "InputSourceKind": "Keyboard Input Method"
    ]

    private let currentPriTypeMode: [String: Any] = [
        "Bundle ID": "com.pritype.inputmethod.v2",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.pritype.inputmethod.v2"
    ]

    private let retiredPriTypeMode: [String: Any] = [
        "Bundle ID": "com.pritype.inputmethod.v2",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.pritype.inputmethod.v2.english"
    ]

    @Test("Keeps PriType parent and Korean mode while removing retired English mode")
    func keepsPriTypeParentAndKoreanModeOnly() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2.english"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsPriTypeParentEntry: true
        )

        #expect(sanitized.count == 2)
        #expect(sanitized.contains { $0["Input Mode"] == nil })  // parent
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2.english" })
    }

    @Test("Keeps PriType parent and removes stale child modes from selected and history sources")
    func keepsPriTypeParentAndRemovesStaleChildModesFromSelectedAndHistorySources() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2.korean"
            ],
            [
                "Bundle ID": "com.apple.PressAndHold",
                "InputSourceKind": "Non Keyboard Input Method"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsPriTypeParentEntry: true
        )

        #expect(sanitized.count == 3)
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.pritype.inputmethod.v2" && $0["Input Mode"] == nil })
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2.korean" })
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.apple.PressAndHold" })
    }

    @Test("Recognizes an existing install from selected or history sources")
    func recognizesExistingInstallOutsideEnabledSources() {
        #expect(!InputSourceManager.hasCurrentPriTypeRegistration(in: []))
        #expect(InputSourceManager.hasCurrentPriTypeRegistration(in: [priTypeParent]))
        #expect(InputSourceManager.hasCurrentPriTypeRegistration(in: [currentPriTypeMode]))
    }

    @Test("Retired child modes do not make a stale install current")
    func retiredModeIsNotCurrentRegistration() {
        #expect(!InputSourceManager.hasCurrentPriTypeRegistration(in: [retiredPriTypeMode]))
    }

    @Test("Cleanup plan detects current registration across every HIToolbox collection")
    func cleanupPlanUsesAllHIToolboxCollections() {
        let plan = InputSourceManager.cleanupPlan(
            enabledSources: [retiredPriTypeMode],
            selectedSources: [currentPriTypeMode],
            historySources: [priTypeParent, priTypeParent]
        )

        #expect(plan.result.hasCurrentPriTypeRegistration)
        #expect(plan.enabledSources.isEmpty)
        #expect(plan.selectedSources.count == 1)
        #expect(plan.historySources.count == 1)
        #expect(plan.result.didChange)
    }

    @Test("Installer enables the parent before the selectable Korean mode")
    func installerOrdersParentBeforeMode() {
        let candidates = [
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2.v2",
                inputModeID: "com.pritype.inputmethod.v2",
                inputSourceType: "TISTypeKeyboardInputMode",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: true
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2.retired",
                inputModeID: "com.pritype.inputmethod.v2.english",
                inputSourceType: "TISTypeKeyboardInputMode",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: true
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: false
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2.private-layout",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardLayout",
                isEnabled: false,
                isEnableCapable: false,
                isSelectCapable: false
            )
        ]

        let ordered = InputSourceManager.installationCandidates(from: candidates)

        #expect(ordered.map(\.inputSourceID) == [
            "com.pritype.inputmethod.v2",
            "com.pritype.inputmethod.v2.v2"
        ])
    }

    @Test("Installer selects PriType only for an unconfigured first install")
    func installerSelectionPolicyPreservesUpdates() {
        #expect(InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: true,
            hasCurrentRegistration: false
        ))
        #expect(!InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: true,
            hasCurrentRegistration: true
        ))
        #expect(!InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: false,
            hasCurrentRegistration: false
        ))
    }
}
