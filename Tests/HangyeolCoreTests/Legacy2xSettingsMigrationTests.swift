import Foundation
import Testing
@testable import HangyeolCore

@Suite("2.x Settings Migration")
struct Legacy2xSettingsMigrationTests {
    @Test("Copies supported settings without overwriting a 3.0 value")
    func preservesCurrentValues() throws {
        let suiteName = "Legacy2xSettingsMigrationTests.destination.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let currentKeyboardKey = "\(ProductIdentity.preferencePrefix).keyboardId"
        let currentToggleKey = "\(ProductIdentity.preferencePrefix).toggleKey"
        defaults.set("2", forKey: currentKeyboardKey)

        let migratedKeys = Legacy2xSettingsMigration.migrate(
            values: [
                "com.pritype.keyboardId": "3",
                "com.pritype.toggleKey": 54
            ],
            into: defaults
        )

        #expect(defaults.string(forKey: currentKeyboardKey) == "2")
        #expect(defaults.integer(forKey: currentToggleKey) == 54)
        #expect(!migratedKeys.contains(currentKeyboardKey))
        #expect(migratedKeys.contains(currentToggleKey))
    }

    @Test("Consumes the legacy preference domain exactly once")
    func consumesLegacyDomainOnce() throws {
        let destinationName = "Legacy2xSettingsMigrationTests.destination.\(UUID().uuidString)"
        let legacyDomainName = "Legacy2xSettingsMigrationTests.source.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: destinationName))
        let domainStore = try #require(UserDefaults(suiteName: legacyDomainName))
        defer {
            defaults.removePersistentDomain(forName: destinationName)
            domainStore.removePersistentDomain(forName: legacyDomainName)
        }

        domainStore.setPersistentDomain(
            ["com.pritype.keyboardId": "3y"],
            forName: legacyDomainName
        )

        #expect(Legacy2xSettingsMigration.migrateInstalledPreferences(
            destination: defaults,
            domainStore: domainStore,
            legacyDomainName: legacyDomainName
        ))
        #expect(defaults.string(
            forKey: "\(ProductIdentity.preferencePrefix).keyboardId"
        ) == "3y")
        #expect(domainStore.persistentDomain(forName: legacyDomainName) == nil)
        #expect(!Legacy2xSettingsMigration.migrateInstalledPreferences(
            destination: defaults,
            domainStore: domainStore,
            legacyDomainName: legacyDomainName
        ))
    }
}
