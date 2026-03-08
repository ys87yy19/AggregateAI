# AggregateAI

`AggregateAI` 是一个 macOS 菜单栏应用，把 Gemini、Grok、ChatGPT 放进同一个窗口里，方便并排查看、快速切换和同步提问。

应用使用 `SwiftUI + AppKit + WKWebView` 实现，适合个人自用、对比多家 AI 回复，或者作为本地桌面聚合器继续扩展。

## 功能概览

- 菜单栏常驻，默认不占用 Dock
- 支持 `All / Gemini / Grok / ChatGPT` 四个标签
- 支持 `1 / 2 / 3` 栏布局切换
- 支持同步提问
- 支持窗口置顶
- 支持 `System / Light / Dark` 三种主题模式
- 登录状态持久化，关闭后无需反复登录
- 支持 `Cmd+Shift+A` 全局快捷键显示/隐藏主窗口

## 当前行为

### 同步提问

- 在 `All` 视图下，底部输入框会依次把同一个问题发送给全部 AI
- 在单个标签页下，只会发送给当前 AI
- 即使当前是 `1` 栏或 `2` 栏布局，`All` 模式也会预加载全部 provider，避免只给可见面板发送
- `Cmd+Return` 可直接发送

### 布局与窗口

- 顶部工具栏支持切换 `1 / 2 / 3` 栏布局
- `Pin` 按钮可将窗口切为浮动层级
- 左键点击菜单栏图标会切换主窗口显示状态
- 右键点击菜单栏图标会打开快捷菜单：
  - 显示主窗口
  - Gmail 邮箱
  - 退出应用

### 主题

- 应用窗口外壳跟随 `System / Light / Dark`
- Grok、ChatGPT 和 Gemini 面板会收到统一的主题提示
- Gemini 额外做了本地主题存储修正，避免和应用主题严重跑偏

说明：
第三方站点最终如何渲染，仍然取决于它们自己的前端逻辑，所以网页内主题同步属于“尽量保持一致”，不是完全可控。

## User-Agent 策略

当前三个 provider 默认都使用 Safari User-Agent：

| Provider | User-Agent |
|----------|------------|
| Gemini | Safari |
| Grok | Safari |
| ChatGPT | Safari |

这样做的目的是尽量保持站点渲染一致，减少因浏览器身份不同导致的主题、验证或页面结构差异。

## 技术实现

### 架构

- `AggregateAIApp.swift`
  - SwiftUI 应用入口
- `AppDelegate.swift`
  - 菜单栏图标、主窗口、全局快捷键、右键菜单
- `ContentView.swift`
  - 主界面状态、标签栏、布局切换、主题切换、同步输入栏
- `PersistentWebView.swift`
  - `WKWebView` 复用、登录态持久化、同步提问注入、主题同步
- `AIProvider.swift`
  - provider 枚举、布局模式、主题模式、User-Agent 配置

### WebView 管理

- 每个 AI provider 对应一个长期复用的 `WKWebView`
- 使用 `WKWebsiteDataStore.default()` 保留 Cookie 和站点数据
- 应用启动后会预加载所有 provider，减少首次发送时的空白或丢发问题

### 提问策略

| Provider | 方式 | 说明 |
|----------|------|------|
| Gemini | JavaScript 注入 | 定位输入框与发送按钮后自动发送 |
| Grok | URL 导航 | 通过 `https://grok.com/?q=...` 发起提问 |
| ChatGPT | JavaScript 注入 | 向输入框写入内容后触发发送 |

## 系统要求

- macOS 13.0 及以上
- Xcode 15 或更高版本

## 运行方式

### 使用 Xcode

```bash
open AggregateAI.xcodeproj
```

然后直接运行 `AggregateAI` scheme。

### 命令行构建

```bash
xcodebuild -project AggregateAI.xcodeproj -scheme AggregateAI -configuration Debug build
```

Debug 构建产物通常位于：

```bash
~/Library/Developer/Xcode/DerivedData/AggregateAI-*/Build/Products/Debug/AggregateAI.app
```

## 使用说明

1. 首次启动后，分别在 Gemini、Grok、ChatGPT 面板中登录账号
2. 点击顶部标签切换单个 AI 或 `All`
3. 在底部输入框中输入问题
4. 按 `Enter`、`Cmd+Return` 或点击发送按钮
5. 用顶部布局按钮切换并排查看方式

## 快捷键

| 快捷键 | 作用 |
|--------|------|
| `Cmd+Shift+A` | 显示 / 隐藏主窗口 |
| `Cmd+Return` | 发送当前问题 |

## 项目结构

```text
AggregateAI/
├── AggregateAI.xcodeproj/
├── AggregateAI/
│   ├── AggregateAIApp.swift
│   ├── AppDelegate.swift
│   ├── AIProvider.swift
│   ├── ContentView.swift
│   ├── PersistentWebView.swift
│   ├── AggregateAI.entitlements
│   └── Assets.xcassets/
└── README.md
```

## 已知限制

- 本项目依赖第三方网页结构，页面改版后，自动发送逻辑可能失效
- Grok 通过 URL 发问，在部分网络环境或服务端策略下可能失败
- Gemini 的主题同步做了额外兼容处理，但仍受站点自身实现影响
- 当前没有自动化测试，主要依赖手工验证

## 适合继续扩展的方向

- 增加 provider 配置页
- 增加每个 provider 的独立刷新 / 重登控制
- 加入日志面板，方便排查页面注入失败
- 为同步提问增加队列状态和错误提示
- 增加测试 target，覆盖核心状态流和基本构建检查

## 许可证

仅供个人学习和研究使用。
