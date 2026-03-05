# AggregateAI

一款 macOS 菜单栏应用，将 Gemini、Grok、ChatGPT 三大 AI 聚合在一个窗口中，支持同步提问、多栏布局、主题切换等功能。

## 功能特性

### 核心功能

- **三合一 AI 聚合** — 在一个窗口中同时使用 Gemini、Grok、ChatGPT
- **同步提问** — 底部输入栏输入问题，一键同时发送给所有 AI，对比不同 AI 的回答
- **菜单栏常驻** — 应用运行在菜单栏，不占用 Dock 栏位置，点击图标即可唤出
- **全局快捷键** — `Cmd+Shift+A` 随时唤出/隐藏窗口

### 界面功能

- **多栏布局切换** — 支持 1 栏 / 2 栏 / 3 栏自由切换
- **标签页切换** — 顶部标签栏可切换 All（全部）或单独查看某个 AI
- **窗口置顶** — 点击 Pin 按钮，窗口始终悬浮在最上层
- **主题切换** — 支持 System（跟随系统）/ Light / Dark 三种外观模式
- **面板刷新** — 每个 AI 面板标题栏有独立刷新按钮
- **可调节分栏** — 拖拽面板边界调整各 AI 的显示宽度
- **登录状态持久化** — 使用 WKWebsiteDataStore 保持 Cookie，无需重复登录

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Xcode 15.0 或更高版本
- Apple Silicon 或 Intel Mac

## 安装与构建

### 方式一：Xcode 打开

```bash
open /path/to/AggregateAI/AggregateAI.xcodeproj
```

然后按 `Cmd+R` 运行。

### 方式二：命令行构建

```bash
cd /path/to/AggregateAI
xcodebuild -project AggregateAI.xcodeproj -scheme AggregateAI -configuration Release build
```

构建产物在 `~/Library/Developer/Xcode/DerivedData/AggregateAI-*/Build/Products/Release/AggregateAI.app`

## 使用说明

### 基本操作

1. 启动应用后，菜单栏会出现一个大脑图标
2. 点击图标或按 `Cmd+Shift+A` 打开主窗口
3. 默认显示三栏布局，同时展示 Gemini、Grok、ChatGPT
4. 点击顶部标签可单独查看某个 AI

### 同步提问

1. 在底部输入栏输入你的问题
2. 按 `Enter` 或点击发送按钮
3. 在 "All" 视图下，问题会同时发送给所有 AI
4. 在单个标签视图下，问题只发送给当前 AI

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Shift+A` | 全局唤出/隐藏窗口 |
| `Cmd+Return` | 发送同步提问 |

### 工具栏按钮

| 按钮 | 功能 |
|------|------|
| All / Gemini / Grok / ChatGPT | 切换标签页 |
| 布局图标（1/2/3栏） | 切换多栏布局 |
| 太阳/月亮图标 | 切换主题（System/Light/Dark） |
| Pin 图标 | 窗口置顶开关 |

## 项目结构

```
AggregateAI/
├── AggregateAI.xcodeproj/       # Xcode 项目配置
│   └── project.pbxproj
└── AggregateAI/
    ├── AggregateAIApp.swift      # 应用入口，SwiftUI App 生命周期
    ├── AppDelegate.swift         # 菜单栏图标、窗口管理、全局快捷键注册
    ├── AIProvider.swift          # AI 提供商枚举、布局模式、外观模式定义
    ├── ContentView.swift         # 主界面：工具栏、标签页、多栏布局、同步输入栏
    ├── PersistentWebView.swift   # WebView 管理器：创建/复用 WKWebView，JS 注入同步提问
    ├── AggregateAI.entitlements  # 应用权限（沙盒、网络）
    └── Assets.xcassets/          # 图标资源
```

## 技术实现

### 架构

- **SwiftUI + AppKit 混合** — SwiftUI 构建 UI，AppKit 管理菜单栏和窗口
- **WKWebView** — 每个 AI 使用独立的 WKWebView 实例，通过 WebViewManager 单例管理
- **NSViewRepresentable** — 将 WKWebView 桥接到 SwiftUI

### 同步提问实现

不同 AI 采用不同的注入策略：

| AI | 方式 | 说明 |
|----|------|------|
| Gemini | JS 注入 | DataTransfer 模拟粘贴 + 按钮点击 |
| Grok | URL 导航 | 通过 `grok.com/?q=问题` 直接发起对话 |
| ChatGPT | JS 注入 | innerHTML 设值 + 发送按钮点击 |

各 AI 之间间隔 0.6 秒依次执行，避免冲突。

### User-Agent 策略

为避免兼容性问题，不同 AI 使用不同的 User-Agent：

| AI | User-Agent | 原因 |
|----|-----------|------|
| Gemini | Chrome UA | Safari UA 下回复异常 |
| Grok | Safari UA | Chrome UA 触发 Cloudflare 验证 |
| ChatGPT | Safari UA | Chrome UA 触发 Cloudflare 验证 |

## 已知问题

- Grok 在部分网络环境下可能出现"无法完成回复"，这是 Grok 服务端的限制，非应用问题
- 首次使用需要在各 AI 面板中分别登录账号
- 同步提问依赖各 AI 网页的 DOM 结构，网站更新后可能需要适配

## 许可证

本项目仅供个人学习使用。
