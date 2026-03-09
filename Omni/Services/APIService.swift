import Foundation
import OSLog

@MainActor
final class APIService {
    static let shared = APIService()
    private let logger = Logger(subsystem: "com.omni.app", category: "APIService")

    private init() {}

    // MARK: - Default System Prompt

    static let defaultSystemPrompt = """
    你是一位严谨的知识整合专家。你将收到来自多个 AI（Gemini、Grok、ChatGPT）对同一问题的回答。

    请执行以下任务：
    1. **综合分析**：对比各 AI 回答的核心观点，找出共识和分歧
    2. **事实核验**：标注各 AI 一致认同的事实（高可信度）和存在分歧的观点（需进一步验证）
    3. **知识整合**：将所有信息整合为一份结构清晰的知识笔记
    4. **格式要求**：
       - 使用 Markdown 格式
       - 包含摘要、正文、关键要点
       - 在正文中用 > 引用块标注各 AI 的独特见解，注明来源
       - 末尾附上「可信度评估」和「待验证事项」

    请用中文输出。确保输出的笔记可以直接保存到 Obsidian 使用。
    """

    // MARK: - Data Models

    struct ModelsResponse: Decodable {
        let data: [ModelEntry]

        struct ModelEntry: Decodable {
            let id: String
        }
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    struct ChatChunk: Decodable {
        let choices: [Choice]?

        struct Choice: Decodable {
            let delta: Delta?
            let finish_reason: String?

            struct Delta: Decodable {
                let content: String?
            }
        }
    }

    enum APIError: LocalizedError {
        case invalidURL
        case noEndpointConfigured
        case noModelSelected
        case networkError(Error)
        case httpError(Int, String)
        case decodingError(Error)
        case noContent

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "API 地址无效"
            case .noEndpointConfigured:
                return "未配置 API 地址，请在偏好设置 > API 中设置。"
            case .noModelSelected:
                return "未选择模型，请在偏好设置 > API 中获取并选择模型。"
            case .networkError(let error):
                return "网络错误: \(error.localizedDescription)"
            case .httpError(let code, let message):
                return "HTTP 错误 \(code): \(message)"
            case .decodingError(let error):
                return "数据解析错误: \(error.localizedDescription)"
            case .noContent:
                return "未能从任何 AI 提取到有效内容"
            }
        }
    }

    // MARK: - Speed Test

    struct SpeedTestResult {
        let model: String
        let latencyMs: Int      // Time to first token (ms)
        let error: String?      // nil = success
    }

    /// Send a tiny request to measure time-to-first-token for a single model
    func testModelSpeed(endpoint: String, apiKey: String, model: String) async -> SpeedTestResult {
        guard !endpoint.isEmpty else {
            return SpeedTestResult(model: model, latencyMs: 0, error: "未配置 API")
        }

        let urlString = endpoint.hasSuffix("/")
            ? "\(endpoint)v1/chat/completions"
            : "\(endpoint)/v1/chat/completions"

        guard let url = URL(string: urlString) else {
            return SpeedTestResult(model: model, latencyMs: 0, error: "无效 URL")
        }

        let chatRequest = ChatRequest(
            model: model,
            messages: [
                ChatRequest.Message(role: "user", content: "Hi")
            ],
            stream: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONEncoder().encode(chatRequest)
        } catch {
            return SpeedTestResult(model: model, latencyMs: 0, error: "编码错误")
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return SpeedTestResult(model: model, latencyMs: 0, error: "HTTP \(code)")
            }

            // Wait for first data line (time to first token)
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data: ") {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let ms = Int(elapsed * 1000)

                    // Cancel the rest — we only need TTFT
                    return SpeedTestResult(model: model, latencyMs: ms, error: nil)
                }
            }

            // If we got here, no data lines received
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            return SpeedTestResult(model: model, latencyMs: Int(elapsed * 1000), error: nil)
        } catch {
            return SpeedTestResult(model: model, latencyMs: 0, error: "超时")
        }
    }

    // MARK: - Fetch Models

    func fetchModels(endpoint: String, apiKey: String) async throws -> [String] {
        guard !endpoint.isEmpty else { throw APIError.noEndpointConfigured }

        let urlString = endpoint.hasSuffix("/")
            ? "\(endpoint)v1/models"
            : "\(endpoint)/v1/models"

        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "APIService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "无效的 HTTP 响应"])
            )
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(httpResponse.statusCode, body)
        }

        let modelsResponse: ModelsResponse
        do {
            modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }

        return modelsResponse.data.map(\.id).sorted()
    }

    // MARK: - Generate Title

    /// Non-streaming request: ask the model to produce a short title for the aggregated note
    func generateTitle(
        endpoint: String,
        apiKey: String,
        model: String,
        text: String
    ) async throws -> String {
        guard !endpoint.isEmpty else { throw APIError.noEndpointConfigured }
        guard !model.isEmpty else { throw APIError.noModelSelected }

        let urlString = endpoint.hasSuffix("/")
            ? "\(endpoint)v1/chat/completions"
            : "\(endpoint)/v1/chat/completions"

        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        // Use a short excerpt (first 2000 chars) so the title request is fast
        let excerpt = String(text.prefix(2000))

        let chatRequest = ChatRequest(
            model: model,
            messages: [
                ChatRequest.Message(
                    role: "system",
                    content: "你是标题生成器。根据以下笔记内容，生成一个简洁准确的中文标题（不超过30字）。只输出标题本身，不要加引号、书名号、前缀或任何额外文字。"
                ),
                ChatRequest.Message(role: "user", content: excerpt)
            ],
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(chatRequest)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(code, body)
        }

        // Parse non-streaming response
        let parsed = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
        let title = parsed.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return title.isEmpty ? "AI聚合笔记" : title
    }

    struct NonStreamingResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: MessageContent
            struct MessageContent: Decodable {
                let content: String
            }
        }
    }

    // MARK: - Aggregation (Streaming)

    func aggregate(
        endpoint: String,
        apiKey: String,
        model: String,
        contents: [(provider: AIProvider, text: String)],
        question: String?,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performStreaming(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        model: model,
                        contents: contents,
                        question: question,
                        systemPrompt: systemPrompt,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private nonisolated func performStreaming(
        endpoint: String,
        apiKey: String,
        model: String,
        contents: [(provider: AIProvider, text: String)],
        question: String?,
        systemPrompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard !endpoint.isEmpty else { throw APIError.noEndpointConfigured }
        guard !model.isEmpty else { throw APIError.noModelSelected }

        let urlString = endpoint.hasSuffix("/")
            ? "\(endpoint)v1/chat/completions"
            : "\(endpoint)/v1/chat/completions"

        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        // Build user message with all provider responses
        var userMessage = ""
        if let q = question, !q.isEmpty {
            userMessage += "用户原始问题：\(q)\n\n"
        }
        userMessage += "以下是各 AI 的回答：\n\n"
        for (provider, text) in contents {
            let truncated = String(text.prefix(8000))
            userMessage += "---\n### \(provider.displayName) 的回答：\n\(truncated)\n\n"
        }

        let chatRequest = ChatRequest(
            model: model,
            messages: [
                ChatRequest.Message(role: "system", content: systemPrompt),
                ChatRequest.Message(role: "user", content: userMessage)
            ],
            stream: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(chatRequest)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "APIService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "无效的 HTTP 响应"])
            )
        }

        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw APIError.httpError(httpResponse.statusCode, errorBody)
        }

        // Parse SSE stream
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }

            let jsonString = String(trimmed.dropFirst(6))
            if jsonString == "[DONE]" {
                break
            }

            guard let jsonData = jsonString.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(ChatChunk.self, from: jsonData)
                if let content = chunk.choices?.first?.delta?.content {
                    continuation.yield(content)
                }
            } catch {
                // Skip malformed chunks
            }
        }

        continuation.finish()
    }
}
