// Luma MVP - Start Page (New Tab)
import SwiftUI

/// Dark grey glassmorphism tint (opaque but see-through; matches dark reference).
let startPageGlassTint = Color(red: 0.06, green: 0.06, blue: 0.07)
let startPageGlassTintOpacity: Double = 0.82

/// Start page view (DIA-style: dark grey glassmorphism, single centered search bar)
/// Shown when tab URL is nil or "about:blank"
struct StartPageView: View {
    @Binding var addressBarText: String
    let historySuggestions: [(display: String, url: URL)]
    let searchSuggestions: [String]
    let onSelectHistory: (URL) -> Void
    let onSelectSearch: (String) -> Void
    let onSubmit: () -> Void
    let onChangeAddressBar: (String) -> Void

    @FocusState private var searchFocused: Bool

    private let textMuted = Color.white.opacity(0.5)

    /// Show suggestions when we have history or search suggestions and bar has text.
    private var showSuggestions: Bool {
        let hasAny = !historySuggestions.isEmpty || !searchSuggestions.isEmpty
        return searchFocused && hasAny && !addressBarText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search bar only (stationary in center); suggestions shown in overlay below so bar never moves.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textMuted)
            TextField("Search the web...", text: $addressBarText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.95))
                .focused($searchFocused)
                .onSubmit { onSubmit() }
                .onChange(of: addressBarText) { _, newValue in
                    onChangeAddressBar(newValue)
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(searchFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.06), value: searchFocused)
    }

    var body: some View {
        ZStack {
            // Dark grey glassmorphism: blur first (see-through), then dark tint (opaque, less transparent)
            ZStack {
                VisualEffectView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    state: .active
                )
                startPageGlassTint.opacity(startPageGlassTintOpacity)
            }
            .ignoresSafeArea()

            // Search bar fixed in center; suggestions in overlay directly below the bar (history first, then search)
            searchBar
                .overlay(alignment: .top) {
                    if showSuggestions {
                        VStack(spacing: 0) {
                            Spacer().frame(height: 48 + 8) // bar height + gap
                            StartPageSuggestionsList(
                                historyItems: historySuggestions,
                                searchPhrases: searchSuggestions,
                                onSelectHistory: onSelectHistory,
                                onSelectSearch: onSelectSearch
                            )
                        }
                        .frame(maxWidth: 560)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { searchFocused = true }
    }
}

/// Suggestions list for start page (history items + search phrases)
struct StartPageSuggestionsList: View {
    let historyItems: [(display: String, url: URL)]
    let searchPhrases: [String]
    let onSelectHistory: (URL) -> Void
    let onSelectSearch: (String) -> Void
    @State private var hoveredId: String? = nil
    private let textMuted = Color.white.opacity(0.5)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(historyItems.enumerated()), id: \.offset) { index, item in
                let id = "h-\(index)"
                Button(action: { onSelectHistory(item.url) }) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.display)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                            if let host = item.url.host, host != item.display {
                                Text(host)
                                    .font(.system(size: 11))
                                    .foregroundColor(textMuted)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 560, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hoveredId == id ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .onHover { hovering in hoveredId = hovering ? id : nil }
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(searchPhrases.enumerated()), id: \.offset) { index, phrase in
                let id = "s-\(index)"
                Button(action: { onSelectSearch(phrase) }) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                            .frame(width: 20)
                        Text(phrase)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 560, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hoveredId == id ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .onHover { hovering in hoveredId = hovering ? id : nil }
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(startPageGlassTint.opacity(startPageGlassTintOpacity * 0.7))
        )
    }
}
