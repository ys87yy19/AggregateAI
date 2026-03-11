import SwiftUI
import Carbon.HIToolbox
import Combine

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    private static let sharedAIKeychainService = "com.omni.app.shared-ai"
    private static let sharedAIKeychainAccount = "gateway-api-key"

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
    @Published var apiEndpoint: String = "http://127.0.0.1:8317"
    @Published var apiKey: String = ""
    @Published var apiSelectedModel: String = ""
    @Published var apiSystemPrompt: String = APIService.defaultSystemPrompt
    @Published var apiSavePath: String = ""
    @Published var apiAvailableModels: [String] = []
    @Published var siftlyBaseURL: String = "http://127.0.0.1:3000"
    @Published var siftlyAutoSyncEnabled: Bool = true
    @Published var moduleActionNotice: ModuleActionNotice?
    @Published var moduleSyncStatuses: [String: ModuleSyncStatus] = [
        OmniModuleRegistry.siftly.id: .idle
    ]
    @Published var isAggregating: Bool = false
    @Published var showAggregationResult: Bool = false
    @Published var aggregationResult: String = ""
    @Published var aggregationError: String? = nil

    weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var integrationSyncTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    private var moduleLauncher: ((OmniModuleDefinition) -> Bool)?
    private var settingsPresenter: (() -> Void)?

    init() {
        loadFromDefaults()
        setupAutoSave()
        setupModuleAutoSync()
    }

    // MARK: - Load saved settings

    private func loadFromDefaults() {
        let d = UserDefaults.standard
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
        apiEndpoint = d.string(forKey: SettingsKeys.apiEndpoint) ?? "http://127.0.0.1:8317"
        apiSelectedModel = d.string(forKey: SettingsKeys.apiSelectedModel) ?? ""
        apiSystemPrompt = d.string(forKey: SettingsKeys.apiSystemPrompt) ?? APIService.defaultSystemPrompt
        apiSavePath = d.string(forKey: SettingsKeys.apiSavePath) ?? ""
        siftlyBaseURL = d.string(forKey: SettingsKeys.siftlyBaseURL) ?? "http://127.0.0.1:3000"
        siftlyAutoSyncEnabled = d.object(forKey: SettingsKeys.siftlyAutoSyncEnabled) as? Bool ?? true

        do {
            apiKey = try KeychainService.shared.string(
                forService: Self.sharedAIKeychainService,
                account: Self.sharedAIKeychainAccount
            ) ?? ""
        } catch {
            apiKey = ""
        }

        if apiKey.isEmpty, let legacyKey = d.string(forKey: SettingsKeys.apiKey), !legacyKey.isEmpty {
            apiKey = legacyKey
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
        let d = UserDefaults.standard

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
        $apiEndpoint.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiEndpoint) }.store(in: &cancellables)
        $apiKey.dropFirst().sink {
            try? KeychainService.shared.setString(
                $0,
                forService: Self.sharedAIKeychainService,
                account: Self.sharedAIKeychainAccount
            )
            d.removeObject(forKey: SettingsKeys.apiKey)
        }.store(in: &cancellables)
        $apiSelectedModel.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSelectedModel) }.store(in: &cancellables)
        $apiSystemPrompt.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSystemPrompt) }.store(in: &cancellables)
        $apiSavePath.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSavePath) }.store(in: &cancellables)
        $siftlyBaseURL.dropFirst().sink { d.set($0, forKey: SettingsKeys.siftlyBaseURL) }.store(in: &cancellables)
        $siftlyAutoSyncEnabled.dropFirst().sink { d.set($0, forKey: SettingsKeys.siftlyAutoSyncEnabled) }.store(in: &cancellables)
    }

    private func setupModuleAutoSync() {
        Publishers.CombineLatest4(
            $apiEndpoint.dropFirst(),
            $apiKey.dropFirst(),
            $apiSelectedModel.dropFirst(),
            $siftlyBaseURL.dropFirst()
        )
        .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            guard let self, self.siftlyAutoSyncEnabled else { return }
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
        integrationSyncTask?.cancel()
        moduleSyncStatuses[OmniModuleRegistry.siftly.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步统一 AI 配置…",
            updatedAt: Date()
        )

        integrationSyncTask = Task { [weak self] in
            guard let self else { return }
            let statuses = await OmniIntegrationService.shared.syncAll(from: self)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses.merge(statuses) { _, new in new }
        }
    }

    var sharedAISettingsSnapshot: SharedAISettingsSnapshot {
        SharedAISettingsSnapshot(
            endpoint: apiEndpoint,
            apiKey: apiKey,
            model: apiSelectedModel
        )
    }

    func syncModule(_ module: OmniModuleDefinition) {
        integrationSyncTask?.cancel()
        presentModuleNotice("正在同步 \(module.title)…")
        moduleSyncStatuses[module.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在同步…",
            updatedAt: Date()
        )

        integrationSyncTask = Task { [weak self] in
            guard let self else { return }
            let status = await OmniIntegrationService.shared.sync(module, from: self)
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses[module.id] = status
        }
    }

    func probeModule(_ module: OmniModuleDefinition) {
        integrationSyncTask?.cancel()
        presentModuleNotice("正在检查 \(module.title) 连接…")
        moduleSyncStatuses[module.id] = ModuleSyncStatus(
            state: .syncing,
            message: "正在检查连接…",
            updatedAt: Date()
        )

        integrationSyncTask = Task { [weak self] in
            guard let self else { return }
            let status = await OmniIntegrationService.shared.probe(
                module,
                baseURLOverride: module.id == OmniModuleRegistry.siftly.id ? self.siftlyBaseURL : nil
            )
            guard !Task.isCancelled else { return }
            self.moduleSyncStatuses[module.id] = status
        }
    }

    func bootstrapIntegrationsIfNeeded() {
        if siftlyAutoSyncEnabled,
           moduleSyncStatuses[OmniModuleRegistry.siftly.id]?.state == .idle,
           !apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !apiSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleModuleSync()
        }
    }

    func baseURL(for module: OmniModuleDefinition) -> String {
        switch module.id {
        case OmniModuleRegistry.siftly.id:
            return siftlyBaseURL
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
        if moduleLauncher?(module) == true {
            presentModuleNotice("已打开 \(module.title) 窗口", kind: .success)
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
        modules.filter { appState.moduleSyncStatuses[$0.id]?.state == .success }.count
    }

    private var issueCount: Int {
        modules.filter { appState.moduleSyncStatuses[$0.id]?.state == .failure }.count
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
                        title: "待处理",
                        value: "\(issueCount)",
                        caption: "需要检查模块连接",
                        color: .orange
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
                    appState.probeModule(module)
                }
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
                ModuleStatusBadge(status: status)
            }

            ModuleInfoRow(label: "模块地址", value: appState.baseURL(for: module))
            ModuleInfoRow(label: "同步状态", value: status.message)

            if let updatedAt = status.updatedAt {
                ModuleInfoRow(
                    label: "最近更新",
                    value: updatedAt.formatted(date: .omitted, time: .shortened)
                )
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
