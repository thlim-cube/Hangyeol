import Foundation

public enum ProductIdentity {
    public static let displayName = "한결"
    public static let systemName = "Hangyeol"
    public static let bundleID = "com.meapri.hangyeol.inputmethod"
    public static let inputModeID = bundleID
    public static let connectionName = "Hangyeol_InputString"
    public static let preferencePrefix = "com.meapri.hangyeol"
    public static let githubRepository = "Meapri/Hangyeol"

    public static let latestReleaseURL = URL(
        string: "https://github.com/\(githubRepository)/releases/latest"
    )!
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

public enum Legacy2xSettingsMigration {
    private static let completionKey = "\(ProductIdentity.preferencePrefix).legacy2xSettingsMigrated"

    @discardableResult
    static func migrate(
        values: [String: Any],
        into destination: UserDefaults
    ) -> Set<String> {
        var migratedKeys = Set<String>()
        for (legacyKey, currentKey) in Legacy2xIdentity.preferenceKeyMap {
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
        guard !destination.bool(forKey: completionKey) else { return false }

        let legacyValues = domainStore.persistentDomain(
            forName: legacyDomainName
        ) ?? [:]
        _ = migrate(values: legacyValues, into: destination)
        destination.set(true, forKey: completionKey)
        destination.synchronize()

        if !legacyValues.isEmpty {
            domainStore.removePersistentDomain(forName: legacyDomainName)
            domainStore.synchronize()
        }
        return true
    }
}
