import AppKit
import Foundation
import Testing
@testable import HangyeolE2ESupport

@Suite("E2E support contracts")
struct E2ESupportTests {
    @Test("Fixture state survives a Chrome-decorated window title")
    func fixtureTitleRoundTrip() throws {
        let state = ChromeFixtureState(
            normalInput: "한글",
            editable: "두벌식",
            left: "나",
            right: "나",
            multiline: "입력\n나",
            focusedID: "right",
            pageID: "tab-2",
            centers: ["right": .init(x: 640, y: 480)],
            selections: ["right": .init(start: 1, end: 1)]
        )
        let title = try FixtureStateCodec.encode(state) + " - Google Chrome"

        #expect(FixtureStateCodec.decode(windowTitle: title) == state)
    }

    @Test("Exact text rejects canonically equivalent decomposed output")
    func exactUnicodeContract() {
        let composed = "나"
        let decomposed = composed.decomposedStringWithCanonicalMapping

        #expect(ExactTextContract.matches(composed, expected: "나"))
        #expect(!ExactTextContract.matches(decomposed, expected: "나"))
    }

    @Test("E2E modifier chords contain physical down/up side flags")
    func physicalModifierPlan() {
        let command = E2EPhysicalModifierPlan.make(for: .maskCommand)
        #expect(command.presses.map(\.keyCode) == [55])
        #expect(command.effectiveFlags.contains(.maskCommand))
        #expect(command.effectiveFlags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) != 0)

        let controlShift = E2EPhysicalModifierPlan.make(
            for: [.maskControl, .maskShift]
        )
        #expect(controlShift.presses.map(\.keyCode) == [59, 56])
        #expect(controlShift.effectiveFlags.contains(.maskControl))
        #expect(controlShift.effectiveFlags.contains(.maskShift))
        #expect(controlShift.effectiveFlags.rawValue & UInt64(NX_DEVICELCTLKEYMASK) != 0)
        #expect(controlShift.effectiveFlags.rawValue & UInt64(NX_DEVICELSHIFTKEYMASK) != 0)

        let rightCommand = E2EPhysicalModifierPlan.make(for: CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK)
        ))
        #expect(rightCommand.presses.map(\.keyCode) == [54])
        #expect(rightCommand.effectiveFlags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0)
    }

    @Test("TextEdit fixture always owns a separate non-interactive instance")
    func textEditFixtureLaunchIsIsolated() {
        let configuration = TextEditFixtureLaunchPolicy.makeConfiguration()

        #expect(configuration.createsNewApplicationInstance)
        #expect(!configuration.allowsRunningApplicationSubstitution)
        #expect(!configuration.promptsUserIfNeeded)
        #expect(!configuration.addsToRecentItems)
    }

    @Test("Code-signature parser keeps the leaf signing authority")
    func codeSignatureParser() {
        let output = """
        Executable=/Library/Input Methods/Hangyeol.app/Contents/MacOS/Hangyeol
        Identifier=com.thlim.inputmethod.Hangyeol
        CDHash=0123456789abcdef0123456789abcdef01234567
        Authority=Apple Development: TaeHyeon Lim (9FRJXJNGZK)
        Authority=Apple Worldwide Developer Relations Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=9FRJXJNGZK
        """

        let fields = ArtifactInspector.parseCodeSignatureDetails(output)

        #expect(fields["Identifier"] == "com.thlim.inputmethod.Hangyeol")
        #expect(
            fields["Executable"]
                == "/Library/Input Methods/Hangyeol.app/Contents/MacOS/Hangyeol"
        )
        #expect(fields["CDHash"] == "0123456789abcdef0123456789abcdef01234567")
        #expect(fields["TeamIdentifier"] == "9FRJXJNGZK")
        #expect(fields["Authority"] == "Apple Development: TaeHyeon Lim (9FRJXJNGZK)")
    }

    @Test("Running-code validation uses Security dynamic validity")
    func runningCodeDynamicValidity() throws {
        try ArtifactInspector.validateRunningCode(pid: getpid())
    }

    @Test("Artifact comparison ignores extraction paths and reports identity drift")
    func artifactComparison() {
        let installed = identity(path: "/Library/Input Methods/Hangyeol.app")
        let matching = identity(path: "/tmp/expanded/Payload/Hangyeol.app")
        let changed = AppArtifactIdentity(
            appPath: matching.appPath,
            bundleID: matching.bundleID,
            version: "3.0.4",
            build: matching.build,
            signingIdentifier: matching.signingIdentifier,
            codeDirectoryHash: matching.codeDirectoryHash,
            teamIdentifier: matching.teamIdentifier,
            signingAuthority: matching.signingAuthority
        )

        #expect(ArtifactInspector.compare(installed: installed, packaged: matching).isMatch)
        let mismatches = ArtifactInspector.compare(
            installed: installed,
            packaged: changed
        ).mismatches
        #expect(mismatches == ["version: installed=3.0.3, package=3.0.4"])

        let changedHash = AppArtifactIdentity(
            appPath: matching.appPath,
            bundleID: matching.bundleID,
            version: matching.version,
            build: matching.build,
            signingIdentifier: matching.signingIdentifier,
            codeDirectoryHash: "ffffffffffffffffffffffffffffffffffffffff",
            teamIdentifier: matching.teamIdentifier,
            signingAuthority: matching.signingAuthority
        )
        #expect(
            ArtifactInspector.compare(installed: installed, packaged: changedHash).mismatches
                == [
                    "CDHash: installed=0123456789abcdef0123456789abcdef01234567, "
                        + "package=ffffffffffffffffffffffffffffffffffffffff"
                ]
        )

        let running = RunningArtifactIdentity(
            pid: 123,
            executablePath: installed.appPath + "/Contents/MacOS/Hangyeol",
            signingIdentifier: installed.signingIdentifier,
            codeDirectoryHash: installed.codeDirectoryHash,
            teamIdentifier: installed.teamIdentifier,
            signingAuthority: installed.signingAuthority
        )
        #expect(ArtifactInspector.compare(running: running, packaged: matching).isEmpty)
        #expect(
            ArtifactInspector.compare(running: running, packaged: changedHash)
                == [
                    "running CDHash: process=0123456789abcdef0123456789abcdef01234567, "
                        + "package=ffffffffffffffffffffffffffffffffffffffff"
                ]
        )
    }

    private func identity(path: String) -> AppArtifactIdentity {
        AppArtifactIdentity(
            appPath: path,
            bundleID: "com.thlim.inputmethod.Hangyeol",
            version: "3.0.3",
            build: "86",
            signingIdentifier: "com.thlim.inputmethod.Hangyeol",
            codeDirectoryHash: "0123456789abcdef0123456789abcdef01234567",
            teamIdentifier: "9FRJXJNGZK",
            signingAuthority: "Apple Development: TaeHyeon Lim (9FRJXJNGZK)"
        )
    }
}
