// Luma — RichMessageView: combined MarkdownUI + LaTeXSwiftUI renderer
// Used by both the AI start page (SmartSearchView) and the side AI panel (CommandSurface).
//
// Strategy: split the response into top-level blocks (paragraphs, code fences,
// headings, list groups, etc.). Blocks that contain any LaTeX delimiters ($...$
// or $$...$$) are rendered entirely by LaTeXSwiftUI; all other blocks go through
// MarkdownUI. This avoids fragmented inline splitting that causes visual glitches.
import SwiftUI
import MarkdownUI
import LaTeXSwiftUI

// MARK: - Public view

struct RichMessageView: View {
    let rawText: String
    let fontSize: CGFloat
    let linkColor: Color
    var onLinkTapped: ((URL) -> Void)?

    var body: some View {
        let blocks = Self.parseBlocks(rawText)
        let anyMath = blocks.contains { $0.containsMath }

        if !anyMath {
            markdownView(rawText)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.containsMath {
                        latexBlockView(block.text)
                    } else if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdownView(block.text)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Renderers

    private func markdownView(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(lumaTheme)
            .markdownTextStyle { FontSize(fontSize) }
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                onLinkTapped?(url)
                return .handled
            })
    }

    private func latexBlockView(_ text: String) -> some View {
        LaTeX(text)
            .parsingMode(.onlyEquations)
            .imageRenderingMode(.template)
            .foregroundStyle(Color.white.opacity(0.95))
            .blockMode(.blockViews)
            .errorMode(.original)
            .renderingStyle(.original)
            .renderingAnimation(.easeIn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: fontSize))
    }

    // MARK: - Block parser

    struct ContentBlock {
        let text: String
        let containsMath: Bool
    }

    /// Splits the input into top-level blocks separated by blank lines or code
    /// fences, then tags each block as math or not. Consecutive non-math blocks
    /// are merged so MarkdownUI can render multi-paragraph markdown in one pass.
    static func parseBlocks(_ input: String) -> [ContentBlock] {
        let lines = input.components(separatedBy: "\n")
        var rawBlocks: [String] = []
        var current: [String] = []
        var inCodeFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    current.append(line)
                    rawBlocks.append(current.joined(separator: "\n"))
                    current = []
                    inCodeFence = false
                } else {
                    if !current.isEmpty {
                        rawBlocks.append(current.joined(separator: "\n"))
                        current = []
                    }
                    current.append(line)
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                current.append(line)
                continue
            }

            if trimmed.isEmpty {
                if !current.isEmpty {
                    rawBlocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            rawBlocks.append(current.joined(separator: "\n"))
        }

        // Tag each block and merge consecutive non-math blocks
        var result: [ContentBlock] = []
        var pendingMarkdown: [String] = []

        for block in rawBlocks {
            let hasMath = Self.blockContainsMath(block)
            if hasMath {
                if !pendingMarkdown.isEmpty {
                    result.append(ContentBlock(
                        text: pendingMarkdown.joined(separator: "\n\n"),
                        containsMath: false
                    ))
                    pendingMarkdown = []
                }
                result.append(ContentBlock(text: block, containsMath: true))
            } else {
                pendingMarkdown.append(block)
            }
        }
        if !pendingMarkdown.isEmpty {
            result.append(ContentBlock(
                text: pendingMarkdown.joined(separator: "\n\n"),
                containsMath: false
            ))
        }

        return result
    }

    /// Returns true if the block contains any LaTeX math delimiters.
    /// Supports: $...$  $$...$$  \(...\)  \[...\]  \begin{equation}
    /// Ignores delimiters inside code fences and inline code spans.
    private static func blockContainsMath(_ block: String) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return false }

        var text = block
        // Strip inline code to avoid false positives on `$var` or `\(expr\)`
        while let start = text.range(of: "`"), let end = text[start.upperBound...].range(of: "`") {
            text.replaceSubrange(start.lowerBound...end.lowerBound, with: " ")
        }

        if text.contains("$") { return true }
        if text.contains("\\(") && text.contains("\\)") { return true }
        if text.contains("\\[") && text.contains("\\]") { return true }
        if text.contains("\\begin{equation") { return true }
        return false
    }

    // MARK: - Luma dark theme for MarkdownUI

    private var lumaTheme: MarkdownUI.Theme {
        .init()
            .text { ForegroundColor(Color.white.opacity(0.95)) }
            .link { ForegroundColor(linkColor); UnderlineStyle(.single) }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .strikethrough { StrikethroughStyle(.single) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 10)
                        FontWeight(.bold)
                        ForegroundColor(Color.white)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 6)
                        FontWeight(.bold)
                        ForegroundColor(Color.white)
                    }
                    .markdownMargin(top: 14, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 3)
                        FontWeight(.semibold)
                        ForegroundColor(Color.white)
                    }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 1)
                        FontWeight(.semibold)
                        ForegroundColor(Color.white.opacity(0.9))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize)
                        FontWeight(.semibold)
                        ForegroundColor(Color.white.opacity(0.85))
                    }
                    .markdownMargin(top: 8, bottom: 2)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize)
                        FontWeight(.medium)
                        ForegroundColor(Color.white.opacity(0.8))
                    }
                    .markdownMargin(top: 6, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(fontSize - 1)
                            ForegroundColor(Color.white.opacity(0.9))
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .markdownMargin(top: 4, bottom: 4)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(fontSize - 1)
                BackgroundColor(Color.white.opacity(0.1))
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(Color.white.opacity(0.7)) }
                        .padding(.leading, 10)
                }
                .markdownMargin(top: 4, bottom: 4)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .table { configuration in
                configuration.label
                    .markdownTextStyle { FontSize(fontSize - 1) }
                    .markdownMargin(top: 4, bottom: 4)
            }
            .thematicBreak {
                Divider()
                    .overlay(Color.white.opacity(0.15))
                    .markdownMargin(top: 8, bottom: 8)
            }
            .image { configuration in
                configuration.label
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
    }
}
