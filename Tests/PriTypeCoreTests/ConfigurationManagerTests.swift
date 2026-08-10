import Testing
import Foundation
import CoreGraphics
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

    @Test("Settings conflicts only on the same key and exact recorded modifiers")
    func semanticKeyBindingConflictDetection() {
        let controlSpace = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskControl.rawValue,
            displayName: "Control + Space"
        )
        let sameShortcutDifferentLabel = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskControl.rawValue,
            displayName: "Stored legacy label"
        )
        let optionSpace = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskAlternate.rawValue,
            displayName: "Option + Space"
        )
        let controlShiftSpace = KeyBinding(
            keyCode: 49,
            modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue,
            displayName: "Control + Shift + Space"
        )

        #expect(ShortcutBindingRouter.conflicts(controlSpace, sameShortcutDifferentLabel))
        #expect(!ShortcutBindingRouter.conflicts(controlSpace, optionSpace))
        #expect(!ShortcutBindingRouter.conflicts(controlSpace, controlShiftSpace))
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

    @Test("Binding prewarm resolves both persisted values and keeps hot-path reads in memory")
    func keyBindingPrewarmKeepsHotPathInMemory() throws {
        let suiteName = "com.pritype.tests.key-binding-prewarm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ToggleKey.controlSpace.rawValue, forKey: "com.pritype.toggleKey")
        let storedHanja = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
        defaults.set(
            try JSONEncoder().encode(storedHanja),
            forKey: "com.pritype.hanjaKeyBinding"
        )

        let probe = BindingDataReadProbe(defaults: defaults)
        let config = ConfigurationManager(
            defaults: defaults,
            keyBindingDataReader: probe.read
        )

        #expect(probe.readCount == 0)
        config.prewarmKeyBindingCache()
        #expect(probe.readCount == 2)
        #expect(config.toggleKeyBinding == ToggleKey.controlSpace.asKeyBinding)
        #expect(config.hanjaKeyBinding == storedHanja)

        // Change persistent values behind the cache. A callback-style read must
        // retain the prewarmed snapshot without touching UserDefaults again.
        defaults.set(ToggleKey.rightCommand.rawValue, forKey: "com.pritype.toggleKey")
        defaults.set(
            try JSONEncoder().encode(KeyBinding.defaultHanja),
            forKey: "com.pritype.hanjaKeyBinding"
        )
        for _ in 0..<1_000 {
            #expect(config.toggleKeyBinding == ToggleKey.controlSpace.asKeyBinding)
            #expect(config.hanjaKeyBinding == storedHanja)
        }
        #expect(probe.readCount == 2)

        // Settings writes still replace the in-memory snapshot immediately and
        // persist it without forcing a read on the callback path.
        let updatedToggle = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        config.toggleKeyBinding = updatedToggle
        config.hanjaKeyBinding = .defaultHanja
        #expect(config.toggleKeyBinding == updatedToggle)
        #expect(config.hanjaKeyBinding == .defaultHanja)
        #expect(probe.readCount == 2)
        #expect(try JSONDecoder().decode(
            KeyBinding.self,
            from: #require(defaults.data(forKey: "com.pritype.toggleKeyBinding"))
        ) == updatedToggle)
    }

    @Test("System text features refresh as one snapshot and keep getters memory-only")
    @MainActor
    func systemTextFeatureSnapshotRefresh() throws {
        let suiteName = "com.pritype.tests.system-text-features.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let probe = SystemTextFeatureReadProbe(values: [
            "NSAutomaticPeriodSubstitutionEnabled": true,
            "NSAutomaticCapitalizationEnabled": false,
            "NSAutomaticQuoteSubstitutionEnabled": true,
            "NSAutomaticDashSubstitutionEnabled": false
        ])
        let config = ConfigurationManager(
            defaults: defaults,
            keyBindingDataReader: { _ in nil },
            systemTextFeatureReader: probe.read
        )

        #expect(probe.readCount == 4)
        #expect(config.doubleSpacePeriodEnabled)
        #expect(!config.autoCapitalizationEnabled)
        #expect(config.smartQuoteSubstitutionEnabled)
        #expect(!config.smartDashSubstitutionEnabled)
        #expect(!config.englishTextConvenienceFallbackEnabled)

        probe.replaceValues(with: [
            "NSAutomaticPeriodSubstitutionEnabled": false,
            "NSAutomaticCapitalizationEnabled": true,
            "NSAutomaticQuoteSubstitutionEnabled": false,
            "NSAutomaticDashSubstitutionEnabled": true
        ])
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: defaults
        )

        #expect(probe.readCount == 8)
        #expect(!config.doubleSpacePeriodEnabled)
        #expect(config.autoCapitalizationEnabled)
        #expect(!config.smartQuoteSubstitutionEnabled)
        #expect(config.smartDashSubstitutionEnabled)

        let readsAfterRefresh = probe.readCount
        for _ in 0..<1_000 {
            #expect(!config.doubleSpacePeriodEnabled)
            #expect(config.autoCapitalizationEnabled)
            #expect(!config.smartQuoteSubstitutionEnabled)
            #expect(config.smartDashSubstitutionEnabled)
        }
        #expect(probe.readCount == readsAfterRefresh)

        probe.replaceValues(with: [
            "NSAutomaticPeriodSubstitutionEnabled": true,
            "NSAutomaticCapitalizationEnabled": true,
            "NSAutomaticQuoteSubstitutionEnabled": true,
            "NSAutomaticDashSubstitutionEnabled": true
        ])
        #expect(config.refreshSystemTextFeatureSnapshot())
        #expect(probe.readCount == readsAfterRefresh + 4)
        #expect(config.doubleSpacePeriodEnabled)
        #expect(config.autoCapitalizationEnabled)
        #expect(config.smartQuoteSubstitutionEnabled)
        #expect(config.smartDashSubstitutionEnabled)
        #expect(!config.refreshSystemTextFeatureSnapshot())
    }
    
    @Test("System double-space-period setting is readable")
    func systemDoubleSpacePeriodSettingIsReadable() {
        let value = ConfigurationManager.shared.doubleSpacePeriodEnabled
        #expect(value == true || value == false)
    }

}

private final class BindingDataReadProbe: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storedReadCount = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func read(_ key: String) -> Data? {
        lock.withLock { storedReadCount += 1 }
        return defaults.data(forKey: key)
    }
}

private final class SystemTextFeatureReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool]
    private var storedReadCount = 0

    init(values: [String: Bool]) {
        self.values = values
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func read(_ key: String) -> Bool? {
        lock.withLock {
            storedReadCount += 1
            return values[key]
        }
    }

    func replaceValues(with values: [String: Bool]) {
        lock.withLock {
            self.values = values
        }
    }
}
