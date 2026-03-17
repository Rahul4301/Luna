import Foundation
/// Routes parsed LLM responses to deterministic browser actions.
/// 
/// Per AGENTS.md: Model output is a proposal. The app decides what can happen.
/// This router performs deterministic mapping only; no LLM calls.
/// Per SRS F4: Actions are allowlisted and executed exactly once.
final class CommandRouter {
    
    /// Parses JSON data into an LLMResponse.
    /// Returns nil if decoding fails (fail closed per AGENTS.md).
    func parseLLMResponse(_ data: Data) -> LLMResponse? {
        let decoder = JSONDecoder()
        return try? decoder.decode(LLMResponse.self, from: data)
    }
    
    /// Executes a browser action by mapping it to TabManager calls.
    /// Per AGENTS.md: Fail closed - if payload missing required fields, return error.
    /// Returns success message or error.
    func execute(action: BrowserAction, tabManager: TabManager) -> Result<String, Error> {
        switch action.type {
        case .new_tab:
            // new_tab requires a URL; normalize scheme if missing.
            guard let urlString = action.payload?["url"] else {
                return .failure(CommandRouterError.missingPayloadField("url"))
            }
            let normalizedString = normalizeURLString(urlString)
            guard let url = URL(string: normalizedString) else {
                return .failure(CommandRouterError.invalidURL(urlString))
            }
            let tabId = tabManager.newTab(url: url)
            return .success("Created new tab: \(tabId.uuidString) -> \(normalizedString)")
            
        case .navigate:
            guard let urlString = action.payload?["url"] else {
                return .failure(CommandRouterError.missingPayloadField("url"))
            }
            let normalizedString = normalizeURLString(urlString)
            guard let url = URL(string: normalizedString) else {
                return .failure(CommandRouterError.invalidURL(urlString))
            }
            tabManager.navigateCurrentTab(to: url)
            return .success("Navigated to: \(normalizedString)")
            
        case .switch_tab:
            // For MVP, switch_tab by index is not supported due to lack of stable tab ordering.
            guard let indexString = action.payload?["index"] else {
                return .failure(CommandRouterError.missingPayloadField("index"))
            }
            guard Int(indexString) != nil else {
                return .failure(CommandRouterError.invalidIndex(indexString))
            }
            return .failure(CommandRouterError.unsupportedOperation("switch_tab by index is not supported in this MVP"))
            
        case .close_tab:
            if let indexString = action.payload?["index"] {
                // Optional index support is not implemented in MVP; fail closed.
                guard Int(indexString) != nil else {
                    return .failure(CommandRouterError.invalidIndex(indexString))
                }
                return .failure(CommandRouterError.unsupportedOperation("close_tab by index is not supported in this MVP"))
            } else {
                // Close current tab if no index specified
                guard let currentId = tabManager.currentTab else {
                    return .failure(CommandRouterError.noCurrentTab)
                }
                tabManager.closeTab(currentId)
                return .success("Closed current tab: \(currentId.uuidString)")
            }
        }
    }
}

/// Errors that can occur during action execution.
enum CommandRouterError: LocalizedError {
    case missingPayloadField(String)
    case invalidURL(String)
    case invalidTabID(String)
    case invalidIndex(String)
    case noCurrentTab
    case unsupportedOperation(String)
    
    var errorDescription: String? {
        switch self {
        case .missingPayloadField(let field):
            return "Missing required payload field: \(field)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidTabID(let id):
            return "Invalid tab ID: \(id)"
        case .invalidIndex(let index):
            return "Invalid tab index: \(index)"
        case .noCurrentTab:
            return "No current tab to close"
        case .unsupportedOperation(let description):
            return "Unsupported operation: \(description)"
        }
    }
}

/// Normalizes a URL string by prefixing https:// if no scheme is present.
private func normalizeURLString(_ urlString: String) -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.contains("://") {
        return trimmed
    } else {
        return "https://" + trimmed
    }
}
