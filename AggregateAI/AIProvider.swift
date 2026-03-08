import Foundation
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable {
    case all
    case gemini
    case grok
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .chatgpt: return "ChatGPT"
        }
    }

    var iconName: String {
        switch self {
        case .all: return "square.grid.3x1"
        case .gemini: return "sparkles"
        case .grok: return "bolt.fill"
        case .chatgpt: return "bubble.left.fill"
        }
    }

    var url: URL? {
        switch self {
        case .all: return nil
        case .gemini: return URL(string: "https://gemini.google.com")
        case .grok: return URL(string: "https://grok.com")
        case .chatgpt: return URL(string: "https://chatgpt.com")
        }
    }

    var color: Color {
        switch self {
        case .all: return .primary
        case .gemini: return .blue
        case .grok: return .white
        case .chatgpt: return .green
        }
    }

    /// All actual AI providers (excluding .all)
    static var providers: [AIProvider] {
        return [.gemini, .grok, .chatgpt]
    }

    var requiresLoadedWebAppForSending: Bool {
        switch self {
        case .gemini, .chatgpt:
            return true
        case .all, .grok:
            return false
        }
    }
}

enum UserAgentProfile: String {
    case safari
    case chrome

    var userAgentString: String {
        switch self {
        case .safari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        }
    }
}

struct UserAgentSettings: Equatable {
    var defaultProfile: UserAgentProfile = .safari
    var providerOverrides: [AIProvider: UserAgentProfile] = [:]

    static let recommended = UserAgentSettings(
        defaultProfile: .safari,
        providerOverrides: [:]
    )

    func profile(for provider: AIProvider) -> UserAgentProfile {
        providerOverrides[provider] ?? defaultProfile
    }
}

// MARK: - Layout Mode

enum LayoutMode: String, CaseIterable {
    case single = "1"
    case twoColumn = "2"
    case threeColumn = "3"

    var columns: Int {
        switch self {
        case .single: return 1
        case .twoColumn: return 2
        case .threeColumn: return 3
        }
    }

    var iconName: String {
        switch self {
        case .single: return "square"
        case .twoColumn: return "rectangle.split.2x1"
        case .threeColumn: return "rectangle.split.3x1"
        }
    }

    var label: String {
        switch self {
        case .single: return "1 Column"
        case .twoColumn: return "2 Columns"
        case .threeColumn: return "3 Columns"
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
