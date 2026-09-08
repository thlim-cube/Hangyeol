import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Extended vowel combination policy")
struct ExtendedVowelCombinationPolicyTests {
    private func type(
        _ input: String,
        into composer: HangulComposer,
        delegate: MockComposerDelegate,
        keys: [Character: UInt16] = [
            "r": 15, "k": 40, "i": 34, "j": 38, "u": 32,
            "l": 37, "o": 31, "O": 31, "p": 35, "P": 35,
            "h": 4, "d": 2, "f": 3, "t": 17, "s": 1, "a": 0
        ]
    ) {
        for key in input {
            #expect(composer.handle(
                TestEventFactory.keyEvent(
                    char: String(key),
                    keyCode: keys[key]!,
                    modifiers: key.isUppercase ? .shift : []
                )!,
                delegate: delegate
            ))
        }
    }

    private func makeComposer(
        enabled: Bool = false
    ) -> (HangulComposer, MockComposerDelegate, MockConfiguration) {
        let configuration = MockConfiguration()
        configuration.extendedVowelCombinationEnabled = enabled
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: configuration
        )
        return (composer, MockComposerDelegate(), configuration)
    }

    @Test(
        "Enabled combines extra vowel plus i",
        arguments: [
            ("kl", "ㅐ"), ("il", "ㅒ"), ("jl", "ㅔ"), ("ul", "ㅖ"),
            ("rkl", "개"), ("ril", "걔"), ("rjl", "게"), ("rul", "계")
        ]
    )
    func extraVowelsCombineWhenEnabled(input: String, expected: String) {
        let (composer, delegate, _) = makeComposer(enabled: true)
        type(input, into: composer, delegate: delegate)
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == expected)
    }

    @Test(
        "Enabled splits extra vowels on backspace",
        arguments: [
            ("kl", "ㅏ"), ("il", "ㅑ"), ("jl", "ㅓ"), ("ul", "ㅕ"),
            ("rkl", "가"), ("ril", "갸"), ("rjl", "거"), ("rul", "겨"),
            ("o", "ㅏ"), ("O", "ㅑ"), ("p", "ㅓ"), ("P", "ㅕ"),
            ("ro", "가"), ("rO", "갸"), ("rp", "거"), ("rP", "겨")
        ]
    )
    func extraVowelBackspaceSplitsWhenEnabled(input: String, expected: String) {
        let (composer, delegate, _) = makeComposer(enabled: true)
        type(input, into: composer, delegate: delegate)
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == expected)
    }

    @Test("Live enable combines the next i")
    func liveEnableCombinesNextI() {
        let (composer, delegate, configuration) = makeComposer()
        type("u", into: composer, delegate: delegate)
        configuration.extendedVowelCombinationEnabled = true
        type("l", into: composer, delegate: delegate)
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == "ㅖ")
    }

    @Test("Live disable separates the next i without discarding the current vowel")
    func liveDisableSeparatesNextI() {
        let (composer, delegate, configuration) = makeComposer(enabled: true)
        type("u", into: composer, delegate: delegate)
        configuration.extendedVowelCombinationEnabled = false
        type("l", into: composer, delegate: delegate)
        #expect(delegate.fullText == "ㅕ")
        #expect(delegate.markedText == "ㅣ")
    }

    @Test("Live enable splits a directly typed vowel on the next backspace")
    func liveEnableSplitsDirectVowel() {
        let (composer, delegate, configuration) = makeComposer()
        type("P", into: composer, delegate: delegate)
        configuration.extendedVowelCombinationEnabled = true
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == "ㅕ")
    }

    @Test("Live disable atomically deletes the current extra vowel")
    func liveDisableDeletesExtraVowelAtomically() {
        let (composer, delegate, configuration) = makeComposer(enabled: true)
        type("rul", into: composer, delegate: delegate)
        #expect(delegate.markedText == "계")
        configuration.extendedVowelCombinationEnabled = false
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == "ㄱ")
    }

    @Test("Layout recreation uses the new layout map for i")
    func layoutRecreationUsesActiveLayoutMap() {
        let (composer, delegate, _) = makeComposer()
        composer.updateKeyboardLayout(id: "3")
        type("ft", into: composer, delegate: delegate)
        #expect(delegate.fullText + delegate.markedText == "ㅏㅣ")

        let (composerOn, delegateOn, _) = makeComposer(enabled: true)
        composerOn.updateKeyboardLayout(id: "3")
        type("ft", into: composerOn, delegate: delegateOn)
        #expect(delegateOn.markedText == "ㅐ")

        let (composerL, delegateL, _) = makeComposer()
        composerL.updateKeyboardLayout(id: "3")
        type("fl", into: composerL, delegate: delegateL)
        #expect(delegateL.markedText != "ㅐ")
        #expect(delegateL.fullText + delegateL.markedText != "ㅏㅣ")
    }

    @Test("Unset layout still uses the composer default two-set map")
    func unsetLayoutKeepsDefaultTwoSetMap() {
        let configuration = MockConfiguration()
        configuration.keyboardId = "3"
        configuration.extendedVowelCombinationEnabled = false
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: configuration
        )
        let delegate = MockComposerDelegate()
        type("ul", into: composer, delegate: delegate)
        #expect(delegate.fullText + delegate.markedText == "ㅕㅣ")
    }

    @Test("Atomic deletion does not disable subsequent standard compound splitting")
    func standardCompoundAfterAtomicDeletion() {
        let (composer, delegate, _) = makeComposer()
        let backspace = TestEventFactory.keyEvent(
            char: "\u{7f}", keyCode: KeyCode.backspace
        )!
        type("P", into: composer, delegate: delegate)
        #expect(composer.handle(backspace, delegate: delegate))
        #expect(delegate.markedText.isEmpty)
        type("dhk", into: composer, delegate: delegate)
        #expect(delegate.markedText == "와")
        #expect(composer.handle(backspace, delegate: delegate))
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == "오")
    }

    @Test("Standard o a compound still combines and splits")
    func standardCompoundRemainsFineGrained() {
        let (composer, delegate, _) = makeComposer()
        type("dhk", into: composer, delegate: delegate)
        #expect(delegate.markedText == "와")
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.markedText == "오")
    }

    @Test("Final consonant still splits on backspace")
    func finalConsonantStillSplits() {
        let (composer, delegate, _) = makeComposer()
        type("rkr", into: composer, delegate: delegate)
        #expect(delegate.markedText == "각")
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.markedText == "가")
    }

    @Test(
        "Compound jongseong still splits on backspace",
        arguments: [false, true]
    )
    func compoundJongseongStillSplits(enabled: Bool) {
        let (composer, delegate, _) = makeComposer(enabled: enabled)
        type("akfr", into: composer, delegate: delegate)
        #expect(delegate.markedText == "맑")
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.markedText == "말")
    }
}
