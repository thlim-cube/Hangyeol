import Cocoa
import Testing
@testable import PriTypeCore

@Suite("Hanja cursor geometry")
struct HanjaCursorGeometryTests {
    private let main = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
    private let left = NSRect(x: -1_280, y: 0, width: 1_280, height: 1_024)
    private let below = NSRect(x: 0, y: -900, width: 1_600, height: 900)

    @Test("Accepts caret coordinates on displays left of and below the main display")
    func acceptsNegativeDisplayCoordinates() {
        let screens = [main, left, below]

        #expect(CursorRectResolver.isValidCursorRect(
            NSRect(x: -1_000, y: 500, width: 0, height: 18),
            screenFrames: screens
        ))
        #expect(CursorRectResolver.isValidCursorRect(
            NSRect(x: 500, y: -400, width: 0, height: 18),
            screenFrames: screens
        ))
        #expect(CursorRectResolver.isValidCursorRect(
            NSRect(x: 0, y: 0, width: 0, height: 18),
            screenFrames: screens
        ))
    }

    @Test("Converts AX coordinates using the containing left display")
    func convertsLeftDisplayAccessibilityRect() throws {
        let converted = try #require(CursorRectResolver.appKitRect(
            fromAccessibilityRect: NSRect(x: -1_000, y: 100, width: 0, height: 18),
            screenFrames: [main, left, below]
        ))

        #expect(converted == NSRect(x: -1_000, y: 962, width: 0, height: 18))
    }

    @Test("Keeps the AX origin on the zero screen when focus is on a display below")
    func convertsBelowDisplayAgainstZeroScreen() throws {
        let focusedScreenFrame = below
        let converted = try #require(CursorRectResolver.appKitRect(
            fromAccessibilityRect: NSRect(x: 500, y: 1_200, width: 0, height: 18),
            screenFrames: [main, left, focusedScreenFrame]
        ))

        #expect(converted == NSRect(x: 500, y: -138, width: 0, height: 18))
        #expect(focusedScreenFrame.contains(converted.origin))
    }

    @Test("Rejects non-finite, subnormal, and off-screen coordinates")
    func rejectsGarbageCoordinates() {
        let screens = [main, left, below]

        #expect(!CursorRectResolver.isValidCursorRect(
            NSRect(x: CGFloat.infinity, y: 500, width: 0, height: 18),
            screenFrames: screens
        ))
        #expect(!CursorRectResolver.isValidCursorRect(
            NSRect(x: 1.6e-314, y: 500, width: 0, height: 18),
            screenFrames: screens
        ))
        #expect(!CursorRectResolver.isValidCursorRect(
            NSRect(x: 50_000, y: 50_000, width: 0, height: 18),
            screenFrames: screens
        ))
    }

    @Test("Mouse fallback stays inside the secondary display at its bottom edge")
    func clampsMouseFallbackToSecondaryVisibleFrame() {
        let belowVisibleFrame = NSRect(x: 0, y: -860, width: 1_600, height: 860)
        let fallback = CursorRectResolver.mouseFallbackRect(
            at: NSPoint(x: 500, y: -895),
            screens: [
                (frame: main, visibleFrame: main),
                (frame: below, visibleFrame: belowVisibleFrame),
            ]
        )

        #expect(fallback == NSRect(x: 500, y: -860, width: 0, height: 20))
        #expect(below.contains(fallback.origin))
        #expect(!main.contains(fallback.origin))
    }
}

@Suite("Hanja cursor cache")
struct HanjaCursorCacheTests {
    private let screen = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)

    @Test("Reuses a recent caret only for the same client, session, and screen")
    func cacheIdentityAndScreenMatch() {
        let client = NSObject()
        let session = NSObject()
        let otherClient = NSObject()
        let otherSession = NSObject()
        let rect = NSRect(x: 300, y: 400, width: 0, height: 18)

        var cache = CursorRectCache()
        cache.store(
            rect: rect,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrame: screen,
            timestamp: 10
        )

        #expect(cache.value(
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrames: [screen],
            now: 11,
            maxAge: 2
        ) == rect)

        cache.store(
            rect: rect,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrame: screen,
            timestamp: 10
        )
        #expect(cache.value(
            clientID: ObjectIdentifier(otherClient),
            sessionID: ObjectIdentifier(session),
            screenFrames: [screen],
            now: 11,
            maxAge: 2
        ) == nil)

        cache.store(
            rect: rect,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrame: screen,
            timestamp: 10
        )
        #expect(cache.value(
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(otherSession),
            screenFrames: [screen],
            now: 11,
            maxAge: 2
        ) == nil)

        cache.store(
            rect: rect,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrame: screen,
            timestamp: 10
        )
        #expect(cache.value(
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrames: [],
            now: 11,
            maxAge: 2
        ) == nil)
    }

    @Test("Expires a caret after its TTL")
    func cacheExpiry() {
        let client = NSObject()
        let session = NSObject()
        let rect = NSRect(x: 300, y: 400, width: 0, height: 18)
        var cache = CursorRectCache()
        cache.store(
            rect: rect,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrame: screen,
            timestamp: 10
        )

        #expect(cache.value(
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(session),
            screenFrames: [screen],
            now: 12.001,
            maxAge: 2
        ) == nil)
    }
}

@Suite("Hanja cursor field lifecycle", .serialized)
struct HanjaCursorFieldLifecycleTests {
    @Test("Host-passed Tab cannot reuse the previous field's cached caret")
    func hostPassedTabInvalidatesCachedCaret() throws {
        CursorRectResolver.invalidateCache()
        defer { CursorRectResolver.invalidateCache() }
        let (client, session, previousFieldCaret) = try makeCachedSession()

        session.observeHostNavigationKeyDown(
            keyCode: KeyCode.tab,
            passedToHost: true
        )
        #expect(session.contextNeedsRefresh)
        #expect(session.refreshContextIfNeeded { _ in
            context(bundleId: client.bundleID)
        })

        client.firstRectValue = .zero
        #expect(CursorRectResolver.resolve(
            client: client,
            sessionID: ObjectIdentifier(session),
            accessibilityResolver: { nil }
        ) != previousFieldCaret)
    }

    @Test("Candidate-consumed Tab preserves the current field's cached caret")
    func candidateConsumedTabPreservesCachedCaret() throws {
        CursorRectResolver.invalidateCache()
        defer { CursorRectResolver.invalidateCache() }
        let (client, session, currentFieldCaret) = try makeCachedSession()

        session.observeHostNavigationKeyDown(
            keyCode: KeyCode.tab,
            passedToHost: false
        )
        #expect(!session.contextNeedsRefresh)

        client.firstRectValue = .zero
        #expect(CursorRectResolver.resolve(
            client: client,
            sessionID: ObjectIdentifier(session),
            accessibilityResolver: { nil }
        ) == currentFieldCaret)
    }

    private func makeCachedSession() throws -> (FakeIMKTextInput, InputSession, NSRect) {
        let client = FakeIMKTextInput()
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: HangulComposer(
                statusBar: MockStatusBar(),
                configuration: MockConfiguration()
            )
        )
        let frame = try #require(NSScreen.screens.first?.frame)
        let caret = NSRect(x: frame.midX, y: frame.midY, width: 0, height: 18)
        client.firstRectValue = caret
        #expect(CursorRectResolver.resolve(
            client: client,
            sessionID: ObjectIdentifier(session),
            accessibilityResolver: { nil }
        ) == caret)
        return (client, session, caret)
    }

    private func context(bundleId: String) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            isLightweight: false,
            documentAccessSafe: true
        )
    }
}

@Suite("Hanja candidate lifecycle")
struct HanjaCandidateLifecycleTests {
    @Test("Mode transition dismisses an open candidate panel")
    func modeTransitionDismissesCandidatePanel() {
        let presenter = MockHanjaCandidatePresenter()
        let composer = makeComposer(presenter: presenter)
        let delegate = MockComposerDelegate()
        openCandidate(composer: composer, delegate: delegate)

        #expect(presenter.isVisible)
        composer.setInputMode(.english)

        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 1)
    }

    @Test("A callback retained across a mode transition cannot edit later state")
    func staleSelectionAfterModeTransitionIsIgnored() throws {
        let presenter = MockHanjaCandidatePresenter()
        let composer = makeComposer(presenter: presenter)
        let delegate = MockComposerDelegate()
        openCandidate(composer: composer, delegate: delegate)
        let staleSelection = try #require(presenter.selectionCallbacks.first)

        composer.setInputMode(.english)
        composer.localTextBuffer = "안전"
        staleSelection(HanjaEntry(hangul: "가", hanja: "可", meaning: "synthetic test"))

        #expect(composer.localTextBuffer == "안전")
    }

    @Test("Secure discard invalidates a retained candidate callback without client writes")
    func secureDiscardInvalidatesRetainedCandidateCallback() throws {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        client.document = "가"
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        let shortcut = TestEventFactory.keyEvent(
            char: "x",
            keyCode: 7,
            modifiers: .command
        )!
        _ = composer.handle(shortcut, delegate: session.adapter)
        composer.triggerHanjaLookup()
        let retainedSelection = try #require(presenter.selectionCallbacks.first)
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count
        #expect(presenter.isVisible)

        session.discardForSecureInput()

        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 1)
        retainedSelection(HanjaEntry(
            hangul: "가",
            hanja: "可",
            meaning: "synthetic test"
        ))
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(client.document == "가")
    }

    @Test("Session handoff invalidates a retained candidate callback without client writes")
    func sessionHandoffInvalidatesRetainedCandidateCallback() throws {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        client.document = "가"
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        let shortcut = TestEventFactory.keyEvent(
            char: "x",
            keyCode: 7,
            modifiers: .command
        )!
        _ = composer.handle(shortcut, delegate: session.adapter)
        composer.triggerHanjaLookup()
        let retainedSelection = try #require(presenter.selectionCallbacks.first)
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count
        #expect(presenter.isVisible)

        session.retireForControllerHandoff(fieldIdentityMayHaveChanged: false)

        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 1)
        retainedSelection(HanjaEntry(
            hangul: "가",
            hanja: "可",
            meaning: "synthetic test"
        ))
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(client.document == "가")
    }

    @Test("App focus loss retires an open candidate interaction without client writes")
    func appFocusLossRetiresCandidateInteraction() throws {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        client.document = "가"
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        let composer = makeComposer(presenter: presenter)
        var retirementCount = 0
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer,
            retireActiveControllerAfterFocusLoss: { _ in
                retirementCount += 1
            }
        )
        _ = session.prepareForNonSecureClientWrites()
        let shortcut = TestEventFactory.keyEvent(
            char: "x",
            keyCode: 7,
            modifiers: .command
        )!
        _ = composer.handle(shortcut, delegate: session.adapter)
        composer.triggerHanjaLookup()
        let retainedSelection = try #require(presenter.selectionCallbacks.first)
        composer.localTextBuffer = "가"
        let insertCount = client.insertCalls.count
        let markCount = client.markCalls.count

        #expect(presenter.isVisible)
        #expect(!session.handleAppDeactivation())

        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 1)
        #expect(composer.localTextBuffer.isEmpty)
        #expect(session.contextNeedsRefresh)
        #expect(retirementCount == 1)

        retainedSelection(HanjaEntry(
            hangul: "가",
            hanja: "可",
            meaning: "synthetic test"
        ))
        #expect(client.insertCalls.count == insertCount)
        #expect(client.markCalls.count == markCount)
        #expect(client.document == "가")
    }

    @Test("App focus loss commits an active composition exactly once before retirement")
    func appFocusLossCommitsActiveCompositionOnce() {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        let composer = makeComposer(presenter: presenter)
        var retirementCount = 0
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer,
            retireActiveControllerAfterFocusLoss: { _ in
                retirementCount += 1
            }
        )
        _ = session.prepareForNonSecureClientWrites()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )

        #expect(session.handleAppDeactivation())
        #expect(client.document == "가")
        #expect(client.insertCalls.count == 1)
        #expect(!composer.hasActiveComposition)
        #expect(composer.localTextBuffer.isEmpty)
        #expect(session.contextNeedsRefresh)
        #expect(retirementCount == 1)

        #expect(!session.finalize(reason: .deactivateServer))
        #expect(client.insertCalls.count == 1)
    }

    @Test("A reentrant activation during focus-loss commit keeps the newer owner active")
    func appFocusLossDoesNotRetireReentrantActivation() {
        let client = FakeIMKTextInput()
        let composer = makeComposer(presenter: MockHanjaCandidatePresenter())
        var retirementCount = 0
        let session = InputSession(
            client: client,
            context: context(bundleId: ""),
            composer: composer,
            retireActiveControllerAfterFocusLoss: { _ in
                retirementCount += 1
            }
        )
        _ = session.prepareForNonSecureClientWrites()
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        client.onInsertText = {
            // Same-session activateServer re-arms the focus observer synchronously.
            session.armFocusLossFinalizer()
        }

        #expect(session.handleAppDeactivation())
        client.onInsertText = nil

        #expect(client.document == "ㄱ")
        #expect(session.contextNeedsRefresh)
        #expect(retirementCount == 0)

        // The newer activation remains responsible for its own later focus loss.
        #expect(!session.handleAppDeactivation())
        #expect(retirementCount == 1)
    }

    @Test("Composer keeps only a weak fallback delegate")
    func composerDoesNotRetainFallbackDelegate() {
        let presenter = MockHanjaCandidatePresenter()
        let composer = makeComposer(presenter: presenter)
        let weakDelegate = establishFallbackDelegate(on: composer)

        #expect(weakDelegate.value == nil)
    }

    @Test("Same client with a new input session invalidates a selection snapshot")
    func newSessionInvalidatesSnapshot() {
        let client = NSObject()
        let originalSession = NSObject()
        let nextSession = NSObject()
        let snapshot = HanjaSelectionSnapshot(
            generation: 7,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(originalSession)
        )

        #expect(snapshot.matches(
            generation: 7,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(originalSession)
        ))
        #expect(!snapshot.matches(
            generation: 7,
            clientID: ObjectIdentifier(client),
            sessionID: ObjectIdentifier(nextSession)
        ))
    }

    @Test("An old callback cannot invalidate a newer candidate panel")
    func staleGenerationCannotDismissCurrentPanel() throws {
        let presenter = MockHanjaCandidatePresenter()
        let composer = makeComposer(presenter: presenter)
        let delegate = MockComposerDelegate()
        openCandidate(composer: composer, delegate: delegate)
        let staleSelection = try #require(presenter.selectionCallbacks.first)

        composer.triggerHanjaLookup() // close the first generation
        composer.triggerHanjaLookup() // open a new generation
        #expect(presenter.isVisible)

        staleSelection(HanjaEntry(hangul: "가", hanja: "可", meaning: "synthetic test"))
        #expect(presenter.isVisible)

        composer.setInputMode(.english)
        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 2)
    }

    @Test("A new composer dismisses an orphaned process-wide candidate panel")
    func newComposerDismissesOrphanedPanel() {
        let presenter = MockHanjaCandidatePresenter()
        var originalComposer: HangulComposer? = makeComposer(presenter: presenter)
        let originalDelegate = MockComposerDelegate()
        openCandidate(composer: originalComposer!, delegate: originalDelegate)
        #expect(presenter.isVisible)

        originalComposer = nil
        let nextComposer = makeComposer(presenter: presenter)
        nextComposer.triggerHanjaLookup()

        #expect(!presenter.isVisible)
        #expect(presenter.dismissCount == 1)
    }

    @Test("A previous composer cannot dismiss a newer composer's panel")
    func previousComposerCannotDismissNewerPanel() throws {
        let presenter = MockHanjaCandidatePresenter()
        let originalComposer = makeComposer(presenter: presenter)
        let nextComposer = makeComposer(presenter: presenter)
        let originalDelegate = MockComposerDelegate()
        let nextDelegate = MockComposerDelegate()
        openCandidate(composer: originalComposer, delegate: originalDelegate)
        let oldDismissCallback = try #require(presenter.dismissCallbacks.first)

        let shortcut = TestEventFactory.keyEvent(
            char: "x",
            keyCode: 7,
            modifiers: .command
        )!
        _ = nextComposer.handle(shortcut, delegate: nextDelegate)
        nextDelegate.fullText = "가"
        nextComposer.triggerHanjaLookup() // close the foreign panel
        #expect(!presenter.isVisible)
        nextComposer.triggerHanjaLookup() // open the next composer's panel
        #expect(presenter.isVisible)

        originalComposer.dismissHanjaCandidates()
        #expect(presenter.isVisible)
        #expect(presenter.dismissCount == 1)

        oldDismissCallback()
        #expect(presenter.isVisible)
        #expect(presenter.dismissCount == 1)
    }

    @Test("A click dismisses a candidate after lookup committed the composition")
    func clickDismissesCandidateAfterCompositionCommit() throws {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        _ = composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: session.adapter
        )
        #expect(composer.hasActiveComposition)

        composer.triggerHanjaLookup()
        let staleSelection = try #require(presenter.selectionCallbacks.first)
        #expect(presenter.isVisible)
        #expect(!composer.hasActiveComposition)
        #expect(session.mouseCompositionState == .inactive)

        let didFinalize = session.reconcileMouseDown(
            characterIndex: 0,
            markedRange: client.markedRange()
        )

        #expect(!didFinalize)
        #expect(!presenter.isVisible)
        #expect(composer.localTextBuffer.isEmpty)

        composer.localTextBuffer = "안전"
        staleSelection(HanjaEntry(hangul: "가", hanja: "可", meaning: "synthetic test"))
        #expect(composer.localTextBuffer == "안전")
        #expect(client.document == "가")
    }

    @Test("A click inside live marked text keeps composition but clears click context")
    func clickInsideMarkedTextKeepsComposition() {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()

        _ = composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: session.adapter
        )
        composer.localTextBuffer = "가"
        let markedRange = client.markedRange()

        let didFinalize = session.reconcileMouseDown(
            characterIndex: markedRange.location,
            markedRange: markedRange
        )

        #expect(!didFinalize)
        #expect(composer.hasActiveComposition)
        #expect(client.markedText == "ㄱ")
        #expect(composer.localTextBuffer.isEmpty)
        #expect(!session.contextNeedsRefresh)

        #expect(session.finalize(reason: .appDeactivate))
        #expect(client.document == "ㄱ")
        #expect(client.insertCalls.count == 1)
    }

    @Test("A candidate-consumed Tab and its duplicate keep the active session")
    func candidateConsumedTabKeepsSession() async {
        let presenter = MockHanjaCandidatePresenter()
        presenter.consumedKeyCodes = [KeyCode.tab]
        let client = FakeIMKTextInput()
        client.document = "가"
        client.selectedRangeValue = NSRange(location: 1, length: 0)
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: client.bundleID),
            composer: composer
        )
        _ = session.prepareForNonSecureClientWrites()
        let shortcut = TestEventFactory.keyEvent(
            char: "x",
            keyCode: 7,
            modifiers: .command
        )!
        _ = composer.handle(shortcut, delegate: session.adapter)
        composer.triggerHanjaLookup()
        #expect(presenter.isVisible)

        let tabSnapshot = KeyDownSnapshot(timestamp: 100, keyCode: KeyCode.tab)
        #expect(session.registerKeyDown(tabSnapshot) == .process)
        let handled = composer.handle(
            TestEventFactory.keyEvent(char: "\t", keyCode: KeyCode.tab)!,
            delegate: session.adapter
        )
        session.observeHostNavigationKeyDown(
            keyCode: KeyCode.tab,
            passedToHost: !handled
        )

        #expect(handled)
        #expect(!session.contextNeedsRefresh)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(session.registerKeyDown(tabSnapshot) == .consumeDuplicate)
        #expect(!session.contextNeedsRefresh)
        #expect(presenter.isVisible)
    }

    @Test("A reactivated session refreshes context before Hanja identity is used")
    func reactivatedSessionRefreshesContext() {
        let presenter = MockHanjaCandidatePresenter()
        let client = FakeIMKTextInput()
        let composer = makeComposer(presenter: presenter)
        let session = InputSession(
            client: client,
            context: context(bundleId: "synthetic.stale", isLightweight: true),
            composer: composer
        )
        session.markContextStale()
        var analyzeCount = 0

        let refreshed = session.refreshContextIfNeeded { client in
            analyzeCount += 1
            return context(bundleId: client.bundleIdentifier(), isLightweight: false)
        }
        let refreshedAgain = session.refreshContextIfNeeded { _ in
            analyzeCount += 1
            return context(bundleId: "synthetic.unexpected")
        }

        #expect(refreshed)
        #expect(!refreshedAgain)
        #expect(analyzeCount == 1)
        #expect(!session.contextNeedsRefresh)
        #expect(session.context.bundleId == client.bundleID)
        #expect(!session.context.isLightweight)
    }

    private func makeComposer(presenter: MockHanjaCandidatePresenter) -> HangulComposer {
        HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            candidateWindow: presenter
        )
    }

    private func context(
        bundleId: String,
        isLightweight: Bool = false
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            isLightweight: isLightweight,
            documentAccessSafe: true
        )
    }

    private func openCandidate(composer: HangulComposer, delegate: MockComposerDelegate) {
        // Establish the delegate without adding composition, then let the lookup use
        // the synthetic Hangul immediately before the caret.
        let shortcut = TestEventFactory.keyEvent(char: "x", keyCode: 7, modifiers: .command)!
        _ = composer.handle(shortcut, delegate: delegate)
        delegate.fullText = "가"
        composer.triggerHanjaLookup()
    }

    private func establishFallbackDelegate(on composer: HangulComposer) -> WeakReference<MockComposerDelegate> {
        let delegate = MockComposerDelegate()
        let weakDelegate = WeakReference(delegate)
        let shortcut = TestEventFactory.keyEvent(char: "x", keyCode: 7, modifiers: .command)!
        _ = composer.handle(shortcut, delegate: delegate)
        return weakDelegate
    }
}

private final class MockHanjaCandidatePresenter: HanjaCandidatePresenting, @unchecked Sendable {
    var isVisible = false
    var visiblePresentationID: HanjaCandidatePresentationID? {
        isVisible ? presentationID : nil
    }
    var consumedKeyCodes: Set<UInt16> = []
    private(set) var dismissCount = 0
    private(set) var selectionCallbacks: [@Sendable (HanjaEntry) -> Void] = []
    private(set) var dismissCallbacks: [@Sendable () -> Void] = []
    private var presentationID: HanjaCandidatePresentationID?

    func show(
        presentationID: HanjaCandidatePresentationID,
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void
    ) {
        self.presentationID = presentationID
        isVisible = !entries.isEmpty
        selectionCallbacks.append(onSelect)
        dismissCallbacks.append(onDismiss)
    }

    func dismiss(presentationID: HanjaCandidatePresentationID) -> Bool {
        guard self.presentationID == presentationID else { return false }

        self.presentationID = nil
        isVisible = false
        dismissCount += 1
        return true
    }

    func handleKey(
        _ event: NSEvent,
        presentationID: HanjaCandidatePresentationID
    ) -> Bool {
        guard self.presentationID == presentationID else { return false }
        return consumedKeyCodes.contains(event.keyCode)
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
