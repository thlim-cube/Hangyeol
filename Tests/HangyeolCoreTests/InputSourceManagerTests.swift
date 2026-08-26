import Testing
@testable import HangyeolCore

@Suite("InputSourceManager")
struct InputSourceManagerTests {
    private let hangyeolParent: [String: Any] = [
        "Bundle ID": "com.meapri.hangyeol.inputmethod",
        "InputSourceKind": "Keyboard Input Method"
    ]

    private let currentHangyeolMode: [String: Any] = [
        "Bundle ID": "com.meapri.hangyeol.inputmethod",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.meapri.hangyeol.inputmethod"
    ]

    private let retiredHangyeolMode: [String: Any] = [
        "Bundle ID": "com.meapri.hangyeol.inputmethod",
        "InputSourceKind": "Input Mode",
        "Input Mode": "com.meapri.hangyeol.inputmethod.english"
    ]

    @Test("Keeps Hangyeol parent and Korean mode while removing retired English mode")
    func keepsHangyeolParentAndKoreanModeOnly() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.meapri.hangyeol.inputmethod"
            ],
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.meapri.hangyeol.inputmethod.english"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsHangyeolParentEntry: true
        )

        #expect(sanitized.count == 2)
        #expect(sanitized.contains { $0["Input Mode"] == nil })  // parent
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.meapri.hangyeol.inputmethod" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.meapri.hangyeol.inputmethod.english" })
    }

    @Test("Keeps Hangyeol parent and removes stale child modes from selected and history sources")
    func keepsHangyeolParentAndRemovesStaleChildModesFromSelectedAndHistorySources() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.meapri.hangyeol.inputmethod"
            ],
            [
                "Bundle ID": "com.meapri.hangyeol.inputmethod",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.meapri.hangyeol.inputmethod.korean"
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
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.meapri.hangyeol.inputmethod" && $0["Input Mode"] == nil })
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.meapri.hangyeol.inputmethod" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.meapri.hangyeol.inputmethod.korean" })
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

    @Test("Installer enables the parent before the selectable Korean mode")
    func installerOrdersParentBeforeMode() {
        let candidates = [
            InputSourceInstallationCandidate(
                inputSourceID: "com.meapri.hangyeol.inputmethod.mode-record",
                inputModeID: "com.meapri.hangyeol.inputmethod",
                inputSourceType: "TISTypeKeyboardInputMode",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: true
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.meapri.hangyeol.inputmethod.retired",
                inputModeID: "com.meapri.hangyeol.inputmethod.english",
                inputSourceType: "TISTypeKeyboardInputMode",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: true
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.meapri.hangyeol.inputmethod",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: false
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.meapri.hangyeol.inputmethod.private-layout",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardLayout",
                isEnabled: false,
                isEnableCapable: false,
                isSelectCapable: false
            )
        ]

        let ordered = InputSourceManager.installationCandidates(from: candidates)

        #expect(ordered.map(\.inputSourceID) == [
            "com.meapri.hangyeol.inputmethod",
            "com.meapri.hangyeol.inputmethod.mode-record"
        ])
    }

    @Test("Installer reasserts cached enabled records and requires both identities")
    func installerPlanReassertsCachedEnabledRecords() {
        let mode = InputSourceInstallationCandidate(
            inputSourceID: "com.meapri.hangyeol.inputmethod.mode-record",
            inputModeID: "com.meapri.hangyeol.inputmethod",
            inputSourceType: "TISTypeKeyboardInputMode",
            isEnabled: true,
            isEnableCapable: true,
            isSelectCapable: true
        )
        let parent = InputSourceInstallationCandidate(
            inputSourceID: "com.meapri.hangyeol.inputmethod",
            inputModeID: nil,
            inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
            isEnabled: true,
            isEnableCapable: true,
            isSelectCapable: false
        )

        let completePlan = InputSourceManager.installationPlan(from: [mode, parent])
        let incompletePlan = InputSourceManager.installationPlan(from: [mode])

        #expect(completePlan.candidatesToEnable.map(\.inputSourceID) == [
            "com.meapri.hangyeol.inputmethod",
            "com.meapri.hangyeol.inputmethod.mode-record"
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
                inputSourceID: "com.meapri.hangyeol.inputmethod",
                inputModeID: nil,
                inputSourceType: "TISTypeKeyboardInputMethodModeEnabled",
                isEnabled: false,
                isEnableCapable: true,
                isSelectCapable: false
            ),
            InputSourceInstallationCandidate(
                inputSourceID: "com.meapri.hangyeol.inputmethod.mode-record",
                inputModeID: "com.meapri.hangyeol.inputmethod",
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

    @Test("Installer restores Hangyeol only when it was selected before an update")
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
