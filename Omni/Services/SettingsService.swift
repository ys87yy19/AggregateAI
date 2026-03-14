import Foundation
import Combine
import OSLog

// MARK: - SettingsServiceProtocol

/// Abstraction over settings persistence.
/// ViewModels depend on this protocol so unit tests can supply a mock.
@MainActor
protocol SettingsServiceProtocol: AnyObject {
    var settings: AppSettings { get }
    var settingsPublisher: AnyPublisher<AppSettings, Never> { get }

    func update(_ transform: (inout AppSettings) -> Void)
}

// MARK: - AppSettings

/// Typed value that carries all persisted app settings.
/// Published as a single struct so observers receive one update per transaction.
struct AppSettings: Equatable {

    // MARK: General UI
    var workspaceMode: WorkspaceMode = .modules
    var layoutMode: LayoutMode = .threeColumn
    var appearanceMode: AppearanceMode = .system
    var isPinned: Bool = false

    // MARK: Hotkey
    var hotkeyKeyCode: UInt32 = 0
    var hotkeyModifiers: UInt32 = 0

    // MARK: Notifications
    var notificationsEnabled: Bool = false
    var notifyOnlyWhenHidden: Bool = true

    // MARK: Clipboard
    var clipboardMonitorEnabled: Bool = false

    // MARK: Obsidian
    var obsidianVaultPath: String = ""

    // MARK: API Gateway (secure values stored in Keychain, not here)
    var gatewaySource: GatewaySource = .custom
    var customAPIEndpoint: String = "http://127.0.0.1:8317"
    var customAPISelectedModel: String = ""
    var omniRouteDashboardURL: String = "http://127.0.0.1:20128"
    var omniRouteAPIURL: String = "http://127.0.0.1:20129"
    var omniRoutePreferredModel: String = ""
    var apiSystemPrompt: String = APIService.defaultSystemPrompt
    var apiSavePath: String = ""

    // MARK: Modules
    var siftlyBaseURL: String = "http://127.0.0.1:3000"
    var siftlyAutoSyncEnabled: Bool = true
    var antigravityBaseURL: String = "http://127.0.0.1:4173"
    /// No default path – user must select their own install directory.
    var antigravityInstallPath: String = ""
    var antigravityEmail: String = ""
    var antigravityProjectId: String = ""
    var antigravityAutoFixEnabled: Bool = true
}

// MARK: - SettingsService

/// Centralised settings persistence layer.
///
/// - Reads all values from `OmniSettingsStore` (UserDefaults) and `KeychainService`
///   at initialisation, handling migration from legacy keys.
/// - Publishes changes as a single `AppSettings` value so any number of ViewModels
///   can subscribe without coupling to individual keys.
/// - Persists through Combine sinks so every assignment is automatically saved.
/// - Secure values (API keys) go to Keychain only; they are **not** in `AppSettings`
///   to avoid accidental logging or state diffing.
@MainActor
final class SettingsService: SettingsServiceProtocol {

    // MARK: - Keychain identifiers

    private static let keychainService = "com.omni.app.shared-ai"
    private static let customKeyAccount = "gateway-api-key"
    private static let omniRouteKeyAccount = "omniroute-endpoint-key"

    // MARK: - Published state

    @Published private(set) var settings: AppSettings
    @Published private(set) var customAPIKey: String = ""
    @Published private(set) var omniRouteEndpointKey: String = ""

    var settingsPublisher: AnyPublisher<AppSettings, Never> {
        $settings.eraseToAnyPublisher()
    }

    // MARK: - Private

    private let keychain: KeychainService
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.omni.app", category: "SettingsService")

    // MARK: - Init

    init(keychain: KeychainService) {
        self.keychain = keychain
        self.settings = AppSettings()
        loadFromDefaults()
        setupAutoSave()
    }

    // MARK: - Public mutation API

    /// Apply a synchronous transform to `settings` and persist the result.
    func update(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
    }

    /// Persist a new custom API key to Keychain.
    func setCustomAPIKey(_ key: String) {
        customAPIKey = key
        do {
            try keychain.setString(key, forService: Self.keychainService, account: Self.customKeyAccount)
        } catch {
            logger.error("Failed to save customAPIKey to Keychain: \(error.localizedDescription)")
        }
        OmniSettingsStore.shared.removeObject(forKey: SettingsKeys.apiKey)
    }

    /// Persist a new OmniRoute endpoint key to Keychain.
    func setOmniRouteEndpointKey(_ key: String) {
        omniRouteEndpointKey = key
        do {
            try keychain.setString(key, forService: Self.keychainService, account: Self.omniRouteKeyAccount)
        } catch {
            logger.error("Failed to save omniRouteEndpointKey to Keychain: \(error.localizedDescription)")
        }
    }

    // MARK: - Derived snapshot

    /// Returns the active gateway configuration as a snapshot for use with
    /// `APIService` and `OmniIntegrationService`.
    var sharedAISnapshot: SharedAISettingsSnapshot {
        switch settings.gatewaySource {
        case .custom:
            return SharedAISettingsSnapshot(
                source: .custom,
                endpoint: settings.customAPIEndpoint,
                apiKey: customAPIKey,
                model: settings.customAPISelectedModel,
                dashboardURL: nil
            )
        case .omniroute:
            return SharedAISettingsSnapshot(
                source: .omniroute,
                endpoint: settings.omniRouteAPIURL,
                apiKey: omniRouteEndpointKey,
                model: settings.omniRoutePreferredModel,
                dashboardURL: settings.omniRouteDashboardURL
            )
        }
    }

    // MARK: - Load

    private func loadFromDefaults() {
        let d = OmniSettingsStore.shared

        if let raw = d.string(forKey: SettingsKeys.workspaceMode),
           let mode = WorkspaceMode(rawValue: raw) {
            settings.workspaceMode = mode
        }
        if let raw = d.string(forKey: SettingsKeys.layoutMode),
           let mode = LayoutMode(rawValue: raw) {
            settings.layoutMode = mode
        }
        if let raw = d.string(forKey: SettingsKeys.appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            settings.appearanceMode = mode
        }
        settings.isPinned = d.bool(forKey: SettingsKeys.isPinned)

        if d.object(forKey: SettingsKeys.hotkeyKeyCode) != nil {
            settings.hotkeyKeyCode = UInt32(d.integer(forKey: SettingsKeys.hotkeyKeyCode))
        }
        if d.object(forKey: SettingsKeys.hotkeyModifiers) != nil {
            settings.hotkeyModifiers = UInt32(d.integer(forKey: SettingsKeys.hotkeyModifiers))
        }

        settings.notificationsEnabled = d.bool(forKey: SettingsKeys.notificationsEnabled)
        settings.notifyOnlyWhenHidden = d.object(forKey: SettingsKeys.notifyOnlyWhenHidden) as? Bool ?? true
        settings.clipboardMonitorEnabled = d.bool(forKey: SettingsKeys.clipboardMonitorEnabled)
        settings.obsidianVaultPath = d.string(forKey: SettingsKeys.obsidianVaultPath) ?? ""

        if let raw = d.string(forKey: SettingsKeys.gatewaySource),
           let source = GatewaySource(rawValue: raw) {
            settings.gatewaySource = source
        }
        settings.customAPIEndpoint = d.string(forKey: SettingsKeys.customAPIEndpoint)
            ?? d.string(forKey: SettingsKeys.apiEndpoint)
            ?? "http://127.0.0.1:8317"
        settings.customAPISelectedModel = d.string(forKey: SettingsKeys.customAPISelectedModel)
            ?? d.string(forKey: SettingsKeys.apiSelectedModel)
            ?? ""
        settings.omniRouteDashboardURL = d.string(forKey: SettingsKeys.omniRouteDashboardURL) ?? "http://127.0.0.1:20128"
        settings.omniRouteAPIURL = d.string(forKey: SettingsKeys.omniRouteAPIURL) ?? "http://127.0.0.1:20129"
        settings.omniRoutePreferredModel = d.string(forKey: SettingsKeys.omniRoutePreferredModel) ?? ""
        settings.apiSystemPrompt = d.string(forKey: SettingsKeys.apiSystemPrompt) ?? APIService.defaultSystemPrompt
        settings.apiSavePath = d.string(forKey: SettingsKeys.apiSavePath) ?? ""
        settings.siftlyBaseURL = d.string(forKey: SettingsKeys.siftlyBaseURL) ?? "http://127.0.0.1:3000"
        settings.siftlyAutoSyncEnabled = d.object(forKey: SettingsKeys.siftlyAutoSyncEnabled) as? Bool ?? true
        settings.antigravityBaseURL = d.string(forKey: SettingsKeys.antigravityBaseURL) ?? "http://127.0.0.1:4173"
        // No hardcoded path default – user must configure their own install directory
        settings.antigravityInstallPath = d.string(forKey: SettingsKeys.antigravityInstallPath) ?? ""
        settings.antigravityEmail = d.string(forKey: SettingsKeys.antigravityEmail) ?? ""
        settings.antigravityProjectId = d.string(forKey: SettingsKeys.antigravityProjectId) ?? ""
        settings.antigravityAutoFixEnabled = d.object(forKey: SettingsKeys.antigravityAutoFixEnabled) as? Bool ?? true

        loadKeychainValues(defaults: d)
    }

    private func loadKeychainValues(defaults d: UserDefaults) {
        // Custom API key
        do {
            customAPIKey = try keychain.string(
                forService: Self.keychainService,
                account: Self.customKeyAccount
            ) ?? ""
        } catch {
            customAPIKey = ""
            logger.warning("Could not load customAPIKey from Keychain: \(error.localizedDescription)")
        }

        // Migrate legacy plaintext API key to Keychain
        if customAPIKey.isEmpty,
           let legacy = d.string(forKey: SettingsKeys.apiKey),
           !legacy.isEmpty {
            customAPIKey = legacy
            try? keychain.setString(legacy, forService: Self.keychainService, account: Self.customKeyAccount)
            d.removeObject(forKey: SettingsKeys.apiKey)
        }

        // OmniRoute endpoint key
        do {
            omniRouteEndpointKey = try keychain.string(
                forService: Self.keychainService,
                account: Self.omniRouteKeyAccount
            ) ?? ""
        } catch {
            omniRouteEndpointKey = ""
            logger.warning("Could not load omniRouteEndpointKey from Keychain: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-save

    private func setupAutoSave() {
        let d = OmniSettingsStore.shared

        $settings
            .dropFirst()
            .sink { [weak self] s in
                guard self != nil else { return }
                d.set(s.workspaceMode.rawValue, forKey: SettingsKeys.workspaceMode)
                d.set(s.layoutMode.rawValue, forKey: SettingsKeys.layoutMode)
                d.set(s.appearanceMode.rawValue, forKey: SettingsKeys.appearanceMode)
                d.set(s.isPinned, forKey: SettingsKeys.isPinned)
                d.set(Int(s.hotkeyKeyCode), forKey: SettingsKeys.hotkeyKeyCode)
                d.set(Int(s.hotkeyModifiers), forKey: SettingsKeys.hotkeyModifiers)
                d.set(s.notificationsEnabled, forKey: SettingsKeys.notificationsEnabled)
                d.set(s.notifyOnlyWhenHidden, forKey: SettingsKeys.notifyOnlyWhenHidden)
                d.set(s.clipboardMonitorEnabled, forKey: SettingsKeys.clipboardMonitorEnabled)
                d.set(s.obsidianVaultPath, forKey: SettingsKeys.obsidianVaultPath)
                d.set(s.gatewaySource.rawValue, forKey: SettingsKeys.gatewaySource)
                d.set(s.customAPIEndpoint, forKey: SettingsKeys.customAPIEndpoint)
                // Dual-write to legacy key so older builds still read the correct value.
                // Remove the legacy write once all users have migrated to the new key.
                d.set(s.customAPIEndpoint, forKey: SettingsKeys.apiEndpoint)
                d.set(s.customAPISelectedModel, forKey: SettingsKeys.customAPISelectedModel)
                // Same dual-write for model key.
                d.set(s.customAPISelectedModel, forKey: SettingsKeys.apiSelectedModel)
                d.set(s.omniRouteDashboardURL, forKey: SettingsKeys.omniRouteDashboardURL)
                d.set(s.omniRouteAPIURL, forKey: SettingsKeys.omniRouteAPIURL)
                d.set(s.omniRoutePreferredModel, forKey: SettingsKeys.omniRoutePreferredModel)
                d.set(s.apiSystemPrompt, forKey: SettingsKeys.apiSystemPrompt)
                d.set(s.apiSavePath, forKey: SettingsKeys.apiSavePath)
                d.set(s.siftlyBaseURL, forKey: SettingsKeys.siftlyBaseURL)
                d.set(s.siftlyAutoSyncEnabled, forKey: SettingsKeys.siftlyAutoSyncEnabled)
                d.set(s.antigravityBaseURL, forKey: SettingsKeys.antigravityBaseURL)
                d.set(s.antigravityInstallPath, forKey: SettingsKeys.antigravityInstallPath)
                d.set(s.antigravityEmail, forKey: SettingsKeys.antigravityEmail)
                d.set(s.antigravityProjectId, forKey: SettingsKeys.antigravityProjectId)
                d.set(s.antigravityAutoFixEnabled, forKey: SettingsKeys.antigravityAutoFixEnabled)
            }
            .store(in: &cancellables)
    }
}
