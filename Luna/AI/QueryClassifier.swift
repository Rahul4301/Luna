// Luma — Query intent classifier for SmartSearch
// Default: AI chat. Only routes to search for clear navigational/lookup intent.
import Foundation

enum QueryIntent {
    case search
    case ai
}

struct QueryClassifier {

    // All O(1) lookups via Set/frozen collections — no async, no network.

    private static let tlds: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "co", "app", "dev",
        "me", "tv", "ai", "xyz", "info", "biz", "us", "uk", "ca",
        "de", "fr", "jp", "au", "in", "br", "it", "nl", "ru", "ch"
    ]

    private static let navigationSites: Set<String> = [
        "youtube", "google", "gmail", "reddit", "twitter",
        "facebook", "instagram", "tiktok", "linkedin", "github",
        "netflix", "spotify", "amazon", "ebay", "wikipedia",
        "twitch", "discord", "slack", "notion", "figma",
        "stackoverflow", "hacker news", "craigslist", "yelp",
        "maps", "drive", "docs", "outlook", "yahoo", "bing",
        "chatgpt", "claude", "pinterest", "tumblr", "whatsapp",
        "telegram", "x.com", "threads"
    ]

    private static let searchTriggers: Set<String> = [
        "near me", "price of", "cost of", "how much is",
        "hours of", "address of", "phone number",
        "weather in", "weather for", "weather tomorrow", "weather today",
        "flights to", "flights from", "hotels in",
        "scores today", "scores last night", "scores yesterday",
        "stock price", "stock market",
        "recipe for", "calories in",
        "release date", "where to buy",
        "best restaurants", "best pizza", "best coffee",
        "directions to", "map of",
        "download", "login", "log in", "sign in", "sign up"
    ]

    /// Lightning-fast, pure-heuristic classification. No network calls.
    /// Philosophy: default to AI. Only return .search when the intent is
    /// clearly navigational or a factual lookup.
    static func classify(_ query: String) -> QueryIntent {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .ai }

        // 1. URL-like input → search (will be resolved to navigation)
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return .search
        }
        if lower.contains(".") && !lower.contains(" ") {
            let parts = lower.components(separatedBy: ".")
            if let last = parts.last {
                let tld = last.components(separatedBy: "/").first ?? last
                if tlds.contains(tld) { return .search }
            }
        }

        // 2. Single word that is a known site → search
        if words.count == 1, navigationSites.contains(words[0]) {
            return .search
        }
        // Two-word known compounds (e.g. "hacker news")
        if words.count == 2, navigationSites.contains(lower) {
            return .search
        }

        // 3. Contains a known search trigger phrase → search
        for trigger in searchTriggers {
            if lower.contains(trigger) { return .search }
        }

        // Everything else → AI chat
        return .ai
    }
}
