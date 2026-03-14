import Foundation
import Combine

// MARK: - AppContainer

/// Dependency-injection root.
///
/// `AppContainer` is the single place where all service singletons are created.
/// Pass the container (or individual services) down to ViewModels; never reach
/// for global singletons inside views or ViewModels.
///
/// Usage:
/// ```swift
/// let container = AppContainer()
/// let vm = MultiAIViewModel(settings: container.settingsService,
///                           api: container.apiService)
/// ```
@MainActor
final class AppContainer: ObservableObject {

    // MARK: - Services

    /// Manages all app settings (UserDefaults + Keychain).
    let settingsService: SettingsService

    /// Performs OpenAI-compatible HTTP requests (models, streaming, aggregation).
    let apiService: APIService

    /// Low-level Keychain read/write operations.
    let keychainService: KeychainService

    // MARK: - Init

    init() {
        // Order matters: KeychainService has no dependencies; SettingsService
        // depends on KeychainService; APIService is stateless.
        self.keychainService = KeychainService.shared
        self.settingsService = SettingsService(keychain: KeychainService.shared)
        self.apiService = APIService.shared
    }
}
