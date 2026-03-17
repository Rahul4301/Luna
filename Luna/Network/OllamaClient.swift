// Luma MVP - Local/Ollama client
import Foundation

/// Errors that can occur when talking to a local Ollama server.
enum OllamaError: LocalizedError {
    case notConfigured
    case invalidURL
    case networkFailure(String)
    case invalidResponse
    case invalidResponseFormat

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Local model is not configured. Choose a model in Settings."
        case .invalidURL:
            return "Invalid Ollama base URL."
        case .networkFailure(let msg):
            return "Ollama network error: \(msg)"
        case .invalidResponse:
            return "Invalid response from Ollama."
        case .invalidResponseFormat:
            return "Ollama response format not recognized."
        }
    }
}

/// Lightweight client for talking to a local Ollama instance.
/// Default base URL is http://127.0.0.1:11434 (Ollama default).
final class OllamaClient {
    /// Last user-visible network error (for status badges).
    static var lastNetworkError: String?

    /// Lists available models from the local Ollama server.
    /// - Parameters:
    ///   - baseURLString: e.g. "http://127.0.0.1:11434"
    ///   - completion: Called on main queue.
    func listModels(baseURLString: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed) else {
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidURL)) }
            return
        }
        let url = base.appendingPathComponent("api/tags")

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.lastNetworkError = error.localizedDescription
                    completion(.failure(OllamaError.networkFailure(error.localizedDescription)))
                    return
                }
                guard let data = data else {
                    Self.lastNetworkError = "No data from Ollama."
                    completion(.failure(OllamaError.invalidResponse))
                    return
                }
                struct TagsResponse: Decodable {
                    struct Model: Decodable { let name: String }
                    let models: [Model]
                }
                do {
                    let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
                    let names = decoded.models.map { $0.name }
                    Self.lastNetworkError = nil
                    completion(.success(names))
                } catch {
                    Self.lastNetworkError = error.localizedDescription
                    completion(.failure(OllamaError.invalidResponseFormat))
                }
            }
        }.resume()
    }

    /// Generates a response from a local Ollama model using /api/generate (non-streaming).
    /// Returns data encoded as LLMResponse (same as GeminiClient).
    func generate(
        baseURLString: String,
        model: String,
        prompt: String,
        context: String?,
        recentMessages: [ChatMessage] = [],
        conversationSummary: String? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.lastNetworkError = "No local model selected. Choose one in Settings."
            DispatchQueue.main.async { completion(.failure(OllamaError.notConfigured)) }
            return
        }
        guard let base = URL(string: trimmedBase.isEmpty ? "http://127.0.0.1:11434" : trimmedBase) else {
            Self.lastNetworkError = "Invalid Ollama base URL."
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidURL)) }
            return
        }
        let url = base.appendingPathComponent("api/generate")

        // Build conversation-style prompt (simple concatenation for now).
        var conversationParts: [String] = []
        if let conversationSummary = conversationSummary, !conversationSummary.isEmpty {
            conversationParts.append("Conversation so far (summary):\n\(conversationSummary)")
        }
        if !recentMessages.isEmpty {
            let recentText = recentMessages.map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "\(role): \(msg.text)"
            }.joined(separator: "\n\n")
            conversationParts.append(recentText)
        }

        let userMessage: String
        if let context = context, !context.isEmpty {
            userMessage = """
            User: \(prompt)

            Use the following context (current page and/or attached documents) when it is relevant:

            \(context)
            """
        } else {
            userMessage = "User: \(prompt)"
        }
        conversationParts.append(userMessage)

        let fullPrompt = conversationParts.joined(separator: "\n\n")

        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        df.timeZone = .current
        let dateString = df.string(from: now)

        let lunaSystem = """
        You are Luna, an AI-native browser assistant built into the Luma web browser. \
        When users address you as Luna, respond naturally — it's your name. \
        Current date and time: \(dateString). \
        You have access to the current page and any documents the user shares with you. \
        Be helpful, clear, and conversational — thorough when explaining concepts but never wordy or repetitive. \
        Do not use emojis unless the user does first. \
        Format responses with clean markdown: **bold** for key terms, ## / ### headings for sections, \
        bullet or numbered lists for multi-point answers, `inline code` and fenced ```language blocks for code, \
        > blockquotes for callouts, and [links](url) for references. \
        For math and science: ALWAYS use LaTeX dollar-sign delimiters — $...$ for inline math and $$...$$ for display/block equations. \
        NEVER use \\( \\) or \\[ \\] delimiters; only dollar signs. \
        When a paragraph contains math, keep the math and surrounding explanation in the same paragraph \
        so the renderer handles it as one unit. Do not put dollar-sign math inside markdown headings or list items; \
        instead put math-heavy content in its own paragraph. \
        Synthesize information from context — don't just echo it back. \
        When web search results are provided, synthesize and cite sources with markdown links [Source Title](url). \
        Never mention that you are a language model, an LLM, or powered by any specific API. \
        You are simply Luna.\(conversationSummary != nil ? "\n\nPrior conversation: \(conversationSummary!)" : "")
        """

        let body: [String: Any] = [
            "model": model,
            "system": lunaSystem,
            "prompt": fullPrompt,
            "stream": false
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            Self.lastNetworkError = "Failed to build Ollama request."
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidResponse)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.lastNetworkError = error.localizedDescription
                    completion(.failure(OllamaError.networkFailure(error.localizedDescription)))
                    return
                }
                guard let data = data else {
                    Self.lastNetworkError = "No data from Ollama."
                    completion(.failure(OllamaError.invalidResponse))
                    return
                }

                // Typical Ollama /api/generate response: { "response": "text...", ... }
                do {
                    guard let jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let text = jsonObj["response"] as? String, !text.isEmpty else {
                        Self.lastNetworkError = "Ollama response format not recognized."
                        completion(.failure(OllamaError.invalidResponseFormat))
                        return
                    }

                    var browserAction: BrowserAction? = nil
                    // Try to extract JSON action from text (same heuristic as GeminiClient).
                    if let jsonRange = text.range(of: "```json", options: .caseInsensitive) ?? text.range(of: "{"),
                       let jsonEndRange = text.range(of: "}", range: jsonRange.upperBound..<text.endIndex) {
                        let jsonString = String(text[jsonRange.lowerBound..<jsonEndRange.upperBound])
                            .replacingOccurrences(of: "```json", with: "")
                            .replacingOccurrences(of: "```", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        if let jsonData = jsonString.data(using: .utf8),
                           let parsed = try? JSONDecoder().decode(LLMResponse.self, from: jsonData) {
                            browserAction = parsed.action
                        }
                    }

                    let lumaResponse = LLMResponse(text: text, action: browserAction)
                    let encoder = JSONEncoder()
                    let encoded = try encoder.encode(lumaResponse)
                    Self.lastNetworkError = nil
                    completion(.success(encoded))
                } catch {
                    Self.lastNetworkError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}

