import Cocoa
import InputMethodKit
import Testing
@testable import PriTypeCore

@Suite("Input method menu")
struct InputMethodMenuTests {
    @Test("Settings and About use InputMethodKit command dispatch")
    func commandItemsRemainEnabledForTextInputMenuAgent() throws {
        let menu = PriTypeInputController.makeInputMethodMenu()

        #expect(!menu.autoenablesItems)
        #expect(menu.items.count == 3)

        let settings = menu.items[0]
        #expect(settings.title == "PriType 설정...")
        #expect(settings.action == #selector(IMKInputController.showPreferences(_:)))
        #expect(settings.target == nil)
        #expect(settings.isEnabled)

        #expect(menu.items[1].isSeparatorItem)

        let about = menu.items[2]
        #expect(about.title == "PriType 정보")
        #expect(about.action != nil)
        #expect(about.target == nil)
        #expect(about.isEnabled)
    }
}
