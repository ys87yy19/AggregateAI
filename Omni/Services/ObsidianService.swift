import Foundation
import AppKit

@MainActor
final class ObsidianService {
    static let shared = ObsidianService()

    func resolveVaultURL() -> URL? {
        guard let bookmarkData = OmniSettingsStore.shared.data(forKey: SettingsKeys.obsidianVaultBookmark) else {
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
                OmniSettingsStore.shared.set(newData, forKey: SettingsKeys.obsidianVaultBookmark)
                var freshStale = false
                if let freshURL = try? URL(
                    resolvingBookmarkData: newData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &freshStale
                ) {
                    return freshURL
                }
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
                OmniSettingsStore.shared.set(bookmarkData, forKey: SettingsKeys.obsidianVaultBookmark)
                appState.obsidianVaultPath = url.path
            }
        }
    }

    private static let vaultDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return df
    }()

    func saveToVault(content: String, provider: AIProvider, question: String?) throws {
        guard let vaultURL = resolveVaultURL() else {
            throw ObsidianError.noVaultConfigured
        }

        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw ObsidianError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let subfolder = vaultURL.appendingPathComponent("Omni", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let filename = "\(provider.displayName)-\(ObsidianService.vaultDateFormatter.string(from: Date())).md"
        let fileURL = subfolder.appendingPathComponent(filename)

        let isoFormatter = ISO8601DateFormatter()
        var markdown = "---\n"
        markdown += "provider: \(provider.displayName)\n"
        markdown += "date: \(isoFormatter.string(from: Date()))\n"
        markdown += "source: Omni\n"
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

    func saveAggregatedNote(markdown: String, question: String?) throws {
        guard let vaultURL = resolveVaultURL() else {
            throw ObsidianError.noVaultConfigured
        }

        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw ObsidianError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let subfolder2 = vaultURL.appendingPathComponent("Omni", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder2, withIntermediateDirectories: true)

        let filename = "Aggregated-\(ObsidianService.vaultDateFormatter.string(from: Date())).md"
        let fileURL = subfolder2.appendingPathComponent(filename)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Open a file in Obsidian using the obsidian:// URL scheme
    func openInObsidian(fileURL: URL) {
        // Use obsidian://open?path= to open the specific file
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Simply launch Obsidian app
    func openObsidian() {
        if let url = URL(string: "obsidian://") {
            NSWorkspace.shared.open(url)
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
