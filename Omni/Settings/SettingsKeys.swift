import Foundation

enum SettingsKeys {
    // General
    static let workspaceMode = "workspaceMode"
    static let layoutMode = "layoutMode"
    static let appearanceMode = "appearanceMode"
    static let isPinned = "isPinned"

    // Feature 7: Custom Hotkey
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"

    // Feature 8: Notifications
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyOnlyWhenHidden = "notifyOnlyWhenHidden"

    // Feature 13: Clipboard monitoring
    static let clipboardMonitorEnabled = "clipboardMonitorEnabled"

    // Feature 14: Obsidian
    static let obsidianVaultBookmark = "obsidianVaultBookmark"
    static let obsidianVaultPath = "obsidianVaultPath"

    // Feature 15: API Aggregation
    static let apiEndpoint = "apiEndpoint"
    static let apiKey = "apiKey"
    static let apiSelectedModel = "apiSelectedModel"
    static let apiSystemPrompt = "apiSystemPrompt"
    static let apiSaveBookmark = "apiSaveBookmark"
    static let apiSavePath = "apiSavePath"
    static let gatewaySource = "gatewaySource"
    static let customAPIEndpoint = "customAPIEndpoint"
    static let customAPISelectedModel = "customAPISelectedModel"
    static let omniRouteDashboardURL = "omniRouteDashboardURL"
    static let omniRouteAPIURL = "omniRouteAPIURL"
    static let omniRoutePreferredModel = "omniRoutePreferredModel"

    // Feature 16: Integrated modules
    static let siftlyBaseURL = "siftlyBaseURL"
    static let siftlyAutoSyncEnabled = "siftlyAutoSyncEnabled"
    static let antigravityBaseURL = "antigravityBaseURL"
    static let antigravityInstallPath = "antigravityInstallPath"
    static let antigravityEmail = "antigravityEmail"
    static let antigravityProjectId = "antigravityProjectId"
    static let antigravityAutoFixEnabled = "antigravityAutoFixEnabled"

    // Persisted app setting keys (used by defaults suite migration)
    static let persistedKeys: [String] = [
        workspaceMode,
        layoutMode,
        appearanceMode,
        isPinned,
        hotkeyKeyCode,
        hotkeyModifiers,
        notificationsEnabled,
        notifyOnlyWhenHidden,
        clipboardMonitorEnabled,
        obsidianVaultBookmark,
        obsidianVaultPath,
        apiEndpoint,
        apiKey,
        apiSelectedModel,
        apiSystemPrompt,
        apiSaveBookmark,
        apiSavePath,
        gatewaySource,
        customAPIEndpoint,
        customAPISelectedModel,
        omniRouteDashboardURL,
        omniRouteAPIURL,
        omniRoutePreferredModel,
        siftlyBaseURL,
        siftlyAutoSyncEnabled,
        antigravityBaseURL,
        antigravityInstallPath,
        antigravityEmail,
        antigravityProjectId,
        antigravityAutoFixEnabled,
    ]
}

enum OmniSettingsStore {
    static let suiteName = "com.omni.settings.v1"

    private static let legacyDomains: [String] = [
        "com.omni.app",
        "com.aggregateai.app",
        "com.aggregate.ai",
        "AggregateAI"
    ]

    static let shared: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        migrateMissingValues(target: store)
        return store
    }()

    private static func migrateMissingValues(target: UserDefaults) {
        var sourceDictionaries: [[String: Any]] = []

        if let bundleID = Bundle.main.bundleIdentifier,
           let dict = UserDefaults.standard.persistentDomain(forName: bundleID),
           !dict.isEmpty {
            sourceDictionaries.append(dict)
        }

        for domain in legacyDomains {
            guard let dict = UserDefaults.standard.persistentDomain(forName: domain), !dict.isEmpty else {
                continue
            }
            sourceDictionaries.append(dict)
        }

        sourceDictionaries.append(UserDefaults.standard.dictionaryRepresentation())

        for key in SettingsKeys.persistedKeys {
            guard target.object(forKey: key) == nil else { continue }
            for dict in sourceDictionaries {
                guard let value = dict[key] else { continue }
                target.set(value, forKey: key)
                break
            }
        }
    }
}
