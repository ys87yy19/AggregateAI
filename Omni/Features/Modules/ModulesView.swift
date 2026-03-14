import SwiftUI

// MARK: - ModulesView

/// The modules dashboard: hero banner, metric cards, gateway status, and per-module panels.
struct ModulesView: View {
    @ObservedObject var viewModel: ModulesViewModel

    private var modules: [OmniModuleDefinition] {
        OmniModuleRegistry.integratedModules
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroSection

                if let notice = viewModel.moduleActionNotice {
                    ModuleNoticeBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                metricsRow

                HStack(alignment: .top, spacing: 18) {
                    gatewayCard
                    quickActionsCard
                }

                modulesPanelSection
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .animation(.easeInOut(duration: 0.25), value: viewModel.moduleActionNotice?.id)
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.18), Color.blue.opacity(0.08), Color.black.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text("模块首页")
                    .font(.system(size: 30, weight: .bold))
                Text("把本地工具放进同一个工作台里管理。AI 网关只配置一次，已接入的模块直接复用。")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ModuleActionButton(title: "打开偏好设置", icon: "slider.horizontal.3") {
                        viewModel.openSettings()
                    }
                    ModuleActionButton(title: "同步全部模块", icon: "arrow.triangle.2.circlepath") {
                        for module in modules where module.syncAdapter != nil {
                            viewModel.triggerModuleSync(module)
                        }
                    }
                }
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    // MARK: - Metrics

    private var healthyCount: Int {
        modules.filter { module in
            if module.managedDocker != nil {
                return viewModel.managedModuleRuntimes[module.id]?.state == .running
            }
            return viewModel.moduleSyncStatuses[module.id]?.state == .success
        }.count
    }

    private var issueCount: Int {
        modules.filter { module in
            if module.managedDocker != nil {
                if let state = viewModel.managedModuleRuntimes[module.id]?.state {
                    return state == .dockerUnavailable || state == .failure || state == .unhealthy
                }
                return false
            }
            return viewModel.moduleSyncStatuses[module.id]?.state == .failure
        }.count
    }

    private var updateAvailableCount: Int {
        modules.filter { viewModel.moduleUpdateStatuses[$0.id]?.state == .updateAvailable }.count
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            MetricCard(title: "已接入模块", value: "\(modules.count)", caption: "统一在 Omni 中管理", color: .blue)
            MetricCard(title: "同步正常", value: "\(healthyCount)", caption: "配置已连通", color: .green)
            MetricCard(title: "有更新", value: "\(updateAvailableCount)", caption: "GitHub 检测到新版本", color: .orange)
            MetricCard(title: "待处理", value: "\(issueCount)", caption: "需要检查模块连接", color: .red)
        }
    }

    // MARK: - Gateway card

    private var gatewayCard: some View {
        let snap = viewModel.settingsService.sharedAISnapshot
        let s = viewModel.settingsService.settings

        return VStack(alignment: .leading, spacing: 14) {
            Label("统一 AI 网关", systemImage: "network")
                .font(.system(size: 17, weight: .semibold))

            ModuleInfoRow(label: "来源", value: s.gatewaySource.displayName)
            ModuleInfoRow(label: "Endpoint", value: snap.normalizedEndpoint.isEmpty ? "未配置" : snap.normalizedEndpoint)
            ModuleInfoRow(label: "Model", value: snap.normalizedModel.isEmpty ? "未选择" : snap.normalizedModel)
            ModuleInfoRow(label: "API Key", value: snap.normalizedApiKey.isEmpty ? "未配置" : "已保存到钥匙串")
            ModuleInfoRow(label: "自动同步", value: s.siftlyAutoSyncEnabled ? "已开启" : "已关闭")

            if !snap.isConfigured {
                Label("还没完成网关配置，模块暂时不会自动继承 AI 能力。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .moduleCardStyle()
    }

    // MARK: - Quick actions card

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("快捷动作", systemImage: "bolt.fill")
                .font(.system(size: 17, weight: .semibold))

            ModuleActionButton(title: "同步全部模块", icon: "arrow.triangle.2.circlepath") {
                for module in modules where module.syncAdapter != nil {
                    viewModel.triggerModuleSync(module)
                }
            }

            ModuleActionButton(title: "检查模块连接", icon: "dot.radiowaves.left.and.right") {
                for module in modules {
                    if module.managedDocker != nil {
                        viewModel.probeManagedModule(module)
                    } else {
                        viewModel.probeModule(module)
                    }
                }
            }

            ModuleActionButton(title: "检查模块更新", icon: "arrow.down.circle") {
                viewModel.checkAllModuleUpdates()
            }
        }
        .padding(20)
        .frame(width: 250, alignment: .leading)
        .moduleCardStyle()
    }

    // MARK: - Module panels

    private var modulesPanelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模块面板")
                .font(.system(size: 18, weight: .semibold))

            ForEach(modules) { module in
                ModuleCard(viewModel: viewModel, module: module)
            }
        }
    }
}

// MARK: - ModuleCard

struct ModuleCard: View {
    @ObservedObject var viewModel: ModulesViewModel
    let module: OmniModuleDefinition

    private var syncStatus: ModuleSyncStatus {
        viewModel.moduleSyncStatuses[module.id] ?? .idle
    }
    private var runtime: ManagedDockerModuleRuntime? {
        viewModel.managedModuleRuntimes[module.id]
    }
    private var updateStatus: ModuleUpdateStatus? {
        viewModel.moduleUpdateStatuses[module.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .top) {
                moduleIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title).font(.system(size: 18, weight: .semibold))
                    Text(module.subtitle).font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                if let runtime {
                    DockerStatusBadge(runtime: runtime)
                } else {
                    SyncStatusBadge(status: syncStatus)
                }
            }

            if module.managedDocker != nil {
                dockerModuleDetails
            } else {
                regularModuleDetails
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
    }

    private var moduleIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 48, height: 48)
            Image(systemName: module.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.accentColor)
        }
    }

    // MARK: Docker module details

    private var dockerModuleDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let managed = module.managedDocker {
                ModuleInfoRow(label: "Dashboard", value: viewModel.baseURL(for: module))
                ModuleInfoRow(label: "API", value: module.id == OmniModuleRegistry.omniRoute.id
                              ? viewModel.settingsService.settings.omniRouteAPIURL
                              : managed.apiBaseURL)
                if !managed.installPath.isEmpty {
                    ModuleInfoRow(label: "安装目录", value: managed.installPath)
                }
                ModuleInfoRow(label: "运行状态", value: runtime?.details ?? "尚未检测")
                if let updatedAt = runtime?.updatedAt {
                    ModuleInfoRow(label: "最近状态", value: updatedAt.formatted(date: .omitted, time: .shortened))
                }
            }

            if let updateStatus {
                ModuleUpdateBanner(updateStatus: updateStatus)
            }

            // Primary actions
            FlowActionRow {
                ModuleActionButton(title: "打开 Dashboard", icon: "arrow.up.right.square") {
                    viewModel.openModule(module)
                }
                ModuleActionButton(title: "启动", icon: "play.fill") {
                    viewModel.startManagedModule(module)
                }
                ModuleActionButton(title: "停止", icon: "stop.fill") {
                    viewModel.stopManagedModule(module)
                }
                ModuleActionButton(title: "重启", icon: "arrow.clockwise") {
                    viewModel.restartManagedModule(module)
                }
                ModuleActionButton(title: "日志", icon: "doc.text.magnifyingglass") {
                    viewModel.fetchManagedModuleLogs(module)
                }
                ModuleActionButton(title: "设为默认网关", icon: "network") {
                    viewModel.setModuleAsDefaultGateway(module)
                }
            }

            if module.updateDefinition != nil {
                updateActions
            }
        }
    }

    // MARK: Regular module details

    private var regularModuleDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleInfoRow(label: "模块地址", value: viewModel.baseURL(for: module))
            ModuleInfoRow(label: "同步状态", value: syncStatus.message)
            if let updatedAt = syncStatus.updatedAt {
                ModuleInfoRow(label: "最近状态", value: updatedAt.formatted(date: .omitted, time: .shortened))
            }

            if let updateStatus {
                ModuleUpdateBanner(updateStatus: updateStatus)
            }

            FlowActionRow {
                ModuleActionButton(title: "打开", icon: "arrow.up.right.square") {
                    viewModel.openModule(module)
                }
                ModuleActionButton(title: "同步", icon: "arrow.triangle.2.circlepath") {
                    viewModel.triggerModuleSync(module)
                }
                ModuleActionButton(title: "测试", icon: "antenna.radiowaves.left.and.right") {
                    viewModel.probeModule(module)
                }
            }

            if module.updateDefinition != nil {
                updateActions
            }
        }
    }

    private var updateActions: some View {
        FlowActionRow {
            ModuleActionButton(title: "检查更新", icon: "arrow.down.circle") {
                viewModel.checkAllModuleUpdates()
            }
            if updateStatus?.state == .updateAvailable {
                ModuleActionButton(title: "立即更新", icon: "arrow.down.circle.fill") {
                    viewModel.updateModule(module)
                }
            }
            ModuleActionButton(title: "更新日志", icon: "text.document") {
                viewModel.openModuleReleasePage(module)
            }
        }
    }

    private var cardBorderColor: Color {
        if let runtime {
            switch runtime.state {
            case .dockerUnavailable, .failure: return Color.red.opacity(0.35)
            case .notInstalled:               return Color.white.opacity(0.06)
            case .stopped:                    return Color.orange.opacity(0.35)
            case .running:                    return Color.green.opacity(0.35)
            case .unhealthy:                  return Color.yellow.opacity(0.35)
            }
        }
        switch syncStatus.state {
        case .idle:    return Color.white.opacity(0.06)
        case .syncing: return Color.orange.opacity(0.35)
        case .success: return Color.green.opacity(0.35)
        case .failure: return Color.red.opacity(0.35)
        }
    }
}

// MARK: - Shared sub-components

struct MetricCard: View {
    let title: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            Text(value).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(caption).font(.caption).foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 1)
        )
    }
}

struct ModuleInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
    }
}

struct ModuleActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

/// Wraps action buttons into a horizontal scroll row.
struct FlowActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                content()
            }
        }
    }
}

struct SyncStatusBadge: View {
    let status: ModuleSyncStatus

    private var title: String {
        switch status.state {
        case .idle: return "未同步"
        case .syncing: return "同步中"
        case .success: return "已同步"
        case .failure: return "失败"
        }
    }
    private var color: Color {
        switch status.state {
        case .idle: return .secondary
        case .syncing: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct DockerStatusBadge: View {
    let runtime: ManagedDockerModuleRuntime

    private var title: String {
        switch runtime.state {
        case .dockerUnavailable: return "Docker 不可用"
        case .notInstalled:      return "未安装"
        case .stopped:           return "已停止"
        case .running:           return runtime.isHealthy ? "健康" : "运行中"
        case .unhealthy:         return "异常"
        case .failure:           return "失败"
        }
    }
    private var color: Color {
        switch runtime.state {
        case .dockerUnavailable, .failure: return .red
        case .notInstalled:                return .secondary
        case .stopped:                     return .orange
        case .running:                     return .green
        case .unhealthy:                   return .yellow
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct ModuleUpdateBanner: View {
    let updateStatus: ModuleUpdateStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName).foregroundColor(accentColor)
                Text(updateStatus.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)
                Spacer(minLength: 0)
            }
            if let v = updateStatus.currentVersion, !v.isEmpty {
                ModuleInfoRow(label: "当前版本", value: v)
            }
            if let v = updateStatus.latestVersion, !v.isEmpty {
                ModuleInfoRow(label: "最新版本", value: v)
            }
            if let t = updateStatus.checkedAt {
                ModuleInfoRow(label: "检查时间", value: t.formatted(date: .omitted, time: .shortened))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accentColor.opacity(0.18), lineWidth: 1))
    }

    private var iconName: String {
        switch updateStatus.state {
        case .idle:                   return "clock"
        case .checking:               return "arrow.triangle.2.circlepath"
        case .upToDate:               return "checkmark.seal.fill"
        case .updateAvailable:        return "arrow.down.circle.fill"
        case .unknownCurrentVersion:  return "questionmark.circle.fill"
        case .failure:                return "exclamationmark.triangle.fill"
        case .unsupported:            return "minus.circle"
        }
    }

    private var accentColor: Color {
        switch updateStatus.state {
        case .upToDate:                return .green
        case .updateAvailable,
             .unknownCurrentVersion:   return .orange
        case .failure:                 return .red
        case .checking:                return .blue
        case .idle, .unsupported:      return .secondary
        }
    }
}

struct ModuleNoticeBanner: View {
    let notice: ModulesViewModel.ModuleActionNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName).font(.system(size: 13, weight: .semibold))
            Text(notice.message).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(backgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(foregroundColor.opacity(0.18), lineWidth: 1))
    }

    private var iconName: String {
        switch notice.kind {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }
    private var foregroundColor: Color {
        switch notice.kind {
        case .info:    return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }
    private var backgroundColor: Color {
        switch notice.kind {
        case .info:    return Color.accentColor.opacity(0.10)
        case .success: return Color.green.opacity(0.10)
        case .failure: return Color.red.opacity(0.10)
        }
    }
}

// MARK: - View modifier helpers

private extension View {
    func moduleCardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
    }
}
