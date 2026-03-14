import Foundation

// MARK: - GatewaySource

/// Selects which backend provides the unified AI gateway.
enum GatewaySource: String, CaseIterable {
    /// A user-supplied OpenAI-compatible endpoint and API key.
    case custom
    /// The locally-managed OmniRoute reverse-proxy.
    case omniroute

    var displayName: String {
        switch self {
        case .custom: return "Custom"
        case .omniroute: return "OmniRoute"
        }
    }
}

// MARK: - SharedAISettingsSnapshot

/// An immutable point-in-time snapshot of the active gateway configuration.
///
/// Computed from `SettingsService.settings` whenever it changes.
/// Passed into `OmniIntegrationService` and `APIService` so those layers
/// never touch `UserDefaults` or `Keychain` directly.
struct SharedAISettingsSnapshot {

    // Models accepted by Siftly's OpenAI provider integration.
    private static let siftlyAllowedOpenAIModels: Set<String> = [
        "gpt-5.4", "gpt-5.2", "gpt-5.1", "gpt-5",
        "gpt-5.4-codex", "gpt-5.3-codex", "gpt-5.2-codex",
        "gpt-5.1-codex", "gpt-5-codex",
    ]

    let source: GatewaySource
    /// Raw endpoint string (may contain trailing slashes).
    let endpoint: String
    let apiKey: String
    let model: String
    /// Dashboard URL, only present for OmniRoute source.
    let dashboardURL: String?

    // MARK: Normalised accessors

    var normalizedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Base URL formatted for Siftly's OpenAI provider (ensures `/v1` suffix).
    var siftlyOpenAIBaseURL: String {
        let trimmed = normalizedEndpoint
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }

    /// Model name normalised for Siftly; falls back to `gpt-5.4` if unsupported.
    var siftlyOpenAIModel: String {
        let trimmed = normalizedModel
        guard !trimmed.isEmpty else { return "gpt-5.4" }
        return Self.siftlyAllowedOpenAIModels.contains(trimmed) ? trimmed : "gpt-5.4"
    }

    /// `true` when both endpoint and model are filled in.
    var isConfigured: Bool {
        !normalizedEndpoint.isEmpty && !normalizedModel.isEmpty
    }
}

// MARK: - ModuleSyncStatus

/// Tracks the current synchronisation state of an individual module.
struct ModuleSyncStatus: Equatable {

    enum State: Equatable {
        case idle
        case syncing
        case success
        case failure
    }

    var state: State
    var message: String
    var updatedAt: Date?

    static let idle = ModuleSyncStatus(state: .idle, message: "尚未同步", updatedAt: nil)
}

// MARK: - ModuleUpdateDefinition

/// Describes how to fetch the latest release version and perform an in-place update.
struct ModuleUpdateDefinition: Equatable {

    enum LocalVersionSource: Equatable {
        /// Read version from a `package.json` at the given relative path.
        case packageJSON(relativePath: String)
    }

    enum UpdateStrategy: Equatable {
        /// git pull → docker compose pull → docker compose up -d
        case dockerCompose(composeFilePath: String, profile: String)
        /// git pull → npm install → pm2 restart <name>
        case nodeProcess(installPath: String, pm2Name: String?)
    }

    let owner: String
    let repository: String
    /// Overrides the module's default `managedDocker.installPath` when reading the local version.
    let installPathOverride: String?
    let localVersionSource: LocalVersionSource
    let updateStrategy: UpdateStrategy?

    var repositorySlug: String { "\(owner)/\(repository)" }
    var releasePageURL: String { "https://github.com/\(repositorySlug)/releases" }
}

// MARK: - ModuleUpdateStatus

/// The result of a GitHub update check for a module.
struct ModuleUpdateStatus: Equatable {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case unknownCurrentVersion
        case failure
        case unsupported
    }

    let state: State
    let message: String
    let currentVersion: String?
    let latestVersion: String?
    let releaseURL: String?
    let releaseTitle: String?
    let publishedAt: Date?
    let checkedAt: Date?

    static let idle = ModuleUpdateStatus(
        state: .idle,
        message: "尚未检查更新",
        currentVersion: nil,
        latestVersion: nil,
        releaseURL: nil,
        releaseTitle: nil,
        publishedAt: nil,
        checkedAt: nil
    )
}

// MARK: - ManagedDockerModuleAction

/// Identifies the last action performed on a Docker-managed module.
enum ManagedDockerModuleAction: String {
    case validate
    case start
    case stop
    case restart
    case logs
    case probe
}

// MARK: - ManagedDockerModuleDefinition

/// Static configuration describing a Docker-managed module.
struct ManagedDockerModuleDefinition: Equatable {
    let dashboardURL: String
    let apiBaseURL: String
    /// Absolute path to the cloned repository on disk.
    let installPath: String
    let composeFilePath: String
    let composeProfile: String
    let composeServiceName: String
    let dockerProjectName: String
    /// Whether this module can act as the unified AI gateway.
    let supportsGatewayRole: Bool
}

// MARK: - ManagedDockerModuleRuntime

/// Dynamic runtime state for a Docker-managed module, refreshed on demand.
struct ManagedDockerModuleRuntime: Equatable {

    enum State: Equatable {
        case dockerUnavailable
        case notInstalled
        case stopped
        case running
        case unhealthy
        case failure
    }

    let state: State
    let isInstalled: Bool
    let isRunning: Bool
    let isHealthy: Bool
    let dockerAvailable: Bool
    let containerName: String?
    let lastAction: ManagedDockerModuleAction?
    let lastError: String?
    let details: String
    let logsPreview: String?
    let updatedAt: Date

    static func idle(for action: ManagedDockerModuleAction? = nil) -> ManagedDockerModuleRuntime {
        ManagedDockerModuleRuntime(
            state: .notInstalled,
            isInstalled: false,
            isRunning: false,
            isHealthy: false,
            dockerAvailable: true,
            containerName: nil,
            lastAction: action,
            lastError: nil,
            details: "尚未检测",
            logsPreview: nil,
            updatedAt: Date()
        )
    }
}

// MARK: - OmniModuleDefinition

/// Describes a single integrated module: how to launch it and how to manage it.
struct OmniModuleDefinition: Identifiable, Equatable {

    enum LaunchStyle: Equatable {
        case webApp(url: String, width: Double, height: Double)
    }

    enum SyncAdapter: Equatable {
        case siftly
        case antigravity
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let launchStyle: LaunchStyle
    let syncAdapter: SyncAdapter?
    let managedDocker: ManagedDockerModuleDefinition?
    let updateDefinition: ModuleUpdateDefinition?
}

// MARK: - OmniModuleRegistry

/// Central registry of all modules integrated into Omni.
///
/// Install paths and localhost URLs intentionally use empty strings as defaults
/// so the app works out-of-the-box on any machine. Users configure actual paths
/// via Settings or the module detail panel.
enum OmniModuleRegistry {

    static let siftly = OmniModuleDefinition(
        id: "siftly",
        title: "Siftly",
        subtitle: "本地书签知识库",
        icon: "books.vertical.fill",
        launchStyle: .webApp(url: "http://127.0.0.1:3000", width: 1440, height: 920),
        syncAdapter: .siftly,
        managedDocker: nil,
        updateDefinition: ModuleUpdateDefinition(
            owner: "viperrcrypto",
            repository: "Siftly",
            installPathOverride: nil,          // user configures via Settings
            localVersionSource: .packageJSON(relativePath: "package.json"),
            updateStrategy: .nodeProcess(installPath: "", pm2Name: "siftly")
        )
    )

    static let omniRoute = OmniModuleDefinition(
        id: "omniroute",
        title: "OmniRoute",
        subtitle: "统一 AI 网关与路由控制台",
        icon: "shippingbox.fill",
        launchStyle: .webApp(url: "http://127.0.0.1:20128", width: 1440, height: 920),
        syncAdapter: nil,
        managedDocker: ManagedDockerModuleDefinition(
            dashboardURL: "http://127.0.0.1:20128",
            apiBaseURL: "http://127.0.0.1:20129/v1",
            installPath: "",                   // user configures via Settings
            composeFilePath: "",               // derived from installPath at runtime
            composeProfile: "base",
            composeServiceName: "omniroute-base",
            dockerProjectName: "omniroute",
            supportsGatewayRole: true
        ),
        updateDefinition: ModuleUpdateDefinition(
            owner: "diegosouzapw",
            repository: "OmniRoute",
            installPathOverride: nil,
            localVersionSource: .packageJSON(relativePath: "package.json"),
            updateStrategy: .dockerCompose(composeFilePath: "", profile: "base")
        )
    )

    static let antigravity = OmniModuleDefinition(
        id: "antigravity",
        title: "Antigravity Debugger",
        subtitle: "账号诊断与 AI 自动修复",
        icon: "wrench.and.screwdriver.fill",
        launchStyle: .webApp(url: "http://127.0.0.1:4173", width: 1440, height: 920),
        syncAdapter: .antigravity,
        managedDocker: nil,
        updateDefinition: nil
    )

    static let integratedModules: [OmniModuleDefinition] = [
        omniRoute,
        siftly,
        antigravity,
    ]

    static func module(id: String) -> OmniModuleDefinition? {
        integratedModules.first { $0.id == id }
    }
}
