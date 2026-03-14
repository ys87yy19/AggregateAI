import SwiftUI

// MARK: - MultiAIView

/// The AI workspace: a tab bar, a grid of persistent WebViews, and a sync input bar.
///
/// This view is controlled entirely by `MultiAIViewModel`; it never reads from
/// `AppState` or `SettingsService` directly.
struct MultiAIView: View {
    @ObservedObject var viewModel: MultiAIViewModel
    @ObservedObject var appState: AppState  // kept for appearance/pin state during transition

    var body: some View {
        VStack(spacing: 0) {
            aiToolbar
            WebContentArea(viewModel: viewModel)
            SyncInputBar(viewModel: viewModel)
        }
    }

    // MARK: - AI Toolbar

    private var aiToolbar: some View {
        HStack(spacing: 0) {
            // Provider tabs
            ForEach(AIProvider.allCases) { provider in
                providerTabButton(provider)
            }

            Spacer()

            // New chat
            Button {
                viewModel.startNewChat()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("新对话")

            toolbarDivider

            // Layout mode picker (only relevant in .all tab)
            ForEach(LayoutMode.allCases, id: \.self) { mode in
                layoutModeButton(mode)
            }

            toolbarDivider

            // Aggregate button
            Button {
                Task { await aggregate() }
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .foregroundColor(viewModel.isAggregating ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isAggregating)
            .help("AI 聚合分析")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $viewModel.showAggregationResult) {
            AggregationResultView(appState: appState)
        }
    }

    // MARK: - Tab button

    private func providerTabButton(_ provider: AIProvider) -> some View {
        Button {
            viewModel.selectedTab = provider
        } label: {
            HStack(spacing: 4) {
                Image(systemName: provider.iconName)
                    .font(.system(size: 12))
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(viewModel.selectedTab == provider
                        ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layout mode button

    private func layoutModeButton(_ mode: LayoutMode) -> some View {
        Button {
            viewModel.layoutMode = mode
            viewModel.selectedTab = .all
        } label: {
            Image(systemName: mode.iconName)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(viewModel.layoutMode == mode && viewModel.selectedTab == .all
                            ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(mode.label)
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 4)
    }

    // MARK: - Aggregation

    @State private var showAggregationAlert = false
    @State private var aggregationAlertMessage = ""

    private func aggregate() async {
        if let errorMessage = await viewModel.aggregate() {
            aggregationAlertMessage = errorMessage
            showAggregationAlert = true
        }
    }
}

// MARK: - WebContentArea

/// Hosts all persistent WebViews. Visibility is controlled by the selected tab
/// and column layout; frames are hidden (not destroyed) to preserve session state.
struct WebContentArea: View {
    @ObservedObject var viewModel: MultiAIViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AIProvider.providers.enumerated()), id: \.element) { index, provider in
                let visible = isVisible(index: index, provider: provider)

                if index > 0 && visible && viewModel.selectedTab == .all {
                    Divider()
                }

                VStack(spacing: 0) {
                    if visible && viewModel.selectedTab == .all {
                        panelHeader(provider)
                        Divider()
                    }
                    PersistentWebView(provider: provider)
                }
                .frame(
                    minWidth: visible && viewModel.selectedTab == .all ? 280 : 0,
                    maxWidth: visible ? .infinity : 0
                )
                .clipped()
                .allowsHitTesting(visible)
            }
        }
    }

    private func panelHeader(_ provider: AIProvider) -> some View {
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
    }

    private func isVisible(index: Int, provider: AIProvider) -> Bool {
        if viewModel.selectedTab == .all {
            return index < viewModel.layoutMode.columns
        }
        return viewModel.selectedTab == provider
    }
}

// MARK: - SyncInputBar

/// The bottom input bar for sending questions to AI providers.
struct SyncInputBar: View {
    @ObservedObject var viewModel: MultiAIViewModel
    @State private var isSending = false

    private var placeholderText: String {
        if viewModel.selectedTab == .all {
            return "Ask all AIs at once..."
        }
        return "Ask \(viewModel.selectedTab.displayName)..."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField(placeholderText, text: $viewModel.syncQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { send() }

            if !viewModel.syncQuestion.isEmpty {
                Button {
                    viewModel.syncQuestion = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(viewModel.syncQuestion.isEmpty ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.syncQuestion.isEmpty || isSending)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private static let sendCooldownDuration: TimeInterval = 1.5

    private func send() {
        guard !viewModel.syncQuestion.isEmpty else { return }
        isSending = true
        viewModel.sendSyncQuestion()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendCooldownDuration) {
            isSending = false
        }
    }
}
