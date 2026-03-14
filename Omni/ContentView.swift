import SwiftUI
import Carbon.HIToolbox
import Combine
import Foundation

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    private static let sharedAIKeychainService = "com.omni.app.shared-ai"
    private static let sharedAIKeychainAccount = "gateway-api-key"
    private static let omniRouteKeychainAccount = "omniroute-endpoint-key"

    struct ModuleActionNotice: Identifiable, Equatable {
        enum Kind: Equatable {
            case info
            case success
            case failure
        }

        let id = UUID()
        let message: String
        let kind: Kind
    }

    private struct AntigravityRunPayload: Encodable {
        let mode: String
        let email: String
        let projectId: String
    }

    private struct AntigravityRunResponse: Decodable {
        let ok: Bool
        let output: String?
        let error: String?
        let exitCode: Int?
        let timedOut: Bool?
    }

    private struct AntigravityAIFixPlan: Decodable {
        struct Command: Decodable {
            let cmd: String
            let reason: String?
        }

        let summary: String
        let commands: [Command]
    }

    private struct ShellCommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private final class ShellFinishBox {
        let lock = NSLock()
        var finished = false
    }

    @Published var workspaceMode: WorkspaceMode = .modules
    @Published var selectedTab: AIProvider = .all
    @Published var syncQuestion: String = ""
    @Published var userAgentSettings = UserAgentSettings.recommended

    @Published var layoutMode: LayoutMode = .threeColumn
    @Published var appearanceMode: AppearanceMode = .system
    @Published var isPinned: Bool = false

    // Feature 7: Custom Hotkey
    @Published var hotkeyKeyCode: UInt32 = UInt32(kVK_ANSI_A)
    @Published var hotkeyModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    // Feature 8: Notifications
    @Published var notificationsEnabled: Bool = false
    @Published var notifyOnlyWhenHidden: Bool = true

    // Feature 13: Clipboard monitoring
    @Published var clipboardMonitorEnabled: Bool = false

    // Feature 14: Obsidian
    @Published var obsidianVaultPath: String = ""

    // Feature 15: API Aggregation
    @Published var gatewaySource: GatewaySource = .custom
    @Published var customAPIEndpoint: String = "http://127.0.0.1:8317"
    @Published var customAPIKey: String = ""
    @Published var customAPISelectedModel: String = ""
    @Published var omniRouteDashboardURL: String = "http://127.0.0.1:20128"
    @Published var omniRouteAPIURL: String = "http://127.0.0.1:20129"
    @Published var omniRouteEndpointKey: String = ""
    @Published var omniRoutePreferredModel: String = ""
    @Published var apiSystemPrompt: String = APIService.defaultSystemPrompt
    @Published var apiSavePath: String = ""
    @Published var apiAvailableModels: [String] = []
    @Published var siftlyBaseURL: String = "http://127.0.0.1:3000"
    @Published var siftlyAutoSyncEnabled: Bool = true
    @Published var antigravityBaseURL: String = "http://127.0.0.1:4173"
    @Published var antigravityInstallPath: String = ""
    @Published var antigravityEmail: String = ""
    @Published var antigravityProjectId: String = ""
    @Published var antigravityAutoFixEnabled: Bool = true
    @Published var antigravityIsRunningWorkflow: Bool = false
    @Published var antigravityRunnerStatus: String = "未检查"
    @Published var antigravityDiagnosisLog: String = ""
    @Published var antigravityAutoFixLog: String = ""
    @Published var moduleActionNotice: ModuleActionNotice?
    @Published var moduleSyncStatuses: [String: ModuleSyncStatus] = [
        OmniModuleRegistry.siftly.id: .idle,
        OmniModuleRegistry.antigravity.id: ModuleSyncStatus(
            state: .success,
            message: "模块不需要同步",
            updatedAt: Date()
        )
    ]
    @Published var moduleUpdateStatuses: [String: ModuleUpdateStatus] = [
        OmniModuleRegistry.siftly.id: .idle,
        OmniModuleRegistry.omniRoute.id: .idle
    ]
    @Published var managedModuleRuntimes: [String: ManagedDockerModuleRuntime] = [
        OmniModuleRegistry.omniRoute.id: ManagedDockerModuleRuntime.idle()
    ]
    @Published var managedModuleLogs: [String: String] = [:]
    @Published var isAggregating: Bool = false
    @Published var showAggregationResult: Bool = false
    @Published var aggregationResult: String = ""
    @Published var aggregationError: String? = nil

    weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var moduleTasks: [String: Task<Void, Never>] = [:]
    private var noticeDismissTask: Task<Void, Never>?
    private var moduleLauncher: ((OmniModuleDefinition) -> Bool)?
    private var settingsPresenter: (() -> Void)?
    private var lastModuleOpenAt: [String: Date] = [:]

    init() {
        loadFromDefaults()
        setupAutoSave()
        setupModuleAutoSync()
    }

    // MARK: - Load saved settings

    private func loadFromDefaults() {
        let d = OmniSettingsStore.shared
        if let raw = d.string(forKey: SettingsKeys.workspaceMode),
           let mode = WorkspaceMode(rawValue: raw) {
            workspaceMode = mode
        }
        if let raw = d.string(forKey: SettingsKeys.layoutMode),
           let mode = LayoutMode(rawValue: raw) {
            layoutMode = mode
        }
        if let raw = d.string(forKey: SettingsKeys.appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        isPinned = d.bool(forKey: SettingsKeys.isPinned)

        if d.object(forKey: SettingsKeys.hotkeyKeyCode) != nil {
            hotkeyKeyCode = UInt32(d.integer(forKey: SettingsKeys.hotkeyKeyCode))
        }
        if d.object(forKey: SettingsKeys.hotkeyModifiers) != nil {
            hotkeyModifiers = UInt32(d.integer(forKey: SettingsKeys.hotkeyModifiers))
        }

        notificationsEnabled = d.bool(forKey: SettingsKeys.notificationsEnabled)
        notifyOnlyWhenHidden = d.object(forKey: SettingsKeys.notifyOnlyWhenHidden) as? Bool ?? true
        clipboardMonitorEnabled = d.bool(forKey: SettingsKeys.clipboardMonitorEnabled)
        obsidianVaultPath = d.string(forKey: SettingsKeys.obsidianVaultPath) ?? ""
        if let raw = d.string(forKey: SettingsKeys.gatewaySource),
           let source = GatewaySource(rawValue: raw) {
            gatewaySource = source
        }
        customAPIEndpoint = d.string(forKey: SettingsKeys.customAPIEndpoint)
            ?? d.string(forKey: SettingsKeys.apiEndpoint)
            ?? "http://127.0.0.1:8317"
        customAPISelectedModel = d.string(forKey: SettingsKeys.customAPISelectedModel)
            ?? d.string(forKey: SettingsKeys.apiSelectedModel)
            ?? ""
        omniRouteDashboardURL = d.string(forKey: SettingsKeys.omniRouteDashboardURL) ?? "http://127.0.0.1:20128"
        omniRouteAPIURL = d.string(forKey: SettingsKeys.omniRouteAPIURL) ?? "http://127.0.0.1:20129"
        omniRoutePreferredModel = d.string(forKey: SettingsKeys.omniRoutePreferredModel) ?? ""
        apiSystemPrompt = d.string(forKey: SettingsKeys.apiSystemPrompt) ?? APIService.defaultSystemPrompt
        apiSavePath = d.string(forKey: SettingsKeys.apiSavePath) ?? ""
        siftlyBaseURL = d.string(forKey: SettingsKeys.siftlyBaseURL) ?? "http://127.0.0.1:3000"
        siftlyAutoSyncEnabled = d.object(forKey: SettingsKeys.siftlyAutoSyncEnabled) as? Bool ?? true
        antigravityBaseURL = d.string(forKey: SettingsKeys.antigravityBaseURL) ?? "http://127.0.0.1:4173"
        antigravityInstallPath = d.string(forKey: SettingsKeys.antigravityInstallPath) ?? ""
        antigravityEmail = d.string(forKey: SettingsKeys.antigravityEmail) ?? ""
        antigravityProjectId = d.string(forKey: SettingsKeys.antigravityProjectId) ?? ""
        antigravityAutoFixEnabled = d.object(forKey: SettingsKeys.antigravityAutoFixEnabled) as? Bool ?? true

        do {
            customAPIKey = try KeychainService.shared.string(
                forService: Self.sharedAIKeychainService,
                account: Self.sharedAIKeychainAccount
            ) ?? ""
        } catch {
            customAPIKey = ""
        }

        do {
            omniRouteEndpointKey = try KeychainService.shared.string(
                forService: Self.sharedAIKeychainService,
                account: Self.omniRouteKeychainAccount
            ) ?? ""
        } catch {
            omniRouteEndpointKey = ""
        }

        if customAPIKey.isEmpty, let legacyKey = d.string(forKey: SettingsKeys.apiKey), !legacyKey.isEmpty {
            customAPIKey = legacyKey
            try? KeychainService.shared.setString(
                legacyKey,
                forService: Self.sharedAIKeychainService,
                account: Self.sharedAIKeychainAccount
            )
            d.removeObject(forKey: SettingsKeys.apiKey)
        }
    }

    // MARK: - Auto-save via Combine (more reliable than didSet)

    private func setupAutoSave() {
        let d = OmniSettingsStore.shared

        $workspaceMode.dropFirst().sink { d.set($0.rawValue, forKey: SettingsKeys.workspaceMode) }.store(in: &cancellables)
        $layoutMode.dropFirst().sink { d.set($0.rawValue, forKey: SettingsKeys.layoutMode) }.store(in: &cancellables)
        $appearanceMode.dropFirst().sink { d.set($0.rawValue, forKey: SettingsKeys.appearanceMode) }.store(in: &cancellables)
        $isPinned.dropFirst().sink { d.set($0, forKey: SettingsKeys.isPinned) }.store(in: &cancellables)
        $hotkeyKeyCode.dropFirst().sink { d.set(Int($0), forKey: SettingsKeys.hotkeyKeyCode) }.store(in: &cancellables)
        $hotkeyModifiers.dropFirst().sink { d.set(Int($0), forKey: SettingsKeys.hotkeyModifiers) }.store(in: &cancellables)
        $notificationsEnabled.dropFirst().sink { d.set($0, forKey: SettingsKeys.notificationsEnabled) }.store(in: &cancellables)
        $notifyOnlyWhenHidden.dropFirst().sink { d.set($0, forKey: SettingsKeys.notifyOnlyWhenHidden) }.store(in: &cancellables)
        $clipboardMonitorEnabled.dropFirst().sink { d.set($0, forKey: SettingsKeys.clipboardMonitorEnabled) }.store(in: &cancellables)
        $obsidianVaultPath.dropFirst().sink { d.set($0, forKey: SettingsKeys.obsidianVaultPath) }.store(in: &cancellables)
        $gatewaySource.dropFirst().sink { d.set($0.rawValue, forKey: SettingsKeys.gatewaySource) }.store(in: &cancellables)
        $customAPIEndpoint.dropFirst().sink {
            d.set($0, forKey: SettingsKeys.customAPIEndpoint)
            d.set($0, forKey: SettingsKeys.apiEndpoint)
        }.store(in: &cancellables)
        $customAPIKey.dropFirst().sink {
            try? KeychainService.shared.setString(
                $0,
                forService: Self.sharedAIKeychainService,
                account: Self.sharedAIKeychainAccount
            )
            d.removeObject(forKey: SettingsKeys.apiKey)
        }.store(in: &cancellables)
        $customAPISelectedModel.dropFirst().sink {
            d.set($0, forKey: SettingsKeys.customAPISelectedModel)
            d.set($0, forKey: SettingsKeys.apiSelectedModel)
        }.store(in: &cancellables)
        $omniRouteDashboardURL.dropFirst().sink { d.set($0, forKey: SettingsKeys.omniRouteDashboardURL) }.store(in: &cancellables)
        $omniRouteAPIURL.dropFirst().sink { d.set($0, forKey: SettingsKeys.omniRouteAPIURL) }.store(in: &cancellables)
        $omniRouteEndpointKey.dropFirst().sink {
            try? KeychainService.shared.setString(
                $0,
                forService: Self.sharedAIKeychainService,
                account: Self.omniRouteKeychainAccount
            )
        }.store(in: &cancellables)
        $omniRoutePreferredModel.dropFirst().sink { d.set($0, forKey: SettingsKeys.omniRoutePreferredModel) }.store(in: &cancellables)
        $apiSystemPrompt.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSystemPrompt) }.store(in: &cancellables)
        $apiSavePath.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSavePath) }.store(in: &cancellables)
        $siftlyBaseURL.dropFirst().sink { d.set($0, forKey: SettingsKeys.siftlyBaseURL) }.store(in: &cancellables)
        $siftlyAutoSyncEnabled.dropFirst().sink { d.set($0, forKey: SettingsKeys.siftlyAutoSyncEnabled) }.store(in: &cancellables)
        $antigravityBaseURL.dropFirst().sink { d.set($0, forKey: SettingsKeys.antigravityBaseURL) }.store(in: &cancellables)
        $antigravityInstallPath.dropFirst().sink { d.set($0, forKey: SettingsKeys.antigravityInstallPath) }.store(in: &cancellables)
        $antigravityEmail.dropFirst().sink { d.set($0, forKey: SettingsKeys.antigravityEmail) }.store(in: &cancellables)
        $antigravityProjectId.dropFirst().sink { d.set($0, forKey: SettingsKeys.antigravityProjectId) }.store(in: &cancellables)
        $antigravityAutoFixEnabled.dropFirst().sink { d.set($0, forKey: SettingsKeys.antigravityAutoFixEnabled) }.store(in: &cancellables)
    }

    private func setupModuleAutoSync() {
        Publishers.CombineLatest4(
            $gatewaySource.dropFirst(),
            $customAPIEndpoint.dropFirst(),
            $customAPISelectedModel.dropFirst(),
            $siftlyBaseURL.dropFirst()
        )
        .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            guard let self, self.siftlyAutoSyncEnabled else { return }
            self.scheduleModuleSync()
        }
        .store(in: &cancellables)

        Publishers.CombineLatest($omniRouteAPIURL.dropFirst(), $omniRoutePreferredModel.dropFirst())
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self, self.siftlyAutoSyncEnabled else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)

        $customAPIKey
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.siftlyAutoSyncEnabled, self.gatewaySource == .custom else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)

        $omniRouteEndpointKey
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.siftlyAutoSyncEnabled, self.gatewaySource == .omniroute else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)

        $siftlyAutoSyncEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)
    }

    private func scheduleModuleSync() {
        cancelModuleTask(key: "sync_all")
        moduleSyncStatuses[OmniModuleRegistry.siftly.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步统一 AI 配置…",
            updatedAt: Date()
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let statuses = await OmniIntegrationService.shared.syncAll(from: self)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses.merge(statuses) { _, new in new }
        }
        registerModuleTask(task, for: "sync_all")
    }

    var sharedAISettingsSnapshot: SharedAISettingsSnapshot {
        switch gatewaySource {
        case .custom:
            return SharedAISettingsSnapshot(
                source: .custom,
                endpoint: customAPIEndpoint,
                apiKey: customAPIKey,
                model: customAPISelectedModel,
                dashboardURL: nil
            )
        case .omniroute:
            return SharedAISettingsSnapshot(
                source: .omniroute,
                endpoint: omniRouteAPIURL,
                apiKey: omniRouteEndpointKey,
                model: omniRoutePreferredModel,
                dashboardURL: omniRouteDashboardURL
            )
        }
    }

    var apiEndpoint: String {
        sharedAISettingsSnapshot.normalizedEndpoint
    }

    var apiKey: String {
        sharedAISettingsSnapshot.normalizedApiKey
    }

    var apiSelectedModel: String {
        sharedAISettingsSnapshot.normalizedModel
    }

    func syncModule(_ module: OmniModuleDefinition) {
        cancelModuleTask(key: "sync:\(module.id)")
        presentModuleNotice("正在同步 \(module.title)…")
        moduleSyncStatuses[module.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步…",
            updatedAt: Date()
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let status = await OmniIntegrationService.shared.sync(module, from: self)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses[module.id] = status
        }
        registerModuleTask(task, for: "sync:\(module.id)")
    }

    func probeModule(_ module: OmniModuleDefinition) {
        cancelModuleTask(key: "probe:\(module.id)")
        presentModuleNotice("正在检查 \(module.title) 连接…")
        moduleSyncStatuses[module.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在检查连接…",
            updatedAt: Date()
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let baseOverride: String?
            switch module.id {
            case OmniModuleRegistry.siftly.id:
                baseOverride = self.siftlyBaseURL
            case OmniModuleRegistry.antigravity.id:
                baseOverride = self.antigravityBaseURL
            default:
                baseOverride = nil
            }
            let status = await OmniIntegrationService.shared.probe(
                module,
                baseURLOverride: baseOverride
            )
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses[module.id] = status
        }
        registerModuleTask(task, for: "probe:\(module.id)")
    }

    func bootstrapIntegrationsIfNeeded() {
        if siftlyAutoSyncEnabled,
           moduleSyncStatuses[OmniModuleRegistry.siftly.id]?.state == .idle,
           !apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !apiSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleModuleSync()
        }

        for module in OmniModuleRegistry.integratedModules where module.managedDocker != nil {
            refreshManagedModuleStatus(module)
        }

        checkModuleUpdatesIfNeeded()
    }

    func baseURL(for module: OmniModuleDefinition) -> String {
        switch module.id {
        case OmniModuleRegistry.siftly.id:
            return siftlyBaseURL
        case OmniModuleRegistry.omniRoute.id:
            return omniRouteDashboardURL
        case OmniModuleRegistry.antigravity.id:
            return antigravityBaseURL
        default:
            switch module.launchStyle {
            case .webApp(let url, _, _):
                return url
            }
        }
    }

    var gatewayConfigured: Bool {
        !apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setGatewaySource(_ source: GatewaySource) {
        gatewaySource = source
        if source == .omniroute, omniRoutePreferredModel.isEmpty, let first = apiAvailableModels.first {
            omniRoutePreferredModel = first
        }
    }

    func setModuleAsDefaultGateway(_ module: OmniModuleDefinition) {
        guard module.id == OmniModuleRegistry.omniRoute.id else { return }
        setGatewaySource(.omniroute)
        presentModuleNotice("已将 OmniRoute 设为默认网关", kind: .success)
    }

    func checkModuleUpdatesIfNeeded() {
        let supportedModules = OmniModuleRegistry.integratedModules.filter { $0.updateDefinition != nil }
        let needsCheck = supportedModules.contains { module in
            let state = moduleUpdateStatuses[module.id]?.state ?? .idle
            return state == .idle || state == .failure
        }

        guard needsCheck else { return }
        checkAllModuleUpdates()
    }

    func checkAllModuleUpdates() {
        let supportedModules = OmniModuleRegistry.integratedModules.filter { $0.updateDefinition != nil }
        guard !supportedModules.isEmpty else {
            presentModuleNotice("当前没有支持更新提醒的模块", kind: .info)
            return
        }

        for module in supportedModules {
            moduleUpdateStatuses[module.id] = ModuleUpdateStatus(
                state: .checking,
                message: "正在检查 GitHub 更新…",
                currentVersion: moduleUpdateStatuses[module.id]?.currentVersion,
                latestVersion: moduleUpdateStatuses[module.id]?.latestVersion,
                releaseURL: moduleUpdateStatuses[module.id]?.releaseURL,
                releaseTitle: moduleUpdateStatuses[module.id]?.releaseTitle,
                publishedAt: moduleUpdateStatuses[module.id]?.publishedAt,
                checkedAt: Date()
            )
        }

        presentModuleNotice("正在检查模块更新…")

        Task { [weak self] in
            guard let self else { return }
            let statuses = await ModuleUpdateService.shared.checkUpdates(for: supportedModules)
            self.moduleUpdateStatuses.merge(statuses) { _, new in new }

            let updateCount = statuses.values.filter { $0.state == .updateAvailable }.count
            let failureCount = statuses.values.filter { $0.state == .failure }.count
            if updateCount > 0 {
                self.presentModuleNotice("发现 \(updateCount) 个模块有新版本", kind: .success)
            } else if failureCount > 0 {
                self.presentModuleNotice("部分模块更新检查失败", kind: .failure)
            } else {
                self.presentModuleNotice("模块已是最新版本", kind: .success)
            }
        }
    }

    func openModuleReleasePage(_ module: OmniModuleDefinition) {
        guard let updateDefinition = module.updateDefinition,
              let targetURL = URL(string: moduleUpdateStatuses[module.id]?.releaseURL ?? updateDefinition.releasePageURL)
        else {
            presentModuleNotice("未找到 \(module.title) 的更新页面", kind: .failure)
            return
        }

        if NSWorkspace.shared.open(targetURL) {
            presentModuleNotice("已打开 \(module.title) 更新页面", kind: .success)
        } else {
            presentModuleNotice("打开 \(module.title) 更新页面失败", kind: .failure)
        }
    }

    func refreshManagedModuleStatus(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.status(module: module)
            self.managedModuleRuntimes[module.id] = runtime
        }
    }

    func startManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在启动 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.up(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(runtime.lastError == nil ? "\(module.title) 已启动" : runtime.details, kind: runtime.lastError == nil ? .success : .failure)
        }
    }

    func stopManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在停止 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.down(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(runtime.lastError == nil ? "\(module.title) 已停止" : runtime.details, kind: runtime.lastError == nil ? .success : .failure)
        }
    }

    func restartManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在重启 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.restart(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(runtime.lastError == nil ? "\(module.title) 已重启" : runtime.details, kind: runtime.lastError == nil ? .success : .failure)
        }
    }

    func fetchManagedModuleLogs(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在读取 \(module.title) 日志…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.logs(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.managedModuleLogs[module.id] = runtime.logsPreview ?? runtime.lastError ?? runtime.details
            self.presentModuleNotice(runtime.lastError == nil ? "已读取 \(module.title) 日志" : runtime.details, kind: runtime.lastError == nil ? .success : .failure)
        }
    }

    func probeManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在检查 \(module.title) 健康状态…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.probeHealth(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(runtime.lastError == nil ? "\(module.title) 健康检查通过" : runtime.details, kind: runtime.lastError == nil ? .success : .failure)
        }
    }

    func updateModule(_ module: OmniModuleDefinition) {
        presentModuleNotice("正在更新 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let log = try await ModuleUpdateService.shared.performUpdate(for: module)
                // Re-check version after update
                let statuses = await ModuleUpdateService.shared.checkUpdates(for: [module])
                self.moduleUpdateStatuses.merge(statuses) { _, new in new }
                let refreshedStatus = statuses[module.id]
                // Refresh Docker runtime if applicable
                if module.managedDocker != nil {
                    let runtime = await DockerModuleService.shared.status(module: module)
                    self.managedModuleRuntimes[module.id] = runtime
                }
                self.managedModuleLogs[module.id] = log

                let noticeMessage: String
                let noticeKind: ModuleActionNotice.Kind
                switch refreshedStatus?.state {
                case .upToDate:
                    noticeMessage = "\(module.title) 已更新至最新版本"
                    noticeKind = .success
                case .updateAvailable:
                    noticeMessage = "\(module.title) 更新流程已执行，但仍有新版本待拉取（可能因本地改动已跳过 git pull）"
                    noticeKind = .info
                case .unknownCurrentVersion:
                    noticeMessage = "\(module.title) 更新流程已执行，但当前本地版本无法确认"
                    noticeKind = .info
                case .failure:
                    noticeMessage = "\(module.title) 已执行更新步骤，但重新检查版本失败：\(refreshedStatus?.message ?? "未知错误")"
                    noticeKind = .failure
                case .checking:
                    noticeMessage = "\(module.title) 更新步骤已执行，正在等待版本检查完成"
                    noticeKind = .info
                case .unsupported:
                    noticeMessage = "\(module.title) 更新已执行，但该模块不支持版本校验"
                    noticeKind = .info
                case .idle, .none:
                    noticeMessage = "\(module.title) 更新步骤已执行"
                    noticeKind = .success
                }
                self.presentModuleNotice(noticeMessage, kind: noticeKind)
            } catch {
                self.moduleUpdateStatuses[module.id] = ModuleUpdateStatus(
                    state: .failure,
                    message: error.localizedDescription,
                    currentVersion: self.moduleUpdateStatuses[module.id]?.currentVersion,
                    latestVersion: self.moduleUpdateStatuses[module.id]?.latestVersion,
                    releaseURL: self.moduleUpdateStatuses[module.id]?.releaseURL,
                    releaseTitle: self.moduleUpdateStatuses[module.id]?.releaseTitle,
                    publishedAt: self.moduleUpdateStatuses[module.id]?.publishedAt,
                    checkedAt: Date()
                )
                self.presentModuleNotice("更新失败：\(error.localizedDescription)", kind: .failure)
            }
        }
    }

    func prepareAntigravityRunner() {
        Task { [weak self] in
            guard let self else { return }
            self.antigravityIsRunningWorkflow = true
            defer { self.antigravityIsRunningWorkflow = false }
            _ = await self.ensureAntigravityRunner()
        }
    }


    func ensureAntigravityRunnerForLaunch() async -> Bool {
        await ensureAntigravityRunner()
    }

    func runAntigravityDiagnosisOnly() {
        Task { [weak self] in
            await self?.runAntigravityWorkflow(autoFix: false)
        }
    }

    func runAntigravityDiagnosisAndAutoRepair() {
        Task { [weak self] in
            await self?.runAntigravityWorkflow(autoFix: true)
        }
    }

    func clearAntigravityLogs() {
        antigravityDiagnosisLog = ""
        antigravityAutoFixLog = ""
    }

    private func runAntigravityWorkflow(autoFix: Bool) async {
        guard !antigravityIsRunningWorkflow else { return }
        let email = antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            presentModuleNotice("请先填写 Google 邮箱", kind: .failure)
            return
        }

        antigravityIsRunningWorkflow = true
        defer { antigravityIsRunningWorkflow = false }

        antigravityDiagnosisLog = ""
        antigravityAutoFixLog = ""

        presentModuleNotice("正在检查 Antigravity 执行器…")
        let runnerReady = await ensureAntigravityRunner()
        guard runnerReady else {
            presentModuleNotice("Antigravity 执行器不可用", kind: .failure)
            return
        }

        presentModuleNotice("正在执行一键诊断…")
        let projectId = antigravityProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnosisResult: AntigravityRunResponse

        do {
            diagnosisResult = try await invokeAntigravityRunner(
                mode: "diag",
                email: email,
                projectId: projectId
            )
        } catch {
            antigravityDiagnosisLog = "诊断请求失败：\(error.localizedDescription)"
            presentModuleNotice("诊断失败：\(error.localizedDescription)", kind: .failure)
            return
        }

        let diagnosisText = diagnosisResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        antigravityDiagnosisLog = diagnosisText.isEmpty ? "(诊断无输出)" : diagnosisText
        antigravityRunnerStatus = diagnosisResult.ok ? "诊断完成" : "诊断返回异常"

        let shouldAutoFix = autoFix && antigravityAutoFixEnabled
        guard shouldAutoFix else {
            presentModuleNotice(diagnosisResult.ok ? "诊断完成" : "诊断完成（存在异常）", kind: diagnosisResult.ok ? .success : .failure)
            return
        }

        guard gatewayConfigured else {
            antigravityAutoFixLog = "未配置统一 AI 网关，无法执行 AI 自动修复。请先在「统一 AI」里配置 Endpoint 和模型。"
            presentModuleNotice("未配置统一 AI，无法自动修复", kind: .failure)
            return
        }

        presentModuleNotice("正在生成 AI 修复计划并自动执行…")
        do {
            let executionLog = try await runAntigravityAutoFix(with: antigravityDiagnosisLog)
            antigravityAutoFixLog = executionLog
            presentModuleNotice("AI 自动修复执行完成", kind: .success)
        } catch {
            antigravityAutoFixLog = "AI 自动修复失败：\(error.localizedDescription)"
            presentModuleNotice("AI 自动修复失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    private func ensureAntigravityRunner() async -> Bool {
        if await probeAntigravityRunner() {
            antigravityRunnerStatus = "在线"
            return true
        }

        antigravityRunnerStatus = "未在线，正在尝试启动"
        let started = await startAntigravityRunner()
        guard started else {
            antigravityRunnerStatus = "启动命令执行失败"
            return false
        }

        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await probeAntigravityRunner() {
                antigravityRunnerStatus = "已自动启动并在线"
                return true
            }
        }

        antigravityRunnerStatus = "启动后仍未连通，请检查项目路径和端口"
        return false
    }

    private func probeAntigravityRunner() async -> Bool {
        guard let baseURL = URL(string: antigravityBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let probeURL = baseURL.appendingPathComponent("api/runner/prefill")
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func startAntigravityRunner() async -> Bool {
        let rawPath = antigravityInstallPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return false }
        let escapedPath = shellEscape(rawPath)
        let port = URL(string: antigravityBaseURL)?.port ?? 4173
        let command = "cd \(escapedPath) && OMNI_EMBEDDED=1 nohup npm run dev -- --host 127.0.0.1 --port \(port) --strictPort >/tmp/omni-antigravity-dev.log 2>&1 < /dev/null &!"

        do {
            let result = try await runShell(command, timeout: 20)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func invokeAntigravityRunner(
        mode: String,
        email: String,
        projectId: String
    ) async throws -> AntigravityRunResponse {
        guard let baseURL = URL(string: antigravityBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "Antigravity", code: -1, userInfo: [NSLocalizedDescriptionKey: "模块地址无效"])
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/runner/run"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AntigravityRunPayload(mode: mode, email: email, projectId: projectId)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Antigravity", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效的模块响应"])
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "Antigravity",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "请求失败（HTTP \(http.statusCode)）" : body]
            )
        }

        do {
            return try JSONDecoder().decode(AntigravityRunResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "Antigravity",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "模块返回数据无法解析" : body]
            )
        }
    }

    private func runAntigravityAutoFix(with diagnosis: String) async throws -> String {
        let systemPrompt = """
        你是 macOS 本地 Antigravity 故障修复助手。你会收到诊断日志，请返回最小修复命令集合。
        你必须仅输出 JSON，不要使用 Markdown。
        JSON 格式：
        {"summary":"一句话结论","commands":[{"cmd":"单行bash命令","reason":"简短原因"}]}

        约束：
        1. 只允许以下命令类型：gcloud、lsof、ps、pkill、kill -9、rm -rf（仅限 Antigravity 的 Cache/CachedData 路径）、open URL。
        2. 禁止 sudo、禁止删除非 Antigravity 路径、禁止安装未知软件、禁止修改系统关键目录。
        3. 如果无需修复，commands 返回空数组。
        """

        let userPrompt = """
        请基于以下诊断日志生成修复计划：

        \(diagnosis)
        """

        let aiRaw = try await APIService.shared.completeText(
            endpoint: apiEndpoint,
            apiKey: apiKey,
            model: apiSelectedModel,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )

        let plan = try decodeAIFixPlan(from: aiRaw)
        var lines: [String] = []
        lines.append("AI 修复总结：\(plan.summary)")
        lines.append("")

        var executed = 0
        for (idx, item) in plan.commands.prefix(10).enumerated() {
            let command = item.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            lines.append("[\(idx + 1)] \(command)")
            if let reason = item.reason, !reason.isEmpty {
                lines.append("原因：\(reason)")
            }

            guard isSafeRepairCommand(command) else {
                lines.append("状态：已跳过（命令不在安全白名单）")
                lines.append("")
                continue
            }

            do {
                let timeout: TimeInterval = command.contains("gcloud auth application-default login") ? 180 : 60
                let result = try await runShell(command, timeout: timeout)
                let output = [result.stdout, result.stderr]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                lines.append("状态：\(result.exitCode == 0 ? "成功" : "失败(\(result.exitCode))")")
                if !output.isEmpty {
                    lines.append(output)
                }
                lines.append("")
                executed += 1
            } catch {
                lines.append("状态：执行异常 - \(error.localizedDescription)")
                lines.append("")
            }
        }

        lines.append("已执行命令数量：\(executed)")
        lines.append("")
        lines.append("=== 自动复检 ===")

        do {
            let verify = try await invokeAntigravityRunner(
                mode: "diag",
                email: antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                projectId: antigravityProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            lines.append(verify.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(复检无输出)")
        } catch {
            lines.append("复检失败：\(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    private func decodeAIFixPlan(from text: String) throws -> AntigravityAIFixPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = try? JSONDecoder().decode(AntigravityAIFixPlan.self, from: Data(trimmed.utf8)) {
            return direct
        }

        guard let jsonBody = extractJSONObject(from: trimmed),
              let data = jsonBody.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AntigravityAIFixPlan.self, from: data)
        else {
            throw NSError(domain: "Antigravity", code: -4, userInfo: [NSLocalizedDescriptionKey: "AI 返回格式无法解析，请重试"])
        }

        return parsed
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else {
            return nil
        }
        return String(text[start...end])
    }

    private func isSafeRepairCommand(_ command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return false }

        let blockedKeywords = [
            "sudo ",
            "rm -rf /",
            "mkfs",
            "diskutil erase",
            "shutdown",
            "reboot",
            "chmod -R 777 /",
            "chown -R /",
            "curl | sh",
            "wget | sh",
            ">/etc",
            "> /etc"
        ]

        if blockedKeywords.contains(where: { cmd.localizedCaseInsensitiveContains($0) }) {
            return false
        }

        if cmd.hasPrefix("gcloud ") { return true }
        if cmd == "ps aux | grep -i antigravity" { return true }
        if cmd == "lsof -i :64147" { return true }
        if cmd.hasPrefix("pkill -f -i antigravity") { return true }
        if cmd.hasPrefix("open http://") || cmd.hasPrefix("open https://") { return true }

        if cmd.hasPrefix("kill -9 ") {
            let parts = cmd.replacingOccurrences(of: "kill -9 ", with: "")
                .split(separator: " ")
                .map(String.init)
            return !parts.isEmpty && parts.allSatisfy { Int($0) != nil }
        }

        if cmd.hasPrefix("rm -rf ") {
            return cmd.contains("/Antigravity/Cache") || cmd.contains("/Antigravity/CachedData")
        }

        return false
    }

    private func runShell(_ command: String, timeout: TimeInterval) async throws -> ShellCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let box = ShellFinishBox()
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let finish: (Result<ShellCommandResult, Error>) -> Void = { result in
                box.lock.lock()
                defer { box.lock.unlock() }
                guard !box.finished else { return }
                box.finished = true
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    finish(.failure(NSError(
                        domain: "Shell",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "命令执行超时：\(command)"]
                    )))
                }
            }

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                finish(.success(ShellCommandResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )))
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            } catch {
                timeoutItem.cancel()
                finish(.failure(error))
            }
        }
    }

    private func shellEscape(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
        updateWindowLevel()
    }

    func registerModuleLauncher(_ launcher: @escaping (OmniModuleDefinition) -> Bool) {
        moduleLauncher = launcher
    }

    func registerSettingsPresenter(_ presenter: @escaping () -> Void) {
        settingsPresenter = presenter
    }

    func openModule(_ module: OmniModuleDefinition) {
        let now = Date()
        if let lastOpened = lastModuleOpenAt[module.id],
           now.timeIntervalSince(lastOpened) < 0.8 {
            return
        }
        lastModuleOpenAt[module.id] = now

        if moduleLauncher?(module) == true {
            presentModuleNotice("已打开 \(module.title) 窗口", kind: .success)
            return
        }


        // Integrated modules should open inside Omni. If launcher is unavailable,
        // avoid falling back to external browser to prevent duplicate windows.
        if OmniModuleRegistry.module(id: module.id) != nil {
            presentModuleNotice("\(module.title) 窗口未就绪，请稍后重试", kind: .failure)
            return
        }
        switch module.launchStyle {
        case .webApp(let url, _, _):
            guard let targetURL = URL(string: url) else {
                presentModuleNotice("\(module.title) 地址无效", kind: .failure)
                return
            }

            if NSWorkspace.shared.open(targetURL) {
                presentModuleNotice("已在浏览器打开 \(module.title)", kind: .success)
            } else {
                presentModuleNotice("打开 \(module.title) 失败", kind: .failure)
            }
        }
    }

    func openSettings() {
        guard let settingsPresenter else {
            presentModuleNotice("偏好设置窗口当前不可用", kind: .failure)
            return
        }

        settingsPresenter()
        presentModuleNotice("已打开偏好设置", kind: .success)
    }

    func presentModuleNotice(_ message: String, kind: ModuleActionNotice.Kind = .info) {
        noticeDismissTask?.cancel()
        moduleActionNotice = ModuleActionNotice(message: message, kind: kind)

        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.moduleActionNotice = nil
        }
    }

    func updateWindowLevel() {
        mainWindow?.level = isPinned ? .floating : .normal
    }

    private func registerModuleTask(_ task: Task<Void, Never>, for key: String) {
        moduleTasks[key]?.cancel()
        moduleTasks[key] = task
    }

    private func cancelModuleTask(key: String) {
        moduleTasks[key]?.cancel()
        moduleTasks[key] = nil
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(appState: appState)
            if appState.workspaceMode == .modules {
                ModuleHomeView(appState: appState)
            } else {
                WebContentArea(appState: appState)
                SyncInputBar(appState: appState)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            appState.applyAppearance()
            WebViewManager.shared.updateUserAgentSettings(appState.userAgentSettings)
            WebViewManager.shared.preloadWebViews()
            WebViewManager.shared.syncThemeForAllWebViews(mode: appState.appearanceMode)
            appState.bootstrapIntegrationsIfNeeded()
        }
        .onChange(of: appState.appearanceMode) { _ in
            appState.applyAppearance()
            WebViewManager.shared.syncThemeForAllWebViews(mode: appState.appearanceMode)
        }
        .onChange(of: appState.isPinned) { _ in
            appState.updateWindowLevel()
        }
        .onChange(of: appState.userAgentSettings) { _ in
            WebViewManager.shared.updateUserAgentSettings(appState.userAgentSettings)
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @ObservedObject var appState: AppState
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        HStack(spacing: 0) {
            TabButton(
                title: WorkspaceMode.modules.title,
                icon: WorkspaceMode.modules.iconName,
                isSelected: appState.workspaceMode == .modules
            ) {
                appState.workspaceMode = .modules
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 6)

            ForEach(AIProvider.allCases) { provider in
                TabButton(
                    title: provider.displayName,
                    icon: provider.iconName,
                    isSelected: appState.workspaceMode == .ai && appState.selectedTab == provider
                ) {
                    appState.workspaceMode = .ai
                    appState.selectedTab = provider
                }
            }

            Spacer()

            if appState.workspaceMode == .ai {
                Button {
                    if appState.selectedTab == .all {
                        WebViewManager.shared.startNewChatForAll()
                    } else {
                        WebViewManager.shared.startNewChat(for: appState.selectedTab)
                    }
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("新对话")

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)
                ForEach(LayoutMode.allCases, id: \.self) { mode in
                    Button {
                        appState.layoutMode = mode
                        appState.selectedTab = .all
                    } label: {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .background(appState.layoutMode == mode && appState.selectedTab == .all
                                        ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(mode.label)
                }

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)
            }

            // Appearance toggle
            Menu {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        appState.appearanceMode = mode
                    } label: {
                        HStack {
                            Image(systemName: mode.iconName)
                            Text(mode.displayName)
                            if appState.appearanceMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: appState.appearanceMode.iconName)
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .help("Theme")

            // Pin on top toggle
            Button {
                appState.isPinned.toggle()
            } label: {
                Image(systemName: appState.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .foregroundColor(appState.isPinned ? .accentColor : .secondary)
                    .background(appState.isPinned ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help(appState.isPinned ? "Unpin window" : "Pin on top")

            if appState.workspaceMode == .ai {
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                Button {
                    Task { await startAggregation() }
                } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .foregroundColor(appState.isAggregating ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(appState.isAggregating)
                .help("AI 聚合分析")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .alert("Omni", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $appState.showAggregationResult) {
            AggregationResultView(appState: appState)
        }
    }

    private func startAggregation() async {
        guard !appState.apiEndpoint.isEmpty else {
            alertMessage = "未配置 API 地址，请在偏好设置 > API 中设置。"
            showAlert = true
            return
        }
        guard !appState.apiSelectedModel.isEmpty else {
            alertMessage = "未选择模型，请在偏好设置 > API 中获取并选择模型。"
            showAlert = true
            return
        }

        var contents: [(provider: AIProvider, text: String)] = []
        for provider in AIProvider.providers {
            do {
                let text = try await ExportService.shared.extractContent(from: provider)
                if !text.isEmpty {
                    contents.append((provider: provider, text: text))
                }
            } catch {
                // Partial aggregation is still useful
            }
        }

        guard !contents.isEmpty else {
            alertMessage = "未能从任何 AI 提取到内容。请先向 AI 提问后再聚合。"
            showAlert = true
            return
        }

        appState.aggregationError = nil
        appState.isAggregating = true
        appState.showAggregationResult = true

        // Reset the streaming store — clears NSTextView and internal buffer
        StreamingTextStore.shared.reset()

        let stream = APIService.shared.aggregate(
            endpoint: appState.apiEndpoint,
            apiKey: appState.apiKey,
            model: appState.apiSelectedModel,
            contents: contents,
            question: appState.syncQuestion.isEmpty ? nil : appState.syncQuestion,
            systemPrompt: appState.apiSystemPrompt
        )

        do {
            // Stream chunks directly to NSTextView via StreamingTextStore
            // No SwiftUI @Published updates during streaming — zero diffing overhead
            for try await chunk in stream {
                StreamingTextStore.shared.append(chunk)
            }
            // Flush any remaining buffered text
            StreamingTextStore.shared.finish()
        } catch {
            // Flush whatever we have so far before reporting the error
            StreamingTextStore.shared.finish()
            appState.aggregationError = error.localizedDescription
        }

        // Sync final text back for save/export (single update, not per-chunk)
        appState.aggregationResult = StreamingTextStore.shared.getFinalText()
        appState.isAggregating = false
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Module Home

struct ModuleHomeView: View {
    @ObservedObject var appState: AppState

    private var modules: [OmniModuleDefinition] {
        OmniModuleRegistry.integratedModules
    }

    private var healthyCount: Int {
        modules.filter { module in
            if module.managedDocker != nil {
                return appState.managedModuleRuntimes[module.id]?.state == .running
            }
            return appState.moduleSyncStatuses[module.id]?.state == .success
        }.count
    }

    private var issueCount: Int {
        modules.filter { module in
            if module.managedDocker != nil {
                if let state = appState.managedModuleRuntimes[module.id]?.state {
                    return state == .dockerUnavailable || state == .failure || state == .unhealthy
                }
                return false
            }
            return appState.moduleSyncStatuses[module.id]?.state == .failure
        }.count
    }

    private var updateAvailableCount: Int {
        modules.filter { module in
            appState.moduleUpdateStatuses[module.id]?.state == .updateAvailable
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero

                if let notice = appState.moduleActionNotice {
                    ModuleActionNoticeBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(spacing: 14) {
                    ModuleMetricCard(
                        title: "已接入模块",
                        value: "\(modules.count)",
                        caption: "统一在 Omni 中管理",
                        color: .blue
                    )
                    ModuleMetricCard(
                        title: "同步正常",
                        value: "\(healthyCount)",
                        caption: "配置已连通",
                        color: .green
                    )
                    ModuleMetricCard(
                        title: "有更新",
                        value: "\(updateAvailableCount)",
                        caption: "GitHub 检测到新版本",
                        color: .orange
                    )
                    ModuleMetricCard(
                        title: "待处理",
                        value: "\(issueCount)",
                        caption: "需要检查模块连接",
                        color: .red
                    )
                }

                HStack(alignment: .top, spacing: 18) {
                    gatewayCard
                    quickActionsCard
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("模块面板")
                        .font(.system(size: 18, weight: .semibold))

                    ForEach(modules) { module in
                        ModuleOverviewCard(appState: appState, module: module)
                    }
                }
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.blue.opacity(0.08),
                            Color.black.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text("模块首页")
                    .font(.system(size: 30, weight: .bold))
                Text("把本地工具放进同一个工作台里管理。AI 网关只配置一次，已接入的模块直接复用。")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    HomeActionButton(title: "进入 AI 工作台", icon: "brain.head.profile") {
                        appState.workspaceMode = .ai
                        appState.selectedTab = .all
                    }

                    HomeActionButton(title: "打开偏好设置", icon: "slider.horizontal.3") {
                        appState.openSettings()
                    }
                }
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    private var gatewayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("统一 AI 网关", systemImage: "network")
                .font(.system(size: 17, weight: .semibold))

            ModuleInfoRow(label: "来源", value: appState.gatewaySource.displayName)
            ModuleInfoRow(label: "Endpoint", value: appState.apiEndpoint.isEmpty ? "未配置" : appState.apiEndpoint)
            ModuleInfoRow(label: "Model", value: appState.apiSelectedModel.isEmpty ? "未选择" : appState.apiSelectedModel)
            ModuleInfoRow(label: "API Key", value: appState.apiKey.isEmpty ? "未配置" : "已保存到钥匙串")
            ModuleInfoRow(label: "自动同步", value: appState.siftlyAutoSyncEnabled ? "已开启" : "已关闭")

            if !appState.gatewayConfigured {
                Label("还没完成网关配置，模块暂时不会自动继承 AI 能力。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("快捷动作", systemImage: "bolt.fill")
                .font(.system(size: 17, weight: .semibold))

            HomeActionButton(title: "同步全部模块", icon: "arrow.triangle.2.circlepath") {
                appState.presentModuleNotice("正在同步全部模块…")
                for module in modules where module.syncAdapter != nil {
                    appState.syncModule(module)
                }
            }

            HomeActionButton(title: "检查模块连接", icon: "dot.radiowaves.left.and.right") {
                appState.presentModuleNotice("正在检查模块连接…")
                for module in modules {
                    if module.managedDocker != nil {
                        appState.probeManagedModule(module)
                    } else {
                        appState.probeModule(module)
                    }
                }
            }

            HomeActionButton(title: "检查模块更新", icon: "arrow.down.circle") {
                appState.checkAllModuleUpdates()
            }

            if let module = modules.first {
                HomeActionButton(title: "打开 \(module.title)", icon: module.icon) {
                    appState.openModule(module)
                }
            }
        }
        .padding(20)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ModuleOverviewCard: View {
    @ObservedObject var appState: AppState
    let module: OmniModuleDefinition

    private var status: ModuleSyncStatus {
        appState.moduleSyncStatuses[module.id] ?? .idle
    }

    private var runtime: ManagedDockerModuleRuntime? {
        appState.managedModuleRuntimes[module.id]
    }

    private var updateStatus: ModuleUpdateStatus? {
        appState.moduleUpdateStatuses[module.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: module.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(module.title)
                            .font(.system(size: 18, weight: .semibold))
                        Text(module.subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
                if let runtime {
                    ManagedModuleStatusBadge(runtime: runtime)
                } else {
                    ModuleStatusBadge(status: status)
                }
            }

            if let managed = module.managedDocker {
                ModuleInfoRow(label: "Dashboard", value: appState.baseURL(for: module))
                ModuleInfoRow(label: "API", value: module.id == OmniModuleRegistry.omniRoute.id ? appState.omniRouteAPIURL : managed.apiBaseURL)
                ModuleInfoRow(label: "安装目录", value: managed.installPath)
                ModuleInfoRow(label: "运行状态", value: runtime?.details ?? "尚未检测")
                if let updatedAt = runtime?.updatedAt {
                    ModuleInfoRow(label: "最近状态", value: updatedAt.formatted(date: .omitted, time: .shortened))
                }

                if let updateStatus {
                    ModuleUpdateSection(updateStatus: updateStatus)
                }

                HStack(spacing: 10) {
                    HomeActionButton(title: "打开 Dashboard", icon: "arrow.up.right.square") {
                        appState.openModule(module)
                    }
                    HomeActionButton(title: "启动", icon: "play.fill") {
                        appState.startManagedModule(module)
                    }
                    HomeActionButton(title: "停止", icon: "stop.fill") {
                        appState.stopManagedModule(module)
                    }
                    HomeActionButton(title: "重启", icon: "arrow.clockwise") {
                        appState.restartManagedModule(module)
                    }
                    HomeActionButton(title: "日志", icon: "doc.text.magnifyingglass") {
                        appState.fetchManagedModuleLogs(module)
                    }
                    HomeActionButton(title: "设为默认网关", icon: "network") {
                        appState.setModuleAsDefaultGateway(module)
                    }
                }

                if module.updateDefinition != nil {
                    HStack(spacing: 10) {
                        HomeActionButton(title: "检查更新", icon: "arrow.down.circle") {
                            appState.checkAllModuleUpdates()
                        }
                        if updateStatus?.state == .updateAvailable {
                            HomeActionButton(title: "立即更新", icon: "arrow.down.circle.fill") {
                                appState.updateModule(module)
                            }
                        }
                        HomeActionButton(title: "更新日志", icon: "text.document") {
                            appState.openModuleReleasePage(module)
                        }
                    }
                }
            } else {
                ModuleInfoRow(label: "模块地址", value: appState.baseURL(for: module))
                ModuleInfoRow(label: "同步状态", value: status.message)

                if let updatedAt = status.updatedAt {
                    ModuleInfoRow(
                        label: "最近状态",
                        value: updatedAt.formatted(date: .omitted, time: .shortened)
                    )
                }

                if let updateStatus {
                    ModuleUpdateSection(updateStatus: updateStatus)
                }

                HStack(spacing: 10) {
                    HomeActionButton(title: "打开", icon: "arrow.up.right.square") {
                        appState.openModule(module)
                    }

                    HomeActionButton(title: "同步", icon: "arrow.triangle.2.circlepath") {
                        appState.syncModule(module)
                    }

                    HomeActionButton(title: "测试", icon: "antenna.radiowaves.left.and.right") {
                        appState.probeModule(module)
                    }
                }

                if module.updateDefinition != nil {
                    HStack(spacing: 10) {
                        HomeActionButton(title: "检查更新", icon: "arrow.down.circle") {
                            appState.checkAllModuleUpdates()
                        }
                        if updateStatus?.state == .updateAvailable {
                            HomeActionButton(title: "立即更新", icon: "arrow.down.circle.fill") {
                                appState.updateModule(module)
                            }
                        }
                        HomeActionButton(title: "更新日志", icon: "text.document") {
                            appState.openModuleReleasePage(module)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    private var strokeColor: Color {
        if let runtime {
            switch runtime.state {
            case .dockerUnavailable, .failure:
                return Color.red.opacity(0.35)
            case .notInstalled:
                return Color.white.opacity(0.06)
            case .stopped:
                return Color.orange.opacity(0.35)
            case .running:
                return Color.green.opacity(0.35)
            case .unhealthy:
                return Color.yellow.opacity(0.35)
            }
        }

        switch status.state {
        case .idle:
            return Color.white.opacity(0.06)
        case .syncing:
            return Color.orange.opacity(0.35)
        case .success:
            return Color.green.opacity(0.35)
        case .failure:
            return Color.red.opacity(0.35)
        }
    }
}

struct ModuleMetricCard: View {
    let title: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(caption)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 1)
        )
    }
}

struct ModuleInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
    }
}

struct ModuleUpdateSection: View {
    let updateStatus: ModuleUpdateStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(accentColor)
                Text(updateStatus.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)
                Spacer(minLength: 0)
            }

            if let currentVersion = updateStatus.currentVersion, !currentVersion.isEmpty {
                ModuleInfoRow(label: "当前版本", value: currentVersion)
            }

            if let latestVersion = updateStatus.latestVersion, !latestVersion.isEmpty {
                ModuleInfoRow(label: "最新版本", value: latestVersion)
            }

            if let checkedAt = updateStatus.checkedAt {
                ModuleInfoRow(label: "检查时间", value: checkedAt.formatted(date: .omitted, time: .shortened))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch updateStatus.state {
        case .idle:
            return "clock"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .upToDate:
            return "checkmark.seal.fill"
        case .updateAvailable:
            return "arrow.down.circle.fill"
        case .unknownCurrentVersion:
            return "questionmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        case .unsupported:
            return "minus.circle"
        }
    }

    private var accentColor: Color {
        switch updateStatus.state {
        case .upToDate:
            return .green
        case .updateAvailable, .unknownCurrentVersion:
            return .orange
        case .failure:
            return .red
        case .checking:
            return .blue
        case .idle, .unsupported:
            return .secondary
        }
    }
}

struct ModuleStatusBadge: View {
    let status: ModuleSyncStatus

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var title: String {
        switch status.state {
        case .idle:
            return "未同步"
        case .syncing:
            return "同步中"
        case .success:
            return "已同步"
        case .failure:
            return "失败"
        }
    }

    private var color: Color {
        switch status.state {
        case .idle:
            return .secondary
        case .syncing:
            return .orange
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}

struct ManagedModuleStatusBadge: View {
    let runtime: ManagedDockerModuleRuntime

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var title: String {
        switch runtime.state {
        case .dockerUnavailable:
            return "Docker 不可用"
        case .notInstalled:
            return "未安装"
        case .stopped:
            return "已停止"
        case .running:
            return runtime.isHealthy ? "健康" : "运行中"
        case .unhealthy:
            return "异常"
        case .failure:
            return "失败"
        }
    }

    private var color: Color {
        switch runtime.state {
        case .dockerUnavailable, .failure:
            return .red
        case .notInstalled:
            return .secondary
        case .stopped:
            return .orange
        case .running:
            return .green
        case .unhealthy:
            return .yellow
        }
    }
}

struct ModuleActionNoticeBanner: View {
    let notice: AppState.ModuleActionNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
            Text(notice.message)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(foregroundColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch notice.kind {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }

    private var foregroundColor: Color {
        switch notice.kind {
        case .info:
            return .accentColor
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch notice.kind {
        case .info:
            return Color.accentColor.opacity(0.10)
        case .success:
            return Color.green.opacity(0.10)
        case .failure:
            return Color.red.opacity(0.10)
        }
    }
}

struct HomeActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sync Input Bar

struct SyncInputBar: View {
    @ObservedObject var appState: AppState
    @State private var isSending = false

    private var placeholderText: String {
        if appState.selectedTab == .all {
            return "Ask all AIs at once..."
        }
        return "Ask \(appState.selectedTab.displayName)..."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            if appState.clipboardMonitorEnabled {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
                    .help("剪贴板监听已开启")
            }

            TextField(placeholderText, text: $appState.syncQuestion, onCommit: sendToAll)
                .textFieldStyle(.plain)
                .font(.system(size: 14))

            if !appState.syncQuestion.isEmpty {
                Button {
                    appState.syncQuestion = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }

            Button(action: sendToAll) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(appState.syncQuestion.isEmpty ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(appState.syncQuestion.isEmpty || isSending)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func sendToAll() {
        guard !appState.syncQuestion.isEmpty else { return }
        isSending = true
        let question = appState.syncQuestion
        let cooldown: TimeInterval

        if appState.selectedTab == .all {
            cooldown = WebViewManager.shared.sendQuestionToAll(question)
        } else {
            cooldown = WebViewManager.shared.sendQuestion(question, to: appState.selectedTab)
        }

        appState.syncQuestion = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldown) {
            isSending = false
        }
    }
}

// MARK: - Unified Web Content Area (all webviews always alive)

struct WebContentArea: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AIProvider.providers.enumerated()), id: \.element) { index, provider in
                let visible = isVisible(index: index, provider: provider)

                // Divider between panels in All mode
                if index > 0 && visible && appState.selectedTab == .all {
                    Divider()
                }

                VStack(spacing: 0) {
                    // Panel header only in All mode
                    if visible && appState.selectedTab == .all {
                        HStack {
                            Image(systemName: provider.iconName)
                                .foregroundColor(provider.color)
                                .font(.system(size: 11))
                            Text(provider.displayName)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()

                            Button {
                                if let url = provider.url {
                                    WebViewManager.shared.webView(for: provider).load(URLRequest(url: url))
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reload \(provider.displayName)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))

                        Divider()
                    }

                    PersistentWebView(provider: provider)
                }
                .frame(
                    minWidth: visible && appState.selectedTab == .all ? 280 : 0,
                    maxWidth: visible ? .infinity : 0
                )
                .clipped()
                .allowsHitTesting(visible)
            }
        }
    }

    private func isVisible(index: Int, provider: AIProvider) -> Bool {
        if appState.selectedTab == .all {
            return index < appState.layoutMode.columns
        }
        return appState.selectedTab == provider
    }
}
