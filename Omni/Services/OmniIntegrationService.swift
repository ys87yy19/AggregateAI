import Foundation

struct DockerCommandResult {
    let command: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    var succeeded: Bool {
        exitCode == 0
    }
}

final class DockerCommandBridge {
    static let shared = DockerCommandBridge()

    private init() {}

    private final class FinishState: @unchecked Sendable {
        let lock = NSLock()
        var didFinish = false
    }

    enum BridgeError: LocalizedError {
        case executableNotFound(String)
        case nonZeroExit(code: Int32, output: String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let name):
                return "未找到可执行命令: \(name)"
            case .nonZeroExit(let code, let output):
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "命令执行失败（退出码 \(code)）" : trimmed
            case .timeout:
                return "命令执行超时"
            }
        }
    }

    func runDocker(arguments: [String], timeout: TimeInterval = 15) async throws -> DockerCommandResult {
        try await run(executableCandidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "docker"], arguments: arguments, timeout: timeout)
    }

    func validateDockerCLI() async throws -> DockerCommandResult {
        try await runDocker(arguments: ["ps"], timeout: 10)
    }

    func validateDockerCompose(composeFilePath: String, profile: String?) async throws -> DockerCommandResult {
        var arguments = ["compose", "-f", composeFilePath]
        if let profile, !profile.isEmpty {
            arguments += ["--profile", profile]
        }
        arguments.append("ps")
        return try await runDocker(arguments: arguments, timeout: 15)
    }

    private func run(
        executableCandidates: [String],
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> DockerCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let queue = DispatchQueue.global(qos: .userInitiated)
            let finishState = FinishState()

            let finishOnce: @Sendable (Result<DockerCommandResult, Error>) -> Void = { result in
                finishState.lock.lock()
                defer { finishState.lock.unlock() }
                guard !finishState.didFinish else { return }
                finishState.didFinish = true
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            var environment = ProcessInfo.processInfo.environment
            let normalizedPath = normalizedExecutableSearchPath(existingPath: environment["PATH"] ?? "")
            environment["PATH"] = normalizedPath
            process.environment = environment

            guard let executableURL = resolveExecutableURL(candidates: executableCandidates, searchPath: normalizedPath) else {
                continuation.resume(throwing: BridgeError.executableNotFound(executableCandidates.last ?? "docker"))
                return
            }

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    finishOnce(.failure(BridgeError.timeout))
                }
            }

            process.terminationHandler = { process in
                timeoutWorkItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let result = DockerCommandResult(
                    command: [executableURL.path] + arguments,
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                )

                if result.succeeded {
                    finishOnce(.success(result))
                } else {
                    finishOnce(.failure(BridgeError.nonZeroExit(code: result.exitCode, output: result.combinedOutput)))
                }
            }

            do {
                try process.run()
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
            } catch {
                timeoutWorkItem.cancel()
                finishOnce(.failure(error))
            }
        }
    }

    private func resolveExecutableURL(candidates: [String], searchPath: String) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates {
            if candidate.contains("/") {
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
                continue
            }

            if let resolved = resolveInPath(named: candidate, searchPath: searchPath, fileManager: fileManager) {
                return resolved
            }
        }
        return nil
    }

    private func resolveInPath(named executable: String, searchPath: String, fileManager: FileManager) -> URL? {
        for directory in searchPath.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func normalizedExecutableSearchPath(existingPath: String) -> String {
        let requiredPrefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return (requiredPrefixes + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }
}

// Type definitions for ManagedDockerModuleAction, ManagedDockerModuleDefinition,
// ManagedDockerModuleRuntime, SharedAISettingsSnapshot, ModuleSyncStatus,
// ModuleUpdateDefinition, ModuleUpdateStatus, OmniModuleDefinition, and
// OmniModuleRegistry are now in Core/Models/SharedAISettings.swift.
// The registry no longer contains hardcoded user paths; module install paths
// default to "" and are configured by the user at runtime.

@MainActor
final class DockerModuleService {
    static let shared = DockerModuleService()

    private let bridge = DockerCommandBridge.shared
    private let fileManager = FileManager.default

    private init() {}

    enum ServiceError: LocalizedError {
        case missingInstallPath
        case missingComposeFile
        case invalidDashboardURL
        case invalidAPIURL

        var errorDescription: String? {
            switch self {
            case .missingInstallPath:
                return "未找到模块安装目录"
            case .missingComposeFile:
                return "未找到 docker-compose.yml"
            case .invalidDashboardURL:
                return "Dashboard 地址无效"
            case .invalidAPIURL:
                return "API 地址无效"
            }
        }
    }

    func validateDockerAvailability(for module: OmniModuleDefinition? = nil) async -> ManagedDockerModuleRuntime {
        do {
            _ = try await bridge.validateDockerCLI()
            if let managed = module?.managedDocker {
                _ = try await bridge.validateDockerCompose(composeFilePath: managed.composeFilePath, profile: managed.composeProfile)
            }
            return ManagedDockerModuleRuntime(
                state: .stopped,
                isInstalled: true,
                isRunning: false,
                isHealthy: false,
                dockerAvailable: true,
                containerName: module?.managedDocker?.dockerProjectName,
                lastAction: .validate,
                lastError: nil,
                details: "Docker CLI 可用",
                logsPreview: nil,
                updatedAt: Date()
            )
        } catch {
            return ManagedDockerModuleRuntime(
                state: .dockerUnavailable,
                isInstalled: false,
                isRunning: false,
                isHealthy: false,
                dockerAvailable: false,
                containerName: module?.managedDocker?.dockerProjectName,
                lastAction: .validate,
                lastError: error.localizedDescription,
                details: "Docker CLI 不可用",
                logsPreview: nil,
                updatedAt: Date()
            )
        }
    }

    func detectInstallation(module: OmniModuleDefinition) -> ManagedDockerModuleRuntime {
        guard let managed = module.managedDocker else {
            return ManagedDockerModuleRuntime(
                state: .failure,
                isInstalled: false,
                isRunning: false,
                isHealthy: false,
                dockerAvailable: false,
                containerName: nil,
                lastAction: .validate,
                lastError: "模块未声明 Docker 管理能力",
                details: "模块不支持受管 Docker",
                logsPreview: nil,
                updatedAt: Date()
            )
        }

        let installExists = fileManager.fileExists(atPath: managed.installPath)
        let composeExists = fileManager.fileExists(atPath: managed.composeFilePath)

        if !installExists {
            return ManagedDockerModuleRuntime(
                state: .notInstalled,
                isInstalled: false,
                isRunning: false,
                isHealthy: false,
                dockerAvailable: true,
                containerName: managed.dockerProjectName,
                lastAction: .validate,
                lastError: ServiceError.missingInstallPath.localizedDescription,
                details: "未找到安装目录",
                logsPreview: nil,
                updatedAt: Date()
            )
        }

        if !composeExists {
            return ManagedDockerModuleRuntime(
                state: .notInstalled,
                isInstalled: false,
                isRunning: false,
                isHealthy: false,
                dockerAvailable: true,
                containerName: managed.dockerProjectName,
                lastAction: .validate,
                lastError: ServiceError.missingComposeFile.localizedDescription,
                details: "缺少 compose 文件",
                logsPreview: nil,
                updatedAt: Date()
            )
        }

        return ManagedDockerModuleRuntime(
            state: .stopped,
            isInstalled: true,
            isRunning: false,
            isHealthy: false,
            dockerAvailable: true,
            containerName: managed.dockerProjectName,
            lastAction: .validate,
            lastError: nil,
            details: "检测到本地安装",
            logsPreview: nil,
            updatedAt: Date()
        )
    }

    func status(module: OmniModuleDefinition) async -> ManagedDockerModuleRuntime {
        let detected = detectInstallation(module: module)
        guard detected.isInstalled, let managed = module.managedDocker else {
            return detected
        }

        do {
            _ = try await bridge.validateDockerCLI()
        } catch {
            return runtime(module: managed, state: .dockerUnavailable, details: "Docker CLI 不可用", error: error.localizedDescription, action: .validate)
        }

        do {
            let result = try await bridge.validateDockerCompose(composeFilePath: managed.composeFilePath, profile: managed.composeProfile)
            let parsed = parseComposeStatus(result.stdout + "\n" + result.stderr, serviceName: managed.composeServiceName)

            let runtimeState: ManagedDockerModuleRuntime.State
            if parsed.running {
                runtimeState = parsed.healthy ? .running : .unhealthy
            } else {
                runtimeState = .stopped
            }

            return ManagedDockerModuleRuntime(
                state: runtimeState,
                isInstalled: true,
                isRunning: parsed.running,
                isHealthy: parsed.healthy,
                dockerAvailable: true,
                containerName: parsed.containerName ?? managed.dockerProjectName,
                lastAction: .validate,
                lastError: nil,
                details: parsed.details,
                logsPreview: nil,
                updatedAt: Date()
            )
        } catch {
            return runtime(module: managed, state: .failure, details: "读取容器状态失败", error: error.localizedDescription, action: .validate)
        }
    }

    func up(module: OmniModuleDefinition) async -> ManagedDockerModuleRuntime {
        await runLifecycle(module: module, action: .start, dockerArguments: composeArguments(for: module, command: ["up", "-d"]))
    }

    func down(module: OmniModuleDefinition) async -> ManagedDockerModuleRuntime {
        await runLifecycle(module: module, action: .stop, dockerArguments: composeArguments(for: module, command: ["down"]))
    }

    func restart(module: OmniModuleDefinition) async -> ManagedDockerModuleRuntime {
        await runLifecycle(module: module, action: .restart, dockerArguments: composeArguments(for: module, command: ["restart"]))
    }

    func logs(module: OmniModuleDefinition, tail: Int = 200) async -> ManagedDockerModuleRuntime {
        guard let managed = module.managedDocker else {
            return ManagedDockerModuleRuntime.idle(for: .logs)
        }

        let detected = detectInstallation(module: module)
        guard detected.isInstalled else { return detected }

        do {
            let result = try await bridge.runDocker(arguments: composeArguments(for: module, command: ["logs", "--tail", String(tail)]), timeout: 20)
            let baseStatus = await status(module: module)
            return ManagedDockerModuleRuntime(
                state: baseStatus.state,
                isInstalled: baseStatus.isInstalled,
                isRunning: baseStatus.isRunning,
                isHealthy: baseStatus.isHealthy,
                dockerAvailable: baseStatus.dockerAvailable,
                containerName: baseStatus.containerName ?? managed.dockerProjectName,
                lastAction: .logs,
                lastError: nil,
                details: baseStatus.details,
                logsPreview: result.combinedOutput,
                updatedAt: Date()
            )
        } catch {
            return runtime(module: managed, state: .failure, details: "读取日志失败", error: error.localizedDescription, action: .logs)
        }
    }

    func probeHealth(module: OmniModuleDefinition) async -> ManagedDockerModuleRuntime {
        guard let managed = module.managedDocker else {
            return ManagedDockerModuleRuntime.idle(for: .probe)
        }

        let baseStatus = await status(module: module)
        guard baseStatus.isRunning else {
            return ManagedDockerModuleRuntime(
                state: baseStatus.state,
                isInstalled: baseStatus.isInstalled,
                isRunning: baseStatus.isRunning,
                isHealthy: false,
                dockerAvailable: baseStatus.dockerAvailable,
                containerName: baseStatus.containerName,
                lastAction: .probe,
                lastError: baseStatus.lastError,
                details: baseStatus.details,
                logsPreview: nil,
                updatedAt: Date()
            )
        }

        guard let apiURL = URL(string: managed.apiBaseURL) else {
            return runtime(module: managed, state: .failure, details: "API 地址无效", error: ServiceError.invalidAPIURL.localizedDescription, action: .probe)
        }

        let probeURL = apiURL.deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let healthy = (200..<500).contains(httpStatus)
            return ManagedDockerModuleRuntime(
                state: healthy ? .running : .unhealthy,
                isInstalled: true,
                isRunning: true,
                isHealthy: healthy,
                dockerAvailable: true,
                containerName: baseStatus.containerName,
                lastAction: .probe,
                lastError: healthy ? nil : "HTTP \(httpStatus)",
                details: healthy ? "API 可访问" : "API 返回异常状态码",
                logsPreview: nil,
                updatedAt: Date()
            )
        } catch {
            return runtime(module: managed, state: .unhealthy, details: "API 不可访问", error: error.localizedDescription, action: .probe)
        }
    }

    private func runLifecycle(
        module: OmniModuleDefinition,
        action: ManagedDockerModuleAction,
        dockerArguments: [String]
    ) async -> ManagedDockerModuleRuntime {
        guard let managed = module.managedDocker else {
            return ManagedDockerModuleRuntime.idle(for: action)
        }

        let detected = detectInstallation(module: module)
        guard detected.isInstalled else { return detected }

        do {
            _ = try await bridge.runDocker(arguments: dockerArguments, timeout: 60)
            let refreshed = await status(module: module)
            return ManagedDockerModuleRuntime(
                state: refreshed.state,
                isInstalled: refreshed.isInstalled,
                isRunning: refreshed.isRunning,
                isHealthy: refreshed.isHealthy,
                dockerAvailable: refreshed.dockerAvailable,
                containerName: refreshed.containerName,
                lastAction: action,
                lastError: nil,
                details: refreshed.details,
                logsPreview: nil,
                updatedAt: Date()
            )
        } catch {
            return runtime(module: managed, state: .failure, details: lifecycleFailureMessage(for: action), error: error.localizedDescription, action: action)
        }
    }

    private func composeArguments(for module: OmniModuleDefinition, command: [String]) -> [String] {
        guard let managed = module.managedDocker else { return [] }
        var arguments = ["compose", "-f", managed.composeFilePath]
        if !managed.composeProfile.isEmpty {
            arguments += ["--profile", managed.composeProfile]
        }
        arguments.append(contentsOf: command)
        return arguments
    }

    private func runtime(
        module: ManagedDockerModuleDefinition,
        state: ManagedDockerModuleRuntime.State,
        details: String,
        error: String?,
        action: ManagedDockerModuleAction
    ) -> ManagedDockerModuleRuntime {
        ManagedDockerModuleRuntime(
            state: state,
            isInstalled: fileManager.fileExists(atPath: module.installPath) && fileManager.fileExists(atPath: module.composeFilePath),
            isRunning: state == .running || state == .unhealthy,
            isHealthy: state == .running,
            dockerAvailable: state != .dockerUnavailable,
            containerName: module.dockerProjectName,
            lastAction: action,
            lastError: error,
            details: details,
            logsPreview: nil,
            updatedAt: Date()
        )
    }

    private func lifecycleFailureMessage(for action: ManagedDockerModuleAction) -> String {
        switch action {
        case .validate:
            return "Docker 校验失败"
        case .start:
            return "启动失败"
        case .stop:
            return "停止失败"
        case .restart:
            return "重启失败"
        case .logs:
            return "日志读取失败"
        case .probe:
            return "健康检查失败"
        }
    }

    private func parseComposeStatus(_ output: String, serviceName: String) -> (running: Bool, healthy: Bool, containerName: String?, details: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, false, nil, "未找到容器状态")
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let serviceLine = lines.first(where: { line in
            line.localizedCaseInsensitiveContains(serviceName)
        }) ?? lines.first(where: { line in
            let lowered = line.lowercased()
            return lowered.contains("running")
                || lowered.contains("up")
                || lowered.contains("unhealthy")
                || lowered.contains("exited")
        })

        guard let serviceLine else {
            return (false, false, nil, "Compose 未返回服务状态")
        }

        let lowered = serviceLine.lowercased()
        let healthy = lowered.contains("healthy")
        let running = lowered.contains("running") || lowered.contains("up") || healthy
        let containerName = serviceLine.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        let details = serviceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return (running, healthy, containerName, details)
    }
}

@MainActor
final class ModuleUpdateService {
    static let shared = ModuleUpdateService()

    private init() {}

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    enum UpdateError: LocalizedError {
        case unsupportedModule
        case unsupported
        case invalidInstallPath
        case missingVersionFile(String)
        case invalidRepositoryURL
        case invalidResponse
        case httpError(Int)
        case releaseNotFound
        case shellFailed(String)
        case shellTimeout(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModule:
                return "该模块暂不支持更新检查"
            case .unsupported:
                return "该模块未配置自动更新策略"
            case .invalidInstallPath:
                return "未找到模块安装目录"
            case .missingVersionFile(let path):
                return "未找到版本文件：\(path)"
            case .invalidRepositoryURL:
                return "GitHub 仓库地址无效"
            case .invalidResponse:
                return "GitHub 返回了无效响应"
            case .httpError(let statusCode):
                return "GitHub 请求失败（HTTP \(statusCode)）"
            case .releaseNotFound:
                return "GitHub 暂无可用版本信息"
            case .shellFailed(let output):
                return "命令执行失败：\(output)"
            case .shellTimeout(let cmd):
                return "命令超时：\(cmd)"
            }
        }
    }

    func checkUpdates(for modules: [OmniModuleDefinition]) async -> [String: ModuleUpdateStatus] {
        var statuses: [String: ModuleUpdateStatus] = [:]
        for module in modules {
            statuses[module.id] = await checkUpdate(for: module)
        }
        return statuses
    }

    func checkUpdate(for module: OmniModuleDefinition) async -> ModuleUpdateStatus {
        guard let definition = module.updateDefinition else {
            return ModuleUpdateStatus(
                state: .unsupported,
                message: "该模块暂不支持更新检查",
                currentVersion: nil,
                latestVersion: nil,
                releaseURL: nil,
                releaseTitle: nil,
                publishedAt: nil,
                checkedAt: Date()
            )
        }

        do {
            let currentVersion = try readCurrentVersion(for: module, definition: definition)
            let release = try await fetchLatestRelease(for: definition)
            let latestVersion = normalizeVersion(release.version)
            let checkedAt = Date()

            guard let currentVersion else {
                return ModuleUpdateStatus(
                    state: .unknownCurrentVersion,
                    message: "已发现线上版本 \(latestVersion)，但当前本地版本未知",
                    currentVersion: nil,
                    latestVersion: latestVersion,
                    releaseURL: release.htmlURL,
                    releaseTitle: release.name,
                    publishedAt: release.publishedAt,
                    checkedAt: checkedAt
                )
            }

            if isRemoteVersion(latestVersion, newerThan: currentVersion) {
                return ModuleUpdateStatus(
                    state: .updateAvailable,
                    message: "检测到新版本：\(latestVersion)",
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    releaseURL: release.htmlURL,
                    releaseTitle: release.name,
                    publishedAt: release.publishedAt,
                    checkedAt: checkedAt
                )
            }

            return ModuleUpdateStatus(
                state: .upToDate,
                message: "当前已是最新版本",
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: release.htmlURL,
                releaseTitle: release.name,
                publishedAt: release.publishedAt,
                checkedAt: checkedAt
            )
        } catch {
            return ModuleUpdateStatus(
                state: .failure,
                message: error.localizedDescription,
                currentVersion: try? readCurrentVersion(for: module, definition: definition),
                latestVersion: nil,
                releaseURL: definition.releasePageURL,
                releaseTitle: nil,
                publishedAt: nil,
                checkedAt: Date()
            )
        }
    }

    private func readCurrentVersion(for module: OmniModuleDefinition, definition: ModuleUpdateDefinition) throws -> String? {
        let installPath = definition.installPathOverride
            ?? module.managedDocker?.installPath

        guard let installPath else {
            throw UpdateError.invalidInstallPath
        }

        switch definition.localVersionSource {
        case .packageJSON(let relativePath):
            let filePath = URL(fileURLWithPath: installPath).appendingPathComponent(relativePath).path
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw UpdateError.missingVersionFile(filePath)
            }
            // Use /bin/cat via subprocess to read outside the sandbox
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [filePath]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else {
                throw UpdateError.missingVersionFile(filePath)
            }
            let packageFile = try JSONDecoder().decode(PackageFile.self, from: data)
            let version = normalizeVersion(packageFile.version)
            return version.isEmpty ? nil : version
        }
    }

    private func fetchLatestRelease(for definition: ModuleUpdateDefinition) async throws -> GitHubRelease {
        let latestReleaseURLString = "https://api.github.com/repos/\(definition.repositorySlug)/releases/latest"
        guard let latestReleaseURL = URL(string: latestReleaseURLString) else {
            throw UpdateError.invalidRepositoryURL
        }

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OmniApp", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let release = try decoder.decode(GitHubRelease.self, from: data)
            let version = normalizeVersion(release.version)
            guard !version.isEmpty else {
                throw UpdateError.releaseNotFound
            }
            return release
        case 404:
            return try await fetchLatestTag(for: definition)
        default:
            throw UpdateError.httpError(httpResponse.statusCode)
        }
    }

    private func fetchLatestTag(for definition: ModuleUpdateDefinition) async throws -> GitHubRelease {
        let tagsURLString = "https://api.github.com/repos/\(definition.repositorySlug)/tags?per_page=1"
        guard let tagsURL = URL(string: tagsURLString) else {
            throw UpdateError.invalidRepositoryURL
        }

        var request = URLRequest(url: tagsURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OmniApp", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpError(httpResponse.statusCode)
        }

        let tags = try JSONDecoder().decode([GitHubTag].self, from: data)
        guard let tag = tags.first else {
            throw UpdateError.releaseNotFound
        }

        return GitHubRelease(
            version: tag.name,
            name: tag.name,
            htmlURL: "https://github.com/\(definition.repositorySlug)/releases/tag/\(tag.name)",
            publishedAt: nil
        )
    }

    private func normalizeVersion(_ version: String?) -> String {
        guard let version else { return "" }
        return version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private func isRemoteVersion(_ remote: String, newerThan current: String) -> Bool {
        let remoteComponents = numericComponents(for: remote)
        let currentComponents = numericComponents(for: current)
        let maxCount = max(remoteComponents.count, currentComponents.count)

        for index in 0..<maxCount {
            let remoteValue = index < remoteComponents.count ? remoteComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if remoteValue != currentValue {
                return remoteValue > currentValue
            }
        }

        return remote.compare(current, options: .numeric) == .orderedDescending
    }

    private func numericComponents(for version: String) -> [Int] {
        version
            .split(whereSeparator: { !($0.isNumber || $0 == ".") })
            .first?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []
    }

    // MARK: - Perform Update

    /// Execute the update in-place with resilient fallbacks for local-dev workspaces.
    /// Returns a human-readable log of all steps.
    func performUpdate(for module: OmniModuleDefinition) async throws -> String {
        guard let definition = module.updateDefinition else {
            throw UpdateError.unsupported
        }
        guard let strategy = definition.updateStrategy else {
            throw UpdateError.unsupported
        }
        guard let installPath = definition.installPathOverride ?? module.managedDocker?.installPath else {
            throw UpdateError.invalidInstallPath
        }

        var log = ""
        var skippedGitPull = false
        var degradedMode = false

        // Step 1: git pull (skip safely if repo is dirty or non-git)
        if try await isGitRepository(at: installPath) {
            if try await gitHasDirtyWorkingTree(at: installPath) {
                skippedGitPull = true
                log += "⚠️ 跳过 git pull：检测到未提交改动，避免覆盖本地工作区\n"
            } else {
                log += "▶ git pull --ff-only\n"
                let gitResult = try await shell("/usr/bin/git", args: ["-C", installPath, "pull", "--ff-only"], timeout: 60)
                log += gitResult + "\n"
            }
        } else {
            skippedGitPull = true
            log += "⚠️ 跳过 git pull：目录不是 Git 仓库\n"
        }

        switch strategy {

        case .dockerCompose(let composeFilePath, let profile):
            // Step 2: docker compose pull (fetch new images)
            log += "▶ docker compose pull\n"
            let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            var pullArgs = ["compose", "-f", composeFilePath]
            if !trimmedProfile.isEmpty {
                pullArgs += ["--profile", trimmedProfile]
            }
            pullArgs.append("pull")
            var shouldBuild = skippedGitPull
            do {
                let pullResult = try await shell(resolveDocker(), args: pullArgs, timeout: 300)
                if !pullResult.isEmpty {
                    log += pullResult + "\n"
                }
            } catch {
                if shouldFallbackToComposeBuild(for: error) {
                    shouldBuild = true
                    log += "⚠️ pull 失败，回退为本地 build：\(error.localizedDescription)\n"
                } else {
                    throw error
                }
            }

            if shouldBuild {
                log += "▶ docker compose build\n"
                var buildArgs = ["compose", "-f", composeFilePath]
                if !trimmedProfile.isEmpty {
                    buildArgs += ["--profile", trimmedProfile]
                }
                buildArgs.append("build")

                do {
                    let buildResult = try await shellWithRetry(
                        resolveDocker(),
                        args: buildArgs,
                        timeout: 900,
                        maxAttempts: 3,
                        baseDelaySeconds: 3
                    ) { error in
                        self.isTransientDockerRegistryFailure(error)
                    }
                    if !buildResult.isEmpty {
                        log += buildResult + "\n"
                    }
                } catch {
                    if isTransientDockerRegistryFailure(error) {
                        degradedMode = true
                        log += "⚠️ docker compose build 重试后仍失败，降级为使用现有镜像继续 up：\(error.localizedDescription)\n"
                    } else {
                        throw error
                    }
                }
            }

            // Step 3: docker compose up -d (recreate containers)
            log += "▶ docker compose up -d\n"
            var upArgs = ["compose", "-f", composeFilePath]
            if !trimmedProfile.isEmpty {
                upArgs += ["--profile", trimmedProfile]
            }
            upArgs += ["up", "-d", "--remove-orphans"]
            let upResult = try await shell(resolveDocker(), args: upArgs, timeout: 120)
            log += upResult + "\n"

        case .nodeProcess(_, let pm2Name):
            // Step 2: npm install
            log += "▶ npm install\n"
            let npm = resolveExecutable(candidates: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "npm"])
            let npmResult = try await shell(npm, args: ["install", "--prefix", installPath], timeout: 120)
            log += npmResult + "\n"

            // Step 3: restart via pm2 if available
            if let pm2Name {
                if let pm2 = resolveExecutableIfPresent(candidates: ["/opt/homebrew/bin/pm2", "/usr/local/bin/pm2", "pm2"]) {
                    log += "▶ pm2 restart \(pm2Name)\n"
                    let pm2Result = try await shell(pm2, args: ["restart", pm2Name], timeout: 30)
                    log += pm2Result + "\n"
                } else {
                    log += "⚠️ 未检测到 pm2，已跳过自动重启，请手动重启服务\n"
                }
            }
        }

        if degradedMode {
            log += "✅ 更新流程完成（降级模式）"
        } else {
            log += "✅ 更新完成"
        }
        return log
    }

    // MARK: - Shell helpers

    private final class OnceState: @unchecked Sendable {
        let lock = NSLock()
        var done = false
    }

    private func shell(_ executable: String, args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = normalizedExecutableSearchPath(existingPath: env["PATH"] ?? "")
            process.environment = env

            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + args
            }

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err

            let didFinish = OnceState()

            let finish: (Result<String, Error>) -> Void = { result in
                didFinish.lock.lock()
                defer { didFinish.lock.unlock() }
                guard !didFinish.done else { return }
                didFinish.done = true
                continuation.resume(with: result)
            }

            // Timeout watchdog on a background queue
            let timeoutItem = DispatchWorkItem {
                process.terminate()
                finish(.failure(UpdateError.shellTimeout(executable)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [outStr, errStr].filter { !$0.isEmpty }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    finish(.success(combined))
                } else {
                    finish(.failure(UpdateError.shellFailed(combined)))
                }
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                finish(.failure(error))
            }
        }
    }

    private func shellWithRetry(
        _ executable: String,
        args: [String],
        timeout: TimeInterval,
        maxAttempts: Int,
        baseDelaySeconds: UInt64,
        shouldRetry: (Error) -> Bool
    ) async throws -> String {
        let attempts = max(1, maxAttempts)
        var delaySeconds = baseDelaySeconds

        for attempt in 1...attempts {
            do {
                return try await shell(executable, args: args, timeout: timeout)
            } catch {
                let isLast = attempt == attempts
                if isLast || !shouldRetry(error) {
                    throw error
                }

                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                delaySeconds *= 2
            }
        }

        throw UpdateError.shellFailed("未知错误")
    }

    private func resolveDocker() -> String {
        resolveExecutable(candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "docker"])
    }

    private func resolveExecutableIfPresent(candidates: [String]) -> String? {
        let fileManager = FileManager.default
        let searchPath = normalizedExecutableSearchPath(existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "")

        for candidate in candidates {
            if candidate.contains("/") {
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
                continue
            }

            if let resolved = resolveInPath(named: candidate, searchPath: searchPath, fileManager: fileManager) {
                return resolved.path
            }
        }

        return nil
    }

    private func resolveExecutable(candidates: [String]) -> String {
        if let resolved = resolveExecutableIfPresent(candidates: candidates) {
            return resolved
        }

        if let fallback = candidates.last {
            return fallback
        }
        return "sh"
    }

    private func isGitRepository(at path: String) async throws -> Bool {
        do {
            _ = try await shell("/usr/bin/git", args: ["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: 10)
            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("not a git repository") {
                return false
            }
            throw error
        }
    }

    private func gitHasDirtyWorkingTree(at path: String) async throws -> Bool {
        let status = try await shell("/usr/bin/git", args: ["-C", path, "status", "--porcelain"], timeout: 15)
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldFallbackToComposeBuild(for error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("must be built from source")
            || message.contains("pull access denied")
            || message.contains("repository does not exist")
            || message.contains("requested access to the resource is denied")
    }

    private func isTransientDockerRegistryFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("service unavailable")
            || message.contains("tls handshake timeout")
            || message.contains("i/o timeout")
            || message.contains("connection reset")
            || message.contains("temporarily unavailable")
            || message.contains("failed to fetch anonymous token")
    }

    private func resolveInPath(named executable: String, searchPath: String, fileManager: FileManager) -> URL? {
        for directory in searchPath.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func normalizedExecutableSearchPath(existingPath: String) -> String {
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return (prefixes + [existingPath]).filter { !$0.isEmpty }.joined(separator: ":")
    }
}

private struct PackageFile: Decodable {
    let version: String?
}

private struct GitHubRelease: Decodable {
    let tagName: String?
    let name: String?
    let htmlURL: String?
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    init(version: String, name: String?, htmlURL: String?, publishedAt: Date?) {
        self.tagName = version
        self.name = name
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
    }

    var version: String {
        tagName ?? name ?? ""
    }
}

private struct GitHubTag: Decodable {
    let name: String
}

@MainActor
final class OmniIntegrationService {
    static let shared = OmniIntegrationService()

    private init() {}

    enum SyncError: LocalizedError {
        case invalidBaseURL
        case incompleteSharedConfig
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "模块地址无效"
            case .incompleteSharedConfig:
                return "统一 AI 配置不完整，请先设置 API 地址和模型"
            case .httpError(let code, let body):
                let message = body.isEmpty ? "HTTP \(code)" : body
                return "同步失败: \(message)"
            case .invalidResponse:
                return "模块返回了无效响应"
            }
        }
    }

    func syncAll(from appState: AppState) async -> [String: ModuleSyncStatus] {
        var statuses: [String: ModuleSyncStatus] = [:]

        for module in OmniModuleRegistry.integratedModules where module.syncAdapter != nil {
            statuses[module.id] = await sync(module, from: appState)
        }

        return statuses
    }

    func sync(_ module: OmniModuleDefinition, from appState: AppState) async -> ModuleSyncStatus {
        let snapshot = appState.sharedAISettingsSnapshot
        if module.syncAdapter == .siftly {
            guard !snapshot.normalizedEndpoint.isEmpty, !snapshot.normalizedModel.isEmpty else {
                return ModuleSyncStatus(
                    state: .failure,
                    message: SyncError.incompleteSharedConfig.localizedDescription,
                    updatedAt: Date()
                )
            }
        }

        do {
            switch module.syncAdapter {
            case .siftly:
                try await syncSiftly(module: module, snapshot: snapshot, baseURLOverride: appState.siftlyBaseURL)
            case .antigravity:
                try await syncAntigravity(
                    module: module,
                    snapshot: snapshot,
                    baseURLOverride: appState.antigravityBaseURL,
                    installPath: appState.antigravityInstallPath,
                    autoFixEnabled: appState.antigravityAutoFixEnabled
                )
            case .none:
                return ModuleSyncStatus(
                    state: .success,
                    message: "模块不需要同步",
                    updatedAt: Date()
                )
            }

            return ModuleSyncStatus(
                state: .success,
                message: "已同步统一 AI 配置",
                updatedAt: Date()
            )
        } catch {
            return ModuleSyncStatus(
                state: .failure,
                message: error.localizedDescription,
                updatedAt: Date()
            )
        }
    }

    func probe(_ module: OmniModuleDefinition, baseURLOverride: String? = nil) async -> ModuleSyncStatus {
        do {
            let baseURL = try resolvedBaseURL(for: module, override: baseURLOverride)
            let path = module.syncAdapter == .antigravity ? "api/runner/prefill" : "api/settings"
            let url = baseURL.appendingPathComponent(path)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw SyncError.httpError(httpResponse.statusCode, "")
            }

            return ModuleSyncStatus(state: .success, message: "模块在线", updatedAt: Date())
        } catch {
            return ModuleSyncStatus(state: .failure, message: error.localizedDescription, updatedAt: Date())
        }
    }

    private func syncSiftly(
        module: OmniModuleDefinition,
        snapshot: SharedAISettingsSnapshot,
        baseURLOverride: String
    ) async throws {
        let baseURL = try resolvedBaseURL(for: module, override: baseURLOverride)

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["provider": "openai"]
        )

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["openaiBaseUrl": snapshot.siftlyOpenAIBaseURL]
        )

        if !snapshot.normalizedApiKey.isEmpty {
            try await postJSON(
                to: baseURL.appendingPathComponent("api/settings"),
                body: ["openaiApiKey": snapshot.normalizedApiKey]
            )
        }

        try await postJSON(
            to: baseURL.appendingPathComponent("api/settings"),
            body: ["openaiModel": snapshot.siftlyOpenAIModel]
        )
    }

    private func syncAntigravity(
        module: OmniModuleDefinition,
        snapshot: SharedAISettingsSnapshot,
        baseURLOverride: String,
        installPath: String,
        autoFixEnabled: Bool
    ) async throws {
        let baseURL = try resolvedBaseURL(for: module, override: baseURLOverride)
        let moduleAddress = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? baseURL.absoluteString
            : baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        try await postJSON(
            to: baseURL.appendingPathComponent("api/runner/prefill"),
            body: [
                "moduleAddress": moduleAddress,
                "installPath": installPath.trimmingCharacters(in: .whitespacesAndNewlines),
                "autoFixEnabled": autoFixEnabled ? "true" : "false",
                "aiEndpoint": snapshot.normalizedEndpoint,
                "aiApiKey": snapshot.normalizedApiKey,
                "aiModel": snapshot.normalizedModel
            ]
        )
    }

    private func resolvedBaseURL(for module: OmniModuleDefinition, override: String?) throws -> URL {
        let candidate = (override?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? override
            : defaultBaseURL(for: module))
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw)
        else {
            throw SyncError.invalidBaseURL
        }
        return url
    }

    private func defaultBaseURL(for module: OmniModuleDefinition) -> String? {
        switch module.launchStyle {
        case .webApp(let url, _, _):
            return url
        }
    }

    private func postJSON(to url: URL, body: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpError(httpResponse.statusCode, bodyText)
        }
    }
}
