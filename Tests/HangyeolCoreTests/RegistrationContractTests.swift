import Testing
import Foundation
import Carbon.HIToolbox
@testable import HangyeolCore

/// Guards the IMK input-source registration in the source-tree `Info.plist`.
///
/// A malformed registration (e.g. a top-level `TISInputSourceID` duplicating a
/// child input-mode id, or per-mode `TISInputSourceID`/`tsInputModeDefaultStateKey`)
/// silently breaks Korean composition system-wide with no error — this happened in
/// commit 030a035 and was fixed in fd72334. These tests catch such regressions at
/// unit-test time (no device / re-login needed).
///
/// Single-mode design: Hangyeol registers only Korean (smKorean). Korean/English is
/// process-global `InputModeStore` state so a new IMK client or tab cannot restore a
/// session-scoped English child mode back to Korean. libhangul composition itself is
/// session-owned.
@Suite("Registration Contract (Info.plist)")
struct RegistrationContractTests {

    enum ContractError: Error { case notADict }

    /// Loads the repo-root `Info.plist` (the one the build copies into the bundle).
    /// `#filePath` → Tests/HangyeolCoreTests/<thisFile>; repo root is three levels up.
    private func loadInfoPlist() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HangyeolCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Info.plist"))
        guard let dict = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ContractError.notADict
        }
        return dict
    }

    private func modes(_ info: [String: Any]) -> [String: Any] {
        let comp = info["ComponentInputModeDict"] as? [String: Any]
        return (comp?["tsInputModeListKey"] as? [String: Any]) ?? [:]
    }

    @Test("Registers exactly one Korean mode")
    func singleKoreanMode() throws {
        let info = try loadInfoPlist()
        let list = modes(info)
        #expect(list.count == 1, "expected exactly 1 input mode, got \(list.count)")

        let korean = list["com.thlim.inputmethod.Hangyeol"] as? [String: Any]
        #expect(korean?["tsInputModeScriptKey"] as? String == "smKorean")
        #expect(list["com.thlim.inputmethod.Hangyeol.english"] == nil)

        let comp = info["ComponentInputModeDict"] as? [String: Any]
        let visible = comp?["tsVisibleInputModeOrderedArrayKey"] as? [String]
        #expect(visible == ["com.thlim.inputmethod.Hangyeol"])
    }

    @Test("Advertises system Caps Lock switching without an English child mode")
    func systemCapsLockCapability() throws {
        let info = try loadInfoPlist()
        #expect(info["TICapsLockLanguageSwitchCapable"] as? Bool == true)
    }

    @Test("Forbidden registration keys are absent (regression guard)")
    func noForbiddenKeys() throws {
        let info = try loadInfoPlist()
        // The 030a035 regression: a top-level TISInputSourceID equal to a child mode id.
        #expect(info["TISInputSourceID"] == nil, "top-level TISInputSourceID must NOT be present")

        for (id, value) in modes(info) {
            let mode = value as? [String: Any] ?? [:]
            #expect(mode["TISInputSourceID"] == nil, "per-mode TISInputSourceID must be absent (\(id))")
            #expect(mode["tsInputModeDefaultStateKey"] == nil, "tsInputModeDefaultStateKey must be absent (\(id))")
        }
    }

    @Test("Core identity keys are correct")
    func coreIdentity() throws {
        let info = try loadInfoPlist()
        #expect(info["CFBundleIdentifier"] as? String == ProductIdentity.bundleID)
        #expect(info["InputMethodConnectionName"] as? String == ProductIdentity.connectionName)
        #expect(info["InputMethodServerControllerClass"] as? String == "HangyeolInputController")
        #expect(info["CFBundleName"] as? String == ProductIdentity.systemName)
        #expect(info["CFBundleShortVersionString"] as? String == "3.0.19")
        #expect(info["CFBundleVersion"] as? String == "102")
        let repertoire = info["tsInputMethodCharacterRepertoireKey"] as? [String]
        #expect(repertoire == ["Hang"], "single-mode registration must declare Hang only")
    }

    @Test("Runs as a UIElement input method without a Dock icon")
    func inputMethodRunsAsUIElement() throws {
        let info = try loadInfoPlist()
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["LSBackgroundOnly"] == nil)
    }

    @Test("Input source icons are mode-specific template images")
    func modeIcons() throws {
        let info = try loadInfoPlist()
        #expect(info["TISIconIsTemplate"] as? Bool == true)
        #expect(info["tsInputMethodIconFileKey"] as? String == "icon.tiff")

        let list = modes(info)
        let korean = list["com.thlim.inputmethod.Hangyeol"] as? [String: Any]

        #expect(korean?["TISIconIsTemplate"] as? Bool == true)
        #expect(korean?["tsInputModeMenuIconFileKey"] as? String == "input-ko.tiff")
        #expect(korean?["tsInputModePaletteIconFileKey"] as? String == "input-ko.tiff")
    }

    @Test("Single-mode callbacks do not enter IMK's composition update path")
    func inputModePropertyCallbackIsConsumedByHangyeol() {
        #expect(!HangyeolInputController.shouldForwardStateChangeToIMK(
            tag: Int(kTextServiceInputModePropertyTag)
        ))
        #expect(HangyeolInputController.shouldForwardStateChangeToIMK(tag: Int.max))
    }
}
