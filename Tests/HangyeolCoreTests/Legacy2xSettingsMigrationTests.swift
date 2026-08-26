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

@Suite("3.0 identifier migration")
struct Legacy3xSettingsMigrationTests {
    @Test("Moves com.meapri settings to the com.thlim preference namespace")
    func migratesRetiredIdentifierPreferences() throws {
        let suiteName = "Legacy3xSettingsMigrationTests.destination.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let migratedKeys = Legacy3xSettingsMigration.migrate(
            values: [
                "com.meapri.hangyeol.keyboardId": "3y",
                "com.meapri.hangyeol.toggleKey": 54
            ],
            into: defaults
        )

        let keyboardKey = "com.thlim.hangyeol.keyboardId"
        let toggleKey = "com.thlim.hangyeol.toggleKey"
        #expect(defaults.string(forKey: keyboardKey) == "3y")
        #expect(defaults.integer(forKey: toggleKey) == 54)
        #expect(migratedKeys == [keyboardKey, toggleKey])
    }

    @Test("Moves settings from the short-lived misordered com.thlim domain")
    func migratesMisorderedIdentifierPreferences() throws {
        let suiteName = "Legacy3xSettingsMigrationTests.misordered.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keyboardKey = "com.thlim.hangyeol.keyboardId"
        let toggleKey = "com.thlim.hangyeol.toggleKey"
        let migratedKeys = Legacy3xSettingsMigration.migrateMisordered(
            values: [
                keyboardKey: "3f",
                toggleKey: 62
            ],
            into: defaults
        )

        #expect(defaults.string(forKey: keyboardKey) == "3f")
        #expect(defaults.integer(forKey: toggleKey) == 62)
        #expect(migratedKeys == [keyboardKey, toggleKey])
    }

    @Test("Prefers the newer 3.0 domain and consumes both retired domains once")
    func migratesInstalled3xDomainsInRecencyOrder() throws {
        let destinationName = "Legacy3xSettingsMigrationTests.installed.\(UUID().uuidString)"
        let storeName = "Legacy3xSettingsMigrationTests.store.\(UUID().uuidString)"
        let misorderedDomain = "Legacy3xSettingsMigrationTests.misordered.\(UUID().uuidString)"
        let meapriDomain = "Legacy3xSettingsMigrationTests.meapri.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: destinationName))
        let domainStore = try #require(UserDefaults(suiteName: storeName))
        defer {
            defaults.removePersistentDomain(forName: destinationName)
            domainStore.removePersistentDomain(forName: storeName)
            domainStore.removePersistentDomain(forName: misorderedDomain)
            domainStore.removePersistentDomain(forName: meapriDomain)
        }

        let keyboardKey = "com.thlim.hangyeol.keyboardId"
        let toggleKey = "com.thlim.hangyeol.toggleKey"
        domainStore.setPersistentDomain(
            [keyboardKey: "3f"],
            forName: misorderedDomain
        )
        domainStore.setPersistentDomain(
            [
                "com.meapri.hangyeol.keyboardId": "3y",
                "com.meapri.hangyeol.toggleKey": 54
            ],
            forName: meapriDomain
        )

        #expect(Legacy3xSettingsMigration.migrateInstalledPreferences(
            destination: defaults,
            domainStore: domainStore,
            misorderedDomainName: misorderedDomain,
            meapriDomainName: meapriDomain
        ))
        #expect(defaults.string(forKey: keyboardKey) == "3f")
        #expect(defaults.integer(forKey: toggleKey) == 54)
        #expect(domainStore.persistentDomain(forName: misorderedDomain) == nil)
        #expect(domainStore.persistentDomain(forName: meapriDomain) == nil)
        #expect(!Legacy3xSettingsMigration.migrateInstalledPreferences(
            destination: defaults,
            domainStore: domainStore,
            misorderedDomainName: misorderedDomain,
            meapriDomainName: meapriDomain
        ))
    }
}
