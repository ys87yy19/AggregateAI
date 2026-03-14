import Foundation
import Combine
import OSLog

// MARK: - ModulesViewModel

/// ViewModel for the Modules workspace tab.
///
/// Owns:
/// - Module sync statuses and update statuses
/// - Docker-managed module runtime states and log previews
/// - Antigravity runner state (diagnosis/auto-fix workflows)
/// - Module action notices (transient banners)
///
/// Reads and writes settings through `SettingsService`.
/// Delegates networking to `OmniIntegrationService`, `DockerModuleService`, and
/// `ModuleUpdateService`.
@MainActor
final class ModulesViewModel: ObservableObject {

    // MARK: - Published state

    /// Sync result per module ID.
    @Published var moduleSyncStatuses: [String: ModuleSyncStatus] = [
        OmniModuleRegistry.siftly.id: .idle,
        OmniModuleRegistry.antigravity.id: ModuleSyncStatus(
            state: .success,
            message: "模块不需要同步",
            updatedAt: Date()
        )
    ]

    /// GitHub update check result per module ID.
    @Published var moduleUpdateStatuses: [String: ModuleUpdateStatus] = [
        OmniModuleRegistry.siftly.id: .idle,
        OmniModuleRegistry.omniRoute.id: .idle
    ]

    /// Docker runtime state per module ID (only populated for managed-Docker modules).
    @Published var managedModuleRuntimes: [String: ManagedDockerModuleRuntime] = [
        OmniModuleRegistry.omniRoute.id: ManagedDockerModuleRuntime.idle()
    ]

    /// Latest log snapshot per module ID.
    @Published var managedModuleLogs: [String: String] = [:]

    /// Transient status banner shown at the top of the module home view.
    @Published var moduleActionNotice: ModuleActionNotice?

    /// `true` while the Antigravity diagnosis/auto-fix workflow is running.
    @Published private(set) var antigravityIsRunningWorkflow: Bool = false

    /// Human-readable Antigravity runner status string.
    @Published private(set) var antigravityRunnerStatus: String = "未检查"

    /// Log output from the most recent Antigravity diagnosis run.
    @Published var antigravityDiagnosisLog: String = ""

    /// Log output from the most recent AI auto-fix execution.
    @Published var antigravityAutoFixLog: String = ""

    // MARK: - Nested types

    struct ModuleActionNotice: Identifiable, Equatable {
        enum Kind: Equatable { case info, success, failure }
        let id = UUID()
        let message: String
        let kind: Kind
    }

    // MARK: - Dependencies

    let settingsService: SettingsService
    private var cancellables = Set<AnyCancellable>()
    private var moduleTasks: [String: Task<Void, Never>] = [:]
    private var noticeDismissTask: Task<Void, Never>?
    private var moduleLauncher: ((OmniModuleDefinition) -> Bool)?
    private var settingsPresenter: (() -> Void)?
    private var lastModuleOpenAt: [String: Date] = [:]
    private let logger = Logger(subsystem: "com.omni.app", category: "ModulesViewModel")

    // MARK: - Init

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
        setupAutoSync()
    }

    // MARK: - Setup

    func registerModuleLauncher(_ launcher: @escaping (OmniModuleDefinition) -> Bool) {
        moduleLauncher = launcher
    }

    func registerSettingsPresenter(_ presenter: @escaping () -> Void) {
        settingsPresenter = presenter
    }

    /// Should be called once the app window is visible and ready.
    func bootstrapIntegrationsIfNeeded() {
        let snapshot = settingsService.sharedAISnapshot
        let s = settingsService.settings

        if s.siftlyAutoSyncEnabled,
           moduleSyncStatuses[OmniModuleRegistry.siftly.id]?.state == .idle,
           snapshot.isConfigured {
            scheduleModuleSync()
        }

        for module in OmniModuleRegistry.integratedModules where module.managedDocker != nil {
            refreshManagedModuleStatus(module)
        }

        checkModuleUpdatesIfNeeded()
    }

    // MARK: - Settings-driven auto-sync

    private func setupAutoSync() {
        // Debounce gateway-config changes and trigger re-sync
        settingsService.$settings
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] s in
                guard let self, s.siftlyAutoSyncEnabled else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)

        // Re-sync when Keychain values change (API key / OmniRoute key)
        settingsService.$customAPIKey
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.settingsService.settings.siftlyAutoSyncEnabled,
                      self.settingsService.settings.gatewaySource == .custom
                else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)

        settingsService.$omniRouteEndpointKey
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.settingsService.settings.siftlyAutoSyncEnabled,
                      self.settingsService.settings.gatewaySource == .omniroute
                else { return }
                self.scheduleModuleSync()
            }
            .store(in: &cancellables)
    }

    // MARK: - Module sync

    private func scheduleModuleSync() {
        cancelModuleTask(key: "sync_all")
        moduleSyncStatuses[OmniModuleRegistry.siftly.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步统一 AI 配置…",
            updatedAt: Date()
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let snapshot = self.settingsService.sharedAISnapshot
            let s = self.settingsService.settings
            let statuses = await self.syncAllModules(snapshot: snapshot, settings: s)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses.merge(statuses) { _, new in new }
        }
        registerModuleTask(task, for: "sync_all")
    }

    private func syncAllModules(
        snapshot: SharedAISettingsSnapshot,
        settings: AppSettings
    ) async -> [String: ModuleSyncStatus] {
        var statuses: [String: ModuleSyncStatus] = [:]
        for module in OmniModuleRegistry.integratedModules where module.syncAdapter != nil {
            statuses[module.id] = await syncModule(module, snapshot: snapshot, settings: settings)
        }
        return statuses
    }

    private func syncModule(
        _ module: OmniModuleDefinition,
        snapshot: SharedAISettingsSnapshot,
        settings: AppSettings
    ) async -> ModuleSyncStatus {
        // Build a temporary AppState-compatible context – bridging to existing OmniIntegrationService
        // TODO: Refactor OmniIntegrationService to accept (snapshot, settings) directly
        let tempAppState = LegacyAppStateBridge(snapshot: snapshot, settings: settings)
        return await OmniIntegrationService.shared.sync(module, from: tempAppState)
    }

    func triggerModuleSync(_ module: OmniModuleDefinition) {
        cancelModuleTask(key: "sync:\(module.id)")
        presentModuleNotice("正在同步 \(module.title)…")
        moduleSyncStatuses[module.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步…",
            updatedAt: Date()
        )

        let snapshot = settingsService.sharedAISnapshot
        let s = settingsService.settings
        let task = Task { [weak self] in
            guard let self else { return }
            let status = await self.syncModule(module, snapshot: snapshot, settings: s)
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

        let s = settingsService.settings
        let task = Task { [weak self] in
            guard let self else { return }
            let baseOverride: String?
            switch module.id {
            case OmniModuleRegistry.siftly.id:      baseOverride = s.siftlyBaseURL
            case OmniModuleRegistry.antigravity.id: baseOverride = s.antigravityBaseURL
            default:                                baseOverride = nil
            }
            let status = await OmniIntegrationService.shared.probe(module, baseURLOverride: baseOverride)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses[module.id] = status
        }
        registerModuleTask(task, for: "probe:\(module.id)")
    }

    // MARK: - Docker module management

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
            self.presentModuleNotice(
                runtime.lastError == nil ? "\(module.title) 已启动" : runtime.details,
                kind: runtime.lastError == nil ? .success : .failure
            )
        }
    }

    func stopManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在停止 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.down(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(
                runtime.lastError == nil ? "\(module.title) 已停止" : runtime.details,
                kind: runtime.lastError == nil ? .success : .failure
            )
        }
    }

    func restartManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在重启 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.restart(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(
                runtime.lastError == nil ? "\(module.title) 已重启" : runtime.details,
                kind: runtime.lastError == nil ? .success : .failure
            )
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
            self.presentModuleNotice(
                runtime.lastError == nil ? "已读取 \(module.title) 日志" : runtime.details,
                kind: runtime.lastError == nil ? .success : .failure
            )
        }
    }

    func probeManagedModule(_ module: OmniModuleDefinition) {
        guard module.managedDocker != nil else { return }
        presentModuleNotice("正在检查 \(module.title) 健康状态…")
        Task { [weak self] in
            guard let self else { return }
            let runtime = await DockerModuleService.shared.probeHealth(module: module)
            self.managedModuleRuntimes[module.id] = runtime
            self.presentModuleNotice(
                runtime.lastError == nil ? "\(module.title) 健康检查通过" : runtime.details,
                kind: runtime.lastError == nil ? .success : .failure
            )
        }
    }

    // MARK: - Module updates

    func checkModuleUpdatesIfNeeded() {
        let supported = OmniModuleRegistry.integratedModules.filter { $0.updateDefinition != nil }
        let needsCheck = supported.contains { module in
            let state = moduleUpdateStatuses[module.id]?.state ?? .idle
            return state == .idle || state == .failure
        }
        guard needsCheck else { return }
        checkAllModuleUpdates()
    }

    func checkAllModuleUpdates() {
        let supported = OmniModuleRegistry.integratedModules.filter { $0.updateDefinition != nil }
        guard !supported.isEmpty else {
            presentModuleNotice("当前没有支持更新提醒的模块", kind: .info)
            return
        }

        for module in supported {
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
            let statuses = await ModuleUpdateService.shared.checkUpdates(for: supported)
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

    func updateModule(_ module: OmniModuleDefinition) {
        presentModuleNotice("正在更新 \(module.title)…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let log = try await ModuleUpdateService.shared.performUpdate(for: module)
                let statuses = await ModuleUpdateService.shared.checkUpdates(for: [module])
                self.moduleUpdateStatuses.merge(statuses) { _, new in new }
                let refreshed = statuses[module.id]

                if module.managedDocker != nil {
                    let runtime = await DockerModuleService.shared.status(module: module)
                    self.managedModuleRuntimes[module.id] = runtime
                }
                self.managedModuleLogs[module.id] = log

                switch refreshed?.state {
                case .upToDate:
                    self.presentModuleNotice("\(module.title) 已更新至最新版本", kind: .success)
                case .updateAvailable:
                    self.presentModuleNotice("\(module.title) 更新已执行，但仍有新版本待拉取", kind: .info)
                case .failure:
                    self.presentModuleNotice("\(module.title) 更新执行后重新检查失败", kind: .failure)
                default:
                    self.presentModuleNotice("\(module.title) 更新步骤已执行", kind: .success)
                }
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

    func openModuleReleasePage(_ module: OmniModuleDefinition) {
        guard let def = module.updateDefinition else { return }
        let urlString = moduleUpdateStatuses[module.id]?.releaseURL ?? def.releasePageURL
        guard let url = URL(string: urlString) else {
            presentModuleNotice("未找到 \(module.title) 的更新页面", kind: .failure)
            return
        }
        if NSWorkspace.shared.open(url) {
            presentModuleNotice("已打开 \(module.title) 更新页面", kind: .success)
        } else {
            presentModuleNotice("打开 \(module.title) 更新页面失败", kind: .failure)
        }
    }

    func setModuleAsDefaultGateway(_ module: OmniModuleDefinition) {
        guard module.id == OmniModuleRegistry.omniRoute.id else { return }
        settingsService.update { $0.gatewaySource = .omniroute }
        presentModuleNotice("已将 OmniRoute 设为默认网关", kind: .success)
    }

    // MARK: - Module launching

    func openModule(_ module: OmniModuleDefinition) {
        let now = Date()
        if let last = lastModuleOpenAt[module.id], now.timeIntervalSince(last) < 0.8 { return }
        lastModuleOpenAt[module.id] = now

        if moduleLauncher?(module) == true {
            presentModuleNotice("已打开 \(module.title) 窗口", kind: .success)
            return
        }

        if OmniModuleRegistry.module(id: module.id) != nil {
            presentModuleNotice("\(module.title) 窗口未就绪，请稍后重试", kind: .failure)
            return
        }

        switch module.launchStyle {
        case .webApp(let urlString, _, _):
            guard let url = URL(string: urlString) else {
                presentModuleNotice("\(module.title) 地址无效", kind: .failure)
                return
            }
            if NSWorkspace.shared.open(url) {
                presentModuleNotice("已在浏览器打开 \(module.title)", kind: .success)
            } else {
                presentModuleNotice("打开 \(module.title) 失败", kind: .failure)
            }
        }
    }

    func openSettings() {
        guard let presenter = settingsPresenter else {
            presentModuleNotice("偏好设置窗口当前不可用", kind: .failure)
            return
        }
        presenter()
        presentModuleNotice("已打开偏好设置", kind: .success)
    }

    // MARK: - Antigravity workflow

    func prepareAntigravityRunner() {
        Task { [weak self] in
            guard let self else { return }
            self.antigravityIsRunningWorkflow = true
            defer { self.antigravityIsRunningWorkflow = false }
            _ = await self.ensureAntigravityRunner()
        }
    }

    func runAntigravityDiagnosisOnly() {
        Task { [weak self] in await self?.runAntigravityWorkflow(autoFix: false) }
    }

    func runAntigravityDiagnosisAndAutoRepair() {
        Task { [weak self] in await self?.runAntigravityWorkflow(autoFix: true) }
    }

    func clearAntigravityLogs() {
        antigravityDiagnosisLog = ""
        antigravityAutoFixLog = ""
    }

    // MARK: - Constants

    /// Maximum number of AI-generated repair commands to execute.
    private static let maxAutoFixCommands = 10
    /// Maximum wait time for the Antigravity runner API (diagnosis can take up to 20 min).
    private static let antigravityRunnerTimeoutSeconds: TimeInterval = 20 * 60
    /// Number of 1-second poll attempts after launching the Antigravity runner.
    private static let startupPollAttempts = 12
    private static let startupPollIntervalNanoseconds: UInt64 = 1_000_000_000
    /// PIDs that must never be targeted by the AI auto-fix kill commands.
    private static let antigravityDevLogPath = "/tmp/omni-antigravity-dev.log"
    /// System process PIDs that are off-limits to AI-generated kill commands.
    private static let protectedPIDs: Set<Int> = [0, 1]
    /// npm script used to start the Antigravity dev server.
    private static let antigravityStartScript = "dev"
    /// Vite CLI flags passed to the dev server to bind to localhost only.
    private static let antigravityServerHostFlag = "--host 127.0.0.1"
    private static let antigravityServerStrictPortFlag = "--strictPort"

    func presentModuleNotice(_ message: String, kind: ModuleActionNotice.Kind = .info) {
        noticeDismissTask?.cancel()
        moduleActionNotice = ModuleActionNotice(message: message, kind: kind)
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.moduleActionNotice = nil
        }
    }

    // MARK: - URL helper

    func baseURL(for module: OmniModuleDefinition) -> String {
        let s = settingsService.settings
        switch module.id {
        case OmniModuleRegistry.siftly.id:      return s.siftlyBaseURL
        case OmniModuleRegistry.omniRoute.id:   return s.omniRouteDashboardURL
        case OmniModuleRegistry.antigravity.id: return s.antigravityBaseURL
        default:
            switch module.launchStyle {
            case .webApp(let url, _, _): return url
            }
        }
    }

    // MARK: - Antigravity internals

    private func runAntigravityWorkflow(autoFix: Bool) async {
        guard !antigravityIsRunningWorkflow else { return }
        let s = settingsService.settings
        let email = s.antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            presentModuleNotice("请先填写 Google 邮箱", kind: .failure)
            return
        }

        antigravityIsRunningWorkflow = true
        defer { antigravityIsRunningWorkflow = false }
        antigravityDiagnosisLog = ""
        antigravityAutoFixLog = ""

        presentModuleNotice("正在检查 Antigravity 执行器…")
        guard await ensureAntigravityRunner() else {
            presentModuleNotice("Antigravity 执行器不可用", kind: .failure)
            return
        }

        presentModuleNotice("正在执行一键诊断…")
        let projectId = s.antigravityProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagResult: AntigravityRunResponse

        do {
            diagResult = try await invokeAntigravityRunner(mode: "diag", email: email, projectId: projectId)
        } catch {
            antigravityDiagnosisLog = "诊断请求失败：\(error.localizedDescription)"
            presentModuleNotice("诊断失败：\(error.localizedDescription)", kind: .failure)
            return
        }

        let diagText = diagResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        antigravityDiagnosisLog = diagText.isEmpty ? "(诊断无输出)" : diagText
        antigravityRunnerStatus = diagResult.ok ? "诊断完成" : "诊断返回异常"

        let snapshot = settingsService.sharedAISnapshot
        guard autoFix && s.antigravityAutoFixEnabled else {
            presentModuleNotice(diagResult.ok ? "诊断完成" : "诊断完成（存在异常）",
                                kind: diagResult.ok ? .success : .failure)
            return
        }

        guard snapshot.isConfigured else {
            antigravityAutoFixLog = "未配置统一 AI 网关，无法执行 AI 自动修复。"
            presentModuleNotice("未配置统一 AI，无法自动修复", kind: .failure)
            return
        }

        presentModuleNotice("正在生成 AI 修复计划并自动执行…")
        do {
            let log = try await runAntigravityAutoFix(
                with: antigravityDiagnosisLog,
                snapshot: snapshot,
                settings: s
            )
            antigravityAutoFixLog = log
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
        guard await startAntigravityRunner() else {
            antigravityRunnerStatus = "启动命令执行失败"
            return false
        }
        for _ in 0..<Self.startupPollAttempts {
            try? await Task.sleep(nanoseconds: Self.startupPollIntervalNanoseconds)
            if await probeAntigravityRunner() {
                antigravityRunnerStatus = "已自动启动并在线"
                return true
            }
        }
        antigravityRunnerStatus = "启动后仍未连通，请检查项目路径和端口"
        return false
    }

    private func probeAntigravityRunner() async -> Bool {
        let base = settingsService.settings.antigravityBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/runner/prefill"))
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            return false
        }
    }

    private func startAntigravityRunner() async -> Bool {
        let s = settingsService.settings
        let rawPath = s.antigravityInstallPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return false }
        let escapedPath = "'\(rawPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        let port = URL(string: s.antigravityBaseURL)?.port ?? 4173
        let command = "cd \(escapedPath) && OMNI_EMBEDDED=1 nohup npm run \(Self.antigravityStartScript) -- \(Self.antigravityServerHostFlag) --port \(port) \(Self.antigravityServerStrictPortFlag) >\(Self.antigravityDevLogPath) 2>&1 < /dev/null &!"
        do {
            let result = try await runShell(command, timeout: 20)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func invokeAntigravityRunner(mode: String, email: String, projectId: String) async throws -> AntigravityRunResponse {
        let base = settingsService.settings.antigravityBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else {
            throw NSError(domain: "Antigravity", code: -1, userInfo: [NSLocalizedDescriptionKey: "模块地址无效"])
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/runner/run"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.antigravityRunnerTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AntigravityRunPayload(mode: mode, email: email, projectId: projectId))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Antigravity", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效的模块响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Antigravity", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "HTTP \(http.statusCode)" : body])
        }
        do {
            return try JSONDecoder().decode(AntigravityRunResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Antigravity", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "模块返回数据无法解析" : body])
        }
    }

    private func runAntigravityAutoFix(
        with diagnosis: String,
        snapshot: SharedAISettingsSnapshot,
        settings: AppSettings
    ) async throws -> String {
        let systemPrompt = """
        你是 macOS 本地 Antigravity 故障修复助手。你会收到诊断日志，请返回最小修复命令集合。
        你必须仅输出 JSON，不要使用 Markdown。
        JSON 格式：
        {"summary":"一句话结论","commands":[{"cmd":"单行bash命令","reason":"简短原因"}]}

        约束：
        1. 只允许以下命令类型：gcloud、lsof、ps、pkill、kill -9、rm -rf（仅限 Antigravity Cache/CachedData 路径）、open URL。
        2. 禁止 sudo、禁止删除非 Antigravity 路径、禁止安装未知软件、禁止修改系统关键目录。
        3. 如果无需修复，commands 返回空数组。
        """

        let aiRaw = try await APIService.shared.completeText(
            endpoint: snapshot.normalizedEndpoint,
            apiKey: snapshot.normalizedApiKey,
            model: snapshot.normalizedModel,
            systemPrompt: systemPrompt,
            userPrompt: "请基于以下诊断日志生成修复计划：\n\n\(diagnosis)"
        )

        let plan = try decodeAIFixPlan(from: aiRaw)
        var lines: [String] = ["AI 修复总结：\(plan.summary)", ""]
        var executed = 0

        for (idx, item) in plan.commands.prefix(Self.maxAutoFixCommands).enumerated() {
            let cmd = item.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { continue }
            lines.append("[\(idx + 1)] \(cmd)")
            if let reason = item.reason, !reason.isEmpty { lines.append("原因：\(reason)") }

            guard isSafeRepairCommand(cmd) else {
                lines.append("状态：已跳过（命令不在安全白名单）")
                lines.append("")
                continue
            }

            do {
                let timeout: TimeInterval = cmd.contains("gcloud auth") ? 180 : 60
                let result = try await runShell(cmd, timeout: timeout)
                let output = [result.stdout, result.stderr]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                lines.append("状态：\(result.exitCode == 0 ? "成功" : "失败(\(result.exitCode))")")
                if !output.isEmpty { lines.append(output) }
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

        let email = settings.antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = settings.antigravityProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let verify = try await invokeAntigravityRunner(mode: "diag", email: email, projectId: projectId)
            lines.append(verify.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(复检无输出)")
        } catch {
            lines.append("复检失败：\(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    private func decodeAIFixPlan(from text: String) throws -> AntigravityAIFixPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plan = try? JSONDecoder().decode(AntigravityAIFixPlan.self, from: Data(trimmed.utf8)) {
            return plan
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              let data = String(trimmed[start...end]).data(using: .utf8),
              let plan = try? JSONDecoder().decode(AntigravityAIFixPlan.self, from: data)
        else {
            throw NSError(domain: "Antigravity", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "AI 返回格式无法解析，请重试"])
        }
        return plan
    }

    private func isSafeRepairCommand(_ command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return false }

        let blocked = ["sudo ", "rm -rf /", "mkfs", "diskutil erase", "shutdown", "reboot",
                       "chmod -R 777 /", "chown -R /", "curl | sh", "wget | sh", ">/etc", "> /etc"]
        if blocked.contains(where: { cmd.localizedCaseInsensitiveContains($0) }) { return false }

        if cmd.hasPrefix("gcloud ") { return true }
        if cmd.hasPrefix("pkill -f -i antigravity") { return true }
        if cmd.hasPrefix("open http://") || cmd.hasPrefix("open https://") { return true }
        if cmd.hasPrefix("kill -9 ") {
            let pids = cmd.replacingOccurrences(of: "kill -9 ", with: "").split(separator: " ").map(String.init)
            // Require all targets to be numeric PIDs that are not protected system processes
            return !pids.isEmpty && pids.allSatisfy { str in
                guard let pid = Int(str) else { return false }
                return !Self.protectedPIDs.contains(pid)
            }
        }
        if cmd.hasPrefix("rm -rf ") {
            return cmd.contains("/Antigravity/Cache") || cmd.contains("/Antigravity/CachedData")
        }
        return false
    }

    // MARK: - Shell runner

    private struct ShellResult { let stdout: String; let stderr: String; let exitCode: Int32 }
    private final class ShellFinishBox { let lock = NSLock(); var finished = false }

    private func runShell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let box = ShellFinishBox()
            let process = Process()
            let out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = out
            process.standardError = err

            let finish: (Result<ShellResult, Error>) -> Void = { result in
                box.lock.lock(); defer { box.lock.unlock() }
                guard !box.finished else { return }
                box.finished = true
                switch result {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            let timer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                finish(.failure(NSError(domain: "Shell", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "命令执行超时：\(command)"])))
            }

            process.terminationHandler = { proc in
                timer.cancel()
                finish(.success(ShellResult(
                    stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                    stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )))
            }
            do {
                try process.run()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                timer.cancel()
                finish(.failure(error))
            }
        }
    }

    // MARK: - Task management

    private func registerModuleTask(_ task: Task<Void, Never>, for key: String) {
        moduleTasks[key]?.cancel()
        moduleTasks[key] = task
    }

    private func cancelModuleTask(key: String) {
        moduleTasks[key]?.cancel()
        moduleTasks[key] = nil
    }

    // MARK: - Private model types

    private struct AntigravityRunPayload: Encodable {
        let mode: String; let email: String; let projectId: String
    }
    private struct AntigravityRunResponse: Decodable {
        let ok: Bool; let output: String?; let error: String?
        let exitCode: Int?; let timedOut: Bool?
    }
    private struct AntigravityAIFixPlan: Decodable {
        struct Command: Decodable { let cmd: String; let reason: String? }
        let summary: String; let commands: [Command]
    }
}

// MARK: - LegacyAppStateBridge

/// Bridges the new `SettingsService`-based architecture to the existing
/// `OmniIntegrationService.sync(_:from:)` API which still expects `AppState`.
///
/// Remove once `OmniIntegrationService` is updated to accept a snapshot directly.
@MainActor
private final class LegacyAppStateBridge: AppState {
    init(snapshot: SharedAISettingsSnapshot, settings: AppSettings) {
        super.init()
        self.gatewaySource = snapshot.source
        self.customAPIEndpoint = snapshot.endpoint
        self.customAPIKey = snapshot.normalizedApiKey
        self.customAPISelectedModel = snapshot.model
        self.omniRouteAPIURL = snapshot.source == .omniroute ? snapshot.endpoint : settings.omniRouteAPIURL
        self.omniRouteDashboardURL = snapshot.dashboardURL ?? settings.omniRouteDashboardURL
        self.omniRoutePreferredModel = snapshot.model
        self.siftlyBaseURL = settings.siftlyBaseURL
        self.antigravityBaseURL = settings.antigravityBaseURL
        self.antigravityInstallPath = settings.antigravityInstallPath
        self.antigravityAutoFixEnabled = settings.antigravityAutoFixEnabled
    }
}
