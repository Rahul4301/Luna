// Luma — SmartSearch: full-viewport new tab page with intent classification
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

// MARK: - State machine

private enum SearchViewState: Equatable {
    case idle
    case aiChat
    case searching
}

// MARK: - Design tokens (matches start page / side panel glassmorphism)

private enum SmartTokens {
    static let textPrimary   = Color(white: 0.94)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary  = Color(white: 0.50)
    static let accent        = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let errorText     = Color(red: 0.95, green: 0.55, blue: 0.55)
    static let surfaceElevated = Color(white: 0.14)
    static let cornerRadius: CGFloat  = 14
    static let barMaxWidth: CGFloat   = 680
    static let chatMaxWidth: CGFloat  = 720
}

// MARK: - SmartSearchView

struct SmartSearchView: View {
    let gemini: GeminiClient
    let ollama: OllamaClient
    let tabManager: TabManager
    let webViewWrapper: WebViewWrapper
    var tabId: UUID?
    @Binding var messages: [ChatMessage]
    let onNavigate: (URL) -> Void

    @AppStorage("luma_ai_provider")    private var aiProviderRaw: String = AIProvider.gemini.rawValue
    @AppStorage("luma_ollama_base_url") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("luma_ollama_model")    private var ollamaModel: String = ""
    @AppStorage("luma_ai_panel_font_size") private var fontSizeRaw: Int = 13

    @State private var viewState: SearchViewState = .idle
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var isInputFocused: Bool

    @State private var hasGeneratedTitle: Bool = false
    @State private var searchBarOffset: CGFloat = 0
    @State private var previousInputLength: Int = 0
    @State private var currentIntent: QueryIntent = .ai
    @State private var streamingTask: Task<Void, Never>? = nil

    // Thinking steps
    @State private var thinkingSteps: [SmartThinkingStep] = []
    @State private var isThinking: Bool = false
    @State private var currentAITask: Task<Void, Never>? = nil

    // Suggestions
    @State private var searchSuggestions: [String] = []
    @State private var selectedSuggestionIndex: Int = -1
    @State private var suggestionDebounceTask: DispatchWorkItem? = nil
    @State private var suggestionKeyMonitor: Any? = nil

    // Find bar
    @State private var showFindBar: Bool = false
    @State private var findQuery: String = ""
    @FocusState private var isFindFocused: Bool

    // Context system
    @State private var attachedDocuments: [SmartAttachedDocument] = []
    @State private var documentPickerPresented: Bool = false
    @State private var documentError: String? = nil
    @State private var includedOtherTabIds: [UUID] = []
    @State private var otherTabContexts: [UUID: (title: String?, text: String?)] = [:]
    @State private var addTabsSheetPresented: Bool = false

    private var aiProvider: AIProvider { AIProvider(rawValue: aiProviderRaw) ?? .gemini }
    private var fontSize: CGFloat { CGFloat(fontSizeRaw) }

    var body: some View {
        ZStack {
            background

            switch viewState {
            case .idle:
                centeredBarLayout
            case .aiChat:
                chatLayout
            case .searching:
                EmptyView()
            }
        }
        .onAppear {
            if !messages.isEmpty {
                viewState = .aiChat
            }
            isInputFocused = true
            installSuggestionKeyMonitor()
        }
        .onDisappear {
            removeSuggestionKeyMonitor()
        }
        .sheet(isPresented: $addTabsSheetPresented) {
            SmartAddTabSheet(
                tabManager: tabManager,
                currentTabId: tabId,
                alreadyIncluded: Set(includedOtherTabIds),
                onAdd: { id in
                    if !includedOtherTabIds.contains(id) {
                        includedOtherTabIds.append(id)
                        loadTabContext(for: id)
                    }
                    if viewState == .idle {
                        enterChatWithContext()
                    }
                }
            )
        }
        .fileImporter(
            isPresented: $documentPickerPresented,
            allowedContentTypes: [UTType.pdf, .plainText, .utf8PlainText, .commaSeparatedText, .xml, .html],
            allowsMultipleSelection: true
        ) { result in
            documentError = nil
            switch result {
            case .success(let urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    addDocument(from: url)
                }
            case .failure(let error):
                documentError = error.localizedDescription
            }
        }
        .background(
            Button("") {
                withAnimation(.easeOut(duration: 0.15)) {
                    showFindBar.toggle()
                    if showFindBar { isFindFocused = true }
                    else { findQuery = "" }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        )
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
            startPageGlassTint.opacity(startPageGlassTintOpacity)
        }
        .ignoresSafeArea()
    }

    // MARK: - Centered bar (idle)

    private var centeredBarLayout: some View {
        GeometryReader { geo in
            let topOffset = geo.size.height * 0.38
            VStack(spacing: 0) {
                // Context chips above the bar
                if !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(includedOtherTabIds, id: \.self) { otherId in
                                SmartContextChip(
                                    label: otherTabLabel(tabId: otherId),
                                    icon: "square.stack.3d.up",
                                    onRemove: { removeIncludedOtherTab(id: otherId) }
                                )
                            }
                            ForEach(attachedDocuments) { doc in
                                SmartContextChip(
                                    label: doc.displayName,
                                    icon: doc.displayName.lowercased().hasSuffix(".pdf") ? "doc.fill" : "doc.text.fill",
                                    onRemove: { removeAttachedDocument(id: doc.id) }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: SmartTokens.barMaxWidth)
                    .padding(.bottom, 8)
                }

                unifiedSearchCard
                    .frame(maxWidth: SmartTokens.barMaxWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, topOffset + searchBarOffset)
            .frame(maxWidth: .infinity)
        }
        .transition(.opacity)
    }

    // MARK: - AI Chat layout

    private var chatLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                chatThread
                if showFindBar { findBar }
            }
            chatInputBar
        }
        .transition(.opacity)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SmartTokens.textTertiary)
            TextField("Find in conversation\u{2026}", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(SmartTokens.textPrimary)
                .focused($isFindFocused)
                .onSubmit { scrollToNextMatch() }
            Text(findMatchSummary)
                .font(.system(size: 11))
                .foregroundColor(SmartTokens.textTertiary)
                .layoutPriority(1)
            Button(action: { scrollToNextMatch() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SmartTokens.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: closeFindBar) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SmartTokens.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var findMatchSummary: String {
        guard !findQuery.isEmpty else { return "" }
        let lower = findQuery.lowercased()
        let count = messages.filter { $0.text.lowercased().contains(lower) }.count
        return count == 0 ? "No matches" : "\(count) match\(count == 1 ? "" : "es")"
    }

    @State private var findScrollTarget: UUID? = nil

    private func scrollToNextMatch() {
        guard !findQuery.isEmpty else { return }
        let lower = findQuery.lowercased()
        let matching = messages.filter { $0.text.lowercased().contains(lower) }
        guard !matching.isEmpty else { return }

        if let current = findScrollTarget,
           let idx = matching.firstIndex(where: { $0.id == current }),
           idx + 1 < matching.count {
            findScrollTarget = matching[idx + 1].id
        } else {
            findScrollTarget = matching.first?.id
        }
    }

    private func closeFindBar() {
        withAnimation(.easeOut(duration: 0.15)) {
            showFindBar = false
            findQuery = ""
            findScrollTarget = nil
        }
    }

    private var chatThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        let isMatch = !findQuery.isEmpty &&
                            msg.text.lowercased().contains(findQuery.lowercased())
                        SmartChatBubble(
                            message: msg,
                            isUser: msg.role == .user,
                            fontSize: fontSize,
                            onRetry: msg.role == .assistant ? { retryResponse(at: index) } : nil,
                            onEdit: msg.role == .user ? { editMessage(at: index) } : nil,
                            onLinkTapped: { url in openLinkInNewTab(url) }
                        )
                        .id(msg.id)
                        .frame(maxWidth: SmartTokens.chatMaxWidth,
                               alignment: msg.role == .user ? .trailing : .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(SmartTokens.accent.opacity(isMatch ? 0.6 : 0), lineWidth: 1.5)
                                .padding(-4)
                        )
                        .animation(.easeInOut(duration: 0.2), value: isMatch)
                    }
                    if isThinking || isSending { thinkingStepsView }
                    if let err = errorMessage { errorBanner(err) }
                }
                .frame(maxWidth: SmartTokens.chatMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: findScrollTarget) { _, target in
                if let target = target {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private var thinkingStepsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(thinkingSteps) { step in
                HStack(spacing: 8) {
                    if step.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(SmartTokens.accent.opacity(0.7))
                    } else {
                        Circle()
                            .fill(SmartTokens.accent)
                            .frame(width: 6, height: 6)
                            .modifier(PulseAnimation())
                    }
                    Text(step.text)
                        .font(.system(size: fontSize - 1))
                        .foregroundColor(Color.white.opacity(step.isComplete ? 0.4 : 0.6))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isSending && thinkingSteps.allSatisfy({ $0.isComplete }) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.white.opacity(0.4)).frame(width: 5, height: 5)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: SmartTokens.chatMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: thinkingSteps.count)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(SmartTokens.errorText)
            Text(message)
                .font(.system(size: fontSize))
                .foregroundColor(SmartTokens.errorText)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: SmartTokens.chatMaxWidth, alignment: .leading)
        .background(SmartTokens.errorText.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: SmartTokens.cornerRadius, style: .continuous))
    }

    private var chatInputBar: some View {
        let isGlowActive = isInputFocused || !inputText.isEmpty
        return VStack(spacing: 0) {
            // Context chips row
            if !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(includedOtherTabIds, id: \.self) { otherId in
                            SmartContextChip(
                                label: otherTabLabel(tabId: otherId),
                                icon: "square.stack.3d.up",
                                onRemove: { removeIncludedOtherTab(id: otherId) }
                            )
                        }
                        ForEach(attachedDocuments) { doc in
                            SmartContextChip(
                                label: doc.displayName,
                                icon: doc.displayName.lowercased().hasSuffix(".pdf") ? "doc.fill" : "doc.text.fill",
                                onRemove: { removeAttachedDocument(id: doc.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 32)
                .frame(maxWidth: SmartTokens.chatMaxWidth)
                .padding(.bottom, 6)
            }

            HStack(alignment: .bottom, spacing: 0) {
                Menu {
                    Button(action: { addTabsSheetPresented = true }) {
                        Label("Tabs", systemImage: "square.stack.3d.up")
                    }
                    Button(action: { documentPickerPresented = true }) {
                        Label("Files", systemImage: "doc.fill")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(SmartTokens.textSecondary)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                SmartGrowingInput(
                    text: $inputText,
                    placeholder: "Follow up\u{2026}",
                    fontSize: fontSize,
                    isFocused: $isInputFocused,
                    onSubmit: sendChatMessage,
                    onLargePaste: { pastedText in
                        let filename = "\(UUID().uuidString.prefix(8)).txt"
                        attachedDocuments.append(SmartAttachedDocument(
                            displayName: filename,
                            extractedText: pastedText
                        ))
                    }
                )
                .frame(maxWidth: .infinity)

                if isSending {
                    Button(action: stopGenerating) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.8))
                            .frame(width: 28, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: sendChatMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(inputText.isEmpty
                                             ? Color.white.opacity(0.3)
                                             : Color.white.opacity(0.9))
                            .frame(width: 28, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: SmartTokens.chatMaxWidth)
            .background(
                RoundedRectangle(cornerRadius: SmartTokens.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: SmartTokens.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SmartTokens.cornerRadius, style: .continuous)
                    .stroke(isGlowActive ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.06), value: isGlowActive)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }

    // MARK: - Unified search card (Dia-style two-row layout)

    private var unifiedSearchCard: some View {
        let isGlowActive = isInputFocused || !inputText.isEmpty
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 0) {
            // Row 1: icon + text field
            HStack(spacing: 8) {
                Image(systemName: currentIntent == .ai ? "bubble.left.fill" : "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SmartTokens.textTertiary)
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: currentIntent)

                TextField("Ask anything\u{2026}", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(SmartTokens.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit { submitWithSelection() }
                    .onChange(of: inputText) { _, newValue in
                        selectedSuggestionIndex = -1
                        fetchSuggestions(for: newValue)
                        handlePasteDetection(newValue)
                        let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasContext = !attachedDocuments.isEmpty || !includedOtherTabIds.isEmpty
                        currentIntent = t.isEmpty ? .ai : (hasContext ? .ai : QueryClassifier.classify(t))
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Inline suggestions (between rows)
            if viewState == .idle && !trimmed.isEmpty {
                inlineSuggestions
            }

            // Divider when suggestions are showing
            if viewState == .idle && !trimmed.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
            }

            // Row 2: action pills + submit
            HStack(spacing: 8) {
                Menu {
                    Button(action: { addTabsSheetPresented = true }) {
                        Label("Add tabs", systemImage: "square.stack.3d.up")
                    }
                    Button(action: { documentPickerPresented = true }) {
                        Label("Add files", systemImage: "doc.fill")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add tabs or files")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(SmartTokens.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                Spacer()

                // Dynamic submit button
                submitButton(trimmed: trimmed)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isGlowActive
                        ? Color.white.opacity(0.25)
                        : Color.white.opacity(0.09),
                    lineWidth: 1.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.1), value: isGlowActive)
    }

    // MARK: - Dynamic submit button

    @ViewBuilder
    private func submitButton(trimmed: String) -> some View {
        if trimmed.isEmpty {
            Button(action: { submitWithSelection() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color.white.opacity(0.15))
            }
            .buttonStyle(.plain)
            .disabled(true)
        } else {
            Button(action: { submitWithSelection() }) {
                HStack(spacing: 4) {
                    Text(currentIntent == .ai ? "Chat" : "Google")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .animation(.easeOut(duration: 0.15), value: currentIntent)
        }
    }

    // MARK: - Inline suggestions

    private var hasSuggestions: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    private var suggestionRows: [SmartSuggestionRow] {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var rows: [SmartSuggestionRow] = []

        if currentIntent == .ai {
            rows.append(SmartSuggestionRow(id: "chat", icon: "bubble.left.fill", label: trimmed, suffix: "Chat", action: .chat))
            rows.append(SmartSuggestionRow(id: "search", icon: "magnifyingglass", label: trimmed, suffix: "Google", action: .search))
        } else {
            rows.append(SmartSuggestionRow(id: "search", icon: "magnifyingglass", label: trimmed, suffix: "Google", action: .search))
            rows.append(SmartSuggestionRow(id: "chat", icon: "bubble.left.fill", label: trimmed, suffix: "Chat", action: .chat))
        }

        for (i, s) in searchSuggestions.prefix(6).enumerated() {
            let lower = s.lowercased()
            if lower == trimmed.lowercased() { continue }
            rows.append(SmartSuggestionRow(id: "sug-\(i)", icon: "magnifyingglass", label: s, suffix: nil, action: .fillAndSearch(s)))
        }
        return rows
    }

    @ViewBuilder
    private var inlineSuggestions: some View {
        VStack(spacing: 0) {
            let rows = suggestionRows
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                Button(action: { applySuggestion(row) }) {
                    HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SmartTokens.textTertiary)
                            .frame(width: 18)
                        Text(row.label)
                            .font(.system(size: 14))
                            .foregroundColor(SmartTokens.textPrimary)
                            .lineLimit(1)
                        if let suffix = row.suffix {
                            Spacer()
                            Text("— \(suffix)")
                                .font(.system(size: 12))
                                .foregroundColor(SmartTokens.textTertiary)
                        } else {
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        idx == selectedSuggestionIndex
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .transition(.opacity)
    }

    private func applySuggestion(_ row: SmartSuggestionRow) {
        switch row.action {
        case .chat:
            clearSuggestions()
            transitionToChat()
        case .search:
            let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            clearSuggestions()
            performSearch(query)
        case .fillAndSearch(let text):
            inputText = text
            clearSuggestions()
            performSearch(text)
        }
    }

    private func submitWithSelection() {
        let rows = suggestionRows
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < rows.count {
            applySuggestion(rows[selectedSuggestionIndex])
        } else {
            handleSubmit()
        }
    }

    private func fetchSuggestions(for query: String) {
        suggestionDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 2 else {
            searchSuggestions = []
            return
        }

        let work = DispatchWorkItem { [trimmed] in
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data, var raw = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async { searchSuggestions = [] }
                    return
                }
                if raw.hasPrefix("window."), let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") {
                    raw = String(raw[start...end])
                }
                guard let jsonData = raw.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
                      json.count >= 2,
                      let rawSuggestions = json[1] as? [Any] else {
                    DispatchQueue.main.async { searchSuggestions = [] }
                    return
                }
                let phrases = rawSuggestions.compactMap { item -> String? in
                    if let s = item as? String { return s }
                    if let arr = item as? [Any], let first = arr.first as? String { return first }
                    return nil
                }
                DispatchQueue.main.async { searchSuggestions = Array(phrases.prefix(8)) }
            }.resume()
        }
        suggestionDebounceTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func handlePasteDetection(_ newValue: String) {
        let delta = newValue.count - previousInputLength
        previousInputLength = newValue.count

        // Large jump in length (>300 chars in a single frame) = likely a paste
        if delta > 300 {
            let pastedText = newValue
            inputText = ""
            previousInputLength = 0

            let filename = "\(UUID().uuidString.prefix(8)).txt"
            attachedDocuments.append(SmartAttachedDocument(
                displayName: filename,
                extractedText: pastedText
            ))

            if viewState == .idle {
                enterChatWithContext()
            }
        }
    }

    private func clearSuggestions() {
        searchSuggestions = []
        selectedSuggestionIndex = -1
    }

    private func installSuggestionKeyMonitor() {
        suggestionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard viewState == .idle, hasSuggestions else { return event }
            let rows = suggestionRows
            guard !rows.isEmpty else { return event }

            if event.keyCode == 125 { // Down arrow
                DispatchQueue.main.async {
                    selectedSuggestionIndex = min(selectedSuggestionIndex + 1, rows.count - 1)
                }
                return nil
            }
            if event.keyCode == 126 { // Up arrow
                DispatchQueue.main.async {
                    selectedSuggestionIndex = max(-1, selectedSuggestionIndex - 1)
                }
                return nil
            }
            return event
        }
    }

    private func removeSuggestionKeyMonitor() {
        if let monitor = suggestionKeyMonitor {
            NSEvent.removeMonitor(monitor)
            suggestionKeyMonitor = nil
        }
    }

    // MARK: - Actions

    private func handleSubmit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard viewState == .idle else { return }

        if let url = resolveAsURL(trimmed) {
            onNavigate(url)
            return
        }

        // If context is attached, always go to AI chat
        let hasContext = !attachedDocuments.isEmpty || !includedOtherTabIds.isEmpty
        let intent = hasContext ? .ai : QueryClassifier.classify(trimmed)

        switch intent {
        case .search:
            performSearch(trimmed)
        case .ai:
            transitionToChat()
        }
    }

    private func stopGenerating() {
        currentAITask?.cancel()
        currentAITask = nil
        skipStreaming()
        withAnimation(.easeOut(duration: 0.2)) {
            thinkingSteps = []
            isThinking = false
            isSending = false
        }
    }

    // MARK: - URL detection + typo correction

    private func resolveAsURL(_ input: String) -> URL? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: lower)
        }

        let tlds: Set<String> = [
            "com", "org", "net", "edu", "gov", "io", "co", "app", "dev",
            "me", "tv", "ai", "xyz", "info", "biz", "us", "uk", "ca",
            "de", "fr", "jp", "au", "in", "br", "it", "nl", "ru", "ch"
        ]
        let parts = lower.components(separatedBy: ".")
        if parts.count >= 2, let lastPart = parts.last {
            let tldCandidate = lastPart.components(separatedBy: "/").first ?? lastPart
            if tlds.contains(tldCandidate) {
                let corrected = correctURLTypos(lower)
                return URL(string: "https://\(corrected)")
            }
        }
        return nil
    }

    private func correctURLTypos(_ input: String) -> String {
        let corrections: [String: String] = [
            "yuotube": "youtube", "yotube": "youtube", "youtbe": "youtube",
            "youube": "youtube", "yotuube": "youtube", "youttube": "youtube",
            "gogle": "google", "goggle": "google", "gooogle": "google",
            "googlr": "google", "googel": "google", "googe": "google",
            "twtter": "twitter", "twiter": "twitter", "tiwtter": "twitter",
            "facebok": "facebook", "facbook": "facebook", "fcebook": "facebook",
            "faecbook": "facebook", "faceboo": "facebook",
            "instagra": "instagram", "instagarm": "instagram",
            "instragram": "instagram", "instagrm": "instagram",
            "linkdin": "linkedin", "linkeind": "linkedin", "linkeidn": "linkedin",
            "redit": "reddit", "rediit": "reddit", "reddti": "reddit",
            "amazo": "amazon", "amzon": "amazon", "amaozn": "amazon",
            "netfilx": "netflix", "netfli": "netflix", "netflx": "netflix",
            "spotfiy": "spotify", "sptoify": "spotify", "spotiy": "spotify",
            "wikpedia": "wikipedia", "wikipdia": "wikipedia", "wikipeida": "wikipedia",
            "githu": "github", "gihub": "github", "githb": "github",
            "githbu": "github", "gihtub": "github",
            "stackovreflow": "stackoverflow", "stackoverlfow": "stackoverflow",
            "stakoverflow": "stackoverflow",
            "chatgtp": "chatgpt", "chatgp": "chatgpt",
            "discrod": "discord", "disocrd": "discord",
            "tiktk": "tiktok", "tikto": "tiktok",
            "pinterst": "pinterest", "pintrest": "pinterest",
            "tumblr": "tumblr", "tumbrl": "tumblr",
            "dcos": "docs", "dcso": "docs"
        ]

        var result = input
        let dotIndex = result.firstIndex(of: ".") ?? result.endIndex
        let domainPart = String(result[result.startIndex..<dotIndex])
        let rest = String(result[dotIndex...])

        if let corrected = corrections[domainPart] {
            result = corrected + rest
        }
        return result
    }

    private func performSearch(_ query: String) {
        withAnimation(.easeOut(duration: 0.15)) { viewState = .searching }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            onNavigate(url)
        }
    }

    private func transitionToChat() {
        let firstMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstMessage.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: firstMessage))
        inputText = ""

        if let id = tabId {
            let aiURL = URL(string: "luma://ai/\(id.uuidString)")!
            tabManager.navigate(tab: id, to: aiURL)
            tabManager.updateTitle(tab: id, title: heuristicTitle(firstMessage))
        }

        // Slide the search bar down before switching to chat layout
        withAnimation(.easeIn(duration: 0.18)) {
            searchBarOffset = 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            searchBarOffset = 0
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewState = .aiChat
            }
        }

        sendAIRequest(prompt: firstMessage, isFirstMessage: true)
    }

    private func sendChatMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        let isFirst = messages.isEmpty
        messages.append(ChatMessage(role: .user, text: trimmed))
        inputText = ""
        sendAIRequest(prompt: trimmed, isFirstMessage: isFirst)
    }

    private func sendAIRequest(prompt: String, isFirstMessage: Bool = false) {
        isSending = true
        isThinking = true
        errorMessage = nil
        thinkingSteps = []

        let capturedQuery = isFirstMessage ? prompt : nil
        let needsWebSearch = Self.shouldWebSearch(prompt)
        let detectedURLs = Self.extractURLs(from: prompt)

        let task = Task {
            // Step 0: If the user included URLs, fetch them
            var linkContext: String? = nil
            if !detectedURLs.isEmpty {
                addThinkingStep("Reading \(detectedURLs.count == 1 ? "link" : "\(detectedURLs.count) links")\u{2026}")
                var fetched: [WebSource] = []
                for url in detectedURLs.prefix(3) {
                    guard !Task.isCancelled else { return }
                    if let source = await WebSearchService.fetchSingleURL(url) {
                        fetched.append(source)
                    }
                }
                guard !Task.isCancelled else { return }
                if !fetched.isEmpty {
                    linkContext = WebSearchService.formatSourcesAsContext(fetched)
                }
                completeLastThinkingStep()
            }

            // Step 1: Optional web search
            var webContext: String? = nil
            if needsWebSearch && detectedURLs.isEmpty {
                addThinkingStep("Searching the web\u{2026}")
                do {
                    let sources = try await WebSearchService.searchAndFetch(query: prompt, maxResults: 3)
                    guard !Task.isCancelled else { return }
                    if !sources.isEmpty {
                        completeLastThinkingStep()
                        addThinkingStep("Reading \(sources.count) source\(sources.count == 1 ? "" : "s")\u{2026}")
                        webContext = WebSearchService.formatSourcesAsContext(sources)
                        completeLastThinkingStep()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    completeLastThinkingStep()
                }
            }

            guard !Task.isCancelled else { return }
            addThinkingStep("Thinking\u{2026}")

            let recentContext = Array(messages.dropLast().suffix(6))
            var contextParts: [String] = []
            if let userContext = buildContextString() { contextParts.append(userContext) }
            if let link = linkContext { contextParts.append(link) }
            if let web = webContext { contextParts.append(web) }
            let finalContext = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n")

            guard !Task.isCancelled else { return }

            let handler: (Result<Data, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    currentAITask = nil
                    withAnimation(.easeOut(duration: 0.3)) {
                        thinkingSteps = []
                        isThinking = false
                    }
                    switch result {
                    case .success(let data):
                        if let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
                            streamResponseWordByWord(response.text, capturedQuery: capturedQuery)
                        } else {
                            isSending = false
                            errorMessage = "Failed to parse response"
                        }
                    case .failure(let error):
                        isSending = false
                        if !Task.isCancelled {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }

            await MainActor.run {
                switch aiProvider {
                case .gemini:
                    gemini.generate(prompt: prompt, context: finalContext,
                                    recentMessages: recentContext, completion: handler)
                case .ollama:
                    ollama.generate(baseURLString: ollamaBaseURL, model: ollamaModel,
                                    prompt: prompt, context: finalContext,
                                    recentMessages: recentContext, completion: handler)
                }
            }
        }
        currentAITask = task
    }

    private func streamResponseWordByWord(_ fullText: String, capturedQuery: String?) {
        let placeholder = ChatMessage(role: .assistant, text: "")
        messages.append(placeholder)
        let targetIndex = messages.count - 1

        if let query = capturedQuery {
            generateAITitle(for: query)
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            messages[targetIndex].text = fullText
            isSending = false
            return
        }

        streamingTask?.cancel()
        streamingTask = Task { @MainActor in
            var index = fullText.startIndex
            while index < fullText.endIndex {
                guard !Task.isCancelled else {
                    messages[targetIndex].text = fullText
                    break
                }
                // Skip whitespace (include it in the next reveal)
                while index < fullText.endIndex && fullText[index].isWhitespace {
                    index = fullText.index(after: index)
                }
                // Advance through one word
                while index < fullText.endIndex && !fullText[index].isWhitespace {
                    index = fullText.index(after: index)
                }
                messages[targetIndex].text = String(fullText[fullText.startIndex..<index])
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            messages[targetIndex].text = fullText
            isSending = false
            streamingTask = nil
        }
    }

    private func skipStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match -> URL? in
            guard let range = Range(match.range, in: text) else { return nil }
            let urlStr = String(text[range])
            return URL(string: urlStr)
        }
    }

    private static func shouldWebSearch(_ query: String) -> Bool {
        let lower = query.lowercased()
        let words = lower.split(separator: " ").map(String.init)

        let webSearchTriggers = [
            "latest", "current", "recent", "today", "tonight", "yesterday",
            "this week", "this month", "this year", "news", "score", "scores",
            "price", "cost", "weather", "stock", "release date", "how much",
            "when does", "when did", "when is", "when will", "who won",
            "results", "standings", "schedule", "stats", "statistics",
            "reviews", "rating", "ratings", "compare prices", "best deals",
            "where to buy", "hours", "open now", "near me", "directions"
        ]
        for trigger in webSearchTriggers {
            if lower.contains(trigger) { return true }
        }

        let yearPattern = try? NSRegularExpression(pattern: "\\b20[2-3]\\d\\b")
        if let regex = yearPattern,
           regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }

        let noSearchVerbs: Set<String> = [
            "write", "create", "make", "draft", "compose", "generate",
            "rewrite", "help", "explain", "teach", "describe", "summarize",
            "analyze", "debug", "fix", "refactor", "optimize", "convert",
            "brainstorm", "plan", "outline", "simplify", "elaborate"
        ]
        if let first = words.first, noSearchVerbs.contains(first) {
            return false
        }

        let noSearchPhrases = [
            "how do i", "how to", "what is the difference",
            "give me ideas", "help me", "can you", "could you",
            "tell me about", "what should i", "why do i",
            "pros and cons", "step by step"
        ]
        for phrase in noSearchPhrases {
            if lower.contains(phrase) { return false }
        }

        return false
    }

    private func addThinkingStep(_ text: String) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                thinkingSteps.append(SmartThinkingStep(text: text))
            }
        }
    }

    private func completeLastThinkingStep() {
        DispatchQueue.main.async {
            guard !thinkingSteps.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                thinkingSteps[thinkingSteps.count - 1].isComplete = true
            }
        }
    }

    // MARK: - Retry / Edit

    private func retryResponse(at index: Int) {
        guard index < messages.count, messages[index].role == .assistant else { return }
        guard !isSending else { return }

        let userIndex = index - 1
        guard userIndex >= 0, messages[userIndex].role == .user else { return }
        let userPrompt = messages[userIndex].text

        messages.removeSubrange(index...)
        sendAIRequest(prompt: userPrompt)
    }

    private func editMessage(at index: Int) {
        guard index < messages.count, messages[index].role == .user else { return }

        inputText = messages[index].text
        messages.removeSubrange(index...)
        isInputFocused = true
    }

    // MARK: - Tab title

    private func heuristicTitle(_ query: String) -> String {
        let maxLen = 25
        if query.count <= maxLen { return query }
        let prefix = String(query.prefix(maxLen))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "\u{2026}"
        }
        return prefix + "\u{2026}"
    }

    private func generateAITitle(for query: String) {
        guard !hasGeneratedTitle, let id = tabId else { return }
        hasGeneratedTitle = true

        let titlePrompt = "Generate a 2-5 word tab title for this conversation. First message: \"\(query)\". Reply with ONLY the title, no quotes, no punctuation."

        let handler: (Result<Data, Error>) -> Void = { result in
            DispatchQueue.main.async {
                if case .success(let data) = result,
                   let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
                    let title = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty && title.count < 40 {
                        tabManager.updateTitle(tab: id, title: title)
                    }
                }
            }
        }

        switch aiProvider {
        case .gemini:
            gemini.generate(prompt: titlePrompt, context: nil, completion: handler)
        case .ollama:
            ollama.generate(baseURLString: ollamaBaseURL, model: ollamaModel,
                            prompt: titlePrompt, context: nil, completion: handler)
        }
    }

    // MARK: - Link handling

    private func openLinkInNewTab(_ url: URL) {
        let newTabId = tabManager.newTab(url: url)
        webViewWrapper.load(url: url, in: newTabId)
    }

    // MARK: - Context helpers

    private func buildContextString() -> String? {
        var parts: [String] = []

        for id in includedOtherTabIds {
            if let url = tabManager.tabURL[id] ?? nil {
                var tp: [String] = ["URL: \(url.absoluteString)"]
                let ctx = otherTabContexts[id]
                if let t = ctx?.title ?? tabManager.tabTitle[id], !t.isEmpty {
                    tp.append("Title: \(t)")
                }
                if let text = ctx?.text, !text.isEmpty {
                    tp.append("Page content:\n\(text)")
                }
                parts.append(tp.joined(separator: "\n"))
            }
        }

        for doc in attachedDocuments {
            parts.append("Document \"\(doc.displayName)\":\n\(doc.textForContext)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func otherTabLabel(tabId: UUID) -> String {
        if let title = tabManager.tabTitle[tabId], !title.isEmpty { return title }
        if let url = tabManager.tabURL[tabId] ?? nil, let host = url.host { return host }
        return "Tab"
    }

    private func removeIncludedOtherTab(id: UUID) {
        includedOtherTabIds.removeAll { $0 == id }
        otherTabContexts.removeValue(forKey: id)
    }

    private func loadTabContext(for id: UUID) {
        let group = DispatchGroup()
        var loadedTitle: String? = nil
        var loadedText: String? = nil

        group.enter()
        webViewWrapper.evaluatePageTitle(for: id) { title in
            loadedTitle = title; group.leave()
        }
        group.enter()
        webViewWrapper.evaluateVisibleText(for: id, maxChars: 4000) { text in
            loadedText = text; group.leave()
        }
        group.notify(queue: .main) {
            otherTabContexts[id] = (title: loadedTitle, text: loadedText)
        }
    }

    private func addDocument(from url: URL) {
        guard SmartDocumentExtractor.isSupported(url) else {
            documentError = "Unsupported format. Use PDF, TXT, MD, JSON, CSV, XML, or HTML."
            return
        }
        guard let text = SmartDocumentExtractor.extractText(from: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            documentError = "Could not read text from \"\(url.lastPathComponent)\"."
            return
        }
        attachedDocuments.append(SmartAttachedDocument(
            displayName: url.lastPathComponent,
            extractedText: text,
            fileURL: url
        ))
        documentError = nil

        // Auto-enter AI chat when a file is added from the start page
        if viewState == .idle {
            enterChatWithContext()
        }
    }

    private func enterChatWithContext() {
        if let id = tabId {
            let aiURL = URL(string: "luma://ai/\(id.uuidString)")!
            tabManager.navigate(tab: id, to: aiURL)
            tabManager.updateTitle(tab: id, title: "New Chat")
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            viewState = .aiChat
        }
        isInputFocused = true
    }

    private func removeAttachedDocument(id: UUID) {
        attachedDocuments.removeAll { $0.id == id }
    }

}

// MARK: - Thinking step model

private struct SmartSuggestionRow: Identifiable {
    let id: String
    let icon: String
    let label: String
    let suffix: String?
    let action: SmartSuggestionAction
}

private enum SmartSuggestionAction {
    case chat
    case search
    case fillAndSearch(String)
}

private struct SmartThinkingStep: Identifiable {
    let id = UUID()
    let text: String
    var isComplete: Bool = false
}

private struct PulseAnimation: ViewModifier {
    @State private var scale: CGFloat = 0.85

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    scale = 1.15
                }
            }
    }
}

// MARK: - Self-contained chat bubble with retry / edit

private struct SmartChatBubble: View {
    let message: ChatMessage
    let isUser: Bool
    let fontSize: CGFloat
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    var onLinkTapped: ((URL) -> Void)?

    private let userBubbleColor = Color.white.opacity(0.15)
    private let linkColor = Color(red: 0.4, green: 0.6, blue: 1.0)
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 48) }
                bubbleContent
                if !isUser { Spacer(minLength: 48) }
            }
            actionRow
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            HStack(alignment: .bottom, spacing: 6) {
                if isHovered, let onEdit = onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                userTextView
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(userBubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        } else {
            RichMessageView(
                rawText: message.text,
                fontSize: fontSize,
                linkColor: linkColor,
                onLinkTapped: onLinkTapped
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @State private var showCopied: Bool = false

    @ViewBuilder
    private var actionRow: some View {
        if !isUser {
            HStack(spacing: 4) {
                if let onRetry = onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(isHovered ? 0.6 : 0.35))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: copyToClipboard) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(showCopied ? 0.7 : (isHovered ? 0.6 : 0.35)))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) { showCopied = false }
        }
    }

    private var userTextView: some View {
        Group {
            if let attr = userMarkdown {
                Text(attr)
            } else {
                Text(message.text)
            }
        }
        .font(.system(size: fontSize))
        .foregroundColor(Color.white.opacity(0.95))
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .lineSpacing(5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var userMarkdown: AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard var attributed = try? AttributedString(markdown: message.text, options: options, baseURL: nil) else {
            return try? AttributedString(markdown: message.text)
        }
        for run in attributed.runs {
            if run.link != nil {
                attributed[run.range].foregroundColor = linkColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

// MARK: - Context chip

private struct SmartContextChip: View {
    let label: String
    let icon: String
    let onRemove: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.6))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.6))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Growing input (self-contained, same pattern as CommandSurface)

private struct SmartGrowingInput: View {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onLargePaste: ((String) -> Void)?

    @State private var textHeight: CGFloat = 36

    private var font: Font { .system(size: fontSize) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SmartMultilineField(
                text: $text,
                fontSize: fontSize,
                dynamicHeight: $textHeight,
                minHeight: 36,
                onSubmit: onSubmit,
                onLargePaste: onLargePaste
            )
            .focused($isFocused)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(Color.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: textHeight)
        .animation(.easeOut(duration: 0.15), value: textHeight)
    }
}

private struct SmartMultilineField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat
    var minHeight: CGFloat
    var onSubmit: () -> Void
    var onLargePaste: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = SmartSubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onLargePaste = onLargePaste
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(white: 0.95, alpha: 1)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 5
        tv.defaultParagraphStyle = ps
        tv.typingAttributes[.paragraphStyle] = ps
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async { context.coordinator.recalculateHeight(tv) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? SmartSubmitTextView else { return }
        let textChanged = tv.string != text
        if textChanged { tv.string = text }
        tv.onSubmit = onSubmit
        tv.onLargePaste = onLargePaste
        tv.font = .systemFont(ofSize: fontSize)
        if let container = tv.textContainer {
            let w = scrollView.contentSize.width
            if w > 0 { container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude) }
        }
        if textChanged {
            DispatchQueue.main.async { context.coordinator.recalculateHeight(tv) }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SmartMultilineField
        weak var textView: SmartSubmitTextView?
        init(_ parent: SmartMultilineField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalculateHeight(tv)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let inset = textView.textContainerInset
            let h = max(parent.minHeight, used.height + inset.height * 2)
            if abs(h - parent.dynamicHeight) > 0.5 { parent.dynamicHeight = h }
        }
    }
}

private class SmartSubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onLargePaste: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isNumpad = event.keyCode == 76
        if (isReturn || isNumpad) && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let clipboard = NSPasteboard.general.string(forType: .string),
           clipboard.count > 300 {
            onLargePaste?(clipboard)
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Add Tab Context Sheet

private struct SmartAddTabSheet: View {
    let tabManager: TabManager
    let currentTabId: UUID?
    let alreadyIncluded: Set<UUID>
    let onAdd: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var orderedTabs: [UUID] { tabManager.tabOrder }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add tab context")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.9))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.white.opacity(0.75))
            }
            .padding(16)

            Divider().opacity(0.2)

            ScrollView {
                VStack(spacing: 8) {
                    if orderedTabs.isEmpty {
                        Text("No tabs found.")
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.top, 24)
                    } else {
                        ForEach(orderedTabs, id: \.self) { id in
                            tabRow(id: id)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                startPageGlassTint.opacity(startPageGlassTintOpacity)
            }
        )
    }

    @ViewBuilder
    private func tabRow(id: UUID) -> some View {
        let isCurrent = (currentTabId == id)
        let isIncluded = alreadyIncluded.contains(id)
        Button(action: {
            guard !isCurrent, !isIncluded else { return }
            onAdd(id)
        }) {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "globe" : "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(isCurrent ? 0.45 : 0.7))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tabTitle(id: id))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.9))
                        .lineLimit(1)
                    if let subtitle = tabSubtitle(id: id) {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.45))
                } else if isIncluded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.55))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || isIncluded)
        .opacity(isCurrent ? 0.7 : 1.0)
    }

    private func tabTitle(id: UUID) -> String {
        if let t = tabManager.tabTitle[id], !t.isEmpty { return t }
        if let url = tabManager.tabURL[id] ?? nil { return url.host ?? url.absoluteString }
        return "Tab"
    }

    private func tabSubtitle(id: UUID) -> String? {
        guard let url = tabManager.tabURL[id] ?? nil else { return nil }
        return url.absoluteString.isEmpty ? nil : url.absoluteString
    }
}

// MARK: - AttachedDocument

private struct SmartAttachedDocument: Identifiable {
    let id: UUID
    let displayName: String
    let extractedText: String
    let fileURL: URL?

    init(id: UUID = UUID(), displayName: String, extractedText: String, fileURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.extractedText = extractedText
        self.fileURL = fileURL
    }

    static let maxCharsInContext: Int = 12_000

    var textForContext: String {
        if extractedText.count <= Self.maxCharsInContext { return extractedText }
        return String(extractedText.prefix(Self.maxCharsInContext)) + "\n\n[Document truncated for length.]"
    }
}

// MARK: - DocumentTextExtractor

private enum SmartDocumentExtractor {
    static let supportedExtensions: Set<String> = ["pdf", "txt", "md", "json", "csv", "xml", "html"]

    static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return PDFDocument(url: url)?.string
        case "txt", "md", "json", "csv", "xml", "html":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16))
        default: return nil
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
