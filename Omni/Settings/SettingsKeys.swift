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

    // Feature 16: Integrated modules
    static let siftlyBaseURL = "siftlyBaseURL"
    static let siftlyAutoSyncEnabled = "siftlyAutoSyncEnabled"
}
