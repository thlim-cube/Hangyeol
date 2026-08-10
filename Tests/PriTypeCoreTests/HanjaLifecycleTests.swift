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
            screenFrames: [main, left, below],
            mainScreenFrame: main
        ))

        #expect(converted == NSRect(x: -1_000, y: 962, width: 0, height: 18))
    }

    @Test("Converts AX coordinates using a display below the main display")
    func convertsBelowDisplayAccessibilityRect() throws {
        let converted = try #require(CursorRectResolver.appKitRect(
            fromAccessibilityRect: NSRect(x: 500, y: 1_200, width: 0, height: 18),
            screenFrames: [main, left, below],
            mainScreenFrame: main
        ))

        #expect(converted == NSRect(x: 500, y: -138, width: 0, height: 18))
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

    private func makeComposer(presenter: MockHanjaCandidatePresenter) -> HangulComposer {
        HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            candidateWindow: presenter
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
}

private final class MockHanjaCandidatePresenter: HanjaCandidatePresenting, @unchecked Sendable {
    var isVisible = false
    private(set) var dismissCount = 0
    private(set) var selectionCallbacks: [@Sendable (HanjaEntry) -> Void] = []

    func show(
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void
    ) {
        isVisible = !entries.isEmpty
        selectionCallbacks.append(onSelect)
    }

    func dismiss() {
        isVisible = false
        dismissCount += 1
    }

    func handleKey(_ event: NSEvent) -> Bool {
        false
    }
}
