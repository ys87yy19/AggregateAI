import Foundation

struct SharedAISettingsSnapshot {
    private static let siftlyAllowedOpenAIModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5",
        "gpt-5.4-codex",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.1-codex",
        "gpt-5-codex",
    ]

    let endpoint: String
    let apiKey: String
    let model: String

    var normalizedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var siftlyOpenAIBaseURL: String {
        let trimmed = normalizedEndpoint
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }

    var siftlyOpenAIModel: String {
        let trimmed = normalizedModel
        guard !trimmed.isEmpty else { return "gpt-5.4" }
        if Self.siftlyAllowedOpenAIModels.contains(trimmed) {
            return trimmed
        }
        return "gpt-5.4"
    }
}

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

struct OmniModuleDefinition: Identifiable, Equatable {
    enum LaunchStyle: Equatable {
        case webApp(url: String, width: Double, height: Double)
    }

    enum SyncAdapter: Equatable {
        case siftly
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let launchStyle: LaunchStyle
    let syncAdapter: SyncAdapter?
}

enum OmniModuleRegistry {
    static let siftly = OmniModuleDefinition(
        id: "siftly",
        title: "Siftly",
        subtitle: "本地书签知识库",
        icon: "books.vertical.fill",
        launchStyle: .webApp(url: "http://127.0.0.1:3000", width: 1440, height: 920),
        syncAdapter: .siftly
    )

    static let integratedModules: [OmniModuleDefinition] = [
        siftly,
    ]

    static func module(id: String) -> OmniModuleDefinition? {
        integratedModules.first(where: { $0.id == id })
    }
}

@MainActor
final class OmniIntegrationService {
    static let shared = OmniIntegrationService()

    private init() {}

    enum SyncError: LocalizedError {
        case invalidBaseURL
        case incompleteSharedConfig
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "模块地址无效"
            case .incompleteSharedConfig:
                return "统一 AI 配置不完整，请先设置 API 地址和模型"
            case .httpError(let code, let body):
                let message = body.isEmpty ? "HTTP \(code)" : body
                return "同步失败: \(message)"
            case .invalidResponse:
                return "模块返回了无效响应"
            }
        }
    }

    func syncAll(from appState: AppState) async -> [String: ModuleSyncStatus] {
        var statuses: [String: ModuleSyncStatus] = [:]

        for module in OmniModuleRegistry.integratedModules where module.syncAdapter != nil {
            statuses[module.id] = await sync(module, from: appState)
        }

        return statuses
    }

    func sync(_ module: OmniModuleDefinition, from appState: AppState) async -> ModuleSyncStatus {
        let snapshot = appState.sharedAISettingsSnapshot
        guard !snapshot.normalizedEndpoint.isEmpty, !snapshot.normalizedModel.isEmpty else {
            return ModuleSyncStatus(
                state: .failure,
                message: SyncError.incompleteSharedConfig.localizedDescription,
                updatedAt: Date()
            )
        }

        do {
            switch module.syncAdapter {
            case .siftly:
                try await syncSiftly(module: module, snapshot: snapshot, baseURLOverride: appState.siftlyBaseURL)
            case .none:
                return ModuleSyncStatus(
                    state: .success,
                    message: "模块不需要同步",
                    updatedAt: Date()
                )
            }

            return ModuleSyncStatus(
                state: .success,
                message: "已同步统一 AI 配置",
                updatedAt: Date()
            )
        } catch {
            return ModuleSyncStatus(
                state: .failure,
                message: error.localizedDescription,
                updatedAt: Date()
            )
        }
    }

    func probe(_ module: OmniModuleDefinition, baseURLOverride: String? = nil) async -> ModuleSyncStatus {
        do {
            let baseURL = try resolvedBaseURL(for: module, override: baseURLOverride)
            let url = baseURL.appendingPathComponent("api/settings")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw SyncError.httpError(httpResponse.statusCode, "")
            }

            return ModuleSyncStatus(state: .success, message: "模块在线", updatedAt: Date())
        } catch {
            return ModuleSyncStatus(state: .failure, message: error.localizedDescription, updatedAt: Date())
        }
    }

    private func syncSiftly(
        module: OmniModuleDefinition,
        snapshot: SharedAISettingsSnapshot,
        baseURLOverride: String
    ) async throws {
        let baseURL = try resolvedBaseURL(for: module, override: baseURLOverride)

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["provider": "openai"]
        )

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["openaiBaseUrl": snapshot.siftlyOpenAIBaseURL]
        )

        if !snapshot.normalizedApiKey.isEmpty {
            try await postJSON(
                to: baseURL.appendingPathComponent("api/settings"),
                body: ["openaiApiKey": snapshot.normalizedApiKey]
            )
        }

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["openaiModel": snapshot.siftlyOpenAIModel]
        )
    }

    private func resolvedBaseURL(for module: OmniModuleDefinition, override: String?) throws -> URL {
        let candidate = (override?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? override
            : defaultBaseURL(for: module))
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw)
        else {
            throw SyncError.invalidBaseURL
        }
        return url
    }

    private func defaultBaseURL(for module: OmniModuleDefinition) -> String? {
        switch module.launchStyle {
        case .webApp(let url, _, _):
            return url
        }
    }

    private func postJSON(to url: URL, body: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpError(httpResponse.statusCode, bodyText)
        }
    }
}
