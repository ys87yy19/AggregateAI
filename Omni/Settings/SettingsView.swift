import SwiftUI
import Carbon.HIToolbox

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab(appState: appState)
                .tabItem { Label("通用", systemImage: "gear") }

            NotificationSettingsTab(appState: appState)
                .tabItem { Label("通知", systemImage: "bell") }

            ClipboardSettingsTab(appState: appState)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }

            ObsidianSettingsTab(appState: appState)
                .tabItem { Label("Obsidian", systemImage: "tray.and.arrow.down") }

            APISettingsTab(appState: appState)
                .tabItem { Label("统一 AI", systemImage: "network") }

            IntegrationsSettingsTab(appState: appState)
                .tabItem { Label("模块", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 560)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("外观") {
                Picker("默认主题", selection: $appState.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("默认布局", selection: $appState.layoutMode) {
                    ForEach(LayoutMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("全局快捷键") {
                HStack {
                    Text("切换窗口:")
                    Spacer()
                    HotkeyRecorderView(
                        keyCode: $appState.hotkeyKeyCode,
                        modifiers: $appState.hotkeyModifiers
                    )
                    .frame(width: 200, height: 28)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notification Settings

struct NotificationSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("AI 回复通知") {
                Toggle("启用通知", isOn: $appState.notificationsEnabled)
                    .onChange(of: appState.notificationsEnabled) { enabled in
                        if enabled {
                            NotificationService.shared.requestPermission()
                        }
                    }

                Toggle("仅在窗口隐藏时通知", isOn: $appState.notifyOnlyWhenHidden)
                    .disabled(!appState.notificationsEnabled)
            }

            Section {
                Text("当 AI 完成回复时，会通过 macOS 通知提醒你。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard Settings

struct ClipboardSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("剪贴板监听") {
                Toggle("启用剪贴板监听", isOn: $appState.clipboardMonitorEnabled)
            }

            Section {
                Text("开启后，复制的文本会自动填入输入框。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Obsidian Settings

struct ObsidianSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Obsidian Vault") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault 路径:")
                            .font(.body)
                        if appState.obsidianVaultPath.isEmpty {
                            Text("未设置")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(appState.obsidianVaultPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }

                HStack {
                    Button("选择文件夹...") {
                        ObsidianService.shared.chooseVaultFolder(appState: appState)
                    }

                    if !appState.obsidianVaultPath.isEmpty {
                        Button("清除") {
                            appState.obsidianVaultPath = ""
                            OmniSettingsStore.shared.removeObject(forKey: SettingsKeys.obsidianVaultBookmark)
                        }
                        .foregroundColor(.red)
                    }
                }
            }

            Section {
                Text("保存的笔记会存放在 vault/Omni/ 子目录中，格式为 Markdown。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - API Settings

struct APISettingsTab: View {
    @ObservedObject var appState: AppState
    @State private var isFetchingModels = false
    @State private var fetchError: String? = nil
    @State private var showPromptEditor = false
    @State private var isTesting = false
    @State private var testProgress: Int = 0
    @State private var testTotal: Int = 0
    @State private var speedResults: [APIService.SpeedTestResult] = []

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                appState.gatewaySource == .custom
                    ? appState.customAPISelectedModel
                    : appState.omniRoutePreferredModel
            },
            set: { newValue in
                if appState.gatewaySource == .custom {
                    appState.customAPISelectedModel = newValue
                } else {
                    appState.omniRoutePreferredModel = newValue
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("统一 AI 网关") {
                Picker("Gateway Source", selection: $appState.gatewaySource) {
                    ForEach(GatewaySource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if appState.gatewaySource == .custom {
                    HStack {
                        Text("API 地址:")
                        TextField("http://127.0.0.1:8317", text: $appState.customAPIEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("API Key:")
                        SecureField("可选", text: $appState.customAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    HStack {
                        Text("Dashboard:")
                        TextField("http://127.0.0.1:20128", text: $appState.omniRouteDashboardURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("API 地址:")
                        TextField("http://127.0.0.1:20129", text: $appState.omniRouteAPIURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Endpoint Key:")
                        SecureField("在 OmniRoute Dashboard 中创建", text: $appState.omniRouteEndpointKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                ModuleInfoRow(label: "当前生效", value: appState.apiEndpoint.isEmpty ? "未配置" : appState.apiEndpoint)
                ModuleInfoRow(label: "当前模型", value: selectedModelBinding.wrappedValue.isEmpty ? "未选择" : selectedModelBinding.wrappedValue)
                ModuleInfoRow(label: "密钥状态", value: appState.apiKey.isEmpty ? "未配置" : "已保存到钥匙串")

                Text("Omni 会把当前来源解析后的地址、模型和 API Key 作为统一网关配置，供聚合能力和已接入模块复用。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("所有密钥都会保存在 macOS 钥匙串，不再落到明文 UserDefaults。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("模型选择") {
                HStack {
                    Button("获取模型列表") {
                        fetchModels()
                    }
                    .disabled(isFetchingModels || appState.apiEndpoint.isEmpty)

                    if !appState.apiAvailableModels.isEmpty {
                        Button("一键测速") {
                            Task { await runSpeedTest() }
                        }
                        .disabled(isTesting)
                    }

                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(testProgress)/\(testTotal)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !appState.apiAvailableModels.isEmpty {
                    Picker("模型", selection: selectedModelBinding) {
                        Text("请选择...").tag("")
                        ForEach(appState.apiAvailableModels, id: \.self) { model in
                            HStack {
                                Text(model)
                                if let result = speedResults.first(where: { $0.model == model }) {
                                    Spacer()
                                    if let err = result.error {
                                        Text(err).foregroundColor(.red)
                                    } else {
                                        Text("\(result.latencyMs)ms")
                                            .foregroundColor(speedColor(ms: result.latencyMs))
                                    }
                                }
                            }.tag(model)
                        }
                    }
                } else if !selectedModelBinding.wrappedValue.isEmpty {
                    Text("当前模型: \(selectedModelBinding.wrappedValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("请先点击「获取模型列表」")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let error = fetchError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Speed test results
                if !speedResults.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("测速结果")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("（首 Token 延迟 · 点击选用）")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        ForEach(sortedResults, id: \.model) { result in
                            Button {
                                selectedModelBinding.wrappedValue = result.model
                            } label: {
                                HStack(spacing: 6) {
                                    if let rank = rankOf(result) {
                                        Text(rankEmoji(rank))
                                            .font(.system(size: 11))
                                    }

                                    Text(result.model)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    if let err = result.error {
                                        Text(err)
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    } else {
                                        Text("\(result.latencyMs) ms")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(speedColor(ms: result.latencyMs))
                                    }

                                    if selectedModelBinding.wrappedValue == result.model {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                            .font(.system(size: 10))
                                    }
                                }
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(
                                    selectedModelBinding.wrappedValue == result.model
                                        ? Color.accentColor.opacity(0.1)
                                        : Color.clear
                                )
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Section("聚合提示词") {
                Button("编辑系统提示词...") {
                    showPromptEditor = true
                }

                if appState.apiSystemPrompt != APIService.defaultSystemPrompt {
                    Button("恢复默认") {
                        appState.apiSystemPrompt = APIService.defaultSystemPrompt
                    }
                    .foregroundColor(.orange)
                }

                Text("系统提示词用于指导 AI 如何综合分析多个 AI 的回答。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("保存路径") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("聚合笔记保存目录:")
                            .font(.body)
                        if appState.apiSavePath.isEmpty {
                            Text("未设置（将弹出文件选择器）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(appState.apiSavePath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }

                HStack {
                    Button("选择文件夹...") {
                        chooseSaveFolder()
                    }

                    if !appState.apiSavePath.isEmpty {
                        Button("清除") {
                            appState.apiSavePath = ""
                            OmniSettingsStore.shared.removeObject(forKey: SettingsKeys.apiSaveBookmark)
                        }
                        .foregroundColor(.red)
                    }
                }

                Text("设置后，聚合结果会直接保存到该目录，无需每次手动选择。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPromptEditor) {
            SystemPromptEditorView(
                prompt: $appState.apiSystemPrompt,
                isPresented: $showPromptEditor
            )
        }
    }

    // MARK: - Speed Test

    private var sortedResults: [APIService.SpeedTestResult] {
        speedResults.sorted { a, b in
            if a.error != nil && b.error == nil { return false }
            if a.error == nil && b.error != nil { return true }
            return a.latencyMs < b.latencyMs
        }
    }

    private func rankOf(_ result: APIService.SpeedTestResult) -> Int? {
        guard result.error == nil else { return nil }
        let successResults = sortedResults.filter { $0.error == nil }
        return successResults.firstIndex(where: { $0.model == result.model }).map { $0 + 1 }
    }

    private func rankEmoji(_ rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return "　"
        }
    }

    private func speedColor(ms: Int) -> Color {
        if ms < 1000 { return .green }
        if ms < 3000 { return .orange }
        return .red
    }

    private func runSpeedTest() async {
        let models = appState.apiAvailableModels
        guard !models.isEmpty else { return }

        isTesting = true
        testProgress = 0
        testTotal = models.count
        speedResults = []

        await withTaskGroup(of: APIService.SpeedTestResult.self) { group in
            for model in models {
                group.addTask {
                    await APIService.shared.testModelSpeed(
                        endpoint: self.appState.apiEndpoint,
                        apiKey: self.appState.apiKey,
                        model: model
                    )
                }
            }

            for await result in group {
                speedResults.append(result)
                testProgress += 1
            }
        }

        isTesting = false
    }

    // MARK: - Fetch Models

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil

        Task {
            do {
                let models = try await APIService.shared.fetchModels(
                    endpoint: appState.apiEndpoint,
                    apiKey: appState.apiKey
                )
                appState.apiAvailableModels = models
                if selectedModelBinding.wrappedValue.isEmpty, let first = models.first {
                    selectedModelBinding.wrappedValue = first
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择聚合笔记的保存目录"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                OmniSettingsStore.shared.set(bookmarkData, forKey: SettingsKeys.apiSaveBookmark)
                appState.apiSavePath = url.path
            }
        }
    }
}

// MARK: - Integrations Settings

struct IntegrationsSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("模块宿主") {
                Text("Omni 现在作为统一 AI 配置中心。后续接入的新模块，只要在这里登记，就可以直接复用同一套网关地址、模型和 API Key。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("OmniRoute（受管 Docker 模块）") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("OmniRoute", systemImage: OmniModuleRegistry.omniRoute.icon)
                            .font(.headline)
                        Spacer()
                        ManagedRuntimeBadge(runtime: appState.managedModuleRuntimes[OmniModuleRegistry.omniRoute.id] ?? ManagedDockerModuleRuntime.idle())
                    }

                    Text(OmniModuleRegistry.omniRoute.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ModuleInfoRow(label: "Dashboard", value: appState.omniRouteDashboardURL)
                ModuleInfoRow(label: "API", value: appState.omniRouteAPIURL)

                if let runtime = appState.managedModuleRuntimes[OmniModuleRegistry.omniRoute.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runtime.details)
                            .font(.caption)
                            .foregroundColor(managedRuntimeColor(runtime))

                        if let updatedAt = runtime.updatedAt as Date? {
                            Text("最近更新时间: \(updatedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let error = runtime.lastError, !error.isEmpty {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }

                HStack {
                    Button("刷新状态") {
                        appState.refreshManagedModuleStatus(OmniModuleRegistry.omniRoute)
                    }
                    Button("启动") {
                        appState.startManagedModule(OmniModuleRegistry.omniRoute)
                    }
                    Button("停止") {
                        appState.stopManagedModule(OmniModuleRegistry.omniRoute)
                    }
                    Button("重启") {
                        appState.restartManagedModule(OmniModuleRegistry.omniRoute)
                    }
                }

                HStack {
                    Button("查看日志") {
                        appState.fetchManagedModuleLogs(OmniModuleRegistry.omniRoute)
                    }
                    Button("健康检查") {
                        appState.probeManagedModule(OmniModuleRegistry.omniRoute)
                    }
                    Button("打开 Dashboard") {
                        (NSApp.delegate as? AppDelegate)?.openIntegratedModule(id: OmniModuleRegistry.omniRoute.id)
                    }
                    Button("设为默认网关") {
                        appState.setModuleAsDefaultGateway(OmniModuleRegistry.omniRoute)
                    }
                }

                if let logs = appState.managedModuleLogs[OmniModuleRegistry.omniRoute.id], !logs.isEmpty {
                    Text(logs)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Section("Siftly 集成") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Siftly", systemImage: OmniModuleRegistry.siftly.icon)
                            .font(.headline)
                        Spacer()
                        statusBadge(for: appState.moduleSyncStatuses[OmniModuleRegistry.siftly.id] ?? .idle)
                    }

                    Text(OmniModuleRegistry.siftly.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("模块地址:")
                    TextField("http://127.0.0.1:3000", text: $appState.siftlyBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("统一 AI 配置变更时自动同步到 Siftly", isOn: $appState.siftlyAutoSyncEnabled)

                HStack {
                    Button("立即同步") {
                        appState.syncModule(OmniModuleRegistry.siftly)
                    }

                    Button("测试连接") {
                        appState.probeModule(OmniModuleRegistry.siftly)
                    }

                    Button("打开 Siftly") {
                        (NSApp.delegate as? AppDelegate)?.openIntegratedModule(id: OmniModuleRegistry.siftly.id)
                    }
                }

                if let status = appState.moduleSyncStatuses[OmniModuleRegistry.siftly.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.message)
                            .font(.caption)
                            .foregroundColor(statusColor(status))

                        if let updatedAt = status.updatedAt {
                            Text("最近更新时间: \(updatedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Text("同步时会把统一网关的 OpenAI 兼容地址、模型和 Key 下发到本地 Siftly，让 AI 搜索和 AI 分类复用同一套配置。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private func statusBadge(for status: ModuleSyncStatus) -> some View {
        let title: String
        switch status.state {
        case .idle:
            title = "未同步"
        case .syncing:
            title = "同步中"
        case .success:
            title = "已同步"
        case .failure:
            title = "失败"
        }

        return Text(title)
            .font(.caption)
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: ModuleSyncStatus) -> Color {
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

    private func managedRuntimeColor(_ runtime: ManagedDockerModuleRuntime) -> Color {
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

struct ManagedRuntimeBadge: View {
    let runtime: ManagedDockerModuleRuntime

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
            return "运行中"
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

// MARK: - System Prompt Editor

struct SystemPromptEditorView: View {
    @Binding var prompt: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑聚合系统提示词")
                    .font(.headline)
                Spacer()
            }
            .padding()

            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)

            HStack {
                Button("恢复默认") {
                    prompt = APIService.defaultSystemPrompt
                }

                Spacer()

                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 600, height: 400)
    }
}
