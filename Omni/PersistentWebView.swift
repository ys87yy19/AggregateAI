import SwiftUI
import WebKit
import OSLog

// MARK: - Persistent WebView Manager

@MainActor
final class WebViewManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WebViewManager()

    private var webViews: [AIProvider: WKWebView] = [:]
    private var pendingQuestions: [AIProvider: String] = [:]
    private var userAgentSettings = UserAgentSettings.recommended
    private var appliedUserAgentProfiles: [AIProvider: UserAgentProfile] = [:]
    private let logger = Logger(subsystem: "com.omni.app", category: "WebViewManager")
    private let multiProviderDispatchInterval: TimeInterval = 0.6
    private let sendCooldown: TimeInterval = 0.7
    private var lastSyncedAppearanceMode: AppearanceMode?
    nonisolated private static let notifyMessageName = "omniNotify"

    private override init() {}

    func updateUserAgentSettings(_ settings: UserAgentSettings) {
        userAgentSettings = settings

        for (provider, webView) in webViews {
            let desiredProfile = settings.profile(for: provider)
            guard appliedUserAgentProfiles[provider] != desiredProfile else { continue }
            webView.customUserAgent = desiredProfile.userAgentString
            appliedUserAgentProfiles[provider] = desiredProfile
            webView.reload()
        }
    }

    func preloadWebViews(for providers: [AIProvider] = AIProvider.providers) {
        for provider in providers {
            _ = webView(for: provider)
        }
    }

    func webView(for provider: AIProvider) -> WKWebView {
        if let existing = webViews[provider] {
            return existing
        }

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Persistent data store to keep cookies/login state
        let dataStore = WKWebsiteDataStore.default()
        config.websiteDataStore = dataStore

        // Allow media playback
        config.mediaTypesRequiringUserActionForPlayback = []

        // Set preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let initialTheme = resolvedWebTheme(for: lastSyncedAppearanceMode ?? .system)
        contentController.addUserScript(
            WKUserScript(
                source: buildThemeBootstrapScript(initialTheme),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        if provider == .gemini {
            contentController.addUserScript(
                WKUserScript(
                    source: buildGeminiThemeStorageBootstrapScript(initialTheme),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        // Register notification message handler
        contentController.add(self, name: WebViewManager.notifyMessageName)

        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self

        let userAgentProfile = userAgentSettings.profile(for: provider)
        webView.customUserAgent = userAgentProfile.userAgentString
        appliedUserAgentProfiles[provider] = userAgentProfile

        if let url = provider.url {
            webView.load(URLRequest(url: url))
        }

        webViews[provider] = webView
        return webView
    }

    func syncThemeForAllWebViews(mode: AppearanceMode = .system) {
        lastSyncedAppearanceMode = mode
        let theme = resolvedWebTheme(for: mode)

        for (provider, webView) in webViews {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.applyRuntimeThemeOverride(in: webView, provider: provider, theme: theme)
            }
        }
    }

    // MARK: - New Chat

    /// Start a new chat for a specific provider
    func startNewChat(for provider: AIProvider) {
        guard provider != .all else { return }
        let wv = webView(for: provider)

        switch provider {
        case .gemini:
            // Navigate to Gemini app page (new chat)
            wv.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
        case .grok:
            // Navigate to Grok home to start fresh
            wv.load(URLRequest(url: URL(string: "https://grok.com/")!))
        case .chatgpt:
            // Navigate to ChatGPT root for a new conversation
            wv.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        case .all:
            break
        }
    }

    /// Start new chats for all providers
    func startNewChatForAll() {
        for provider in AIProvider.providers {
            startNewChat(for: provider)
        }
    }

    /// Send question to a specific provider
    @discardableResult
    func sendQuestion(_ question: String, to provider: AIProvider) -> TimeInterval {
        guard provider != .all else { return 0 }

        let webView = webView(for: provider)

        if provider.requiresLoadedWebAppForSending && (webView.url == nil || webView.isLoading) {
            pendingQuestions[provider] = question
            logger.debug("Queued question for \(provider.displayName, privacy: .public) until the page is ready.")
            return sendCooldown
        }

        switch provider {
        case .gemini:
            sendQuestionToGemini(question, in: webView)
        case .grok:
            sendQuestionToGrok(question, in: webView)
        case .chatgpt:
            sendQuestionToChatGPT(question, in: webView)
        case .all:
            break
        }

        // Inject response observer for notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.injectResponseObserver(for: provider)
        }

        return sendCooldown
    }

    /// Send question to all providers with staggered delays
    @discardableResult
    func sendQuestionToAll(_ question: String) -> TimeInterval {
        preloadWebViews()

        let providers = AIProvider.providers
        for (index, provider) in providers.enumerated() {
            let delay = Double(index) * multiProviderDispatchInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.sendQuestion(question, to: provider)
            }
        }

        guard !providers.isEmpty else { return 0 }
        let lastDispatchDelay = Double(providers.count - 1) * multiProviderDispatchInterval
        return lastDispatchDelay + sendCooldown
    }

    // MARK: - Provider Actions

    private func sendQuestionToGrok(_ question: String, in webView: WKWebView) {
        var components = URLComponents(string: "https://grok.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: question)]
        guard let url = components?.url else {
            logger.error("Grok: failed to build URL for sync question.")
            return
        }

        webView.load(URLRequest(url: url))
        logger.debug("Grok: navigated via URL.")
    }

    private func sendQuestionToGemini(_ question: String, in webView: WKWebView) {
        evaluate(
            buildGeminiSendScript(escapedTemplateLiteral(question)),
            in: webView,
            provider: .gemini
        )
    }

    private func sendQuestionToChatGPT(_ question: String, in webView: WKWebView) {
        evaluate(
            buildChatGPTSendScript(escapedTemplateLiteral(question)),
            in: webView,
            provider: .chatgpt
        )
    }

    private func evaluate(_ script: String, in webView: WKWebView, provider: AIProvider) {
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                self.logger.error("JS error for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }

            if let status = result as? String {
                self.logger.debug("\(provider.displayName, privacy: .public): \(status, privacy: .public)")
            } else {
                self.logger.debug("JS OK for \(provider.displayName, privacy: .public)")
            }
        }
    }

    private func escapedTemplateLiteral(_ question: String) -> String {
        question
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func resolvedWebTheme(for mode: AppearanceMode) -> String {
        switch mode {
        case .light:
            return "light"
        case .dark:
            return "dark"
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? "dark" : "light"
        }
    }

    private func applyRuntimeThemeOverride(in webView: WKWebView, provider: AIProvider, theme: String) {
        evaluate(buildRuntimeThemeOverrideScript(theme), in: webView, provider: provider)
    }

    private func buildThemeBootstrapScript(_ theme: String) -> String {
        return """
        (function() {
            const desiredTheme = "\(theme)";
            const prefersDark = desiredTheme === 'dark';
            const originalMatchMedia = window.matchMedia ? window.matchMedia.bind(window) : null;

            function stubMatchMedia(query) {
                const media = String(query || '');
                const isColorSchemeQuery = media.includes('prefers-color-scheme');
                const matches = isColorSchemeQuery
                    ? (media.includes('dark') ? prefersDark : media.includes('light') ? !prefersDark : false)
                    : (originalMatchMedia ? originalMatchMedia(media).matches : false);

                return {
                    matches,
                    media,
                    onchange: null,
                    addListener() {},
                    removeListener() {},
                    addEventListener() {},
                    removeEventListener() {},
                    dispatchEvent() { return false; }
                };
            }

            try {
                Object.defineProperty(window, 'matchMedia', {
                    configurable: true,
                    value(query) {
                        return stubMatchMedia(query);
                    }
                });
            } catch (_) {
                window.matchMedia = stubMatchMedia;
            }

            try {
                document.documentElement.style.setProperty('color-scheme', desiredTheme, 'important');
                document.documentElement.dataset.omniTheme = desiredTheme;
            } catch (_) {}
        })();
        """
    }

    private func buildRuntimeThemeOverrideScript(_ theme: String) -> String {
        return """
        (function() {
            try {
                const desiredTheme = "\(theme)";
                const root = document.documentElement;
                const body = document.body;
                const prefersDark = desiredTheme === 'dark';

                if (root) {
                    root.style.setProperty('color-scheme', desiredTheme, 'important');
                    root.dataset.omniTheme = desiredTheme;
                    root.dataset.theme = desiredTheme;
                    root.classList.toggle('dark', prefersDark);
                    root.classList.toggle('light', !prefersDark);
                    root.classList.toggle('dark-theme', prefersDark);
                    root.classList.toggle('light-theme', !prefersDark);
                }

                if (body) {
                    body.style.setProperty('color-scheme', desiredTheme, 'important');
                    body.dataset.omniTheme = desiredTheme;
                    body.dataset.theme = desiredTheme;
                    body.classList.toggle('dark', prefersDark);
                    body.classList.toggle('light', !prefersDark);
                    body.classList.toggle('dark-theme', prefersDark);
                    body.classList.toggle('light-theme', !prefersDark);
                }

                window.dispatchEvent(new CustomEvent('omni:theme-changed', {
                    detail: { theme: desiredTheme }
                }));

                return 'theme_override_' + desiredTheme;
            } catch (e) {
                return 'theme_override_error';
            }
        })();
        """
    }

    private func buildGeminiThemeStorageBootstrapScript(_ theme: String) -> String {
        return """
        (function() {
            const desiredTheme = "\(theme)";
            const wantsDark = desiredTheme === 'dark';
            const themeRegex = /(theme|appearance|color.?scheme|dark)/i;

            function normalizedValue(value) {
                if (value == null) return desiredTheme;
                const stringValue = String(value);

                if (stringValue === 'true' || stringValue === 'false') {
                    return wantsDark ? 'true' : 'false';
                }

                if (/dark/i.test(stringValue) || /light/i.test(stringValue)) {
                    return stringValue
                        .replace(/dark/gi, desiredTheme)
                        .replace(/light/gi, desiredTheme);
                }

                return desiredTheme;
            }

            function patchStorage(storage) {
                if (!storage) return;

                try {
                    for (let index = 0; index < storage.length; index += 1) {
                        const key = storage.key(index);
                        if (!key || !themeRegex.test(key)) continue;
                        const currentValue = storage.getItem(key);
                        storage.setItem(key, normalizedValue(currentValue));
                    }
                } catch (_) {}

                const originalGetItem = storage.getItem.bind(storage);
                const originalSetItem = storage.setItem.bind(storage);

                storage.getItem = function(key) {
                    const value = originalGetItem(key);
                    return themeRegex.test(String(key || '')) ? normalizedValue(value) : value;
                };

                storage.setItem = function(key, value) {
                    const patchedValue = themeRegex.test(String(key || ''))
                        ? normalizedValue(value)
                        : value;
                    return originalSetItem(key, patchedValue);
                };
            }

            function patchCookies() {
                const cookieNames = [
                    'theme',
                    'appearance',
                    'color_scheme',
                    'color-scheme',
                    'dark_mode',
                    'darkmode'
                ];

                for (const name of cookieNames) {
                    try {
                        document.cookie = `${name}=${desiredTheme}; path=/; SameSite=Lax`;
                    } catch (_) {}
                }
            }

            try {
                patchStorage(window.localStorage);
                patchStorage(window.sessionStorage);
                patchCookies();
                document.documentElement.dataset.omniGeminiTheme = desiredTheme;
            } catch (_) {}
        })();
        """
    }

    // MARK: - JS Builders

    private func buildGeminiSendScript(_ q: String) -> String {
        // Gemini needs stricter composer/send targeting than the other providers.
        return """
        (function() {
            try {
                const text = `\(q)`;

                function isVisible(el) {
                    return !!el && el.offsetParent !== null;
                }

                function findComposer() {
                    const selectors = [
                        'div[contenteditable="true"][role="textbox"]',
                        '.ql-editor[contenteditable="true"]',
                        'rich-textarea div[contenteditable="true"]',
                        'div[contenteditable="true"][aria-label*="Gemini"]',
                        'div[contenteditable="true"][aria-label*="message"]'
                    ];
                    for (const selector of selectors) {
                        const match = Array.from(document.querySelectorAll(selector)).find(isVisible);
                        if (match) return match;
                    }

                    const candidates = Array.from(document.querySelectorAll('div[contenteditable="true"]'));
                    for (const candidate of candidates) {
                        const rect = candidate.getBoundingClientRect();
                        if (isVisible(candidate) && rect.height < 260 && rect.bottom > window.innerHeight - 360) {
                            return candidate;
                        }
                    }

                    return null;
                }

                function buttonLabel(btn) {
                    return (
                        (btn.getAttribute('aria-label') || '') + ' ' +
                        (btn.getAttribute('title') || '') + ' ' +
                        (btn.textContent || '')
                    ).toLowerCase();
                }

                function findSendButton() {
                    const selectors = [
                        'button[aria-label*="Send"]',
                        'button[aria-label*="send"]',
                        'button[aria-label*="发送"]',
                        'button[data-testid*="send"]',
                        'button[title*="Send"]',
                        'button[title*="send"]'
                    ];
                    const buttons = [];
                    const seen = new Set();

                    for (const s of selectors) {
                        for (const btn of document.querySelectorAll(s)) {
                            if (seen.has(btn)) continue;
                            seen.add(btn);
                            buttons.push(btn);
                        }
                    }

                    for (const btn of buttons) {
                        const label = buttonLabel(btn);
                        const looksLikeSend =
                            label.includes('send') || label.includes('发送');
                        const looksLikeStop =
                            label.includes('stop') || label.includes('stopping') ||
                            label.includes('停止') || label.includes('中止') ||
                            label.includes('cancel') || label.includes('取消');
                        if (looksLikeSend && !looksLikeStop && !btn.disabled && isVisible(btn)) {
                            return btn;
                        }
                    }

                    return null;
                }

                const composer = findComposer();
                if (!composer) return 'gemini:composer_missing';

                composer.focus();
                composer.textContent = text;
                composer.dispatchEvent(new InputEvent('input', {
                    bubbles: true, cancelable: true, inputType: 'insertText', data: text
                }));
                composer.dispatchEvent(new Event('change', { bubbles: true }));

                let attempts = 0;
                function trySend() {
                    const btn = findSendButton();
                    if (btn) {
                        btn.click();
                        return;
                    }
                    attempts += 1;
                    if (attempts < 10) {
                        setTimeout(trySend, 200);
                    }
                }

                setTimeout(trySend, 150);
                return 'gemini:send_scheduled';
            } catch(e) { console.error('Gemini error:', e); }
        })();
        """
    }

    private func buildChatGPTSendScript(_ q: String) -> String {
        // ChatGPT accepts either contenteditable or textarea, but the send button is easier to target.
        return """
        (function() {
            try {
                const text = `\(q)`;
                let el = document.querySelector('#prompt-textarea');
                if (!el) el = document.querySelector('textarea');
                if (!el) { console.log('ChatGPT: no input found'); return; }

                el.focus();
                if (el.getAttribute('contenteditable') === 'true') {
                    el.textContent = text;
                    el.dispatchEvent(new InputEvent('input', {
                        bubbles: true, cancelable: true, inputType: 'insertText', data: text
                    }));
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
                return 'chatgpt:send_scheduled';
            } catch(e) { console.error('ChatGPT error:', e); }
        })();
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let provider = webViews.first(where: { $0.value == webView })?.key else {
            return
        }

        let theme = resolvedWebTheme(for: lastSyncedAppearanceMode ?? .system)
        applyRuntimeThemeOverride(in: webView, provider: provider, theme: theme)

        if let question = pendingQuestions.removeValue(forKey: provider) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.sendQuestion(question, to: provider)
            }
        }
    }

    // MARK: - WKScriptMessageHandler (Notification Support)

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let expectedName = WebViewManager.notifyMessageName

        Task { @MainActor in
            guard message.name == expectedName else { return }
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String,
                  event == "response_complete",
                  let preview = body["preview"] as? String,
                  let providerName = body["provider"] as? String else {
                return
            }

            let provider: AIProvider
            switch providerName {
            case "gemini": provider = .gemini
            case "grok": provider = .grok
            case "chatgpt": provider = .chatgpt
            default: return
            }

            NotificationService.shared.sendNotification(provider: provider, preview: preview)
        }
    }

    /// Inject MutationObserver JS to detect when AI finishes responding
    func injectResponseObserver(for provider: AIProvider) {
        guard let webView = webViews[provider] else { return }
        let providerName = provider.rawValue
        let js = """
        (function() {
            if (window.__omni_observer) {
                window.__omni_observer.disconnect();
                window.__omni_observer = null;
            }
            if (window.__omni_debounce) {
                clearTimeout(window.__omni_debounce);
                window.__omni_debounce = null;
            }

            var DEBOUNCE_MS = 3000;
            var started = false;

            function getResponseArea() {
                var selectors = [
                    '[data-message-author-role="assistant"]:last-of-type',
                    '.model-response:last-of-type',
                    '.message-bubble:last-of-type',
                    '[class*="response"]:last-of-type'
                ];
                for (var i = 0; i < selectors.length; i++) {
                    var els = document.querySelectorAll(selectors[i]);
                    if (els.length > 0) return els[els.length - 1];
                }
                return document.querySelector('main') || document.body;
            }

            setTimeout(function() {
                var target = getResponseArea();
                var observer = new MutationObserver(function(mutations) {
                    started = true;
                    if (window.__omni_debounce) {
                        clearTimeout(window.__omni_debounce);
                    }
                    window.__omni_debounce = setTimeout(function() {
                        var text = target.textContent || '';
                        window.webkit.messageHandlers.omniNotify.postMessage({
                            event: 'response_complete',
                            provider: '\(providerName)',
                            preview: text.substring(0, 300)
                        });
                        observer.disconnect();
                        window.__omni_observer = null;
                        window.__omni_debounce = null;
                    }, DEBOUNCE_MS);
                });

                observer.observe(target, { childList: true, subtree: true, characterData: true });
                window.__omni_observer = observer;
            }, 1000);
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                self.logger.error("Failed to inject response observer for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - SwiftUI WebView Wrapper

struct PersistentWebView: NSViewRepresentable {
    let provider: AIProvider

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        reparentWebView(into: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        reparentWebView(into: nsView)
    }

    private func reparentWebView(into container: NSView) {
        let webView = WebViewManager.shared.webView(for: provider)
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
