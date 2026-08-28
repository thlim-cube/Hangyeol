import Testing
@testable import HangyeolInstallerSupport

@Suite("Installer input-source lifecycle")
struct InstallerInputSourceLifecycleTests {
    private let identity = InstallerInputSourceIdentity(
        bundleID: "com.thlim.inputmethod.Hangyeol",
        modeID: "com.thlim.inputmethod.Hangyeol",
        legacyBundleIDs: [
            "com.thlim.hangyeol.inputmethod",
            "com.meapri.hangyeol.inputmethod",
            "com.pritype.inputmethod.v2"
        ]
    )

    private func candidate(
        sourceID: String,
        bundleID: String? = nil,
        modeID: String? = nil,
        kind: InstallerInputSourceKind = .other,
        enabled: Bool = true,
        enableCapable: Bool = true,
        selectCapable: Bool = true,
        asciiCapable: Bool = false
    ) -> InstallerInputSourceCandidate {
        InstallerInputSourceCandidate(
            sourceID: sourceID,
            bundleID: bundleID,
            modeID: modeID,
            kind: kind,
            isEnabled: enabled,
            isEnableCapable: enableCapable,
            isSelectCapable: selectCapable,
            isASCIICapable: asciiCapable
        )
    }

    @Test("Safe fallback excludes every current and retired Hangyeol identity")
    func filtersOwnedFallbacks() {
        let abc = candidate(
            sourceID: "com.apple.keylayout.ABC",
            asciiCapable: true
        )
        let disabled = candidate(
            sourceID: "com.apple.keylayout.US",
            enabled: false,
            asciiCapable: true
        )
        let legacy = candidate(
            sourceID: "com.pritype.inputmethod.v2.mode",
            bundleID: "com.pritype.inputmethod.v2",
            asciiCapable: true
        )
        let current = candidate(
            sourceID: identity.modeID,
            bundleID: identity.bundleID,
            modeID: identity.modeID,
            asciiCapable: true
        )

        #expect(InputSourceLifecycleRules.safeFallbackCandidates(
            from: [legacy, disabled, abc, current, abc],
            identity: identity
        ) == [abc, disabled])
    }

    @Test("Installation readiness requires one exact parent and one exact mode")
    func requiresUniqueParentAndMode() {
        let parent = candidate(
            sourceID: identity.bundleID,
            bundleID: identity.bundleID,
            kind: .inputMethodParent,
            selectCapable: false
        )
        let mode = candidate(
            sourceID: identity.modeID,
            bundleID: identity.bundleID,
            modeID: identity.modeID,
            kind: .inputMode
        )
        #expect(InputSourceLifecycleRules.roster(
            from: [parent, mode],
            identity: identity
        ).isEnabled)
        #expect(!InputSourceLifecycleRules.roster(
            from: [parent, mode, mode],
            identity: identity
        ).hasUniquePair)
    }

    @Test("Selection restores first installs and previously selected updates only")
    func selectsOnlyWhenRequired() {
        #expect(InputSourceLifecycleRules.shouldSelectAfterActivation(
            installationKind: .firstInstallation,
            selectedBeforeInstall: false
        ))
        #expect(InputSourceLifecycleRules.shouldSelectAfterActivation(
            installationKind: .ordinaryUpdate,
            selectedBeforeInstall: true
        ))
        #expect(!InputSourceLifecycleRules.shouldSelectAfterActivation(
            installationKind: .ordinaryUpdate,
            selectedBeforeInstall: false
        ))
    }

    @Test("Selection is the final optional activation boundary")
    func buildsActivationBoundaries() {
        #expect(InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: false
        ).map(\.action) == [.register, .enableParent, .enableMode])
        #expect(InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: true
        ).map(\.verify) == [
            .verifyInstalled,
            .verifyParent,
            .verifyMode,
            .verifySelected
        ])
        #expect(InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: true,
            hasTemporaryFallback: true
        ).suffix(2).map(\.verify) == [
            .verifySelected,
            .verifyTemporaryFallbackDisabled
        ])
        #expect(!InputSourceLifecycleRules.activationBoundaries(
            shouldSelect: false,
            hasTemporaryFallback: true
        ).contains { $0.action == .disableTemporaryFallback })
    }
}
