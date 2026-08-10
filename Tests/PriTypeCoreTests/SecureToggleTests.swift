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
        let client = FakeIMKTextInput()
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
}
