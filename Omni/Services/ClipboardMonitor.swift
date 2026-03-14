import AppKit

@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    weak var appState: AppState?

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    var isActive: Bool = false {
        didSet {
            if isActive {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text.count < 5000 else { return }

        appState?.syncQuestion = text
    }
}
