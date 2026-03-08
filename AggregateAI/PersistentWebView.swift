import SwiftUI
import WebKit
import OSLog

// MARK: - Persistent WebView Manager

@MainActor
final class WebViewManager: NSObject, WKNavigationDelegate {
    static let shared = WebViewManager()

    private var webViews: [AIProvider: WKWebView] = [:]
    private var pendingQuestions: [AIProvider: String] = [:]
    private var userAgentSettings = UserAgentSettings.recommended
    private var appliedUserAgentProfiles: [AIProvider: UserAgentProfile] = [:]
    private let logger = Logger(subsystem: "com.aggregateai.app", category: "WebViewManager")
    private let multiProviderDispatchInterval: TimeInterval = 0.6
    private let sendCooldown: TimeInterval = 0.7
    private var lastSyncedAppearanceMode: AppearanceMode?

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

        for (provider, webView) in webViews {
            guard provider == .gemini else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.syncGeminiTheme(in: webView, mode: mode)
            }
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

    private func resolvedGeminiTheme(for mode: AppearanceMode) -> String {
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

    private func syncGeminiTheme(in webView: WKWebView, mode: AppearanceMode) {
        let theme = resolvedGeminiTheme(for: mode)
        evaluate(buildGeminiThemeScript(theme), in: webView, provider: .gemini)
    }

    private func buildGeminiThemeScript(_ theme: String) -> String {
        return """
        (function() {
            try {
                const desiredTheme = "\(theme)";
                const wantsDark = desiredTheme === 'dark';
                let openedSettingsMenu = false;
                let openedThemeMenu = false;
                let attempts = 0;

                function isVisible(el) {
                    if (!el) return false;
                    const rect = el.getBoundingClientRect();
                    const style = window.getComputedStyle(el);
                    return rect.width > 0 && rect.height > 0 &&
                        style.display !== 'none' && style.visibility !== 'hidden';
                }

                function click(el) {
                    if (!el) return false;
                    el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
                    el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
                    el.click();
                    return true;
                }

                function normalizedText(el) {
                    return [
                        el?.textContent || '',
                        el?.innerText || '',
                        el?.getAttribute?.('aria-label') || '',
                        el?.getAttribute?.('title') || ''
                    ].join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
                }

                function applyThemeToRoot() {
                    const root = document.querySelector(':root') || document.documentElement;
                    if (root) {
                        root.dataset.theme = desiredTheme;
                    }
                    if (document.body) {
                        document.body.dataset.theme = desiredTheme;
                    }

                    const message = { type: 'APPLY_THEME', theme: desiredTheme };
                    try {
                        window.postMessage(message, '*');
                    } catch (_) {}
                    try {
                        window.dispatchEvent(new MessageEvent('message', { data: message }));
                    } catch (_) {}
                }

                function findInSelectors(selectors) {
                    for (const selector of selectors) {
                        const match = Array.from(document.querySelectorAll(selector)).find(isVisible);
                        if (match) return match;
                    }
                    return null;
                }

                function settingsButton() {
                    return findInSelectors([
                        '[data-test-id="settings-and-help-button"]',
                        '[data-test-id="mobile-settings-and-help-control"]'
                    ]);
                }

                function themeMenuButton() {
                    return findInSelectors([
                        '[data-test-id="desktop-theme-menu-button"]',
                        '[data-test-id="theme-menu-item"]'
                    ]);
                }

                function explicitThemeOption() {
                    const mobileSelector = wantsDark
                        ? '[data-test-id="mobile-theme-dark"]'
                        : '[data-test-id="mobile-theme-light"]';
                    const mobile = findInSelectors([mobileSelector]);
                    if (mobile) return mobile;

                    const optionNeedles = wantsDark
                        ? ['dark', 'dark theme', '深色', '深色模式']
                        : ['light', 'light theme', '浅色', '浅色模式'];

                    return Array.from(document.querySelectorAll('[role="menuitemradio"], [role="option"], mat-menu-item'))
                        .find((el) => isVisible(el) && optionNeedles.some((needle) => normalizedText(el).includes(needle))) || null;
                }

                function darkToggle() {
                    return findInSelectors([
                        '[data-test-id="bard-dark-theme-toggle"] [role="switch"]',
                        '[data-test-id="bard-dark-theme-toggle"] [aria-label*="dark theme"]',
                        '[data-test-id="bard-dark-theme-toggle"] [aria-label*="Dark theme"]',
                        '[data-test-id="bard-dark-theme-toggle"] [aria-label*="深色主题"]',
                        '[data-test-id="bard-dark-theme-toggle"] [aria-checked]',
                        '[data-test-id="bard-dark-theme-toggle"] input[type="checkbox"]',
                        '[data-test-id="bard-dark-theme-toggle"]'
                    ]);
                }

                function readChecked(el) {
                    if (!el) return null;
                    if (el.hasAttribute('aria-checked')) {
                        return el.getAttribute('aria-checked') === 'true';
                    }
                    if ('checked' in el && typeof el.checked === 'boolean') {
                        return el.checked;
                    }
                    const descendant = el.querySelector?.('[aria-checked], input[type="checkbox"]');
                    if (descendant) {
                        return readChecked(descendant);
                    }
                    return null;
                }

                function closeMenu() {
                    document.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Escape',
                        code: 'Escape',
                        bubbles: true
                    }));
                }

                function syncTheme() {
                    attempts += 1;
                    applyThemeToRoot();

                    const option = explicitThemeOption();
                    const optionChecked = readChecked(option);

                    if (option && optionChecked !== null) {
                        const shouldClick = optionChecked !== true;
                        if (!shouldClick) {
                            closeMenu();
                            return;
                        }

                        click(option);
                        setTimeout(closeMenu, 80);
                        return;
                    }

                    if (option) {
                        click(option);
                        setTimeout(closeMenu, 80);
                        return;
                    }

                    const toggle = darkToggle();
                    const toggleChecked = readChecked(toggle);
                    if (toggle && toggleChecked !== null) {
                        if (toggleChecked !== wantsDark) {
                            click(toggle.closest('[data-test-id="bard-dark-theme-toggle"]') || toggle);
                        }
                        setTimeout(closeMenu, 80);
                        return;
                    }

                    if (toggle) {
                        click(toggle.closest('[data-test-id="bard-dark-theme-toggle"]') || toggle);
                        setTimeout(closeMenu, 80);
                        return;
                    }

                    if (openedSettingsMenu && !openedThemeMenu) {
                        const themeButton = themeMenuButton();
                        if (themeButton) {
                            openedThemeMenu = click(themeButton);
                        }
                    }

                    if (!openedSettingsMenu) {
                        const button = settingsButton();
                        if (button) {
                            openedSettingsMenu = click(button);
                        }
                    }

                    if (attempts < 10) {
                        setTimeout(syncTheme, 180);
                    }
                }

                syncTheme();
                return 'gemini:theme_\(theme)_scheduled';
            } catch (e) {
                return 'gemini:theme_\(theme)_error';
            }
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

        if provider == .gemini {
            syncGeminiTheme(in: webView, mode: lastSyncedAppearanceMode ?? .system)
        }

        if let question = pendingQuestions.removeValue(forKey: provider) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.sendQuestion(question, to: provider)
            }
        }
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
