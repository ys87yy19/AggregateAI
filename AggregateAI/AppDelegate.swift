import Cocoa
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?

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
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出应用 (Exit)", action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = nil // Don't set menu by default (left click opens window)

        // Store menu for right-click
        statusItem.button?.tag = 0
        objc_setAssociatedObject(self, "statusMenu", menu, .OBJC_ASSOCIATION_RETAIN)

        // Register global hotkey: Cmd+Shift+A
        registerGlobalHotKey()
    }

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            showWindow()
            return
        }

        if event.type == .rightMouseUp {
            // Right click: show menu
            if let menu = objc_getAssociatedObject(self, "statusMenu") as? NSMenu {
                statusItem.menu = menu
                statusItem.button?.performClick(nil)
                // Reset menu to nil so left click works normally next time
                DispatchQueue.main.async {
                    self.statusItem.menu = nil
                }
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
            let contentView = ContentView()
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
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, refcon) -> OSStatus in
            guard let refcon = refcon else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.toggleWindow()
            }
            return noErr
        }, 1, &eventType, refcon, nil)

        // Cmd+Shift+A: keycode 0 = 'A'
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
