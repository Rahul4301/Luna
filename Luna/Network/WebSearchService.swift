// Luma — Web search service for Perplexity-style source fetching
import Foundation

struct WebSource: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let snippet: String
    let content: String
}

enum WebSearchError: LocalizedError {
    case noResults
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noResults: return "No web results found."
        case .fetchFailed(let msg): return "Web search failed: \(msg)"
        }
    }
}

enum WebSearchService {

    static func fetchSingleURL(_ url: URL) async -> WebSource? {
        let raw = RawResult(title: url.host ?? url.absoluteString, url: url, snippet: "")
        return await fetchSourceContent(raw)
    }

    static func searchAndFetch(query: String, maxResults: Int = 3) async throws -> [WebSource] {
        let rawResults = try await fetchGoogleResults(query: query, count: maxResults + 2)
        let topResults = Array(rawResults.prefix(maxResults))
        guard !topResults.isEmpty else { throw WebSearchError.noResults }

        return await withTaskGroup(of: WebSource?.self, returning: [WebSource].self) { group in
            for result in topResults {
                group.addTask { await fetchSourceContent(result) }
            }
            var sources: [WebSource] = []
            for await source in group {
                if let s = source { sources.append(s) }
            }
            return sources
        }
    }

    // MARK: - Google results HTML parsing

    private struct RawResult {
        let title: String
        let url: URL
        let snippet: String
    }

    private static func fetchGoogleResults(query: String, count: Int) async throws -> [RawResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)&num=\(count)&hl=en") else {
            throw WebSearchError.fetchFailed("Invalid query")
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 5

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.fetchFailed("Could not decode response")
        }

        return parseGoogleHTML(html)
    }

    private static func parseGoogleHTML(_ html: String) -> [RawResult] {
        var results: [RawResult] = []

        let chunks = html.components(separatedBy: "<a href=\"/url?q=")
        for chunk in chunks.dropFirst() {
            guard let ampIdx = chunk.range(of: "&") else { continue }
            let rawURL = String(chunk[chunk.startIndex..<ampIdx.lowerBound])
            guard let decoded = rawURL.removingPercentEncoding,
                  let linkURL = URL(string: decoded),
                  let host = linkURL.host,
                  !host.contains("google.com"),
                  !host.contains("youtube.com/redirect") else { continue }

            let title = extractFirstText(from: chunk, tag: "h3") ?? linkURL.host ?? decoded
            let snippet = extractSnippet(from: chunk)

            results.append(RawResult(title: title, url: linkURL, snippet: snippet))
        }

        if results.isEmpty {
            return parseGoogleHTMLFallback(html)
        }
        return results
    }

    private static func parseGoogleHTMLFallback(_ html: String) -> [RawResult] {
        var results: [RawResult] = []
        let pattern = "href=\"(https?://[^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var seen = Set<String>()
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let urlString = String(html[range])
            guard let url = URL(string: urlString),
                  let host = url.host,
                  !host.contains("google"),
                  !host.contains("gstatic"),
                  !host.contains("googleapis"),
                  !seen.contains(host) else { continue }
            seen.insert(host)
            results.append(RawResult(title: host, url: url, snippet: ""))
            if results.count >= 5 { break }
        }
        return results
    }

    private static func extractFirstText(from html: String, tag: String) -> String? {
        guard let open = html.range(of: "<\(tag)") else { return nil }
        guard let contentStart = html.range(of: ">", range: open.upperBound..<html.endIndex) else { return nil }
        guard let close = html.range(of: "</\(tag)>", range: contentStart.upperBound..<html.endIndex) else { return nil }
        let inner = String(html[contentStart.upperBound..<close.lowerBound])
        return stripHTML(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSnippet(from chunk: String) -> String {
        let spanPattern = "<span[^>]*>(.*?)</span>"
        guard let regex = try? NSRegularExpression(pattern: spanPattern, options: .dotMatchesLineSeparators) else { return "" }
        let matches = regex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk))

        var best = ""
        for match in matches {
            guard let range = Range(match.range(at: 1), in: chunk) else { continue }
            let text = stripHTML(String(chunk[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > best.count && text.count > 40 {
                best = text
            }
        }
        return String(best.prefix(300))
    }

    // MARK: - Page content fetching

    private static func fetchSourceContent(_ result: RawResult) async -> WebSource? {
        var request = URLRequest(url: result.url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 4

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return WebSource(title: result.title, url: result.url, snippet: result.snippet, content: result.snippet)
        }

        let text = extractMainContent(from: html)
        let trimmed = String(text.prefix(2500))
        return WebSource(title: result.title, url: result.url, snippet: result.snippet, content: trimmed.isEmpty ? result.snippet : trimmed)
    }

    private static func extractMainContent(from html: String) -> String {
        var working = html

        let removeTags = ["script", "style", "nav", "footer", "header", "aside", "noscript", "iframe"]
        for tag in removeTags {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: " ")
            }
        }

        let articlePattern = "<(?:article|main)[^>]*>([\\s\\S]*?)</(?:article|main)>"
        if let regex = try? NSRegularExpression(pattern: articlePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let range = Range(match.range(at: 1), in: working) {
            let articleContent = stripHTML(String(working[range]))
            if articleContent.count > 200 {
                return cleanWhitespace(articleContent)
            }
        }

        let bodyPattern = "<body[^>]*>([\\s\\S]*?)</body>"
        if let regex = try? NSRegularExpression(pattern: bodyPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let range = Range(match.range(at: 1), in: working) {
            return cleanWhitespace(stripHTML(String(working[range])))
        }

        return cleanWhitespace(stripHTML(working))
    }

    // MARK: - HTML utilities

    static func stripHTML(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .dotMatchesLineSeparators) else { return html }
        var result = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&#x27;", "'"), ("&#x2F;", "/"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…")
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }

    private static func cleanWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context formatting

    static func formatSourcesAsContext(_ sources: [WebSource]) -> String {
        guard !sources.isEmpty else { return "" }
        var parts: [String] = ["Web search results:"]
        for (i, source) in sources.enumerated() {
            let section = """
            
            [Source \(i + 1): \(source.title)](\(source.url.absoluteString))
            \(source.content)
            """
            parts.append(section)
        }
        return parts.joined(separator: "\n")
    }
}
