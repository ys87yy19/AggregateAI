import SwiftUI
import Carbon.HIToolbox
import Combine

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
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
    @Published var isAggregating: Bool = false
    @Published var showAggregationResult: Bool = false
    @Published var aggregationResult: String = ""
    @Published var aggregationError: String? = nil

    weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadFromDefaults()
        setupAutoSave()
    }

    // MARK: - Load saved settings

    private func loadFromDefaults() {
        let d = UserDefaults.standard
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
        apiKey = d.string(forKey: SettingsKeys.apiKey) ?? ""
        apiSelectedModel = d.string(forKey: SettingsKeys.apiSelectedModel) ?? ""
        apiSystemPrompt = d.string(forKey: SettingsKeys.apiSystemPrompt) ?? APIService.defaultSystemPrompt
        apiSavePath = d.string(forKey: SettingsKeys.apiSavePath) ?? ""
    }

    // MARK: - Auto-save via Combine (more reliable than didSet)

    private func setupAutoSave() {
        let d = UserDefaults.standard

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
        $apiKey.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiKey) }.store(in: &cancellables)
        $apiSelectedModel.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSelectedModel) }.store(in: &cancellables)
        $apiSystemPrompt.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSystemPrompt) }.store(in: &cancellables)
        $apiSavePath.dropFirst().sink { d.set($0, forKey: SettingsKeys.apiSavePath) }.store(in: &cancellables)
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
        updateWindowLevel()
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
            // Top toolbar
            ToolbarView(appState: appState)

            // Web content area — all webviews always alive, no destroy/recreate
            WebContentArea(appState: appState)

            // Sync question bar
            SyncInputBar(appState: appState)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            appState.applyAppearance()
            WebViewManager.shared.updateUserAgentSettings(appState.userAgentSettings)
            WebViewManager.shared.preloadWebViews()
            WebViewManager.shared.syncThemeForAllWebViews(mode: appState.appearanceMode)
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
            // Tab buttons
            ForEach(AIProvider.allCases) { provider in
                TabButton(
                    title: provider.displayName,
                    icon: provider.iconName,
                    isSelected: appState.selectedTab == provider
                ) {
                    appState.selectedTab = provider
                    if provider == .all {
                        // Keep current layout
                    }
                }
            }

            Spacer()

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // Layout switcher
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

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // AI Aggregation button
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
