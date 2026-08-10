import Cocoa
import Testing
@testable import PriTypeCore

@Suite("Input mode and composition ownership")
struct InputModeOwnershipTests {
    private func makeComposer(
        store: InputModeStore,
        statusBar: MockStatusBar = MockStatusBar()
    ) -> HangulComposer {
        HangulComposer(
            statusBar: statusBar,
            configuration: MockConfiguration(),
            inputModeStore: store
        )
    }

    @Test("Sessions share mode without sharing libhangul composition")
    func sharedModeIsolatedComposition() {
        let store = InputModeStore()
        let first = makeComposer(store: store)
        let second = makeComposer(store: store)
        let firstDelegate = MockComposerDelegate()
        let secondDelegate = MockComposerDelegate()

        _ = first.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: firstDelegate)
        _ = first.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: firstDelegate)

        #expect(first.hasActiveComposition)
        #expect(firstDelegate.markedText == "가")
        #expect(!second.hasActiveComposition)
        #expect(secondDelegate.markedText.isEmpty)

        second.setInputMode(.english)
        #expect(first.inputMode == .english)
        #expect(second.inputMode == .english)
        #expect(first.hasActiveComposition, "Changing the shared mode must not flush another session")

        let committed = first.flushCommitString()
        #expect(committed == "가")
        #expect(!first.hasActiveComposition)
        #expect(!second.hasActiveComposition)
    }

    @Test("Standalone composers retain isolated mode stores")
    func standaloneComposerModeIsolation() {
        let first = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let second = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())

        first.setInputMode(.english)

        #expect(first.inputMode == .english)
        #expect(second.inputMode == .korean)
    }
}

@Suite("Process-wide input ownership")
struct ProcessWideInputOwnershipTests {
    private final class Owner {}

    @Test("Claim retires the previous owner before publishing the next owner")
    func claimOrdersRetirementBeforeReplacement() {
        let registry = ActiveOwnerHandoffRegistry<Owner>()
        let first = Owner()
        let second = Owner()
        var retiredOwner: Owner?
        var ownerVisibleDuringRetirement: Owner?

        registry.claim(first) { _ in }
        registry.claim(second) { retiring in
            retiredOwner = retiring
            ownerVisibleDuringRetirement = registry.owner
        }

        #expect(retiredOwner === first)
        #expect(ownerVisibleDuringRetirement === first)
        #expect(registry.owner === second)

        registry.release(first)
        #expect(registry.owner === second)
        registry.release(second)
        #expect(registry.owner == nil)
    }
}
