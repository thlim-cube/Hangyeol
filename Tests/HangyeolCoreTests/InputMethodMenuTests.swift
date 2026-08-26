import Cocoa
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
        #expect(settings.title == "\(L10n.app.name) \(L10n.settings.title)...")
        #expect(settings.action == #selector(IMKInputController.showPreferences(_:)))
        #expect(settings.target == nil)
        #expect(settings.isEnabled)

        #expect(menu.items[1].isSeparatorItem)

        let about = menu.items[2]
        #expect(about.title == "\(L10n.app.name) \(L10n.about.title)")
        #expect(about.action != nil)
        #expect(about.target == nil)
        #expect(about.isEnabled)
    }
}
