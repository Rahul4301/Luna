// Luma MVP - History Page (luma://history)
import SwiftUI

/// Displays browsing (URL) history only. Chat sessions are not shown.
/// Accessible via luma://history special URL.
struct HistoryPageView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    var onSelectURL: (URL) -> Void

    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var clearTimeframe: HistoryManager.ClearTimeframe = .allTime

    private let bgColor = Color(white: 0.11)
    private let textPrimary = Color(white: 0.9)
    private let textSecondary = Color(white: 0.6)
    private let accentColor = Color.blue

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE MMM d, yyyy"
        return f
    }()

    /// URL history only (page visits), optionally filtered by search.
    private var filteredEvents: [HistoryEvent] {
        let all = historyManager.getHistory(for: .allTime).filter { $0.type == .pageVisit }
        if searchQuery.isEmpty { return all }
        return historyManager.searchHistory(query: searchQuery).filter { $0.type == .pageVisit }
    }

    private var groupedByDate: [(date: Date, label: String, events: [HistoryEvent])] {
        let calendar = Calendar.current
        var grouped: [Date: [HistoryEvent]] = [:]
        for event in filteredEvents {
            let dateKey = calendar.startOfDay(for: event.timestamp)
            if grouped[dateKey] == nil { grouped[dateKey] = [] }
            grouped[dateKey]?.append(event)
        }
        return grouped.keys.sorted(by: >).compactMap { date in
            let events = (grouped[date] ?? []).sorted(by: { $0.timestamp > $1.timestamp })
            return (date: date, label: dateSectionLabel(date), events: events)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(accentColor)
                Text("History")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(textPrimary)
                Text("\(filteredEvents.count) sites")
                    .font(.system(size: 12))
                    .foregroundColor(textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    TextField("Search history...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .foregroundColor(textPrimary)
                        .frame(maxWidth: 200)
                    Menu {
                        Button("Clear Today") { clearTimeframe = .today; showClearConfirmation = true }
                        Button("Clear This Week") { clearTimeframe = .thisWeek; showClearConfirmation = true }
                        Button("Clear Last 30 Days") { clearTimeframe = .last30Days; showClearConfirmation = true }
                        Divider()
                        Button("Clear All History", role: .destructive) { clearTimeframe = .allTime; showClearConfirmation = true }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(bgColor)
            Divider().opacity(0.2)

            if filteredEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedByDate.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.label)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(textSecondary)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 20)
                                    .padding(.bottom, 8)
                                ForEach(group.events) { event in
                                    urlHistoryRow(event)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgColor)
        .alert("Clear History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                historyManager.clearHistory(timeframe: clearTimeframe)
            }
        } message: {
            Text(clearMessage(for: clearTimeframe))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(textSecondary.opacity(0.5))
            Text("No browsing history")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func urlHistoryRow(_ event: HistoryEvent) -> some View {
        let timeStr = Self.timeFormatter.string(from: event.timestamp)
        let urlString = event.url ?? ""
        let title = event.pageTitle ?? ""
        if let url = URL(string: urlString) {
            Button(action: { onSelectURL(url) }) {
                HStack(alignment: .center, spacing: 12) {
                    Text(timeStr)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textSecondary)
                        .frame(width: 52, alignment: .leading)
                    FaviconView(url: url)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        if !title.isEmpty {
                            Text(title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(urlString)
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.03))
        }
    }

    private func dateSectionLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let dayPart = Self.dayFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "Today - \(dayPart)"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday - \(dayPart)"
        } else {
            return dayPart
        }
    }

    private func clearMessage(for timeframe: HistoryManager.ClearTimeframe) -> String {
        switch timeframe {
        case .today: return "This will clear all history from today."
        case .thisWeek: return "This will clear all history from the past 7 days."
        case .last30Days: return "This will clear all history from the past 30 days."
        case .allTime: return "This will permanently delete all browsing history."
        }
    }
}
