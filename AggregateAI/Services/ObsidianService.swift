import Foundation
import AppKit

@MainActor
final class ObsidianService {
    static let shared = ObsidianService()

    func resolveVaultURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: SettingsKeys.obsidianVaultBookmark) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(newData, forKey: SettingsKeys.obsidianVaultBookmark)
            }
        }
        return url
    }

    func chooseVaultFolder(appState: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择你的 Obsidian Vault 文件夹"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(bookmarkData, forKey: SettingsKeys.obsidianVaultBookmark)
                appState.obsidianVaultPath = url.path
            }
        }
    }

    func saveToVault(content: String, provider: AIProvider, question: String?) throws {
        guard let vaultURL = resolveVaultURL() else {
            throw ObsidianError.noVaultConfigured
        }

        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw ObsidianError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let subfolder = vaultURL.appendingPathComponent("AggregateAI", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "\(provider.displayName)-\(dateFormatter.string(from: Date())).md"
        let fileURL = subfolder.appendingPathComponent(filename)

        let isoFormatter = ISO8601DateFormatter()
        var markdown = "---\n"
        markdown += "provider: \(provider.displayName)\n"
        markdown += "date: \(isoFormatter.string(from: Date()))\n"
        markdown += "source: AggregateAI\n"
        if let q = question, !q.isEmpty {
            markdown += "question: \(q)\n"
        }
        markdown += "tags: [ai-response]\n"
        markdown += "---\n\n"
        markdown += content

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func saveAllToVault(question: String?) async throws {
        for provider in AIProvider.providers {
            let content = try await ExportService.shared.extractContent(from: provider)
            if !content.isEmpty {
                try saveToVault(content: content, provider: provider, question: question)
            }
        }
    }

    enum ObsidianError: LocalizedError {
        case noVaultConfigured
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .noVaultConfigured: return "未配置 Obsidian Vault 路径，请在偏好设置中设置。"
            case .accessDenied: return "无法访问 Obsidian Vault，请在偏好设置中重新选择文件夹。"
            }
        }
    }
}
