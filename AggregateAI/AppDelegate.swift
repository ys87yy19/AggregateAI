import Cocoa
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var mainWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "AggregateAI")
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Build right-click menu
        let showWindowItem = NSMenuItem(title: "显示主窗口", action: #selector(showWindow), keyEquivalent: "")
        showWindowItem.target = self
        statusMenu.addItem(showWindowItem)

        let gmailItem = NSMenuItem(title: "Gmail 邮箱", action: #selector(openGmail), keyEquivalent: "")
        gmailItem.target = self
        statusMenu.addItem(gmailItem)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出应用 (Exit)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = nil // Don't set menu by default (left click opens window)

        // Register global hotkey: Cmd+Shift+A
        registerGlobalHotKey()

        // Auto show main window on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showWindow()
        }
    }

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            showWindow()
            return
        }

        if event.type == .rightMouseUp {
            // Right click: show menu
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            // Reset menu to nil so left click works normally next time
            DispatchQueue.main.async {
                self.statusItem.menu = nil
            }
        } else {
            // Left click: toggle window
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

    @objc private func showWindow() {
        if mainWindow == nil {
            let contentView = ContentView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AggregateAI"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AggregateAIMainWindow")
            mainWindow = window
            appState.attachMainWindow(window)
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    @objc private func openGmail() {
        if let url = URL(string: "https://mail.google.com") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global HotKey (Cmd+Shift+A)

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

        // Cmd+Shift+A: keycode 0 = 'A'
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if handlerStatus != noErr || hotKeyStatus != noErr {
            NSLog("Failed to register AggregateAI global hotkey. handlerStatus=%d hotKeyStatus=%d", handlerStatus, hotKeyStatus)
        }
    }
}
