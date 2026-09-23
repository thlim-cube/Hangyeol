import Testing
import Foundation
import HangyeolInstallerSupport

struct SessionRuntimeActivationTests {
    @Test func sessionPathAcceptsBothMacOSTemporaryDirectorySpellings() {
        for root in ["/tmp", "/private/tmp"] {
            #expect(SessionRuntimeLease.isSessionApp(URL(fileURLWithPath: "\(root)/hangyeol-session.abc/Hangyeol.app")))
        }
        #expect(!SessionRuntimeLease.isSessionApp(URL(fileURLWithPath: "/Library/Input Methods/Hangyeol.app")))
        #expect(!SessionRuntimeLease.isSessionApp(URL(fileURLWithPath: "/tmp/unrelated/Hangyeol.app")))
        #expect(!SessionRuntimeLease.isSessionApp(URL(fileURLWithPath: "/tmp/nested/hangyeol-session.abc/Hangyeol.app")))
    }

    @Test func installerRestoresOnlyTheFallbackItSelected() {
        #expect(SessionRuntimeActivation.shouldRestoreSelection(
            selectedBefore: true, currentSourceID: "ABC", fallbackID: "ABC"))
        #expect(!SessionRuntimeActivation.shouldRestoreSelection(
            selectedBefore: false, currentSourceID: "ABC", fallbackID: "ABC"))
        #expect(!SessionRuntimeActivation.shouldRestoreSelection(
            selectedBefore: true, currentSourceID: "user-chosen", fallbackID: "ABC"))
        #expect(!SessionRuntimeActivation.shouldRestoreSelection(
            selectedBefore: true, currentSourceID: nil, fallbackID: nil))
    }

    @Test func temporaryRuntimeCannotSurviveIntoAnotherLoginOrUser() {
        let lease = SessionRuntimeLease(userID: 501, sessionID: 123)
        #expect(lease.permits(userID: 501, sessionID: 123))
        #expect(!lease.permits(userID: 501, sessionID: 124))
        #expect(!lease.permits(userID: 502, sessionID: 123))
        #expect(!lease.permits(userID: 501, sessionID: nil))
    }

    private final class Host: SessionRuntimeHost {
        var failure: String?
        var recoverySucceeds = true
        var candidateChecks = 0
        var calls: [String] = []
        var running = "installed"
        var source = "hangyeol"

        func perform(_ step: String) -> Bool {
            calls.append(step)
            return failure != step
        }
        func validateCandidate() -> Bool { perform("validate") }
        func prepareInputSource() -> Bool {
            guard perform("prepare") else { return false }
            source = "fallback"
            return true
        }
        func stopCurrentRuntime() -> Bool {
            #expect(source == "fallback", "The old IMK must retire its active composition first")
            guard perform("stop") else { return false }
            running = "none"
            return true
        }
        func launchCandidate() -> Bool {
            guard perform("launch") else { return false }
            running = "session"
            return true
        }
        func verifyCandidate() -> Bool {
            candidateChecks += 1
            return perform("verify\(candidateChecks)") && running == "session"
        }
        func restoreInputSource() -> Bool {
            #expect(running == "session")
            guard perform("select") else { return false }
            source = "hangyeol"
            return true
        }
        func restoreInstalledRuntime() -> Bool {
            calls.append("recover")
            guard recoverySucceeds else { return false }
            running = "installed"
            source = "hangyeol"
            return true
        }
    }

    @Test func invalidCandidateLeavesCurrentInputUntouched() {
        let host = Host()
        host.failure = "validate"
        #expect(SessionRuntimeActivation.apply(using: host) == .deferred)
        #expect(host.calls == ["validate"])
        #expect(host.running == "installed")
        #expect(host.source == "hangyeol")
    }

    @Test func successfulHandoffVerifiesAgainAfterReselectingHangyeol() {
        let host = Host()
        #expect(SessionRuntimeActivation.apply(using: host) == .applied)
        #expect(host.running == "session")
        #expect(host.source == "hangyeol")
        #expect(host.candidateChecks == 2)
        #expect(!host.calls.contains("recover"))
    }

    @Test(arguments: ["prepare", "stop", "launch", "verify1", "select", "verify2"])
    func incompleteHandoffRestoresInstalledInput(step: String) {
        let host = Host()
        host.failure = step
        #expect(SessionRuntimeActivation.apply(using: host) == .restored)
        #expect(host.running == "installed")
        #expect(host.source == "hangyeol")
        #expect(host.calls.last == "recover")
    }

    @Test func recoveryFailureIsNotReportedAsSuccess() {
        let host = Host()
        host.failure = "launch"
        host.recoverySucceeds = false
        #expect(SessionRuntimeActivation.apply(using: host) == .recoveryFailed)
    }
}
