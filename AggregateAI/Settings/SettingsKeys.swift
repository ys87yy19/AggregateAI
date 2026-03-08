import Foundation

enum SettingsKeys {
    // General
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
}
