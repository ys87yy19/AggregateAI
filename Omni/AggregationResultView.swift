import SwiftUI
import AppKit

// MARK: - Shared streaming store (bypasses SwiftUI during streaming)

@MainActor
final class StreamingTextStore: ObservableObject {
    static let shared = StreamingTextStore()

    /// The NSTextView managed by StreamingTextView — set once the view appears
    weak var textView: NSTextView?

    /// Accumulated full text (only for save/export after streaming ends)
    private(set) var fullText: String = ""

    /// Pending buffer not yet flushed to NSTextView
    private var buffer: String = ""
    private var lastFlush: Date = .distantPast
    private let flushInterval: TimeInterval = 0.12

    private let defaultAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.textColor
    ]

    // MARK: - API

    func reset() {
        fullText = ""
        buffer = ""
        lastFlush = .distantPast
        textView?.textStorage?.setAttributedString(
            NSAttributedString(string: "等待 AI 响应...", attributes: defaultAttrs)
        )
    }

    /// Called on every streaming chunk — fast path, no SwiftUI involvement
    func append(_ chunk: String) {
        buffer += chunk
        let now = Date()
        if now.timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    /// Flush remaining buffer (call when stream ends)
    func finish() {
        flush()
    }

    /// Get final text for save/export
    func getFinalText() -> String {
        return fullText
    }

    // MARK: - Internal

    private func flush() {
        guard !buffer.isEmpty else { return }

        let text = buffer
        buffer = ""
        lastFlush = Date()

        // First chunk — clear placeholder
        if fullText.isEmpty {
            textView?.textStorage?.setAttributedString(
                NSAttributedString(string: "", attributes: defaultAttrs)
            )
        }

        fullText += text

        // Direct NSTextView textStorage append — O(1), no SwiftUI diff
        textView?.textStorage?.beginEditing()
        textView?.textStorage?.append(
            NSAttributedString(string: text, attributes: defaultAttrs)
        )
        textView?.textStorage?.endEditing()

        // Throttled scroll — only if near bottom already
        textView?.scrollToEndOfDocument(nil)
    }
}

// MARK: - Aggregation Result View

struct AggregationResultView: View {
    @ObservedObject var appState: AppState
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                Text("AI 聚合结果")
                    .font(.headline)

                Spacer()

                if appState.isAggregating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("正在聚合...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            // High-performance streaming text view — direct NSTextView, no SwiftUI diffing
            StreamingTextView()

            // Error display
            if let error = appState.aggregationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            Divider()

            // Bottom action bar
            HStack {
                Button("复制结果") {
                    let text = StreamingTextStore.shared.getFinalText()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(appState.isAggregating)

                Button(isSaving ? "正在生成标题..." : "保存笔记") {
                    Task { await saveNote() }
                }
                .disabled(appState.isAggregating || isSaving)

                Button("导出 Markdown...") {
                    exportMarkdown()
                }
                .disabled(appState.isAggregating)

                Spacer()

                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(idealWidth: 800, idealHeight: 600)
        .alert("Omni", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Save Note

    private func saveNote() async {
        isSaving = true
        defer { isSaving = false }

        let text = StreamingTextStore.shared.getFinalText()

        // Ask AI to generate a title
        let title = await generateSmartTitle(text: text)
        let sanitized = sanitizeFilename(title)

        let markdown = buildAggregatedMarkdown(title: title)

        if let folderURL = resolveSaveFolderURL() {
            do {
                try saveToFolder(folderURL, filename: sanitized, markdown: markdown)
                alertMessage = "已保存「\(title)」到 \(appState.apiSavePath)"
                showAlert = true
                return
            } catch {
                alertMessage = "保存失败: \(error.localizedDescription)"
                showAlert = true
                return
            }
        }

        exportMarkdown()
    }

    /// Call the API to generate a short title, with fallback to question or date
    private func generateSmartTitle(text: String) async -> String {
        do {
            let title = try await APIService.shared.generateTitle(
                endpoint: appState.apiEndpoint,
                apiKey: appState.apiKey,
                model: appState.apiSelectedModel,
                text: text
            )
            return title
        } catch {
            // Fallback: use the user's question, or date
            if !appState.syncQuestion.isEmpty {
                return String(appState.syncQuestion.prefix(40))
            }
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HHmmss"
            return "AI聚合笔记-\(df.string(from: Date()))"
        }
    }

    /// Remove characters that are invalid in filenames
    private func sanitizeFilename(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = title.components(separatedBy: illegal).joined(separator: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Limit length
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80))
        }
        return cleaned.isEmpty ? "AI聚合笔记" : cleaned
    }

    private func resolveSaveFolderURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: SettingsKeys.apiSaveBookmark) else {
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
                UserDefaults.standard.set(newData, forKey: SettingsKeys.apiSaveBookmark)
            }
        }
        return url
    }

    private func saveToFolder(_ folderURL: URL, filename: String, markdown: String) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "Omni", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法访问保存目录，请在偏好设置 > API 中重新选择。"])
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let fileURL = folderURL.appendingPathComponent("\(filename).md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Export

    private func exportMarkdown() {
        let markdown = buildAggregatedMarkdown()
        ExportService.shared.exportToFile(markdown: markdown)
    }

    private func buildAggregatedMarkdown(title: String? = nil) -> String {
        let text = StreamingTextStore.shared.getFinalText()
        let isoFormatter = ISO8601DateFormatter()
        var md = "---\n"
        md += "type: aggregated-note\n"
        if let t = title {
            md += "title: \(t)\n"
        }
        md += "sources: [Gemini, Grok, ChatGPT]\n"
        md += "date: \(isoFormatter.string(from: Date()))\n"
        md += "source: Omni\n"
        if !appState.syncQuestion.isEmpty {
            md += "question: \(appState.syncQuestion)\n"
        }
        md += "tags: [ai-aggregated]\n"
        md += "---\n\n"
        if let t = title {
            md += "# \(t)\n\n"
        }
        md += text
        return md
    }
}

// MARK: - NSTextView wrapper — zero SwiftUI overhead during streaming

struct StreamingTextView: NSViewRepresentable {

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        // Disable layout manager logging for performance
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView.documentView = textView

        // Register with the shared store — streaming writes go directly here
        StreamingTextStore.shared.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Intentionally empty — all updates go through StreamingTextStore directly
    }
}
