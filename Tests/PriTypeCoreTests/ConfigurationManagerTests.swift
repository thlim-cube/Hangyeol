import Testing
import Foundation
@testable import PriTypeCore

// MARK: - ConfigurationManager Tests

@Suite("ConfigurationManager", .serialized)
struct ConfigurationManagerTests {
    
    // MARK: - Keyboard Layout Tests
    
    @Test("Default keyboard ID is Dubeolsik (2)")
    func defaultKeyboardId() {
        #expect(ConfigurationManager.shared.keyboardId == "2")
    }
    
    @Test("Keyboard ID persists to UserDefaults")
    func keyboardIdPersistence() {
        let original = ConfigurationManager.shared.keyboardId
        defer { ConfigurationManager.shared.keyboardId = original }
        
        ConfigurationManager.shared.keyboardId = "3"
        #expect(ConfigurationManager.shared.keyboardId == "3")
        
        let stored = UserDefaults.standard.string(forKey: "com.pritype.keyboardId")
        #expect(stored == "3")
    }

    @Test("Roman keyboard layout preference defaults to forced ABC/US and persists")
    func romanKeyboardLayoutPreferencePersistence() {
        let defaults = UserDefaults.standard
        let key = "com.pritype.respectCurrentRomanKeyboardLayout"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(!ConfigurationManager.shared.respectCurrentRomanKeyboardLayout)

        ConfigurationManager.shared.respectCurrentRomanKeyboardLayout = true
        #expect(ConfigurationManager.shared.respectCurrentRomanKeyboardLayout)
        #expect(defaults.bool(forKey: key))
    }

    @Test("Roman keyboard layout selection respects opt-in and falls back safely")
    func romanKeyboardLayoutSelection() {
        let abc = "com.apple.keylayout.ABC"
        let dvorak = "com.apple.keylayout.Dvorak"

        #expect(PriTypeInputController.preferredRomanKeyboardLayoutID(
            inputMode: .english,
            respectCurrentLayout: false,
            currentASCIILayoutID: dvorak,
            forcedLayoutID: abc
        ) == abc)
        #expect(PriTypeInputController.preferredRomanKeyboardLayoutID(
            inputMode: .english,
            respectCurrentLayout: true,
            currentASCIILayoutID: dvorak,
            forcedLayoutID: abc
        ) == dvorak)
        #expect(PriTypeInputController.preferredRomanKeyboardLayoutID(
            inputMode: .korean,
            respectCurrentLayout: true,
            currentASCIILayoutID: dvorak,
            forcedLayoutID: abc
        ) == abc)
        #expect(PriTypeInputController.preferredRomanKeyboardLayoutID(
            inputMode: .english,
            respectCurrentLayout: true,
            currentASCIILayoutID: nil,
            forcedLayoutID: abc
        ) == abc)
    }

    @Test("English text convenience preference can be disabled and persists")
    func englishTextConveniencePreferencePersistence() {
        let config = ConfigurationManager.shared
        let original = config.englishTextConvenienceFallbackEnabled
        defer { config.englishTextConvenienceFallbackEnabled = original }

        config.englishTextConvenienceFallbackEnabled = false
        #expect(!config.englishTextConvenienceFallbackEnabled)

        config.englishTextConvenienceFallbackEnabled = true
        #expect(config.englishTextConvenienceFallbackEnabled)
        #expect(UserDefaults.standard.bool(forKey: "com.pritype.englishTextConvenienceFallbackEnabled"))
    }
    
    // MARK: - Toggle Key Tests (Legacy)
    
    @Test("Default toggle key is rightCommand")
    func defaultToggleKey() {
        #expect(ConfigurationManager.shared.toggleKey == .rightCommand)
    }
    
    @Test("Toggle key persists correctly")
    func toggleKeyPersistence() {
        let original = ConfigurationManager.shared.toggleKey
        defer { ConfigurationManager.shared.toggleKey = original }
        
        ConfigurationManager.shared.toggleKey = .controlSpace
        #expect(ConfigurationManager.shared.toggleKey == .controlSpace)
    }
    
    // MARK: - KeyBinding Tests
    
    @Test("Default toggle key binding is Right Command")
    func defaultToggleKeyBinding() {
        let binding = KeyBinding.defaultToggle
        #expect(binding.keyCode == 54)
        #expect(binding.modifiers == 0)
        #expect(binding.isModifierOnly)
        #expect(binding.displayName == "우측 Command")
    }
    
    @Test("Default hanja key binding is Right Option")
    func defaultHanjaKeyBinding() {
        let binding = KeyBinding.defaultHanja
        #expect(binding.keyCode == 61)
        #expect(binding.modifiers == 0)
        #expect(binding.isModifierOnly)
        #expect(binding.displayName == "우측 Option")
    }
    
    @Test("KeyBinding Codable round-trip")
    func keyBindingCodable() throws {
        let original = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)
        #expect(original == decoded)
    }
    
    @Test("KeyBinding displayName generation for modifier-only keys")
    func keyBindingDisplayNameModifierOnly() {
        #expect(KeyBinding.generateDisplayName(keyCode: 54, modifiers: 0) == "우측 Command")
        #expect(KeyBinding.generateDisplayName(keyCode: 61, modifiers: 0) == "우측 Option")
        #expect(KeyBinding.generateDisplayName(keyCode: 62, modifiers: 0) == "우측 Control")
        #expect(KeyBinding.generateDisplayName(keyCode: 59, modifiers: 0) == "좌측 Control")
        #expect(KeyBinding.generateDisplayName(keyCode: 57, modifiers: 0) == "Caps Lock")
    }
    
    @Test("KeyBinding displayName generation for regular keys")
    func keyBindingDisplayNameRegularKeys() {
        #expect(KeyBinding.generateDisplayName(keyCode: 0, modifiers: 0) == "A")
        #expect(KeyBinding.generateDisplayName(keyCode: 5, modifiers: 0) == "G")
        #expect(KeyBinding.generateDisplayName(keyCode: 49, modifiers: 0) == "Space")
        #expect(KeyBinding.generateDisplayName(keyCode: 122, modifiers: 0) == "F1")
        #expect(KeyBinding.generateDisplayName(keyCode: 18, modifiers: 0) == "1")
    }
    
    @Test("KeyBinding isModifierKey distinguishes modifier from regular keys")
    func keyBindingIsModifierKey() {
        let rightCmd = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        #expect(rightCmd.isModifierKey)
        
        let gKey = KeyBinding(keyCode: 5, modifiers: 0, displayName: "G")
        #expect(!gKey.isModifierKey)
        
        let f13 = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
        #expect(!f13.isModifierKey)
    }
    @Test("KeyBinding Equatable detects conflicts")
    func keyBindingConflictDetection() {
        let toggle = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        let hanja = KeyBinding(keyCode: 61, modifiers: 0, displayName: "우측 Option")
        let duplicate = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        
        #expect(toggle != hanja)
        #expect(toggle == duplicate)
    }
    
    @Test("Legacy ToggleKey migration to KeyBinding")
    func legacyToggleKeyMigration() {
        let rightCmd = ToggleKey.rightCommand.asKeyBinding
        #expect(rightCmd.keyCode == 54)
        #expect(rightCmd.isModifierOnly)
        
        let ctrlSpace = ToggleKey.controlSpace.asKeyBinding
        #expect(ctrlSpace.keyCode == 49)
        #expect(!ctrlSpace.isModifierOnly)
        #expect(ctrlSpace.modifiers != 0)
    }
    
    @Test("Toggle key binding persists correctly")
    func toggleKeyBindingPersistence() {
        let original = ConfigurationManager.shared.toggleKeyBinding
        defer { ConfigurationManager.shared.toggleKeyBinding = original }
        
        let newBinding = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        ConfigurationManager.shared.toggleKeyBinding = newBinding
        #expect(ConfigurationManager.shared.toggleKeyBinding == newBinding)
        #expect(!ConfigurationManager.shared.rightCommandAsToggle)
    }
    
    @Test("Hanja key binding persists correctly")
    func hanjaKeyBindingPersistence() {
        let original = ConfigurationManager.shared.hanjaKeyBinding
        defer { ConfigurationManager.shared.hanjaKeyBinding = original }
        
        let newBinding = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        ConfigurationManager.shared.hanjaKeyBinding = newBinding
        #expect(ConfigurationManager.shared.hanjaKeyBinding == newBinding)
    }
    
    @Test("Convenience properties reflect key bindings")
    func conveniencePropertiesReflectBindings() {
        let original = ConfigurationManager.shared.toggleKeyBinding
        defer { ConfigurationManager.shared.toggleKeyBinding = original }
        
        ConfigurationManager.shared.toggleKeyBinding = .defaultToggle
        #expect(ConfigurationManager.shared.rightCommandAsToggle)
        #expect(!ConfigurationManager.shared.controlSpaceAsToggle)
    }
    
    @Test("System double-space-period setting is readable")
    func systemDoubleSpacePeriodSettingIsReadable() {
        let value = ConfigurationManager.shared.doubleSpacePeriodEnabled
        #expect(value == true || value == false)
    }

}
