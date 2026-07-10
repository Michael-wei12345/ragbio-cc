import Foundation

enum CredentialKey: String {
    case openAlexAPIKey
    case semanticScholarAPIKey
    case deepSeekAPIKey
    case openAIAPIKey
    case anthropicAPIKey
    case geminiAPIKey
}

enum CredentialStore {
    private static let appDefaults = UserDefaults(suiteName: "com.local.RagBio") ?? .standard
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryCache: [CredentialKey: String] = [:]

    static func string(for key: CredentialKey) -> String {
        lock.lock()
        let cached = memoryCache[key]
        lock.unlock()
        if let cached {
            return cached
        }

        if let mirrored = appDefaults.string(forKey: mirrorKey(for: key)),
           !mirrored.isEmpty {
            cache(mirrored, for: key)
            return mirrored
        }

        if key == .openAlexAPIKey,
           let legacy = appDefaults.string(forKey: SettingsKeys.openAlexAPIKey),
           !legacy.isEmpty {
            set(legacy, for: key)
            appDefaults.removeObject(forKey: SettingsKeys.openAlexAPIKey)
            return legacy
        }
        return ""
    }

    static func set(_ value: String, for key: CredentialKey) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            appDefaults.removeObject(forKey: mirrorKey(for: key))
            if key == .openAlexAPIKey {
                appDefaults.removeObject(forKey: SettingsKeys.openAlexAPIKey)
            }
            _ = appDefaults.synchronize()
            lock.lock()
            memoryCache.removeValue(forKey: key)
            lock.unlock()
            return
        }

        appDefaults.set(clean, forKey: mirrorKey(for: key))
        _ = appDefaults.synchronize()
        cache(clean, for: key)
    }

    static func saveAndVerify(_ value: String, for key: CredentialKey) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        set(clean, for: key)
        guard string(for: key) == clean else {
            return "凭据写入后无法回读，请重新打开 App 后再试"
        }
        return nil
    }

    static func preloadCommonKeys() {
        preloadSearchKeys()
    }

    static func preloadSearchKeys() {
        let providerRaw = UserDefaults.standard.string(forKey: SettingsKeys.activeAIProvider)
        let provider = providerRaw.flatMap(AIProvider.init(rawValue:)) ?? .deepSeek
        let keys: [CredentialKey] = [
            .openAlexAPIKey,
            .semanticScholarAPIKey,
            provider.credentialKey
        ]
        for key in keys {
            _ = string(for: key)
        }
    }

    static func removeAllAIKeys() {
        for provider in AIProvider.allCases {
            set("", for: provider.credentialKey)
        }
    }

    private static func cache(_ value: String, for key: CredentialKey) {
        lock.lock()
        memoryCache[key] = value
        lock.unlock()
    }

    private static func mirrorKey(for key: CredentialKey) -> String {
        "credential.mirror.\(key.rawValue)"
    }
}
