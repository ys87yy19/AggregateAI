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
                .tabItem { Label("API", systemImage: "network") }
        }
        .frame(width: 480, height: 400)
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
                            UserDefaults.standard.removeObject(forKey: SettingsKeys.obsidianVaultBookmark)
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

    var body: some View {
        Form {
            Section("API 配置") {
                HStack {
                    Text("API 地址:")
                    TextField("http://127.0.0.1:8317", text: $appState.apiEndpoint)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("API Key:")
                    SecureField("可选", text: $appState.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("模型选择") {
                HStack {
                    Button("获取模型列表") {
                        fetchModels()
                    }
                    .disabled(isFetchingModels || appState.apiEndpoint.isEmpty)

                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !appState.apiAvailableModels.isEmpty {
                    Picker("模型", selection: $appState.apiSelectedModel) {
                        Text("请选择...").tag("")
                        ForEach(appState.apiAvailableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } else if !appState.apiSelectedModel.isEmpty {
                    Text("当前模型: \(appState.apiSelectedModel)")
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
                            UserDefaults.standard.removeObject(forKey: SettingsKeys.apiSaveBookmark)
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
                if appState.apiSelectedModel.isEmpty, let first = models.first {
                    appState.apiSelectedModel = first
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
                UserDefaults.standard.set(bookmarkData, forKey: SettingsKeys.apiSaveBookmark)
                appState.apiSavePath = url.path
            }
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
