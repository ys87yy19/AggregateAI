import SwiftUI
import WebKit

// MARK: - Persistent WebView Manager

class WebViewManager {
    static let shared = WebViewManager()

    private var webViews: [AIProvider: WKWebView] = [:]
    private let processPool = WKProcessPool()

    private init() {}

    func webView(for provider: AIProvider) -> WKWebView {
        if let existing = webViews[provider] {
            return existing
        }

        let config = WKWebViewConfiguration()

        // Shared process pool for all webviews
        config.processPool = processPool

        // Persistent data store to keep cookies/login state
        let dataStore = WKWebsiteDataStore.default()
        config.websiteDataStore = dataStore

        // Allow media playback
        config.mediaTypesRequiringUserActionForPlayback = []

        // Set preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Per-provider UA: Safari for ChatGPT/Grok (avoids Cloudflare), Chrome for Gemini
        switch provider {
        case .gemini:
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        default:
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        }

        if let url = provider.url {
            webView.load(URLRequest(url: url))
        }

        webViews[provider] = webView
        return webView
    }

    /// Send question to a specific provider
    func sendQuestion(_ question: String, to provider: AIProvider) {
        guard provider != .all else { return }
        guard let webView = webViews[provider] else {
            print("No webView found for \(provider.displayName)")
            return
        }

        // Grok: navigate via URL to start a new chat with the question
        if provider == .grok {
            if let encoded = question.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://grok.com/?q=\(encoded)") {
                webView.load(URLRequest(url: url))
                print("Grok: navigated via URL")
            }
            return
        }

        let escapedQuestion = question
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        let js = buildJS(for: provider, question: escapedQuestion)

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("JS error for \(provider.displayName): \(error)")
            } else {
                print("JS OK for \(provider.displayName)")
            }
        }
    }

    /// Send question to all providers with staggered delays
    func sendQuestionToAll(_ question: String) {
        let providers = AIProvider.providers
        for (index, provider) in providers.enumerated() {
            let delay = Double(index) * 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.sendQuestion(question, to: provider)
            }
        }
    }

    // MARK: - JS builders per provider

    private func buildJS(for provider: AIProvider, question: String) -> String {
        switch provider {
        case .gemini:
            return buildGeminiJS(question)
        case .grok:
            return buildGrokJS(question)
        case .chatgpt:
            return buildChatGPTJS(question)
        case .all:
            return ""
        }
    }

    private func buildGeminiJS(_ q: String) -> String {
        // Gemini: set text in contenteditable, trigger InputEvent, click send
        return """
        (function() {
            try {
                const text = `\(q)`;
                let el = document.querySelector('div[contenteditable="true"][role="textbox"]');
                if (!el) el = document.querySelector('.ql-editor[contenteditable="true"]');
                if (!el) {
                    const all = document.querySelectorAll('div[contenteditable="true"]');
                    for (const d of all) {
                        const r = d.getBoundingClientRect();
                        if (r.bottom > window.innerHeight - 300 && r.height < 300) {
                            el = d; break;
                        }
                    }
                }
                if (!el) { console.log('Gemini: no input found'); return; }

                el.focus();
                el.textContent = text;

                // Use InputEvent with inputType to trigger Gemini's framework
                el.dispatchEvent(new InputEvent('input', {
                    bubbles: true, cancelable: true, inputType: 'insertText', data: text
                }));

                // Wait then click send
                setTimeout(() => {
                    const btns = document.querySelectorAll('button');
                    // Try aria-label with "send"
                    for (const btn of btns) {
                        const label = (btn.getAttribute('aria-label') || '').toLowerCase();
                        if (label.includes('send') && !btn.disabled && btn.offsetParent !== null) {
                            btn.click(); console.log('Gemini: sent via aria-label'); return;
                        }
                    }
                    // Try class containing "send"
                    for (const btn of btns) {
                        const cls = (btn.className || '').toLowerCase();
                        if (cls.includes('send') && !btn.disabled && btn.offsetParent !== null) {
                            btn.click(); console.log('Gemini: sent via class'); return;
                        }
                    }
                    // Bottom-right SVG button
                    for (const btn of btns) {
                        if (!btn.disabled && btn.offsetParent !== null && btn.querySelector('svg')) {
                            const r = btn.getBoundingClientRect();
                            if (r.bottom > window.innerHeight - 200 && r.right > window.innerWidth - 200) {
                                btn.click(); console.log('Gemini: sent via SVG btn'); return;
                            }
                        }
                    }
                    console.log('Gemini: no send button found');
                }, 1000);
            } catch(e) { console.error('Gemini error:', e); }
        })();
        """
    }

    private func buildGrokJS(_ q: String) -> String {
        // Grok is handled via URL navigation, this is just a fallback
        return ""
    }

    private func buildChatGPTJS(_ q: String) -> String {
        // ChatGPT: contenteditable #prompt-textarea
        return """
        (function() {
            try {
                const text = `\(q)`;
                let el = document.querySelector('#prompt-textarea');
                if (!el) el = document.querySelector('textarea');
                if (!el) { console.log('ChatGPT: no input found'); return; }

                el.focus();
                if (el.getAttribute('contenteditable') === 'true') {
                    el.innerHTML = '<p>' + text + '</p>';
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                } else {
                    const nativeSetter = Object.getOwnPropertyDescriptor(
                        window.HTMLTextAreaElement.prototype, 'value'
                    ).set;
                    nativeSetter.call(el, text);
                    const tracker = el._valueTracker;
                    if (tracker) { tracker.setValue(''); }
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                }
                setTimeout(() => {
                    const btns = document.querySelectorAll('button[data-testid="send-button"], button[aria-label*="Send"], button[aria-label*="send"]');
                    for (const btn of btns) {
                        if (!btn.disabled) { btn.click(); return; }
                    }
                }, 500);
            } catch(e) { console.error('ChatGPT error:', e); }
        })();
        """
    }

}

// MARK: - SwiftUI WebView Wrapper

struct PersistentWebView: NSViewRepresentable {
    let provider: AIProvider

    func makeNSView(context: Context) -> WKWebView {
        return WebViewManager.shared.webView(for: provider)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // WebView is managed by WebViewManager, no updates needed
    }
}
