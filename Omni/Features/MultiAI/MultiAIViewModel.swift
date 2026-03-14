import Foundation
import Combine
import OSLog

// MARK: - MultiAIViewModel

/// ViewModel for the AI workspace tab.
///
/// Owns:
/// - Provider tab selection and layout mode
/// - The sync-question input string
/// - User-agent settings
/// - Aggregation lifecycle (isAggregating, result, error)
///
/// Reads gateway credentials from `SettingsService`; never touches UserDefaults
/// or Keychain directly.
@MainActor
final class MultiAIViewModel: ObservableObject {

    // MARK: - Published state

    /// The currently selected AI provider tab.
    @Published var selectedTab: AIProvider = .all

    /// Text the user typed in the sync input bar.
    @Published var syncQuestion: String = ""

    /// Number-of-columns layout for the "All" view.
    @Published var layoutMode: LayoutMode = .threeColumn

    /// Per-provider user-agent overrides.
    @Published var userAgentSettings: UserAgentSettings = .recommended

    /// `true` while an aggregation request is in flight.
    @Published private(set) var isAggregating: Bool = false

    /// `true` when the aggregation result sheet should be shown.
    @Published var showAggregationResult: Bool = false

    /// Final aggregated markdown text (empty until aggregation completes).
    @Published private(set) var aggregationResult: String = ""

    /// Set when aggregation fails; `nil` on success.
    @Published private(set) var aggregationError: String? = nil

    // MARK: - Dependencies

    private let settingsService: SettingsService
    private let apiService: APIService
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.omni.app", category: "MultiAIViewModel")

    // MARK: - Init

    init(settingsService: SettingsService, apiService: APIService) {
        self.settingsService = settingsService
        self.apiService = apiService
        bindSettings()
    }

    // MARK: - Settings binding

    private func bindSettings() {
        // Mirror layout mode from settings so it stays in sync with SettingsView
        settingsService.$settings
            .map(\.layoutMode)
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.layoutMode = mode
            }
            .store(in: &cancellables)
    }

    // MARK: - Send sync question

    /// Sends `syncQuestion` to the currently selected provider(s) via JavaScript injection.
    /// Clears the input field after dispatching.
    func sendSyncQuestion() {
        guard !syncQuestion.isEmpty else { return }
        let question = syncQuestion
        let cooldown: TimeInterval

        if selectedTab == .all {
            cooldown = WebViewManager.shared.sendQuestionToAll(question)
        } else {
            cooldown = WebViewManager.shared.sendQuestion(question, to: selectedTab)
        }

        syncQuestion = ""
        logger.debug("Sent question to \(self.selectedTab.displayName), cooldown \(cooldown)s")
    }

    /// Start a new chat in the selected provider(s).
    func startNewChat() {
        if selectedTab == .all {
            WebViewManager.shared.startNewChatForAll()
        } else {
            WebViewManager.shared.startNewChat(for: selectedTab)
        }
    }

    // MARK: - Aggregation

    /// Validates configuration, extracts page content, then streams the aggregated response.
    ///
    /// - Returns: An optional user-facing error message if preconditions fail.
    @discardableResult
    func aggregate() async -> String? {
        let snapshot = settingsService.sharedAISnapshot

        guard !snapshot.normalizedEndpoint.isEmpty else {
            return "未配置 API 地址，请在偏好设置 > API 中设置。"
        }
        guard !snapshot.normalizedModel.isEmpty else {
            return "未选择模型，请在偏好设置 > API 中获取并选择模型。"
        }

        var contents: [(provider: AIProvider, text: String)] = []
        for provider in AIProvider.providers {
            do {
                let text = try await ExportService.shared.extractContent(from: provider)
                if !text.isEmpty {
                    contents.append((provider: provider, text: text))
                }
            } catch {
                logger.warning("Could not extract content from \(provider.displayName): \(error.localizedDescription)")
            }
        }

        guard !contents.isEmpty else {
            return "未能从任何 AI 提取到内容。请先向 AI 提问后再聚合。"
        }

        aggregationError = nil
        isAggregating = true
        showAggregationResult = true

        // Direct-to-NSTextView streaming; no per-token @Published updates
        StreamingTextStore.shared.reset()

        let stream = apiService.aggregate(
            endpoint: snapshot.normalizedEndpoint,
            apiKey: snapshot.normalizedApiKey,
            model: snapshot.normalizedModel,
            contents: contents,
            question: syncQuestion.isEmpty ? nil : syncQuestion,
            systemPrompt: settingsService.settings.apiSystemPrompt
        )

        do {
            for try await chunk in stream {
                StreamingTextStore.shared.append(chunk)
            }
            StreamingTextStore.shared.finish()
        } catch {
            StreamingTextStore.shared.finish()
            aggregationError = error.localizedDescription
            logger.error("Aggregation failed: \(error.localizedDescription)")
        }

        // Single @Published update for save/export
        aggregationResult = StreamingTextStore.shared.getFinalText()
        isAggregating = false
        return nil
    }
}
