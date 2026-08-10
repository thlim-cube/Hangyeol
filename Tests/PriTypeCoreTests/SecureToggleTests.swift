import Foundation
import Testing
@testable import PriTypeCore

@Suite("Secure external toggle")
struct SecureToggleTests {
    private func context(
        bundleId: String,
        hasTextInputCapability: Bool,
        documentAccessSafe: Bool
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: hasTextInputCapability,
            isLikelyDesktopArea: false,
            documentAccessSafe: documentAccessSafe
        )
    }

    private func makeNonsecureSession() -> (
        session: InputSession,
        composer: HangulComposer,
        client: FakeIMKTextInput,
        statusBar: MockStatusBar
    ) {
        let client = FakeIMKTextInput()
        client.bundleID = "com.google.Chrome"
        let statusBar = MockStatusBar()
        let composer = HangulComposer(
            statusBar: statusBar,
            configuration: MockConfiguration()
        )
        let session = InputSession(
            client: client,
            context: context(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        return (session, composer, client, statusBar)
    }

    @Test("Stale password context discards composition and defers only layout sync")
    func secureToggleRefreshesBeforeAnyClientWrite() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.nousresearch.hermes"
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let statusBar = MockStatusBar()
        let composer = HangulComposer(
            statusBar: statusBar,
            configuration: MockConfiguration()
        )
        let session = InputSession(
            client: client,
            context: context(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                documentAccessSafe: true
            ),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        let insertCountBefore = client.insertCalls.count
        let markCountBefore = client.markCalls.count
        session.markContextStaleForSameClientReactivation()
        var analyzeCount = 0
        var keyboardOverrideModes: [InputMode] = []

        let performedClientTransaction = PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in
                analyzeCount += 1
                return context(
                    bundleId: client.bundleID,
                    hasTextInputCapability: false,
                    documentAccessSafe: false
                )
            },
            shouldPassThroughSecureInput: { _, refreshedContext in
                #expect(!refreshedContext.hasTextInputCapability)
                return SecureInputPolicy.shouldPassThrough(SecureInputSignals(
                    bundleId: refreshedContext.bundleId,
                    hasTextInputCapability: refreshedContext.hasTextInputCapability,
                    hasInvalidSelection: true,
                    hasGlobalSecureInput: false
                ))
            },
            syncRomanKeyboardLayout: { _, mode in
                keyboardOverrideModes.append(mode)
            }
        )

        #expect(!performedClientTransaction)
        #expect(analyzeCount == 1)
        #expect(!session.contextNeedsRefresh)
        #expect(!composer.hasActiveComposition)
        #expect(composer.inputMode == .english)
        #expect(statusBar.currentMode == .english)
        #expect(client.markedText == "ㄱ", "Secure discard must not clear host marked text")
        #expect(client.insertCalls.count == insertCountBefore)
        #expect(client.markCalls.count == markCountBefore)
        #expect(keyboardOverrideModes.isEmpty)

        session.markContextStale()
        #expect(session.refreshContextForInputBoundary { _ in
            context(
                bundleId: client.bundleID,
                hasTextInputCapability: true,
                documentAccessSafe: true
            )
        })
        var operationOrder: [String] = []
        _ = session.prepareForNonSecureClientWrites()
        #expect(session.reconcileDeferredRomanKeyboardLayoutSync { _, mode in
            keyboardOverrideModes.append(mode)
            operationOrder.append("layout")
        })
        session.ensureAdapterMatchesPolicy()
        operationOrder.append("input")
        let handled = composer.handle(
            TestEventFactory.keyEvent(char: "a", keyCode: 0)!,
            delegate: session.adapter
        )

        #expect(keyboardOverrideModes == [.english])
        #expect(operationOrder == ["layout", "input"])
        #expect(!handled, "The first English key must pass through after layout sync")
        #expect(!session.reconcileDeferredRomanKeyboardLayoutSync { _, _ in
            Issue.record("Deferred layout sync must run once")
        })
    }

    @Test("Nonsecure toggle preserves finalize, layout, and mode order")
    func nonsecureTogglePreservesTransactionOrder() {
        let (session, composer, client, statusBar) = makeNonsecureSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        var modeDuringKeyboardOverride: InputMode?

        let performedClientTransaction = PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in
                Issue.record("Fresh context must not be analyzed again")
                return session.context
            },
            shouldPassThroughSecureInput: { _, _ in false },
            syncRomanKeyboardLayout: { _, _ in
                #expect(client.document == "ㄱ", "Composition must finalize before layout override")
                #expect(!composer.hasActiveComposition)
                modeDuringKeyboardOverride = composer.inputMode
            }
        )

        #expect(performedClientTransaction)
        #expect(client.insertCalls.count == 1)
        #expect(modeDuringKeyboardOverride == .korean)
        #expect(composer.inputMode == .english)
        #expect(statusBar.currentMode == .english)
    }

    @Test("Context-analysis reentry aborts the stale outer toggle")
    func contextAnalysisReentryAbortsToggle() {
        let (session, composer, _, _) = makeNonsecureSession()
        session.markContextStaleForSameClientReactivation()
        var secureProbeCount = 0
        var layoutCount = 0

        #expect(!PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in
                session.retireForControllerHandoff(fieldIdentityMayHaveChanged: true)
                return session.context
            },
            shouldPassThroughSecureInput: { _, _ in
                secureProbeCount += 1
                return false
            },
            syncRomanKeyboardLayout: { _, _ in
                layoutCount += 1
            }
        ))
        #expect(session.contextNeedsRefresh)
        #expect(composer.inputMode == .korean)
        #expect(secureProbeCount == 0)
        #expect(layoutCount == 0)
    }

    @Test("Secure-query reentry aborts layout and mode writes")
    func secureQueryReentryAbortsToggle() {
        let (session, composer, client, _) = makeNonsecureSession()
        var layoutCount = 0
        var publishedSecureStates: [Bool] = []

        #expect(!PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in
                Issue.record("Fresh context must not be analyzed")
                return session.context
            },
            shouldPassThroughSecureInput: { _, _ in
                session.markContextStale()
                return false
            },
            publishSecureInputState: { isSecureInput in
                publishedSecureStates.append(isSecureInput)
            },
            syncRomanKeyboardLayout: { _, _ in
                layoutCount += 1
            }
        ))
        #expect(session.contextNeedsRefresh)
        #expect(composer.inputMode == .korean)
        #expect(layoutCount == 0)
        #expect(publishedSecureStates.isEmpty)
        #expect(client.insertCalls.isEmpty)
        #expect(client.markCalls.isEmpty)
    }

    @Test("A reentrant deferred layout sync is retried at the next safe boundary")
    func deferredLayoutReentryKeepsRecoveryPending() {
        let (session, _, _, _) = makeNonsecureSession()
        var synchronizedModes: [InputMode] = []

        #expect(!session.reconcileDeferredRomanKeyboardLayoutSync { _, mode in
            synchronizedModes.append(mode)
            session.markContextStaleForSameClientReactivation()
        })
        #expect(session.contextNeedsRefresh)

        #expect(session.refreshContextIfNeeded { _ in session.context })
        _ = session.prepareForNonSecureClientWrites()
        #expect(session.reconcileDeferredRomanKeyboardLayoutSync { _, mode in
            synchronizedModes.append(mode)
        })
        #expect(synchronizedModes == [.korean, .korean])
    }

    @Test("Layout-override reentry keeps the toggle intent and retry token")
    func layoutOverrideReentryPreservesToggleIntent() {
        let (session, composer, _, _) = makeNonsecureSession()
        var synchronizedModes: [InputMode] = []

        #expect(!PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in session.context },
            shouldPassThroughSecureInput: { _, _ in false },
            syncRomanKeyboardLayout: { _, mode in
                synchronizedModes.append(mode)
                session.markContextStaleForSameClientReactivation()
            }
        ))
        #expect(composer.inputMode == .english)
        #expect(session.contextNeedsRefresh)

        #expect(session.refreshContextIfNeeded { _ in session.context })
        _ = session.prepareForNonSecureClientWrites()
        #expect(session.reconcileDeferredRomanKeyboardLayoutSync { _, mode in
            synchronizedModes.append(mode)
        })
        #expect(synchronizedModes == [.english, .english])
    }

    @Test("A retired transition cannot overwrite the newer owner's mode")
    func retiredTransitionDoesNotWriteModeIntent() {
        let (session, composer, client, _) = makeNonsecureSession()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        var ownsTransaction = true
        var layoutCount = 0
        client.onInsertText = {
            client.onInsertText = nil
            ownsTransaction = false
        }

        #expect(!PriTypeInputController.routeExternalModeTransition(
            in: session,
            source: .customKey,
            trace: .begin(source: .customKey),
            analyzeContext: { _ in session.context },
            shouldPassThroughSecureInput: { _, _ in false },
            syncRomanKeyboardLayout: { _, _ in
                layoutCount += 1
            },
            transactionIsCurrent: {
                ownsTransaction
            }
        ))
        #expect(composer.inputMode == .korean)
        #expect(layoutCount == 0)
    }
}
