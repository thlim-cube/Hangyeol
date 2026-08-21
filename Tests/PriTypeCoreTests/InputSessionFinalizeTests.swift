import Foundation
import Testing
@testable import PriTypeCore

@Suite("Input session finalize")
struct InputSessionFinalizeTests {
    private func context(
        bundleId: String,
        hasTextInputCapability: Bool = true,
        documentAccessSafe: Bool
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: hasTextInputCapability,
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
        _ = session.prepareForNonSecureClientWrites()
        return (session, composer, client)
    }

    private func makeMarkedSession() -> (InputSession, HangulComposer, FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(
                bundleId: client.bundleID,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
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

    @Test("Composition root keeps the live direct-insertion preference")
    func compositionRootUsesLiveDirectInsertionPreference() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let configuration = MockConfiguration()
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: configuration
        )
        let session = PriTypeInputController.makeInputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer,
            configuration: configuration
        )
        _ = session.prepareForNonSecureClientWrites()

        #expect(session.adapter.deliveryMode == .markedText)
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㄱ")

        configuration.experimentalDirectInsertion = true
        session.ensureAdapterMatchesPolicy()
        #expect(session.adapter.deliveryMode == .directInsertion)
        #expect(client.document == "ㄱ")

        configuration.experimentalDirectInsertion = false
        session.ensureAdapterMatchesPolicy()
        #expect(session.adapter.deliveryMode == .markedText)
    }

    @Test("An unclassified session cannot write during lifecycle finalize")
    func unclassifiedSessionFinalizeDoesNotWrite() {
        let client = FakeIMKTextInput()
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: "com.apple.TextEdit", documentAccessSafe: true),
            composer: composer
        )
        let renderOnlyDelegate = MockComposerDelegate()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: renderOnlyDelegate
        )
        #expect(composer.hasActiveComposition)

        #expect(session.finalize(reason: .appDeactivate))
        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.isEmpty)
        #expect(client.markCalls.isEmpty)
    }

    @Test("A host commit boundary invalidates shortcut state without a client write")
    func hostCommitBoundaryInvalidatesShortcutState() {
        let client = FakeIMKTextInput()
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let shortcutState = HanjaShortcutSessionStateStore(initialState: .nonsecure)
        let session = InputSession(
            client: client,
            context: context(bundleId: "com.apple.TextEdit", documentAccessSafe: true),
            composer: composer,
            invalidateHanjaShortcutSessionState: {
                shortcutState.update(.unknown)
            }
        )
        _ = session.prepareForNonSecureClientWrites()

        let staleClient = FakeIMKTextInput()
        #expect(!PriTypeInputController.routeHostCommitComposition(
            in: session,
            sender: staleClient
        ))
        #expect(!session.contextNeedsRefresh)
        #expect(shortcutState.state == .nonsecure)

        #expect(PriTypeInputController.routeHostCommitComposition(
            in: session,
            sender: client
        ))

        #expect(session.contextNeedsRefresh)
        #expect(shortcutState.state == .unknown)
        #expect(!HanjaShortcutSuppressionPolicy.allowsSuppression(
            binding: KeyBinding(keyCode: 102, modifiers: 0, displayName: "F15"),
            sessionState: shortcutState.state
        ))
        #expect(client.insertCalls.isEmpty)
        #expect(client.markCalls.isEmpty)
    }

    @Test("A deferred Return replay revokes only its matching field context")
    func deferredReturnReplayInvalidatesMatchingSession() {
        let (session, _, client) = makeMarkedSession()
        let staleClient = FakeIMKTextInput()

        #expect(!PriTypeInputController.routeDeferredHostKey(
            in: session,
            client: staleClient,
            keyCode: KeyCode.return
        ))
        #expect(!session.contextNeedsRefresh)

        session.adapter.recordDeferredHostKeyPassedToHost(keyCode: KeyCode.return)
        #expect(session.contextNeedsRefresh)
        #expect(client.insertCalls.isEmpty)
        #expect(client.markCalls.isEmpty)
    }

    @Test("Host-passed field boundaries make the reused client context untrusted")
    func hostPassedFieldBoundariesInvalidateContext() async {
        let fieldBoundaryKeys: [(name: String, keyCode: UInt16, character: String)] = [
            ("Tab", KeyCode.tab, "\t"),
            ("Return", KeyCode.return, "\r"),
            ("Numpad Enter", KeyCode.numpadEnter, "\r")
        ]

        for boundary in fieldBoundaryKeys {
            let client = FakeIMKTextInput()
            let composer = HangulComposer(
                statusBar: MockStatusBar(),
                configuration: MockConfiguration()
            )
            let shortcutState = HanjaShortcutSessionStateStore(initialState: .nonsecure)
            let session = InputSession(
                client: client,
                context: context(bundleId: "com.apple.TextEdit", documentAccessSafe: true),
                composer: composer,
                invalidateHanjaShortcutSessionState: {
                    shortcutState.update(.unknown)
                }
            )
            _ = session.prepareForNonSecureClientWrites()

            let snapshot = KeyDownSnapshot(timestamp: 100, keyCode: boundary.keyCode)
            #expect(session.registerKeyDown(snapshot) == .process)
            let handled = composer.handle(
                TestEventFactory.keyEvent(
                    char: boundary.character,
                    keyCode: boundary.keyCode
                )!,
                delegate: session.adapter
            )
            session.observeHostFieldBoundaryKeyDown(
                keyCode: boundary.keyCode,
                passedToHost: !handled
            )

            #expect(!handled, "\(boundary.name) should pass to the host")
            #expect(session.contextNeedsRefresh)
            #expect(shortcutState.state == .unknown)
            #expect(client.insertCalls.isEmpty)
            #expect(client.markCalls.isEmpty)

            // The same-turn guard expires on the main queue, but an exact
            // full-signature duplicate remains deduplicated after that turn. Let
            // the clear run before deliberately restoring the old field context;
            // the host action is still pending when the duplicate arrives.
            await flushMainQueue()
            #expect(session.refreshContextIfNeeded { _ in
                self.context(bundleId: client.bundleID, documentAccessSafe: true)
            })
            #expect(!session.contextNeedsRefresh)
            #expect(session.registerKeyDown(snapshot) == .consumeDuplicate)
            #expect(session.contextNeedsRefresh)
            #expect(shortcutState.state == .unknown)

            // Once the host has applied the boundary, the next real key must
            // classify the reused client again and route the password-like field
            // without any extra client write.
            client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
            #expect(session.refreshContextForInputBoundary { _ in
                self.context(
                    bundleId: client.bundleID,
                    hasTextInputCapability: false,
                    documentAccessSafe: false
                )
            })
            #expect(SecureInputPolicy.shouldPassThrough(SecureInputSignals(
                bundleId: session.context.bundleId,
                hasTextInputCapability: session.context.hasTextInputCapability,
                hasInvalidSelection: true,
                hasGlobalSecureInput: false
            )))
            #expect(!PriTypeInputController.routeSecureKeyDown(
                in: session,
                keyCode: 15
            ))
            #expect(!session.finalize(reason: .appDeactivate))
            #expect(client.insertCalls.isEmpty)
            #expect(client.markCalls.isEmpty)
        }
    }

    @Test("Text convenience timing does not cross field boundaries")
    func textConvenienceTimingDoesNotCrossFieldBoundaries() {
        let boundaries: [(String, (InputSession) -> Void)] = [
            ("mouse", { session in
                _ = session.reconcileMouseDown(
                    characterIndex: 0,
                    markedRange: NSRange(location: NSNotFound, length: 0)
                )
            }),
            ("host commit", { $0.finishHostCommitBoundary() }),
            ("Tab", {
                $0.observeHostFieldBoundaryKeyDown(
                    keyCode: KeyCode.tab,
                    passedToHost: true
                )
            }),
            ("Return", {
                $0.observeHostFieldBoundaryKeyDown(
                    keyCode: KeyCode.return,
                    passedToHost: true
                )
            }),
            ("Numpad Enter", {
                $0.observeHostFieldBoundaryKeyDown(
                    keyCode: KeyCode.numpadEnter,
                    passedToHost: true
                )
            }),
            ("app switch", {
                _ = $0.finalize(reason: .appDeactivate)
                $0.markContextStale()
            })
        ]

        for (boundaryName, applyBoundary) in boundaries {
            let client = FakeIMKTextInput()
            client.bundleID = "com.example.synthetic.\(boundaryName)"
            let configuration = MockConfiguration()
            configuration.englishTextConvenienceFallbackEnabled = true
            let composer = HangulComposer(
                statusBar: MockStatusBar(),
                configuration: configuration
            )
            let session = InputSession(
                client: client,
                context: context(bundleId: client.bundleID, documentAccessSafe: true),
                composer: composer
            )
            _ = session.prepareForNonSecureClientWrites()
            composer.setInputMode(.english)

            let space = TestEventFactory.keyEvent(
                char: " ",
                keyCode: KeyCode.space
            )!
            client.document = "x"
            client.selectedRangeValue = NSRange(location: 1, length: 0)
            #expect(!composer.handle(space, delegate: session.adapter))
            client.document = "x "
            client.selectedRangeValue = NSRange(location: 2, length: 0)

            applyBoundary(session)

            client.document = "y "
            client.selectedRangeValue = NSRange(location: 2, length: 0)
            #expect(
                !composer.handle(space, delegate: session.adapter),
                "\(boundaryName) must not reuse the previous field's space timing"
            )
            #expect(client.document == "y ")
        }
    }

    @Test("New physical field-boundary keys do not inherit duplicate disposition")
    func newFieldBoundaryEventsDoNotInheritDuplicateDisposition() async {
        for keyCode in [KeyCode.tab, KeyCode.return, KeyCode.numpadEnter] {
            let client = FakeIMKTextInput()
            let composer = HangulComposer(
                statusBar: MockStatusBar(),
                configuration: MockConfiguration()
            )
            let session = InputSession(
                client: client,
                context: context(bundleId: "com.apple.TextEdit", documentAccessSafe: true),
                composer: composer
            )
            _ = session.prepareForNonSecureClientWrites()

            let original = KeyDownSnapshot(timestamp: 100, keyCode: keyCode)
            #expect(session.registerKeyDown(original) == .process)
            session.observeHostFieldBoundaryKeyDown(keyCode: keyCode, passedToHost: true)
            await flushMainQueue()
            #expect(session.refreshContextIfNeeded { _ in
                self.context(bundleId: client.bundleID, documentAccessSafe: true)
            })

            let fastPhysical = KeyDownSnapshot(timestamp: 100.02, keyCode: keyCode)
            #expect(session.registerKeyDown(fastPhysical) == .process)
            #expect(!session.contextNeedsRefresh)
            session.observeHostFieldBoundaryKeyDown(keyCode: keyCode, passedToHost: true)
            #expect(session.contextNeedsRefresh)
            #expect(session.refreshContextIfNeeded { _ in
                self.context(bundleId: client.bundleID, documentAccessSafe: true)
            })

            let repeated = KeyDownSnapshot(
                timestamp: 100.03,
                keyCode: keyCode,
                isARepeat: true
            )
            #expect(session.registerKeyDown(repeated) == .process)
            #expect(!session.contextNeedsRefresh)
            session.observeHostFieldBoundaryKeyDown(keyCode: keyCode, passedToHost: false)
            #expect(!session.contextNeedsRefresh)
        }
    }

    @Test("Client-consumed Return and its duplicate keep the current field")
    func clientConsumedReturnKeepsContext() async {
        for bundleId in ["com.goodnotesapp.x", "com.nousresearch.hermes"] {
            let client = FakeIMKTextInput()
            client.bundleID = bundleId
            let composer = HangulComposer(
                statusBar: MockStatusBar(),
                configuration: MockConfiguration()
            )
            let shortcutState = HanjaShortcutSessionStateStore(initialState: .nonsecure)
            let session = InputSession(
                client: client,
                context: context(bundleId: bundleId, documentAccessSafe: true),
                composer: composer,
                invalidateHanjaShortcutSessionState: {
                    shortcutState.update(.unknown)
                }
            )
            _ = session.prepareForNonSecureClientWrites()
            composer.markKeystroke(bundleId: bundleId)
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
                delegate: session.adapter
            )

            let snapshot = KeyDownSnapshot(timestamp: 100, keyCode: KeyCode.return)
            #expect(session.registerKeyDown(snapshot) == .process)
            let handled = composer.handle(
                TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.return)!,
                delegate: session.adapter
            )
            session.observeHostFieldBoundaryKeyDown(
                keyCode: KeyCode.return,
                passedToHost: !handled
            )

            #expect(handled)
            #expect(!session.contextNeedsRefresh)
            #expect(shortcutState.state == .nonsecure)
            await flushMainQueue()
            #expect(session.registerKeyDown(snapshot) == .consumeDuplicate)
            #expect(!session.contextNeedsRefresh)
            #expect(shortcutState.state == .nonsecure)
        }
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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

    @Test("Empty-engine fallback never clears marked text replaced by the host")
    func emptyEngineFallbackRejectsUnownedMarkedText() {
        let (session, composer, client) = makeDirectFallbackSession()

        session.adapter.setMarkedText("ㄱ")
        #expect(!composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        client.document = "ㄴ"
        client.markedText = "ㄴ"
        client.markedRangeValue = NSRange(location: 0, length: 1)
        client.selectedRangeValue = NSRange(location: 1, length: 0)

        #expect(!session.finalize(reason: .mouseCommit))
        #expect(client.document == "ㄴ")
        #expect(client.markedText == "ㄴ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Marked finalize never commits over marked text replaced by the host")
    func markedFinalizeRejectsUnownedMarkedText() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        client.document = "ㄴ"
        client.markedText = "ㄴ"
        client.markedRangeValue = NSRange(location: 0, length: 1)
        client.selectedRangeValue = NSRange(location: 1, length: 0)

        #expect(session.finalize(reason: .deactivateServer))
        #expect(!composer.hasActiveComposition)
        #expect(client.document == "ㄴ")
        #expect(client.markedText == "ㄴ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("An unproven marked range never commits old composition at a new caret")
    func mouseBoundaryRejectsUnprovenMarkedOwnership() {
        let cases: [(document: String, markedRange: NSRange, readbackUnavailable: Bool)] = [
            ("UNRELATED", NSRange(location: NSNotFound, length: 0), false),
            ("OTHER", NSRange(location: 0, length: 5), true)
        ]

        for testCase in cases {
            let (session, composer, client) = makeMarkedSession()
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )

            client.document = testCase.document
            client.markedText = testCase.markedRange.location == NSNotFound
                ? ""
                : testCase.document
            client.markedRangeValue = testCase.markedRange
            client.selectedRangeValue = NSRange(
                location: client.document.utf16.count,
                length: 0
            )
            client.attributedSubstringUnavailable = testCase.readbackUnavailable

            #expect(session.reconcileMouseDown(
                characterIndex: client.selectedRangeValue.location,
                markedRange: client.markedRangeValue
            ))
            #expect(client.document == testCase.document)
            #expect(client.insertCalls.isEmpty)
            #expect(!composer.hasActiveComposition)
            #expect(session.contextNeedsRefresh)
        }
    }

    @Test("Canonical marked finalize remains available without document readback")
    func markedFinalizeWithoutDocumentAccessUsesCanonicalCommit() {
        let (session, composer, client) = makeMarkedSession()
        client.attributedSubstringUnavailable = true
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )

        #expect(session.finalize(reason: .deactivateServer))
        #expect(client.document == "ㄱ")
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.1.location == NSNotFound)
    }

    @Test("Marked ownership is rechecked after a reentrant client read")
    func markedFinalizeRejectsReentrantOwnershipChange() {
        for revokeContext in [false, true] {
            let (session, composer, client) = makeMarkedSession()
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )
            client.onAttributedSubstring = {
                client.onAttributedSubstring = nil
                if revokeContext {
                    session.markContextStale()
                } else {
                    client.document = "ㄴ"
                    client.markedText = "ㄴ"
                    client.markedRangeValue = NSRange(location: 0, length: 1)
                    client.selectedRangeValue = NSRange(location: 1, length: 0)
                }
            }

            #expect(session.finalize(reason: .deactivateServer))
            #expect(client.insertCalls.isEmpty)
            if revokeContext {
                #expect(session.contextNeedsRefresh)
                #expect(client.markedText == "ㄱ")
            } else {
                #expect(client.document == "ㄴ")
                #expect(client.markedText == "ㄴ")
            }
        }
    }

    @Test("Same-client activation during delivery revokes subsequent client writes")
    func deliveryReactivationRevokesSubsequentClientWrites() {
        let (session, composer, client) = makeMarkedSession()
        for event in [
            TestEventFactory.keyEvent(char: "d", keyCode: 2)!,
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            TestEventFactory.keyEvent(char: "s", keyCode: 1)!
        ] {
            _ = composer.handle(event, delegate: session.adapter)
        }

        let markCountBeforeReactivation = client.markCalls.count
        client.onInsertText = {
            client.onInsertText = nil
            client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
            session.markContextStaleForSameClientReactivation()
        }
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )

        #expect(client.document == "아")
        #expect(client.markCalls.count == markCountBeforeReactivation)
        #expect(client.markedText.isEmpty)
        #expect(composer.hasActiveComposition)
        #expect(session.contextNeedsRefresh)
    }

    @Test("A new session defers Roman layout sync until a nonsecure boundary")
    func initialRomanLayoutSyncIsDeferred() {
        let (session, _, _) = makeMarkedSession()
        var synchronizedModes: [InputMode] = []

        #expect(session.reconcileDeferredRomanKeyboardLayoutSync { _, mode in
            synchronizedModes.append(mode)
        })
        #expect(synchronizedModes == [.korean])
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

    @Test("Secure cleanup rejects marked text no longer owned by PriType")
    func secureCleanupRejectsUnownedMarkedText() {
        let sessions = [makeDirectFallbackSession(), makeMarkedSession()]

        for (session, composer, client) in sessions {
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )
            #expect(client.markedText == "ㄱ")

            session.discardForSecureInput()
            client.markedText = "나"
            client.markedRangeValue = NSRange(location: 0, length: 1)

            #expect(!session.prepareForNonSecureClientWrites())
            #expect(client.insertCalls.isEmpty)
            #expect(client.markedText == "나")
        }
    }

    @Test("Secure cleanup rechecks marked ownership after client readback")
    func secureCleanupRejectsReentrantMarkedTextChange() {
        let (session, composer, client) = makeMarkedSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.discardForSecureInput()
        client.onAttributedSubstring = {
            client.onAttributedSubstring = nil
            client.document = "ㄴ"
            client.markedText = "ㄴ"
            client.markedRangeValue = NSRange(location: 0, length: 1)
            client.selectedRangeValue = NSRange(location: 1, length: 0)
        }

        #expect(!session.prepareForNonSecureClientWrites())
        #expect(client.document == "ㄴ")
        #expect(client.markedText == "ㄴ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Secure cleanup abandons unreadable or overflowing marked text")
    func secureCleanupAbandonsInvalidMarkedText() {
        let invalidations: [(String, (FakeIMKTextInput) -> Void)] = [
            ("unreadable", { client in
                client.attributedSubstringUnavailable = true
            }),
            ("garbage", { client in
                client.markedRangeValue = NSRange(
                    location: DirectInsertionPlanner.maxReasonableLocation,
                    length: 1
                )
            }),
            ("overflowing", { client in
                client.markedRangeValue = NSRange(location: Int.max - 1, length: 2)
            })
        ]

        for (reason, invalidate) in invalidations {
            let (session, composer, client) = makeMarkedSession()
            _ = composer.handle(
                TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
                delegate: session.adapter
            )
            session.discardForSecureInput()
            invalidate(client)

            #expect(
                !session.prepareForNonSecureClientWrites(),
                "\(reason) marked text must be abandoned"
            )
            #expect(client.insertCalls.isEmpty)
            #expect(client.markedText == "ㄱ")
        }
    }

    @Test("Secure cleanup compares canonically normalized marked text")
    func secureCleanupAcceptsCanonicalEquivalentMarkedText() {
        let (session, composer, client) = makeMarkedSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "가")

        session.discardForSecureInput()
        client.markedText = "가"
        client.markedRangeValue = NSRange(location: 0, length: 2)

        #expect(session.prepareForNonSecureClientWrites())
        #expect(client.insertCalls.count == 1)
        #expect(client.insertCalls.first?.1 == NSRange(location: 0, length: 2))
    }

    @Test("A field reached by Secure Tab never receives deferred marked-text cleanup")
    func secureTabFieldAbandonsDeferredMarkedCleanup() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(!PriTypeInputController.routeSecureKeyDown(
            in: session,
            keyCode: KeyCode.tab
        ))
        #expect(client.insertCalls.isEmpty)

        #expect(session.contextNeedsRefresh)
        session.markContextStaleForSameClientReactivation()
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
        session.markContextStaleForSameClientReactivation()
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

    @Test("Same-client repeated activation preserves a still-owned marked composition")
    func sameClientRepeatedActivationPreservesOwnedComposition() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㄱ")

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        _ = session.prepareForNonSecureClientWrites()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )

        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "가")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Stale activation layout refresh does not write")
    func staleActivationLayoutRefreshDoesNotWrite() {
        let (session, composer, client) = makeMarkedSession()
        #expect(composer.keyboardLayoutId == "2")

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")

        session.markContextStaleForSameClientReactivation()
        session.refreshKeyboardLayoutForStaleActivation(id: "3")

        #expect(composer.keyboardLayoutId == "3")
        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(client.markedText == "ㄱ")
        #expect(session.contextNeedsRefresh)
    }

    @Test("Same-layout stale activation preserves owned composition")
    func sameLayoutStaleActivationPreservesOwnedComposition() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count

        session.markContextStaleForSameClientReactivation()
        session.refreshKeyboardLayoutForStaleActivation(id: composer.keyboardLayoutId)

        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(session.contextNeedsRefresh)
    }

    @Test(
        "Same-client reactivation requires exact readable marked content",
        arguments: [false, true]
    )
    func sameClientReactivationRejectsSameLengthUnownedMarkedText(
        attributedSubstringUnavailable: Bool
    ) {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㄱ")

        // The same IMK client now exposes another normal field whose unrelated mark
        // happens to have the same UTF-16 length as PriType's previous preedit.
        client.markedText = "나"
        client.markedRangeValue = NSRange(location: 0, length: 1)
        client.attributedSubstringUnavailable = attributedSubstringUnavailable
        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )

        #expect(client.markedText == "ㅏ")
        #expect(client.markedText != "가")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Reentrant marked ownership read cannot erase a stronger field boundary")
    func sameClientReactivationReadbackKeepsReentrantStaleBoundary() {
        let (session, composer, client) = makeMarkedSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.markContextStaleForSameClientReactivation()
        client.onAttributedSubstring = {
            client.onAttributedSubstring = nil
            session.markContextStale()
        }

        #expect(!session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        #expect(session.contextNeedsRefresh)
        #expect(client.markedText == "ㄱ")
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Same-client reactivation without an owned marked composition resets convenience timing")
    func sameClientReactivationWithoutOwnedMarkedCompositionResetsConvenience() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let configuration = MockConfiguration()
        configuration.englishTextConvenienceFallbackEnabled = true
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: configuration
        )
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        composer.setInputMode(.english)
        let space = TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!

        client.document = "x"
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        #expect(!composer.handle(space, delegate: session.adapter))
        client.document = "x "
        client.selectedRangeValue = NSRange(location: 2, length: 0)

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        _ = session.prepareForNonSecureClientWrites()

        client.document = "y "
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        #expect(!composer.handle(space, delegate: session.adapter))
        #expect(client.document == "y ")
    }

    @Test("Same-client activation without marked ownership discards the old composition")
    func sameClientActivationWithoutMarkedOwnershipFailsClosed() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        let markCount = client.markCalls.count
        client.markedText = ""
        client.markedRangeValue = NSRange(location: NSNotFound, length: 0)

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        _ = session.prepareForNonSecureClientWrites()

        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.isEmpty)
        #expect(client.markCalls.count == markCount)

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㅏ")
    }

    @Test("Direct delivery fails closed across same-client activation")
    func directDeliveryReactivationFailsClosed() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        _ = session.prepareForNonSecureClientWrites()

        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
    }

    @Test("Secure reactivation cannot authorize cleanup in an unrelated normal field")
    func secureThenUnrelatedNormalReactivationDoesNotWrite() {
        let (session, composer, client) = makeMarkedSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(
                bundleId: client.bundleID,
                hasTextInputCapability: false,
                documentAccessSafe: false
            )
        })
        #expect(!PriTypeInputController.routeSecureKeyDown(in: session, keyCode: 15))
        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)

        client.markedText = "다른"
        client.markedRangeValue = NSRange(location: 0, length: 2)
        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })

        #expect(!session.prepareForNonSecureClientWrites())
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(client.markedText == "다른")

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )
        #expect(client.markedText == "ㅏ")
    }

    @Test("Same-client reactivation cannot weaken a host commit boundary")
    func sameClientReactivationPreservesHostCommitBoundary() {
        let (session, composer, client) = makeDirectFallbackSession()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        session.discardForSecureInput()
        #expect(PriTypeInputController.routeHostCommitComposition(
            in: session,
            sender: client
        ))

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded { _ in
            self.context(bundleId: client.bundleID, documentAccessSafe: true)
        })
        client.markedText = "다른"
        client.markedRangeValue = NSRange(location: 2, length: 2)

        #expect(!session.prepareForNonSecureClientWrites())
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

        session.retireForControllerHandoff(fieldIdentityMayHaveChanged: false)
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

    @Test("A same-client controller handoff revokes writes before retiring")
    func sameClientControllerHandoffDoesNotWrite() {
        let (session, composer, client) = makeDirectFallbackSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )

        session.retireForControllerHandoff(fieldIdentityMayHaveChanged: true)

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
        _ = session.prepareForNonSecureClientWrites()

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

    @Test("Same-client surface changes discard old ownership and rebuild marked delivery")
    func sameClientSurfaceChangeRebuildsMarkedAdapter() {
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

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(session.adapter.hostSurface == .appKit)
        #expect(client.markedPayloadWasAttributed == [true])

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

        session.markContextStaleForSameClientReactivation()
        #expect(session.refreshContextIfNeeded(using: { _ in blinkContext }))
        _ = session.prepareForNonSecureClientWrites()
        session.ensureAdapterMatchesPolicy()

        #expect(!composer.hasActiveComposition)
        #expect(client.insertCalls.isEmpty)
        #expect(session.adapter.deliveryMode == .markedText)
        #expect(session.adapter.hostSurface == .blinkWeb)

        session.adapter.setMarkedText("가")
        #expect(client.markedPayloadWasAttributed == [true, false])
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
            hasGlobalSecureInput: false
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

    @Test("A different-client handoff commits the old field before late deactivation")
    func differentClientHandoffCommitsBeforeLateDeactivation() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.TextEdit"
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID, documentAccessSafe: true),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: session.adapter)
        #expect(client.markedText == "가")

        session.retireForControllerHandoff(fieldIdentityMayHaveChanged: false)

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
