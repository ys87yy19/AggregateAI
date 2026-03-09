import Cocoa
import SwiftUI
import WebKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var serviceWindows: [String: NSWindow] = [:]
    private var serviceWebViews: [String: WKWebView] = [:]
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var cancellables: [AnyCancellable] = []

    // Service definitions
    private struct WebService {
        let id: String
        let title: String
        let url: String
        let icon: String
        let width: CGFloat
        let height: CGFloat
    }

    private let gmailService = WebService(
        id: "gmail", title: "Gmail", url: "https://mail.google.com",
        icon: "envelope.fill", width: 1200, height: 800
    )

    private let twitterService = WebService(
        id: "twitter", title: "Twitter", url: "https://x.com/home",
        icon: "bird.fill", width: 700, height: 900
    )

    private var twitterWebView: WKWebView?
    private var twitterNavDelegate: TwitterNavigationDelegate?

    private let videoServices: [WebService] = [
        WebService(id: "youtube", title: "YouTube", url: "https://www.youtube.com",
                   icon: "play.rectangle.fill", width: 1200, height: 800),
        WebService(id: "bilibili", title: "哔哩哔哩", url: "https://www.bilibili.com",
                   icon: "play.circle.fill", width: 1200, height: 800),
        WebService(id: "douyin", title: "抖音", url: "https://www.douyin.com",
                   icon: "music.note", width: 1200, height: 800),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Omni")
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Build right-click menu
        buildStatusMenu()

        statusItem.menu = nil

        // Register global hotkey
        registerGlobalHotKey()

        // Observe hotkey changes
        appState.$hotkeyKeyCode
            .combineLatest(appState.$hotkeyModifiers)
            .dropFirst()
            .sink { [weak self] _, _ in
                self?.reregisterGlobalHotKey()
            }
            .store(in: &cancellables)

        // Clipboard monitor
        ClipboardMonitor.shared.appState = appState
        appState.$clipboardMonitorEnabled
            .sink { enabled in
                ClipboardMonitor.shared.isActive = enabled
            }
            .store(in: &cancellables)

        // Notification service
        NotificationService.shared.appState = appState

        // Observe appearance mode for Twitter theme sync
        appState.$appearanceMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.syncTwitterTheme()
            }
            .store(in: &cancellables)

        // Auto show main window on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showWindow()
        }
    }

    // MARK: - Menu

    private func buildStatusMenu() {
        statusMenu.removeAllItems()

        // 1. AI 搜索
        let aiItem = NSMenuItem(title: "AI 搜索", action: #selector(showWindow), keyEquivalent: "")
        aiItem.target = self
        aiItem.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
        statusMenu.addItem(aiItem)

        statusMenu.addItem(NSMenuItem.separator())

        // 2. 视频平台 submenu
        let videoItem = NSMenuItem(title: "视频平台", action: nil, keyEquivalent: "")
        videoItem.image = NSImage(systemSymbolName: "play.tv", accessibilityDescription: nil)
        let videoSubmenu = NSMenu()
        for service in videoServices {
            let item = NSMenuItem(title: service.title, action: #selector(openVideoService(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service.id
            item.image = NSImage(systemSymbolName: service.icon, accessibilityDescription: nil)
            videoSubmenu.addItem(item)
        }
        videoItem.submenu = videoSubmenu
        statusMenu.addItem(videoItem)

        // 3. Twitter
        let twitterItem = NSMenuItem(title: "Twitter", action: #selector(openTwitter), keyEquivalent: "")
        twitterItem.target = self
        twitterItem.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)
        statusMenu.addItem(twitterItem)

        // 4. 收取邮件
        let mailItem = NSMenuItem(title: "收取邮件", action: #selector(openGmail), keyEquivalent: "")
        mailItem.target = self
        mailItem.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        statusMenu.addItem(mailItem)

        statusMenu.addItem(NSMenuItem.separator())

        // 4. 偏好设置
        let settingsItem = NSMenuItem(title: "偏好设置", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(NSMenuItem.separator())

        // 5. 退出
        let quitItem = NSMenuItem(title: "退出应用", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Status Item Click

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            showWindow()
            return
        }

        if event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async {
                self.statusItem.menu = nil
            }
        } else {
            toggleWindow()
        }
    }

    @objc func toggleWindow() {
        if let window = mainWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    // MARK: - Main Window

    @objc private func showWindow() {
        if mainWindow == nil {
            let contentView = ContentView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Omni"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OmniMainWindow")
            mainWindow = window
            appState.attachMainWindow(window)
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Service WebView Windows

    private func openServiceWindow(_ service: WebService) {
        // If window already exists, just show it
        if let window = serviceWindows[service.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create persistent WebView with cookie storage
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = UserAgentProfile.safari.userAgentString

        if let url = URL(string: service.url) {
            webView.load(URLRequest(url: url))
        }

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: service.width, height: service.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = service.title
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Omni_\(service.id)")

        // Add navigation toolbar
        window.toolbar = makeServiceToolbar(for: service, webView: webView)

        serviceWindows[service.id] = window
        serviceWebViews[service.id] = webView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeServiceToolbar(for service: WebService, webView: WKWebView) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ServiceToolbar_\(service.id)")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = ServiceToolbarDelegate.shared
        ServiceToolbarDelegate.shared.registerWebView(webView, for: service.id)
        return toolbar
    }

    // MARK: - Menu Actions

    @objc private func openVideoService(_ sender: NSMenuItem) {
        guard let serviceId = sender.representedObject as? String,
              let service = videoServices.first(where: { $0.id == serviceId }) else { return }
        openServiceWindow(service)
    }

    @objc private func openGmail() {
        openServiceWindow(gmailService)
    }

    @objc private func openTwitter() {
        openTwitterServiceWindow()
    }

    // MARK: - Twitter Service Window

    private var currentThemeIsDark: Bool {
        switch appState.appearanceMode {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func openTwitterServiceWindow() {
        let service = twitterService

        // If window already exists, just show it
        if let window = serviceWindows[service.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create config with CSS injection
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Inject CSS at document start (before render → no flash)
        let bootstrapJS = TwitterCSSInjector.buildBootstrapScript(isDark: currentThemeIsDark)
        let userScript = WKUserScript(source: bootstrapJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Chrome UA — Twitter degrades Safari WKWebView
        webView.customUserAgent = UserAgentProfile.chrome.userAgentString

        // Navigation delegate to re-inject CSS on SPA navigations
        let navDelegate = TwitterNavigationDelegate(isDark: currentThemeIsDark)
        webView.navigationDelegate = navDelegate
        twitterNavDelegate = navDelegate

        if let url = URL(string: service.url) {
            webView.load(URLRequest(url: url))
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: service.width, height: service.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = service.title
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Omni_\(service.id)")
        window.toolbar = makeServiceToolbar(for: service, webView: webView)

        serviceWindows[service.id] = window
        serviceWebViews[service.id] = webView
        twitterWebView = webView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func syncTwitterTheme() {
        guard let webView = twitterWebView else { return }
        let isDark = currentThemeIsDark
        twitterNavDelegate?.isDark = isDark
        let js = TwitterCSSInjector.buildRuntimeUpdateScript(isDark: isDark)
        webView.evaluateJavaScript(js)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Omni 偏好设置"
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global HotKey

    private func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x41474149) // "AGAI"
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { (_, _, refcon) -> OSStatus in
            guard let refcon = refcon else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.toggleWindow()
            }
            return noErr
        }, 1, &eventType, refcon, &hotKeyHandlerRef)

        let hotKeyStatus = RegisterEventHotKey(
            appState.hotkeyKeyCode,
            appState.hotkeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if handlerStatus != noErr || hotKeyStatus != noErr {
            NSLog("Failed to register Omni global hotkey. handlerStatus=%d hotKeyStatus=%d", handlerStatus, hotKeyStatus)
        }
    }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func reregisterGlobalHotKey() {
        unregisterGlobalHotKey()
        registerGlobalHotKey()
    }
}

// MARK: - Service Toolbar Delegate

final class ServiceToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = ServiceToolbarDelegate()
    private var webViews: [String: WKWebView] = [:]

    func registerWebView(_ webView: WKWebView, for serviceId: String) {
        webViews[serviceId] = webView
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("back"),
            NSToolbarItem.Identifier("forward"),
            .flexibleSpace,
            NSToolbarItem.Identifier("reload"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let serviceId = String(toolbar.identifier).replacingOccurrences(of: "ServiceToolbar_", with: "")

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier.rawValue {
        case "back":
            item.label = "后退"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            item.action = #selector(goBack(_:))
            item.target = self
            item.tag = serviceId.hashValue
        case "forward":
            item.label = "前进"
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            item.action = #selector(goForward(_:))
            item.target = self
            item.tag = serviceId.hashValue
        case "reload":
            item.label = "刷新"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.action = #selector(reload(_:))
            item.target = self
            item.tag = serviceId.hashValue
        default:
            return nil
        }

        return item
    }

    private func findWebView(for tag: Int) -> WKWebView? {
        return webViews.first(where: { $0.key.hashValue == tag })?.value
    }

    @objc func goBack(_ sender: NSToolbarItem) {
        findWebView(for: sender.tag)?.goBack()
    }

    @objc func goForward(_ sender: NSToolbarItem) {
        findWebView(for: sender.tag)?.goForward()
    }

    @objc func reload(_ sender: NSToolbarItem) {
        findWebView(for: sender.tag)?.reload()
    }
}

// MARK: - Twitter Navigation Delegate

final class TwitterNavigationDelegate: NSObject, WKNavigationDelegate {
    var isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Re-inject CSS after full page navigations (not SPA pushState)
        let js = TwitterCSSInjector.buildBootstrapScript(isDark: isDark)
        webView.evaluateJavaScript(js)
    }
}
