import Foundation
import Testing
@testable import PriTypeCore

@Suite("Input session finalize")
struct InputSessionFinalizeTests {
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

    private func makeDirectFallbackSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.nousresearch.hermes"
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        return (session, composer, client)
    }

    private func makeMarkedSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        return (session, composer, client)
    }

    private func makeStaleDirectFallbackSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let result = makeDirectFallbackSession()
        _ = result.1.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: result.0.adapter
        )
        result.0.markContextStale()
        return result
    }

    @Test("Direct insertion marked fallback commits through the marked path")
    func directFallbackCommitsMarkedText() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        #expect(session.finalize(reason: .modeTransition))
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.1.location == NSNotFound)
    }

    @Test("Owned marked fallback is cleared even when the engine is already empty")
    func emptyEngineReconcilesOwnedFallback() {
        let (session, composer, client) = makeDirectFallbackSession()

        session.adapter.setMarkedText("ㄱ")
        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(session.mouseCompositionState == .staleMarkedFallback)
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: client.markedRange(),
            state: session.mouseCompositionState
        ))

        #expect(session.finalize(reason: .mouseCommit))
        #expect(session.mouseCompositionState == .inactive)
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.0 == "")
        #expect(client.insertCalls.first?.1 == NSRange(location: 0, length: 1))
    }

    @Test("Secure discard defers owned marked fallback until nonsecure resume")
    func secureDiscardDefersOwnedFallbackCleanup() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㄱ")

        session.discardForSecureInput()

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)

        #expect(session.prepareForNonSecureClientWrites())
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.0 == "")
        #expect(client.insertCalls.first?.1 == NSRange(location: 0, length: 1))
        #expect(!session.prepareForNonSecureClientWrites())
        #expect(client.insertCalls.count == 1)
    }

    @Test("Canonical marked text is cleared once after same-field nonsecure resume")
    func canonicalMarkedTextCleanupOnSameFieldResume() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)

        session.discardForSecureInput()

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)

        #expect(session.prepareForNonSecureClientWrites())
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.0 == "")
        #expect(!session.prepareForNonSecureClientWrites())
        #expect(client.insertCalls.count == 1)
    }

    @Test("A refreshed field never receives deferred marked-text cleanup")
    func refreshedFieldAbandonsDeferredMarkedCleanup() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.discardForSecureInput()
        #expect(client.insertCalls.isEmpty)

        session.markContextStale()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: false)
        })
        client.markedText = "다른"
        client.markedRangeValue = NSRange(location: 3, length: 2)

        #expect(!session.prepareForNonSecureClientWrites())
        #expect(client.insertCalls.isEmpty)
        #expect(client.markedText == "다른")
    }

    @Test("A refreshed nonsecure field never receives the previous field's active preedit")
    func refreshedFieldDiscardsActivePreeditWithoutWrite() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.markContextStale()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        client.markedText = "다른"
        client.markedRangeValue = NSRange(location: 4, length: 2)

        #expect(!session.prepareForNonSecureClientWrites())
        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.isEmpty)
        #expect(client.markedText == "다른")
    }

    @Test("Secure discard followed by lifecycle handoff never writes to the client")
    func secureDiscardLifecycleHandoffDoesNotWrite() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.discardForSecureInput()

        session.retireForControllerHandoff()
        #expect(!session.finalize(reason: .deactivateServer))

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("A stale password-context deactivation discards without client writes")
    func staleContextDeactivationDoesNotWrite() {
        let (session, composer, client) = makeStaleDirectFallbackSession()

        #expect(session.finalize(reason: .deactivateServer))

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("A stale password-context controller handoff discards without client writes")
    func staleContextControllerHandoffDoesNotWrite() {
        let (session, composer, client) = makeStaleDirectFallbackSession()

        session.retireForControllerHandoff()

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("A stale password-context app deactivation discards without client writes")
    func staleContextAppDeactivationDoesNotWrite() {
        let (session, composer, client) = makeStaleDirectFallbackSession()

        #expect(session.finalize(reason: .appDeactivate))

        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("A confirmed nonsecure app deactivation keeps the early marked commit")
    func nonsecureAppDeactivationCommitsMarkedText() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(session.finalize(reason: .appDeactivate))

        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
    }

    @Test("Changing from marked to direct delivery finalizes through the old adapter")
    func markedToDirectFinalizesBeforeAdapterReplacement() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(session.adapter.deliveryMode == .markedText)
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        session.refreshContext(context(bundleId: "com.nousresearch.hermes", documentAccessSafe: true))
        _ = session.prepareForNonSecureClientWrites()
        session.ensureAdapterMatchesPolicy()

        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
    }

    @Test("Changing from direct to marked delivery preserves committed text")
    func directToMarkedFinalizesBeforeAdapterReplacement() {
        let (session, composer, client) = makeDirectFallbackSession()
        client.selectedRangeValue = NSRange(location: 0, length: 0)

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(composer.hasActiveComposition)
        #expect(client.document == "ㄱ")

        session.refreshContext(context(bundleId: client.bundleID, documentAccessSafe: false))
        _ = session.prepareForNonSecureClientWrites()
        session.ensureAdapterMatchesPolicy()

        #expect(session.adapter.deliveryMode == .markedText)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
    }

    @Test("Secure context refresh rebuilds policy without committing old fallback")
    func secureContextRefreshRebuildsWithoutClientWrite() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)

        session.markContextStale()
        #expect(session.refreshContextIfNeeded { _ in
            ClientContext(
                bundleId: client.bundleID,
                hasTextInputCapability: false,
                isLikelyDesktopArea: false,
                documentAccessSafe: false
            )
        })

        // The refreshed signals take the raw-pass branch. Until that branch discards
        // the engine, the old direct adapter must remain untouched and write nothing.
        #expect(SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: session.context.bundleId,
            hasTextInputCapability: session.context.hasTextInputCapability,
            hasInvalidSelection: true,
            hasGlobalSecureInput: false,
            hasMarkedTextSupport: false
        )))
        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(composer.hasActiveComposition)
        #expect(client.insertCalls.isEmpty)

        session.discardForSecureInput()

        #expect(!composer.hasActiveComposition)
        #expect(session.adapter.deliveryMode == .markedText)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Controller handoff retires the old session before late deactivation")
    func controllerHandoffRetiresSession() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: session.adapter)
        #expect(client.markedText == "가")

        session.retireForControllerHandoff()

        #expect(session.contextNeedsRefresh)
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "가")
        #expect(client.markedText.isEmpty)
        #expect(!session.finalize(reason: .deactivateServer))
        #expect(client.document == "가")
    }

    @Test(
        "Invalid selection after a real preedit fails closed without duplicate text",
        arguments: [NSNotFound, 20_000_000]
    )
    func invalidSelectionWithLivePreeditPreservesDocument(invalidLocation: Int) {
        let (session, composer, client) = makeDirectFallbackSession()
        client.selectedRangeValue = NSRange(location: 0, length: 0)

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)

        client.selectedRangeValue = NSRange(location: invalidLocation, length: 0)
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )

        // The adapter cannot prove where its real `ㄱ` lives anymore. It must not
        // delete a guessed range or show the full `가` as marked text, because that
        // would finalize as `ㄱ가`. The current key is dropped fail-closed instead.
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
        #expect(client.markCalls.isEmpty)

        #expect(session.finalize(reason: .modeTransition))
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄱ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.count == 1)
    }

    @Test("Insert-only boundaries re-arm direct insertion after invalid selection")
    func insertOnlyBoundariesRecoverAfterInvalidSelection() {
        let boundaries: [(character: String, keyCode: UInt16, insertsText: Bool)] = [
            (" ", KeyCode.space, true),
            ("\t", KeyCode.tab, false),
            ("", KeyCode.leftArrow, false),
        ]

        for boundary in boundaries {
            let (session, composer, client) = makeDirectFallbackSession()
            client.selectedRangeValue = NSRange(location: 0, length: 0)

            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )
            client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
                delegate: session.adapter
            )
            #expect(client.document == "ㄱ")

            client.selectedRangeValue = NSRange(location: client.document.utf16.count, length: 0)
            _ = composer.handle(
                TestEventFactory.keyEvent(
                    char: boundary.character,
                    keyCode: boundary.keyCode
                )!,
                delegate: session.adapter
            )
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )

            #expect(client.document == (boundary.insertsText ? "ㄱ ㄱ" : "ㄱㄱ"))
        }
    }

    @Test("Finalized insert commits when invalid selection outlives fail-closed composition")
    func finalizedInsertCommitsWithPersistentlyInvalidSelection() {
        let (session, composer, client) = makeDirectFallbackSession()
        client.selectedRangeValue = NSRange(location: 0, length: 0)

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )
        _ = composer.handle(
            TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!,
            delegate: session.adapter
        )

        #expect(client.document == "ㄱ ")
        #expect(client.markedText.isEmpty)
        #expect(client.insertCalls.last?.0 == " ")
        #expect(client.insertCalls.last?.1.location == NSNotFound)
        #expect(client.markCalls.isEmpty)

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(session.finalize(reason: .modeTransition))
        #expect(client.document == "ㄱ ㄱ")
        #expect(client.markedText.isEmpty)
    }
}

@Suite("Mouse composition policy")
struct MouseCompositionPolicyTests {
    @Test("Click outside marked range finalizes")
    func outsideFinalizes() {
        let marked = NSRange(location: 10, length: 2)
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 9, markedRange: marked, state: .active))
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 12, markedRange: marked, state: .active))
    }

    @Test("Click inside marked range keeps composition")
    func insideKeepsComposition() {
        let marked = NSRange(location: 10, length: 2)
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 10, markedRange: marked, state: .active))
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 11, markedRange: marked, state: .active))
    }

    @Test("Direct insertion without marked range finalizes on any click")
    func directInsertionFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 42,
            markedRange: NSRange(location: NSNotFound, length: 0),
            state: .active
        ))
    }

    @Test("No active composition is a no-op")
    func inactiveNoOp() {
        #expect(!MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: NSNotFound, length: 0),
            state: .inactive
        ))
    }

    @Test("Malformed overflowing marked range fails closed to finalize")
    func malformedRangeFinalizes() {
        #expect(MouseCompositionPolicy.shouldFinalize(
            characterIndex: 0,
            markedRange: NSRange(location: Int.max - 1, length: 4),
            state: .active
        ))
    }
}
