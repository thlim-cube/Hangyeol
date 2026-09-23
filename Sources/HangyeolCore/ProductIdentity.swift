import Foundation

public enum ProductIdentity {
    public static let displayName = "한결"
    public static let systemName = "Hangyeol"
    public static let bundleID = "com.thlim.inputmethod.Hangyeol"
    public static let inputModeID = bundleID
    public static let connectionName = "\(bundleID)_Connection"
    public static let preferencePrefix = "com.thlim.hangyeol"
    public static let githubRepository = "thlim-cube/Hangyeol"

    public static let releasesURL = URL(
        string: "https://github.com/\(githubRepository)/releases"
    )!
}

enum Legacy3xIdentity {
    static let bundleID = "com.meapri.hangyeol.inputmethod"

    static let preferenceKeyMap: [String: String] = [
        "com.meapri.hangyeol.keyboardId": currentKey("keyboardId"),
        "com.meapri.hangyeol.toggleKey": currentKey("toggleKey"),
        "com.meapri.hangyeol.toggleKeyBinding": currentKey("toggleKeyBinding"),
        "com.meapri.hangyeol.hanjaKeyBinding": currentKey("hanjaKeyBinding"),
        "com.meapri.hangyeol.lastUpdateCheck": currentKey("lastUpdateCheck"),
        "com.meapri.hangyeol.autoUpdateCheck": currentKey("autoUpdateCheck"),
        "com.meapri.hangyeol.experimentalDirectInsertion": currentKey(
            "experimentalDirectInsertion"
        ),
        "com.meapri.hangyeol.respectCurrentRomanKeyboardLayout": currentKey(
            "respectCurrentRomanKeyboardLayout"
        ),
        "com.meapri.hangyeol.englishTextConvenienceFallbackEnabled": currentKey(
            "englishTextConvenienceFallbackEnabled"
        ),
        "com.meapri.hangyeol.capsLockProducesDoubleConsonants": currentKey(
            "capsLockProducesDoubleConsonants"
        ),
        "HangyeolPendingPostInstallSetup": "HangyeolPendingPostInstallSetup",
        "HangyeolSelectedBeforeInstall": "HangyeolSelectedBeforeInstall",
        "HangyeolInstalledBeforeInstall": "HangyeolInstalledBeforeInstall"
    ]

    private static func currentKey(_ suffix: String) -> String {
        "\(ProductIdentity.preferencePrefix).\(suffix)"
    }
}

enum Misordered3xIdentity {
    static let bundleID = "com.thlim.hangyeol.inputmethod"

    static let preferenceKeyMap: [String: String] = [
        currentKey("keyboardId"): currentKey("keyboardId"),
        currentKey("toggleKey"): currentKey("toggleKey"),
        currentKey("toggleKeyBinding"): currentKey("toggleKeyBinding"),
        currentKey("hanjaKeyBinding"): currentKey("hanjaKeyBinding"),
        currentKey("lastUpdateCheck"): currentKey("lastUpdateCheck"),
        currentKey("autoUpdateCheck"): currentKey("autoUpdateCheck"),
        currentKey("experimentalDirectInsertion"): currentKey(
            "experimentalDirectInsertion"
        ),
        currentKey("respectCurrentRomanKeyboardLayout"): currentKey(
            "respectCurrentRomanKeyboardLayout"
        ),
        currentKey("englishTextConvenienceFallbackEnabled"): currentKey(
            "englishTextConvenienceFallbackEnabled"
        ),
        currentKey("capsLockProducesDoubleConsonants"): currentKey(
            "capsLockProducesDoubleConsonants"
        ),
        "HangyeolPendingPostInstallSetup": "HangyeolPendingPostInstallSetup",
        "HangyeolSelectedBeforeInstall": "HangyeolSelectedBeforeInstall",
        "HangyeolInstalledBeforeInstall": "HangyeolInstalledBeforeInstall"
    ]

    private static func currentKey(_ suffix: String) -> String {
        "\(ProductIdentity.preferencePrefix).\(suffix)"
    }
}

enum Legacy2xIdentity {
    static let bundleID = "com.pritype.inputmethod.v2"

    static let preferenceKeyMap: [String: String] = [
        "com.pritype.keyboardId": currentKey("keyboardId"),
        "com.pritype.toggleKey": currentKey("toggleKey"),
        "com.pritype.toggleKeyBinding": currentKey("toggleKeyBinding"),
        "com.pritype.hanjaKeyBinding": currentKey("hanjaKeyBinding"),
        "com.pritype.lastUpdateCheck": currentKey("lastUpdateCheck"),
        "com.pritype.autoUpdateCheck": currentKey("autoUpdateCheck"),
        "com.pritype.experimentalDirectInsertion": currentKey("experimentalDirectInsertion"),
        "com.pritype.respectCurrentRomanKeyboardLayout": currentKey(
            "respectCurrentRomanKeyboardLayout"
        ),
        "com.pritype.englishTextConvenienceFallbackEnabled": currentKey(
            "englishTextConvenienceFallbackEnabled"
        ),
        "com.pritype.capsLockProducesDoubleConsonants": currentKey(
            "capsLockProducesDoubleConsonants"
        ),
        "PriTypePendingPostInstallSetup": "HangyeolPendingPostInstallSetup",
        "PriTypeSelectedBeforeInstall": "HangyeolSelectedBeforeInstall"
    ]

    private static func currentKey(_ suffix: String) -> String {
        "\(ProductIdentity.preferencePrefix).\(suffix)"
    }
}

private enum SettingsMigrationSupport {
    @discardableResult
    static func migrate(
        values: [String: Any],
        keyMap: [String: String],
        into destination: UserDefaults
    ) -> Set<String> {
        var migratedKeys = Set<String>()
        for (legacyKey, currentKey) in keyMap {
            guard destination.object(forKey: currentKey) == nil,
                  let value = values[legacyKey] else {
                continue
            }
            destination.set(value, forKey: currentKey)
            migratedKeys.insert(currentKey)
        }
        return migratedKeys
    }

    @discardableResult
    static func migrateInstalledPreferences(
        destination: UserDefaults,
        domainStore: UserDefaults,
        legacyDomainName: String,
        completionKey: String,
        keyMap: [String: String]
    ) -> Bool {
        guard !destination.bool(forKey: completionKey) else { return false }

        let legacyValues = domainStore.persistentDomain(
            forName: legacyDomainName
        ) ?? [:]
        _ = migrate(values: legacyValues, keyMap: keyMap, into: destination)
        destination.set(true, forKey: completionKey)
        destination.synchronize()

        if !legacyValues.isEmpty {
            domainStore.removePersistentDomain(forName: legacyDomainName)
            domainStore.synchronize()
        }
        return true
    }
}

public enum Legacy3xSettingsMigration {
    private static let completionKey = "\(ProductIdentity.preferencePrefix).legacy3xSettingsMigrated"
    private static let misorderedCompletionKey =
        "\(ProductIdentity.preferencePrefix).misordered3xSettingsMigrated"

    @discardableResult
    static func migrate(
        values: [String: Any],
        into destination: UserDefaults
    ) -> Set<String> {
        SettingsMigrationSupport.migrate(
            values: values,
            keyMap: Legacy3xIdentity.preferenceKeyMap,
            into: destination
        )
    }

    @discardableResult
    static func migrateMisordered(
        values: [String: Any],
        into destination: UserDefaults
    ) -> Set<String> {
        SettingsMigrationSupport.migrate(
            values: values,
            keyMap: Misordered3xIdentity.preferenceKeyMap,
            into: destination
        )
    }

    @discardableResult
    public static func migrateInstalledPreferences(
        destination: UserDefaults = .standard,
        domainStore: UserDefaults = .standard
    ) -> Bool {
        migrateInstalledPreferences(
            destination: destination,
            domainStore: domainStore,
            misorderedDomainName: Misordered3xIdentity.bundleID,
            meapriDomainName: Legacy3xIdentity.bundleID
        )
    }

    @discardableResult
    static func migrateInstalledPreferences(
        destination: UserDefaults,
        domainStore: UserDefaults,
        misorderedDomainName: String,
        meapriDomainName: String
    ) -> Bool {
        // The short-lived com.thlim.hangyeol.inputmethod build is newer than
        // the com.meapri builds, so import it first and keep its values when
        // both retired domains exist.
        let migratedMisordered = SettingsMigrationSupport.migrateInstalledPreferences(
            destination: destination,
            domainStore: domainStore,
            legacyDomainName: misorderedDomainName,
            completionKey: misorderedCompletionKey,
            keyMap: Misordered3xIdentity.preferenceKeyMap
        )
        let migratedMeapri = SettingsMigrationSupport.migrateInstalledPreferences(
            destination: destination,
            domainStore: domainStore,
            legacyDomainName: meapriDomainName,
            completionKey: completionKey,
            keyMap: Legacy3xIdentity.preferenceKeyMap
        )
        return migratedMisordered || migratedMeapri
    }
}

public enum Legacy2xSettingsMigration {
    private static let completionKey = "\(ProductIdentity.preferencePrefix).legacy2xSettingsMigrated"

    @discardableResult
    static func migrate(
        values: [String: Any],
        into destination: UserDefaults
    ) -> Set<String> {
        SettingsMigrationSupport.migrate(
            values: values,
            keyMap: Legacy2xIdentity.preferenceKeyMap,
            into: destination
        )
    }

    @discardableResult
    public static func migrateInstalledPreferences(
        destination: UserDefaults = .standard,
        domainStore: UserDefaults = .standard
    ) -> Bool {
        migrateInstalledPreferences(
            destination: destination,
            domainStore: domainStore,
            legacyDomainName: Legacy2xIdentity.bundleID
        )
    }

    @discardableResult
    static func migrateInstalledPreferences(
        destination: UserDefaults,
        domainStore: UserDefaults,
        legacyDomainName: String
    ) -> Bool {
        SettingsMigrationSupport.migrateInstalledPreferences(
            destination: destination,
            domainStore: domainStore,
            legacyDomainName: legacyDomainName,
            completionKey: completionKey,
            keyMap: Legacy2xIdentity.preferenceKeyMap
        )
    }
}
