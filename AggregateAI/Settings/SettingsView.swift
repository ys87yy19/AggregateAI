import SwiftUI
import Carbon.HIToolbox

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab(appState: appState)
                .tabItem { Label("通用", systemImage: "gear") }

            NotificationSettingsTab(appState: appState)
                .tabItem { Label("通知", systemImage: "bell") }

            ClipboardSettingsTab(appState: appState)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }

            ObsidianSettingsTab(appState: appState)
                .tabItem { Label("Obsidian", systemImage: "tray.and.arrow.down") }
        }
        .frame(width: 480, height: 340)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("外观") {
                Picker("默认主题", selection: $appState.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("默认布局", selection: $appState.layoutMode) {
                    ForEach(LayoutMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("全局快捷键") {
                HStack {
                    Text("切换窗口:")
                    Spacer()
                    HotkeyRecorderView(
                        keyCode: $appState.hotkeyKeyCode,
                        modifiers: $appState.hotkeyModifiers
                    )
                    .frame(width: 200, height: 28)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notification Settings

struct NotificationSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("AI 回复通知") {
                Toggle("启用通知", isOn: $appState.notificationsEnabled)
                    .onChange(of: appState.notificationsEnabled) { enabled in
                        if enabled {
                            NotificationService.shared.requestPermission()
                        }
                    }

                Toggle("仅在窗口隐藏时通知", isOn: $appState.notifyOnlyWhenHidden)
                    .disabled(!appState.notificationsEnabled)
            }

            Section {
                Text("当 AI 完成回复时，会通过 macOS 通知提醒你。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard Settings

struct ClipboardSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("剪贴板监听") {
                Toggle("启用剪贴板监听", isOn: $appState.clipboardMonitorEnabled)
            }

            Section {
                Text("开启后，复制的文本会自动填入输入框。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Obsidian Settings

struct ObsidianSettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Obsidian Vault") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault 路径:")
                            .font(.body)
                        if appState.obsidianVaultPath.isEmpty {
                            Text("未设置")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(appState.obsidianVaultPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }

                HStack {
                    Button("选择文件夹...") {
                        ObsidianService.shared.chooseVaultFolder(appState: appState)
                    }

                    if !appState.obsidianVaultPath.isEmpty {
                        Button("清除") {
                            appState.obsidianVaultPath = ""
                            UserDefaults.standard.removeObject(forKey: SettingsKeys.obsidianVaultBookmark)
                        }
                        .foregroundColor(.red)
                    }
                }
            }

            Section {
                Text("保存的笔记会存放在 vault/AggregateAI/ 子目录中，格式为 Markdown。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
