// Luma MVP - History Management System
import Foundation
import Combine

/// Manages persistent storage of browsing history and chat conversations.
/// Stores data on disk in Application Support directory.
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    
    @Published private(set) var historyEvents: [HistoryEvent] = []
    @Published private(set) var conversationSummaries: [UUID: [ConversationSummary]] = [:] // tabId -> summaries
    
    private let fileManager = FileManager.default
    private let historyFileName = "browsing_history.json"
    private let summariesFileName = "conversation_summaries.json"
    
    private var historyFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let lumaDir = appSupport.appendingPathComponent("Luma", isDirectory: true)
        try? fileManager.createDirectory(at: lumaDir, withIntermediateDirectories: true)
        return lumaDir.appendingPathComponent(historyFileName)
    }
    
    private var summariesFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let lumaDir = appSupport.appendingPathComponent("Luma", isDirectory: true)
        return lumaDir.appendingPathComponent(summariesFileName)
    }
    
    private init() {
        loadHistory()
        loadSummaries()
    }
    
    // MARK: - Page Visit Tracking
    
    func recordPageVisit(url: URL, title: String) {
        let event = HistoryEvent(
            timestamp: Date(),
            type: .pageVisit,
            url: url.absoluteString,
            pageTitle: title
        )
        historyEvents.insert(event, at: 0)
        saveHistory()
    }
    
    // MARK: - Chat History Management
    
    /// Records a chat session. sessionId = tabId so all chats in the same tab belong to one session until the tab is closed.
    func recordChatSession(tabId: UUID, messages: [ChatMessage], summary: String? = nil) {
        let event = HistoryEvent(
            timestamp: Date(),
            type: .chatConversation,
            sessionId: tabId,
            chatMessages: messages,
            conversationSummary: summary
        )
        historyEvents.insert(event, at: 0)
        saveHistory()
    }
    
    func addConversationSummary(tabId: UUID, summary: ConversationSummary) {
        if conversationSummaries[tabId] == nil {
            conversationSummaries[tabId] = []
        }
        conversationSummaries[tabId]?.append(summary)
        saveSummaries()
    }
    
    func getSummariesForTab(tabId: UUID) -> [ConversationSummary] {
        return conversationSummaries[tabId] ?? []
    }
    
    // MARK: - Clear History
    
    enum ClearTimeframe {
        case today
        case thisWeek
        case last30Days
        case allTime
    }
    
    func clearHistory(timeframe: ClearTimeframe) {
        let now = Date()
        let calendar = Calendar.current
        
        let cutoffDate: Date
        switch timeframe {
        case .today:
            cutoffDate = calendar.startOfDay(for: now)
        case .thisWeek:
            cutoffDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .last30Days:
            cutoffDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .allTime:
            historyEvents.removeAll()
            conversationSummaries.removeAll()
            saveHistory()
            saveSummaries()
            return
        }
        
        historyEvents.removeAll { $0.timestamp >= cutoffDate }
        saveHistory()
    }
    
    func clearIndividualEvent(_ eventId: UUID) {
        historyEvents.removeAll { $0.id == eventId }
        saveHistory()
    }
    
    func clearChatHistoryForTab(_ tabId: UUID) {
        conversationSummaries.removeValue(forKey: tabId)
        saveSummaries()
    }
    
    // MARK: - Persistence
    
    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(historyEvents)
            try data.write(to: historyFileURL)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
    
    private func loadHistory() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard fileManager.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let events = try? decoder.decode([HistoryEvent].self, from: data) else {
            return
        }
        
        historyEvents = events
    }
    
    private func saveSummaries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(conversationSummaries)
            try data.write(to: summariesFileURL)
        } catch {
            print("Failed to save summaries: \(error)")
        }
    }
    
    private func loadSummaries() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard fileManager.fileExists(atPath: summariesFileURL.path),
              let data = try? Data(contentsOf: summariesFileURL),
              let summaries = try? decoder.decode([UUID: [ConversationSummary]].self, from: data) else {
            return
        }
        
        conversationSummaries = summaries
    }
    
    // MARK: - Query Methods
    
    func getHistory(for timeframe: ClearTimeframe) -> [HistoryEvent] {
        let now = Date()
        let calendar = Calendar.current
        
        let cutoffDate: Date
        switch timeframe {
        case .today:
            cutoffDate = calendar.startOfDay(for: now)
        case .thisWeek:
            cutoffDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .last30Days:
            cutoffDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .allTime:
            return historyEvents
        }
        
        return historyEvents.filter { $0.timestamp >= cutoffDate }
    }
    
    func searchHistory(query: String) -> [HistoryEvent] {
        let lowercased = query.lowercased()
        return historyEvents.filter { event in
            if let title = event.pageTitle, title.lowercased().contains(lowercased) {
                return true
            }
            if let url = event.url, url.lowercased().contains(lowercased) {
                return true
            }
            if let messages = event.chatMessages {
                return messages.contains { $0.text.lowercased().contains(lowercased) }
            }
            return false
        }
    }

    // MARK: - URL bar autocomplete (history-based suggestions)

    /// Returns address-bar suggestions from browsing history. Matches query against URL and page title.
    /// Ranking: prefer (1) URLs with a meaningful path (e.g. discord.com/channels/@me over discord.com) so
    /// signed-in / frequently used pages surface first; (2) higher visit count; (3) more recent.
    /// display = page title if present, else host or URL.
    func urlAutocompleteSuggestions(prefix: String, limit: Int = 5) -> [(display: String, url: URL)] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        // Group by URL: (visitCount, mostRecentTimestamp, display from most recent title)
        struct URLInfo {
            var visitCount: Int
            var mostRecent: Date
            var display: String
            var url: URL
            var hasMeaningfulPath: Bool
        }
        var byURL: [String: URLInfo] = [:]
        for event in historyEvents where event.type == .pageVisit {
            guard let urlString = event.url, let url = URL(string: urlString) else { continue }
            let urlMatch = urlString.lowercased().contains(trimmed)
            let titleMatch = event.pageTitle?.lowercased().contains(trimmed) ?? false
            if !urlMatch && !titleMatch { continue }

            let path = url.path
            let hasPath = path.count > 1 && path != "/"

            if let existing = byURL[urlString] {
                let isNewer = event.timestamp > existing.mostRecent
                let display = (!(event.pageTitle?.isEmpty ?? true)) ? (event.pageTitle ?? "") : (url.host ?? url.absoluteString)
                byURL[urlString] = URLInfo(
                    visitCount: existing.visitCount + 1,
                    mostRecent: isNewer ? event.timestamp : existing.mostRecent,
                    display: isNewer ? display : existing.display,
                    url: url,
                    hasMeaningfulPath: hasPath || existing.hasMeaningfulPath
                )
            } else {
                let display = (!(event.pageTitle?.isEmpty ?? true)) ? (event.pageTitle ?? "") : (url.host ?? url.absoluteString)
                byURL[urlString] = URLInfo(
                    visitCount: 1,
                    mostRecent: event.timestamp,
                    display: display,
                    url: url,
                    hasMeaningfulPath: hasPath
                )
            }
        }

        let sorted = byURL.values.sorted { a, b in
            // Prefer URLs with path (e.g. /channels/@me, /courses) over bare domain
            if a.hasMeaningfulPath != b.hasMeaningfulPath { return a.hasMeaningfulPath }
            // Then by visit count (more visits = more likely where user wants to go)
            if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
            // Then by recency
            return a.mostRecent > b.mostRecent
        }
        return Array(sorted.prefix(limit).map { ($0.display, $0.url) })
    }
}
