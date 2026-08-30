import Cocoa
import Foundation
import InputMethodKit
import Testing
@testable import HangyeolCore

@Suite("Input method menu")
struct InputMethodMenuTests {
    @Test("Settings and About use InputMethodKit command dispatch")
    func commandItemsRemainEnabledForTextInputMenuAgent() throws {
        let menu = HangyeolInputController.makeInputMethodMenu()

        #expect(!menu.autoenablesItems)
        #expect(menu.items.count == 3)

        let settings = menu.items[0]
        #expect(settings.title == HangyeolInputController.inputMethodSettingsMenuTitle)
        #expect(settings.title.hasSuffix("..."))
        #expect(!settings.title.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty)
        #expect(settings.title.contains("설정") || settings.title.lowercased().contains("settings"))
        #expect(settings.action == #selector(IMKInputController.showPreferences(_:)))
        #expect(settings.target == nil)
        #expect(settings.isEnabled)

        #expect(menu.items[1].isSeparatorItem)

        let about = menu.items[2]
        #expect(about.title == HangyeolInputController.inputMethodAboutMenuTitle)
        #expect(!about.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(about.action != nil)
        #expect(about.target == nil)
        #expect(about.isEnabled)
    }
}
