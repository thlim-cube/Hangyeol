import Foundation
import Testing
@testable import HangyeolCore

@Suite("Deferred client write lease")
struct DeferredClientWriteLeaseTests {
    private func context(
        bundleId: String,
        documentAccessSafe: Bool
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: documentAccessSafe
        )
    }

    private func makeMarkedSession() -> (InputSession, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration()
        )
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        return (session, client)
    }

    @Test("A captured deferred write is not revived by later same-client reapproval")
    func staleFieldReapprovalDoesNotReviveCapturedWrite() {
        let (session, client) = makeMarkedSession()
        #expect(session.adapter.canWriteToClient())

        let capturedA = session.adapter.captureDeferredClientWriteValidator()
        #expect(capturedA())

        session.markContextStale()
        session.refreshContext(
            context(bundleId: client.bundleID, documentAccessSafe: true),
            fieldIdentityMayHaveChanged: true
        )
        _ = session.prepareForNonSecureClientWrites()

        #expect(session.adapter.canWriteToClient())
        #expect(!capturedA())

        let capturedB = session.adapter.captureDeferredClientWriteValidator()
        #expect(capturedB())
    }

    @Test("A captured deferred write stays bound to the scheduling adapter")
    func replacedAdapterDeniesOldCapture() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.example.opaque"
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration()
        )
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        let originalAdapter = session.adapter
        let capturedA = originalAdapter.captureDeferredClientWriteValidator()
        #expect(capturedA())

        session.markContextStaleForSameClientReactivation()
        let blinkCapabilities = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: true,
            advertisesDocumentAccess: true,
            hasUsableSelection: true,
            advertisesBlinkReplacementRange: true,
            caretGeometry: .usable
        )
        let blinkContext = ClientContext(
            bundleId: client.bundleID,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true,
            capabilities: blinkCapabilities,
            hostSurface: HostSurfaceResolver.resolve(
                bundleId: client.bundleID,
                capabilities: blinkCapabilities
            )
        )
        #expect(session.refreshContextIfNeeded(using: { _ in blinkContext }))
        _ = session.prepareForNonSecureClientWrites()
        session.ensureAdapterMatchesPolicy()

        #expect(session.adapter !== originalAdapter)
        #expect(session.adapter.canWriteToClient())
        #expect(!capturedA())
        #expect(session.adapter.captureDeferredClientWriteValidator()())
    }

    @Test("Secure revocation denies a previously captured deferred write")
    func secureRevocationDeniesOldCapture() {
        let (session, _) = makeMarkedSession()
        let capturedA = session.adapter.captureDeferredClientWriteValidator()
        #expect(capturedA())

        session.discardForSecureInput()

        #expect(!session.adapter.canWriteToClient())
        #expect(!capturedA())
    }

    @Test("Secure reapproval does not revive a previously captured deferred write")
    func secureReapprovalDoesNotReviveCapturedWrite() {
        let (session, _) = makeMarkedSession()
        let capturedA = session.adapter.captureDeferredClientWriteValidator()
        #expect(capturedA())

        session.discardForSecureInput()
        _ = session.prepareForNonSecureClientWrites()

        #expect(session.adapter.canWriteToClient())
        #expect(!capturedA())
        #expect(session.adapter.captureDeferredClientWriteValidator()())
    }

    @Test("A capture taken before nonsecure approval stays denied after prepare")
    func unapprovedCaptureStaysDeniedAfterPrepare() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: HangulComposer(
                statusBar: MockStatusBar(),
                configuration: MockConfiguration()
            )
        )

        let capturedBeforePrepare = session.adapter.captureDeferredClientWriteValidator()
        #expect(!session.adapter.canWriteToClient())
        #expect(!capturedBeforePrepare())

        _ = session.prepareForNonSecureClientWrites()

        #expect(session.adapter.canWriteToClient())
        #expect(!capturedBeforePrepare())
        #expect(session.adapter.captureDeferredClientWriteValidator()())
    }

    @Test("Standalone adapters keep a live deferred write validator")
    func standaloneAdapterKeepsDynamicValidator() {
        let client = FakeIMKTextInput()
        let adapter = MarkedTextAdapter(client: client, hostSurface: .appKit)
        var allowed = true
        adapter.setClientWriteValidator { allowed }

        let captured = adapter.captureDeferredClientWriteValidator()
        #expect(captured())
        allowed = false
        #expect(!captured())
        allowed = true
        #expect(captured())
    }
}
