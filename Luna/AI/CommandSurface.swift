// Luma MVP - AI Side Panel (redesigned for clarity, calmness, accessibility)
import Foundation
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Panel tokens (WCAG AA: body ≥4.5:1, secondary ≥3:1 on panel bg)

private enum PanelTokens {
    static let panelBg = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let panelBgSecondary = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let surfaceElevated = Color(white: 0.14)
    /// Body text: ≥4.5:1 on panelBg
    static let textPrimary = Color(white: 0.94)
    /// Secondary text: ≥3:1 on panelBg
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.50)
    static let accent = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let accentDim = Color(red: 0.4, green: 0.5, blue: 0.62).opacity(0.15)
    static let errorText = Color(red: 0.95, green: 0.55, blue: 0.55)
    static let cornerRadius: CGFloat = 14
    static let cornerRadiusLarge: CGFloat = 18
}

/// Cross-tab affordance microcopy (≤50 characters).
private let otherTabsMicrocopy = "Add context from other tabs (coming soon)"

/// Glassmorphism: match start page style (dark grey glassmorphism)
private let panelGlassTint = Color(red: 0.06, green: 0.06, blue: 0.07)
private let panelGlassTintOpacity: Double = 0.82

/// Right-side AI command panel (Cmd+E toggle). Per-tab chat with history.
///
/// Redesign: clear hierarchy (header → context → conversation → input),
/// calm visuals, WCAG contrast, keyboard + screen reader support.
struct CommandSurfaceView: View {
    @Binding var isPresented: Bool
    @Binding var messages: [ChatMessage]
    let webViewWrapper: WebViewWrapper
    let commandRouter: CommandRouter
    let gemini: GeminiClient
    let ollama: OllamaClient
    let onActionProposed: (LLMResponse) -> Void
    
    var tabId: UUID? = nil

    @AppStorage("luma_ai_panel_font_size") private var aiPanelFontSizeRaw: Int = 13
    @AppStorage("luma_ai_provider") private var aiProviderRaw: String = AIProvider.gemini.rawValue
    @AppStorage("luma_ollama_base_url") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("luma_ollama_model") private var ollamaModel: String = ""
    @State private var inputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSending: Bool = false
    @State private var actionProposedMessage: String? = nil
    @State private var includeSelection: Bool = false
    @State private var selectedText: String? = nil
    @State private var contextSectionExpanded: Bool = false
    @State private var conversationSummary: String? = nil
    @State private var lastSummarizedMessageCount: Int = 0
    @FocusState private var isInputFocused: Bool

    @State private var pageTitle: String? = nil
    @State private var pageText: String? = nil
    @State private var isLoadingContext: Bool = false

    @State private var attachedDocuments: [AttachedDocument] = []
    @State private var documentPickerPresented: Bool = false
    @State private var documentError: String? = nil
    @State private var includeCurrentTab: Bool = true // Current tab is always included initially
    @State private var includedOtherTabIds: [UUID] = []
    @State private var otherTabContexts: [UUID: (title: String?, text: String?)] = [:]
    @State private var addTabsSheetPresented: Bool = false
    @State private var currentTabChipId: UUID = UUID()

    /// Tracks the editor's current natural height so the outer container can match it without any fixed frame.
    @State private var editorContentHeight: CGFloat = 36

    private let minInputHeight: CGFloat = 36

    private var chatFontSize: CGFloat { CGFloat(aiPanelFontSizeRaw) }

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .gemini
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader()
            conversationStream()
            inputArea()
        }
        .background(
            ZStack {
                VisualEffectView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    state: .active
                )
                panelGlassTint.opacity(panelGlassTintOpacity)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelTokens.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelTokens.cornerRadiusLarge, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        // Load page context only when the sidebar is toggled open (not on every URL change).
        // Auto-reloading on navigation can look like automated scraping to strict sites (e.g. Akamai).
        .onAppear {
            loadPageContext()
        }
        .sheet(isPresented: $addTabsSheetPresented) {
            AddTabContextSheet(
                tabManager: webViewWrapper.tabManager,
                currentTabId: tabId,
                alreadyIncluded: Set(includedOtherTabIds),
                onAdd: { id in
                    if !includedOtherTabIds.contains(id) {
                        includedOtherTabIds.append(id)
                        loadTabContext(for: id)
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
    }

    // MARK: - Header (minimal - note icon for new chat, close button)

    private func panelHeader() -> some View {
        HStack {
            Button(action: startNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(PanelTokens.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start new chat")
            .accessibilityHint("Clears conversation and context to start fresh")
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelTokens.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close AI panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private func startNewChat() {
        messages = []
        attachedDocuments = []
        includeCurrentTab = true
        includedOtherTabIds = []
        otherTabContexts = [:]
        inputText = ""
        errorMessage = nil
        actionProposedMessage = nil
        conversationSummary = nil
        lastSummarizedMessageCount = 0
        editorContentHeight = minInputHeight
        loadPageContext() // Reload current page context
    }

    private func statusBadge() -> some View {
        let (color, label) = statusDotState()
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(PanelTokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }

    private func statusDotState() -> (Color, String) {
        switch aiProvider {
        case .gemini:
            if GeminiClient.lastNetworkError != nil {
                return (.red, "Error")
            }
            if KeychainManager.shared.fetchGeminiKey() == nil {
                return (.gray, "No API key")
            }
            return (.green, "Ready")
        case .ollama:
            if OllamaClient.lastNetworkError != nil {
                return (.red, "Error")
            }
            if ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.gray, "No local model")
            }
            return (.green, "Ready")
        }
    }

    // MARK: - Context sources (this page + documents + other tabs teaser)

    private func contextSourcesSection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $contextSectionExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    thisPageBadge()
                    documentsRow()
                    otherTabsTeaser()
                    if contextSectionExpanded {
                        contextPreviewSnippet()
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(PanelTokens.textSecondary)
                    Text("Context")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(PanelTokens.textPrimary)
                    contextCountBadge()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(panelGlassTint.opacity(panelGlassTintOpacity * 0.75))
            .tint(PanelTokens.textSecondary)
            .accessibilityLabel("Context sources")
            .accessibilityHint("Expand to see page, documents, and what will be sent")
        }
    }

    @ViewBuilder
    private func thisPageBadge() -> some View {
        HStack(spacing: 6) {
            if isLoadingContext {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(PanelTokens.textSecondary)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundColor(PanelTokens.textSecondary)
            }
            Text(thisPageLabel())
                .font(.system(size: 11))
                .foregroundColor(PanelTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PanelTokens.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("This page: \(thisPageLabel())")
    }

    private func thisPageLabel() -> String {
        if let title = pageTitle, !title.isEmpty { return title }
        if let host = webViewWrapper.currentURL?.host { return host }
        return "Loading…"
    }

    @ViewBuilder
    private func contextCountBadge() -> some View {
        let count = 1 + (attachedDocuments.isEmpty ? 0 : attachedDocuments.count)
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(PanelTokens.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PanelTokens.surfaceElevated)
                .clipShape(Capsule())
        }
    }

    private func documentsRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Documents")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PanelTokens.textSecondary)
                if !attachedDocuments.isEmpty {
                    Text("(\(attachedDocuments.count))")
                        .font(.caption2)
                        .foregroundColor(PanelTokens.textTertiary)
                }
                Spacer()
                Button(action: { documentPickerPresented = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("Add file")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(PanelTokens.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add file")
                .accessibilityHint("Attach a document for AI context")
            }
            if let err = documentError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(PanelTokens.errorText)
                    .lineLimit(2)
                    .accessibilityLabel("Document error: \(err)")
            }
            if attachedDocuments.isEmpty {
                Text("No documents")
                    .font(.system(size: 11))
                    .foregroundColor(PanelTokens.textTertiary)
                    .padding(.vertical, 4)
                    .accessibilityLabel("No documents attached")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedDocuments) { doc in
                            documentChip(doc)
                        }
                    }
                }
                .frame(maxHeight: 36)
            }
        }
        .onDrop(of: [.fileURL, .pdf, .plainText, .utf8PlainText], isTargeted: nil) { providers in
            handleDocumentDrop(providers: providers)
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
    }

    private func documentChip(_ doc: AttachedDocument) -> some View {
        HStack(spacing: 6) {
            Image(systemName: doc.displayName.lowercased().hasSuffix(".pdf") ? "doc.fill" : "doc.text.fill")
                .font(.system(size: 10))
                .foregroundColor(PanelTokens.textSecondary)
            Text(doc.displayName)
                .font(.system(size: 11))
                .foregroundColor(PanelTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { removeAttachedDocument(id: doc.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(PanelTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(doc.displayName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(PanelTokens.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func otherTabsTeaser() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10))
                .foregroundColor(PanelTokens.textTertiary)
            Text(otherTabsMicrocopy)
                .font(.system(size: 10))
                .foregroundColor(PanelTokens.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTokens.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(otherTabsMicrocopy)
        .accessibilityHint("Feature not yet available")
    }

    @ViewBuilder
    private func contextPreviewSnippet() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = webViewWrapper.currentURL {
                Text(url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundColor(PanelTokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let text = pageText, !text.isEmpty {
                Text("\(text.prefix(180))\(text.count > 180 ? "…" : "")")
                    .font(.system(size: 10))
                    .foregroundColor(PanelTokens.textTertiary)
                    .lineLimit(3)
            }
            if includeSelection, let sel = selectedText, !sel.isEmpty {
                Text("Selection: \(sel.prefix(80))\(sel.count > 80 ? "…" : "")")
                    .font(.system(size: 10))
                    .foregroundColor(PanelTokens.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Conversation stream

    private func conversationStream() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        emptyConversationState()
                    } else {
                        ForEach(messages) { msg in
                            ChatBubble(message: msg, isUser: msg.role == .user, fontSize: chatFontSize) { url in
                                openLinkInNewTab(url)
                            }
                            .frame(maxWidth: 720, alignment: msg.role == .user ? .trailing : .leading)
                        }
                        if isSending {
                            loadingIndicator()
                        }
                        if let err = errorMessage {
                            errorInlineView(message: err)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private func emptyConversationState() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(Color.white.opacity(0.3))
            Text("Ask about this page")
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No messages yet. Ask about this page.")
    }

    private func loadingIndicator() -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Text("Thinking…")
                .font(.system(size: chatFontSize))
                .foregroundColor(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Assistant is thinking")
    }

    private func errorInlineView(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(PanelTokens.errorText)
            Text(message)
                .font(.system(size: chatFontSize))
                .foregroundColor(PanelTokens.errorText)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTokens.errorText.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: PanelTokens.cornerRadius, style: .continuous))
        .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Input area
    //
    // Glass rounded-rect box (start page style). Grows to show all typed text.
    // No internal scrolling — you always see everything before sending.

    private func inputArea() -> some View {
        VStack(spacing: 0) {
            // Context tabs row
            if includeCurrentTab || !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if includeCurrentTab {
                            contextTab(
                                id: currentTabChipId,
                                label: thisPageLabel(),
                                isCurrentTab: true,
                                onRemove: { includeCurrentTab = false }
                            )
                        }
                        ForEach(includedOtherTabIds, id: \.self) { otherId in
                            contextTab(
                                id: otherId,
                                label: otherTabLabel(tabId: otherId),
                                isCurrentTab: false,
                                onRemove: { removeIncludedOtherTab(id: otherId) },
                                leadingSymbol: "square.stack.3d.up"
                            )
                        }
                        ForEach(attachedDocuments) { doc in
                            contextTab(
                                id: doc.id,
                                label: doc.displayName,
                                isCurrentTab: false,
                                onRemove: { removeAttachedDocument(id: doc.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 32)
                .padding(.bottom, 8)
            }

            let isGlowActive = isInputFocused || !inputText.isEmpty

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
                        .foregroundColor(PanelTokens.textSecondary)
                        .frame(width: 32, height: minInputHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Add context")
                .accessibilityHint("Choose tabs or files to add as context")

                GrowingTextEditor(
                    text: $inputText,
                    placeholder: "Ask a question about this page...",
                    minHeight: minInputHeight,
                    fontSize: chatFontSize,
                    isFocused: $isInputFocused,
                    onSubmit: sendCommand,
                    reportedHeight: $editorContentHeight
                )
                .frame(maxWidth: .infinity)

                Button(action: sendCommand) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(inputText.isEmpty || isSending
                                         ? Color.white.opacity(0.3)
                                         : Color.white.opacity(0.9))
                        .frame(width: 28, height: minInputHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isGlowActive ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.06), value: isGlowActive)
            .accessibilityLabel("Message input")
            .accessibilityHint("Type your message. Enter to send.")
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
    
    // Context tab component (mini tab showing file/tab name with hover trash icon)
    private func contextTab(
        id: UUID,
        label: String,
        isCurrentTab: Bool,
        onRemove: @escaping () -> Void,
        leadingSymbol: String? = nil
    ) -> some View {
        ContextTabView(label: label, isCurrentTab: isCurrentTab, leadingSymbol: leadingSymbol, onRemove: onRemove)
    }

    private func sendIfEnter() {
        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendCommand()
        }
    }

    private struct ChatBubble: View {
        let message: ChatMessage
        let isUser: Bool
        let fontSize: CGFloat
        let onLinkTapped: (URL) -> Void

        private let userBubbleColor = Color.white.opacity(0.15)
        private let assistantTextColor = Color.white.opacity(0.95)
        private let linkColor = Color(red: 0.4, green: 0.6, blue: 1.0)

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 32) }
                if isUser {
                    messageTextView
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(userBubbleColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    messageTextView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isUser { Spacer(minLength: 32) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        private func styledAttributedString(for string: String) -> AttributedString? {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            guard var attributed = try? AttributedString(markdown: string, options: options, baseURL: nil) else {
                guard var fallback = try? AttributedString(markdown: string) else { return nil }
                for run in fallback.runs {
                    if run.link != nil {
                        let range = run.range
                        fallback[range].foregroundColor = linkColor
                        fallback[range].underlineStyle = .single
                    }
                }
                return fallback
            }
            for run in attributed.runs {
                if run.link != nil {
                    let range = run.range
                    attributed[range].foregroundColor = linkColor
                    attributed[range].underlineStyle = .single
                }
            }
            return attributed
        }

        @ViewBuilder
        private var messageTextView: some View {
            if isUser {
                singleBlockMessageView
            } else {
                RichMessageView(
                    rawText: message.text,
                    fontSize: fontSize,
                    linkColor: linkColor,
                    onLinkTapped: onLinkTapped
                )
            }
        }

        @ViewBuilder
        private var singleBlockMessageView: some View {
            Group {
                if let attributed = styledAttributedString(for: message.text) {
                    Text(attributed)
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
            .environment(\.openURL, OpenURLAction { url in
                onLinkTapped(url)
                return .handled
            })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)")
        }
    }

    private func openLinkInNewTab(_ url: URL) {
        // Open URL in a new browser tab
        if let tabManager = webViewWrapper.tabManager {
            let newTabId = tabManager.newTab(url: url)
            webViewWrapper.load(url: url, in: newTabId)
        }
    }

    private func fetchSelectedText() {
        webViewWrapper.evaluateSelectedText { text in
            selectedText = text
        }
    }

    // Legacy contextPreviewContent removed; see contextPreviewSnippet() and contextSourcesSection()

    @ViewBuilder
    private func _unused_contextPreviewContent() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = webViewWrapper.currentURL {
                Text("URL: \(url.absoluteString)")
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(1)
            }
            if let title = pageTitle, !title.isEmpty {
                Text("Title: \(title)")
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(1)
            }
            if let text = pageText, !text.isEmpty {
                Text("Page: \(text.prefix(200))\(text.count > 200 ? "…" : "")")
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(3)
            }
            if includeSelection, let sel = selectedText, !sel.isEmpty {
                Text("Selection: \(sel.prefix(100))\(sel.count > 100 ? "…" : "")")
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(2)
            }
            if !attachedDocuments.isEmpty {
                Text("Documents: \(attachedDocuments.map(\.displayName).joined(separator: ", "))")
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(2)
                ForEach(attachedDocuments) { doc in
                    Text("  “\(doc.displayName)”: \(doc.extractedText.prefix(80))\(doc.extractedText.count > 80 ? "…" : "")")
                        .foregroundColor(Color(white: 0.55))
                        .lineLimit(1)
                }
            }
            if isLoadingContext {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attachedDocumentsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attached documents")
                    .font(.caption)
                    .foregroundColor(PanelTokens.textSecondary)
                if !attachedDocuments.isEmpty {
                    Text("(\(attachedDocuments.count))")
                        .font(.caption2)
                        .foregroundColor(PanelTokens.textSecondary.opacity(0.8))
                }
                Spacer()
                Button(action: { documentPickerPresented = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("Add file")
                            .font(.caption)
                    }
                    .foregroundColor(PanelTokens.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            if let err = documentError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 18)
            }

            if !attachedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedDocuments) { doc in
                            HStack(spacing: 6) {
                                Image(systemName: doc.displayName.hasSuffix(".pdf") ? "doc.fill" : "doc.text.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(PanelTokens.textSecondary)
                                Text(doc.displayName)
                                    .font(.caption)
                                    .foregroundColor(PanelTokens.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button(action: { removeAttachedDocument(id: doc.id) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(PanelTokens.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.14))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 32)
            }
        }
        .background(PanelTokens.panelBgSecondary.opacity(0.6))
        .onDrop(of: [.fileURL, .pdf, .plainText, .utf8PlainText], isTargeted: nil) { providers in
            handleDocumentDrop(providers: providers)
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
    }

    private func addDocument(from url: URL) {
        guard DocumentTextExtractor.isSupported(url) else {
            documentError = "Unsupported format. Use PDF, TXT, MD, JSON, CSV, XML, or HTML."
            return
        }
        guard let text = DocumentTextExtractor.extractText(from: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            documentError = "Could not read text from “\(url.lastPathComponent)”."
            return
        }
        let name = url.lastPathComponent
        let doc = AttachedDocument(displayName: name, extractedText: text, fileURL: url)
        attachedDocuments.append(doc)
        documentError = nil
    }

    private func removeAttachedDocument(id: UUID) {
        attachedDocuments.removeAll { $0.id == id }
    }

    private func handleDocumentDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let u = url else { return }
            DispatchQueue.main.async {
                addDocument(from: u)
            }
        }
        return true
    }

    private func close() {
        isPresented = false
        inputText = ""
        errorMessage = nil
        isSending = false
        actionProposedMessage = nil
        attachedDocuments = []
        includeCurrentTab = true
        editorContentHeight = minInputHeight
    }

    /// Loads page context (title + visible text) when panel appears.
    private func loadPageContext() {
        isLoadingContext = true
        let group = DispatchGroup()

        group.enter()
        webViewWrapper.evaluatePageTitle { title in
            pageTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(maxChars: 4000) { text in
            pageText = text
            group.leave()
        }

        group.notify(queue: .main) {
            isLoadingContext = false
        }
    }
    
    /// Loads page context (title + visible text) for a specific tab.
    private func loadTabContext(for tabId: UUID) {
        let group = DispatchGroup()
        var loadedTitle: String? = nil
        var loadedText: String? = nil

        group.enter()
        webViewWrapper.evaluatePageTitle(for: tabId) { title in
            loadedTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(for: tabId, maxChars: 4000) { text in
            loadedText = text
            group.leave()
        }

        group.notify(queue: .main) {
            otherTabContexts[tabId] = (title: loadedTitle, text: loadedText)
        }
    }

    /// Builds context string from enabled context sources (current tab + attached files).
    private func buildContextString() -> String? {
        var parts: [String] = []

        // Include current tab context if enabled
        if includeCurrentTab {
            if let url = webViewWrapper.currentURL {
                parts.append("URL: \(url.absoluteString)")
            }
            if let title = pageTitle, !title.isEmpty {
                parts.append("Title: \(title)")
            }
            if let text = pageText, !text.isEmpty {
                parts.append("Page content:\n\(text)")
            }
        }

        // Include other tabs (same format as current tab: URL + title + page content)
        if let tm = webViewWrapper.tabManager {
            for id in includedOtherTabIds {
                if let url = tm.tabURL[id] ?? nil {
                    var tabParts: [String] = []
                    tabParts.append("URL: \(url.absoluteString)")
                    let context = otherTabContexts[id]
                    if let title = context?.title, !title.isEmpty {
                        tabParts.append("Title: \(title)")
                    } else if let t = tm.tabTitle[id], !t.isEmpty {
                        tabParts.append("Title: \(t)")
                    }
                    if let text = context?.text, !text.isEmpty {
                        tabParts.append("Page content:\n\(text)")
                    }
                    parts.append(tabParts.joined(separator: "\n"))
                }
            }
        }

        // Include attached documents
        for doc in attachedDocuments {
            parts.append("Document \"\(doc.displayName)\":\n\(doc.textForContext)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func otherTabLabel(tabId: UUID) -> String {
        guard let tm = webViewWrapper.tabManager else { return "Tab" }
        if let title = tm.tabTitle[tabId], !title.isEmpty { return title }
        if let url = tm.tabURL[tabId] ?? nil, let host = url.host { return host }
        return "Tab"
    }

    private func removeIncludedOtherTab(id: UUID) {
        includedOtherTabIds.removeAll { $0 == id }
        otherTabContexts.removeValue(forKey: id)
    }

    private func sendCommand() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        errorMessage = nil
        actionProposedMessage = nil

        let userMsg = ChatMessage(
            role: .user,
            text: trimmed,
            pageURL: webViewWrapper.currentURL?.absoluteString,
            pageTitle: pageTitle
        )
        messages.append(userMsg)
        inputText = ""

        let context = buildContextString()
        proceedWithSend(prompt: trimmed, context: context)
    }

    private func proceedWithSend(prompt: String, context: String?) {
        let promptToSend = prompt
        let contextToSend = context
        
        // Only send last 4-6 messages for immediate context to save tokens
        let recentContext = messages.dropLast().suffix(6)

        let completionHandler: (Result<Data, Error>) -> Void = { result in
            DispatchQueue.main.async {
                isSending = false

                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
                        let assistantMsg = ChatMessage(
                            role: .assistant,
                            text: response.text,
                            pageURL: webViewWrapper.currentURL?.absoluteString,
                            pageTitle: pageTitle
                        )
                        messages.append(assistantMsg)
                        
                        // Auto-summarize every 8 messages
                        checkAndSummarize()
                        
                        if response.action != nil {
                            onActionProposed(response)
                            actionProposedMessage = "Action proposed"
                        }
                    } else {
                        errorMessage = "Failed to parse response"
                    }

                case .failure(let error):
                    let msg = error.localizedDescription
                    errorMessage = msg
                    let errorMsg = ChatMessage(role: .assistant, text: "Error: \(msg)")
                    messages.append(errorMsg)
                    actionProposedMessage = nil
                }
            }
        }

        switch aiProvider {
        case .gemini:
            gemini.generate(
                prompt: promptToSend,
                context: contextToSend,
                recentMessages: Array(recentContext),
                conversationSummary: conversationSummary,
                completion: completionHandler
            )
        case .ollama:
            ollama.generate(
                baseURLString: ollamaBaseURL,
                model: ollamaModel,
                prompt: promptToSend,
                context: contextToSend,
                recentMessages: Array(recentContext),
                conversationSummary: conversationSummary,
                completion: completionHandler
            )
        }
    }
    
    private func checkAndSummarize() {
        // Auto-summarize every 8 messages (4 exchanges)
        let messagesToSummarize = messages.count - lastSummarizedMessageCount
        
        if messagesToSummarize >= 8 {
            let messagesToProcess = Array(messages.suffix(messagesToSummarize))
            
            gemini.summarizeConversation(messages: messagesToProcess) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let summary):
                        // Append to existing summary or create new one
                        if let existing = conversationSummary {
                            conversationSummary = "\(existing)\n\nRecent: \(summary)"
                        } else {
                            conversationSummary = summary
                        }
                        lastSummarizedMessageCount = messages.count
                        
                        // Save summary to history if we have a tab ID
                        if let tabId = tabId {
                            let summaryObj = ConversationSummary(
                                tabId: tabId,
                                summary: summary,
                                messageRange: (messages.count - messagesToSummarize)...(messages.count - 1)
                            )
                            HistoryManager.shared.addConversationSummary(tabId: tabId, summary: summaryObj)
                        }
                        
                    case .failure:
                        // Silently fail - summarization is optimization, not critical
                        break
                    }
                }
            }
        }
    }
}

// MARK: - GrowingTextEditor
//
// Height comes from the NSTextView's own layout manager — no invisible Text
// mirror, no PreferenceKey. The NSTextView reports its content height after
// every keystroke; the SwiftUI frame follows.

private struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var fontSize: CGFloat = 13
    @FocusState.Binding var isFocused: Bool
    var onSubmit: (() -> Void)? = nil
    @Binding var reportedHeight: CGFloat

    @State private var textHeight: CGFloat = 36

    private var font: Font { .system(size: fontSize) }
    private let placeholderColor = Color.white.opacity(0.5)

    var body: some View {
        ZStack(alignment: .topLeading) {
            MultilineTextField(
                text: $text,
                fontSize: fontSize,
                dynamicHeight: $textHeight,
                minHeight: minHeight,
                onSubmit: onSubmit
            )
            .focused($isFocused)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(placeholderColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: textHeight)
        .onChange(of: textHeight) { _, h in reportedHeight = h }
        .onAppear { reportedHeight = textHeight }
        .animation(.easeOut(duration: 0.15), value: textHeight)
    }
}

// MARK: - MultilineTextField (NSTextView wrapper)
//
// Reports its own content height via `dynamicHeight` using the layout manager.
// No internal scrolling — the view always shows all text.

private struct MultilineTextField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat
    var minHeight: CGFloat
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = BorderedTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(white: 0.95, alpha: 1)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        tv.defaultParagraphStyle = paragraphStyle
        tv.typingAttributes[.paragraphStyle] = paragraphStyle
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? BorderedTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        tv.onSubmit = onSubmit
        tv.font = .systemFont(ofSize: fontSize)
        if let container = tv.textContainer {
            let w = scrollView.contentSize.width
            if w > 0 {
                container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            }
        }
        // Defer height recalculation so we don't write @Binding during a view update
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextField
        weak var textView: BorderedTextView?

        init(_ parent: MultilineTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let usedRect = manager.usedRect(for: container)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            let clamped = max(parent.minHeight, newHeight)
            if abs(clamped - parent.dynamicHeight) > 0.5 {
                parent.dynamicHeight = clamped
            }
        }
    }
}

private class BorderedTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isKeypadEnter = event.keyCode == 76
        let isSubmitKey = (isReturn || isKeypadEnter) && !event.modifierFlags.contains(.shift)

        if isSubmitKey {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Allow Cmd+A, Cmd+C, Cmd+V, Cmd+X to work
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Attached documents (upload for AI context)

private struct AttachedDocument: Identifiable {
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

    /// Max chars per document in context to avoid token overflow.
    static let maxCharsInContext: Int = 12_000

    var textForContext: String {
        if extractedText.count <= Self.maxCharsInContext { return extractedText }
        return String(extractedText.prefix(Self.maxCharsInContext)) + "\n\n[Document truncated for length.]"
    }
}

// MARK: - Context Tab View

private struct ContextTabView: View {
    let label: String
    let isCurrentTab: Bool
    let leadingSymbol: String?
    let onRemove: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: resolvedLeadingSymbol)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.6))
            
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.12))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(isCurrentTab ? "Current tab: \(label)" : "File: \(label)")
        .accessibilityHint("Hover to remove from context")
    }

    private var resolvedLeadingSymbol: String {
        if let s = leadingSymbol { return s }
        if isCurrentTab { return "globe" }
        return "doc.fill"
    }
}

// MARK: - Add tab context sheet

private struct AddTabContextSheet: View {
    let tabManager: TabManager?
    let currentTabId: UUID?
    let alreadyIncluded: Set<UUID>
    let onAdd: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var orderedTabs: [UUID] {
        guard let tm = tabManager else { return [] }
        return tm.tabOrder
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            content
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                panelGlassTint.opacity(panelGlassTintOpacity)
            }
        )
    }

    private var header: some View {
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
    }

    private var content: some View {
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
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || isIncluded)
        .opacity(isCurrent ? 0.7 : 1.0)
    }

    private func tabTitle(id: UUID) -> String {
        guard let tm = tabManager else { return "Tab" }
        if let title = tm.tabTitle[id], !title.isEmpty { return title }
        if let url = tm.tabURL[id] ?? nil { return url.host ?? url.absoluteString }
        return "Tab"
    }

    private func tabSubtitle(id: UUID) -> String? {
        guard let tm = tabManager else { return nil }
        guard let url = tm.tabURL[id] ?? nil else { return nil }
        let s = url.absoluteString
        return s.isEmpty ? nil : s
    }
}

private enum DocumentTextExtractor {
    static let supportedExtensions: Set<String> = ["pdf", "txt", "md", "json", "csv", "xml", "html"]

    static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            return doc.string
        case "txt", "md", "json", "csv", "xml", "html":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16))
        default:
            return nil
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
