import SwiftUI

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AIProvider = .all
    @Published var layoutMode: LayoutMode = .threeColumn
    @Published var appearanceMode: AppearanceMode = .system
    @Published var isPinned: Bool = false
    @Published var syncQuestion: String = ""
    @Published var userAgentSettings = UserAgentSettings.recommended

    weak var mainWindow: NSWindow?

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

            // Web content area
            if appState.selectedTab == .all {
                MultiColumnView(appState: appState)
            } else {
                SingleWebView(provider: appState.selectedTab)
            }

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
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

// MARK: - Multi Column Layout

struct MultiColumnView: View {
    @ObservedObject var appState: AppState

    private var visibleProviders: [AIProvider] {
        let all = AIProvider.providers
        return Array(all.prefix(appState.layoutMode.columns))
    }

    var body: some View {
        HSplitView {
            ForEach(visibleProviders) { provider in
                WebPanel(provider: provider)
            }
        }
    }
}

struct WebPanel: View {
    let provider: AIProvider

    var body: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Image(systemName: provider.iconName)
                    .foregroundColor(provider.color)
                    .font(.system(size: 11))
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()

                // Reload button
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

            // WebView
            PersistentWebView(provider: provider)
        }
        .frame(minWidth: 280)
    }
}

struct SingleWebView: View {
    let provider: AIProvider

    var body: some View {
        PersistentWebView(provider: provider)
    }
}
