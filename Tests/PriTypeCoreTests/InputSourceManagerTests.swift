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

    @Test("Installer reasserts cached enabled records and requires both identities")
    func installerPlanReassertsCachedEnabledRecords() {
        let mode = InputSourceInstallationCandidate(
            inputSourceID: "com.pritype.inputmethod.v2.v2",
            inputModeID: "com.pritype.inputmethod.v2",
            inputSourceType: "TISTypeKeyboardInputMode",
            isEnabled: true,
            isEnableCapable: true,
            isSelectCapable: true
        )
        let parent = InputSourceInstallationCandidate(
            inputSourceID: "com.pritype.inputmethod.v2",
            inputModeID: nil,
            inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
            isEnabled: true,
            isEnableCapable: true,
            isSelectCapable: false
        )

        let completePlan = InputSourceManager.installationPlan(from: [mode, parent])
        let incompletePlan = InputSourceManager.installationPlan(from: [mode])

        #expect(completePlan.candidatesToEnable.map(\.inputSourceID) == [
            "com.pritype.inputmethod.v2",
            "com.pritype.inputmethod.v2.v2"
        ])
        #expect(completePlan.hasRequiredCandidates)
        #expect(completePlan.isEnabled)
        #expect(completePlan.enabledMode == mode)
        #expect(!incompletePlan.hasRequiredCandidates)
        #expect(!incompletePlan.isEnabled)
    }

    @Test("Installer reloads after the registration change when the first snapshot is empty")
    func installerSettlesAsynchronousRegistration() {
        let registeredCandidates = [
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: false
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.pritype.inputmethod.v2.v2",
                inputModeID: "com.pritype.inputmethod.v2",
                inputSourceType: "TISTypeKeyboardInputMode",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: true
            )
        ]
        var waitCount = 0
        var reloadCount = 0

        let settled = InputSourceManager.settleInstallationState(
            initial: [InputSourceInstallationCandidate](),
            isSettled: {
                InputSourceManager.installationPlan(from: $0).hasRequiredCandidates
            },
            waitForChange: {
                waitCount += 1
                return true
            },
            reload: {
                reloadCount += 1
                return registeredCandidates
            }
        )

        #expect(InputSourceManager.installationPlan(from: settled).hasRequiredCandidates)
        #expect(waitCount == 1)
        #expect(reloadCount == 1)
    }

    @Test("Installer returns the last snapshot when registration never changes")
    func installerStopsAtRegistrationDeadline() {
        var waitCount = 0
        var reloadCount = 0

        let settled = InputSourceManager.settleInstallationState(
            initial: [InputSourceInstallationCandidate](),
            isSettled: { !$0.isEmpty },
            waitForChange: {
                waitCount += 1
                return false
            },
            reload: {
                reloadCount += 1
                return []
            }
        )

        #expect(settled.isEmpty)
        #expect(waitCount == 1)
        #expect(reloadCount == 1)
    }

    @Test("Installer restores PriType only when it was selected before an update")
    func installerSelectionPolicyRestoresPreviousSelection() {
        #expect(InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: true,
            hasCurrentRegistration: false,
            restorePreviousSelection: false
        ))
        #expect(!InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: true,
            hasCurrentRegistration: true,
            restorePreviousSelection: false
        ))
        #expect(InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: true,
            hasCurrentRegistration: true,
            restorePreviousSelection: true
        ))
        #expect(!InputSourceManager.shouldSelectInstalledInputSource(
            selectIfUnconfigured: false,
            hasCurrentRegistration: false,
            restorePreviousSelection: false
        ))
    }
}
