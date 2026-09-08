import Cocoa
import Testing
@testable import HangyeolCore

@Suite("Default extended vowel behavior")
struct ExtendedVowelDefaultRegressionTests {
    private func type(_ input: String, into composer: HangulComposer,
                      delegate: MockComposerDelegate) {
        let keys: [Character: UInt16] = [
            "r": 15, "k": 40, "i": 34, "j": 38, "u": 32,
            "l": 37, "o": 31, "O": 31, "p": 35, "P": 35
        ]
        for key in input {
            #expect(composer.handle(
                TestEventFactory.keyEvent(
                    char: String(key), keyCode: keys[key]!,
                    modifiers: key.isUppercase ? .shift : []
                )!, delegate: delegate
            ))
        }
    }

    @Test("The default does not combine extra vowel plus i",
          arguments: ["kl", "il", "jl", "ul", "rkl", "ril", "rjl", "rul"])
    func extraVowelsRemainSeparateByDefault(input: String) {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let delegate = MockComposerDelegate()
        let expected = [
            "kl": "ㅏㅣ", "il": "ㅑㅣ", "jl": "ㅓㅣ", "ul": "ㅕㅣ",
            "rkl": "가ㅣ", "ril": "갸ㅣ", "rjl": "거ㅣ", "rul": "겨ㅣ"
        ]
        type(input, into: composer, delegate: delegate)
        #expect(delegate.fullText + delegate.markedText == expected[input])
    }

    @Test("The default deletes directly typed ae yae e ye as one vowel",
          arguments: ["o", "O", "p", "P", "ro", "rO", "rp", "rP"])
    func directVowelBackspaceIsAtomicByDefault(input: String) {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let delegate = MockComposerDelegate()
        let before = [
            "o": "ㅐ", "O": "ㅒ", "p": "ㅔ", "P": "ㅖ",
            "ro": "개", "rO": "걔", "rp": "게", "rP": "계"
        ]
        type(input, into: composer, delegate: delegate)
        #expect(delegate.markedText == before[input])
        #expect(composer.handle(
            TestEventFactory.keyEvent(char: "\u{7f}", keyCode: KeyCode.backspace)!,
            delegate: delegate
        ))
        #expect(delegate.fullText.isEmpty)
        #expect(delegate.markedText == (input.hasPrefix("r") ? "ㄱ" : ""))
    }
}
