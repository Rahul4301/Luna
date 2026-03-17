// Luma MVP - AI provider selection
import Foundation

/// Supported AI backends for the side panel.
enum AIProvider: String, CaseIterable, Identifiable {
    case gemini = "gemini"
    case ollama = "ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini API (cloud)"
        case .ollama: return "Local / Ollama"
        }
    }
}

