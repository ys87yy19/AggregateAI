import Foundation
import WebKit
import AppKit

@MainActor
final class ExportService {
    static let shared = ExportService()

    func extractContent(from provider: AIProvider) async throws -> String {
        guard provider != .all else {
            // Extract from all providers concurrently
            async let c0 = extractSingleProviderContent(AIProvider.providers[0])
            async let c1 = extractSingleProviderContent(AIProvider.providers[1])
            async let c2 = extractSingleProviderContent(AIProvider.providers[2])
            let results = try await (c0, c1, c2)
            let contents = [results.0, results.1, results.2]
            return zip(AIProvider.providers, contents).reduce("") { acc, pair in
                let (p, content) = pair
                return content.isEmpty ? acc : acc + "# \(p.displayName)\n\n\(content)\n\n---\n\n"
            }
        }
        return try await extractSingleProviderContent(provider)
    }

    private func extractSingleProviderContent(_ provider: AIProvider) async throws -> String {
        let webView = WebViewManager.shared.webView(for: provider)

        let js = """
        (function() {
            // Provider-specific selectors
            var selectors = [];

            // ChatGPT
            selectors.push('[data-message-author-role]');
            // Gemini
            selectors.push('.conversation-container .message-content');
            selectors.push('message-content');
            selectors.push('.model-response');
            selectors.push('.user-query');
            // Grok
            selectors.push('.message-bubble');
            selectors.push('[class*="message"]');

            for (var i = 0; i < selectors.length; i++) {
                var els = document.querySelectorAll(selectors[i]);
                if (els.length > 2) {
                    var result = [];
                    for (var j = 0; j < els.length; j++) {
                        var el = els[j];
                        var role = el.dataset && el.dataset.messageAuthorRole;
                        if (!role) {
                            var text = el.textContent || '';
                            if (text.length < 10) continue;
                            role = (el.closest && el.closest('[data-message-author-role]'))
                                ? el.closest('[data-message-author-role]').dataset.messageAuthorRole
                                : 'unknown';
                        }
                        var prefix = role === 'user' ? '## User' : '## Assistant';
                        result.push(prefix + '\\n\\n' + (el.textContent || '').trim());
                    }
                    if (result.length > 0) return result.join('\\n\\n---\\n\\n');
                }
            }

            // Fallback: grab main content area text
            var main = document.querySelector('main') || document.body;
            return main.innerText || '';
        })();
        """

        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (result as? String) ?? "")
                }
            }
        }
    }

    func formatAsMarkdown(content: String, provider: AIProvider, question: String?) -> String {
        let dateFormatter = ISO8601DateFormatter()
        var md = "---\n"
        md += "provider: \(provider.displayName)\n"
        md += "date: \(dateFormatter.string(from: Date()))\n"
        md += "source: Omni\n"
        if let q = question, !q.isEmpty {
            md += "question: \(q)\n"
        }
        md += "---\n\n"
        md += content
        return md
    }

    func exportToFile(markdown: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Omni-\(dateFormatter.string(from: Date())).md"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                showWriteErrorAlert(error)
            }
        }
    }

    private func showWriteErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "导出失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
