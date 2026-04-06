// Luna — Ollama Client (token-by-token streaming via /api/generate)
import Foundation

final class OllamaClient {

    static var lastNetworkError: String?

    // MARK: - Streaming generate

    @discardableResult
    func generateStreaming(
        baseURLString: String,
        model: String,
        prompt: String,
        context: String?,
        recentMessages: [ChatMessage] = [],
        conversationSummary: String? = nil,
        onToken: @escaping (String) -> Void,
        onCompletion: @escaping (Result<Void, Error>) -> Void
    ) -> Task<Void, Never> {
        Task {
            let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    onCompletion(.failure(OllamaError.configuration("No base URL or model set. Configure in Settings.")))
                }
                return
            }
            guard let url = URL(string: "\(base)/api/chat") else {
                await MainActor.run { onCompletion(.failure(OllamaError.invalidURL)) }
                return
            }

            let body = buildChatBody(model: model, prompt: prompt, context: context,
                                     recentMessages: recentMessages, conversationSummary: conversationSummary, stream: true)
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                await MainActor.run { onCompletion(.failure(OllamaError.invalidURL)) }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData

            do {
                let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let msg = "Ollama HTTP \(http.statusCode)"
                    Self.lastNetworkError = msg
                    await MainActor.run { onCompletion(.failure(OllamaError.serverError(msg))) }
                    return
                }

                var lineBuffer = ""
                for try await byte in asyncBytes {
                    if Task.isCancelled { break }
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        let line = lineBuffer
                        lineBuffer = ""
                        if let token = Self.extractStreamToken(from: line) {
                            let t = token
                            await MainActor.run { onToken(t) }
                        }
                    } else {
                        lineBuffer.append(char)
                    }
                }
                Self.lastNetworkError = nil
                await MainActor.run { onCompletion(.success(())) }
            } catch is CancellationError {
                await MainActor.run { onCompletion(.success(())) }
            } catch {
                Self.lastNetworkError = error.localizedDescription
                await MainActor.run { onCompletion(.failure(OllamaError.network(error.localizedDescription))) }
            }
        }
    }

    // MARK: - Non-streaming generate

    func generate(
        baseURLString: String,
        model: String,
        prompt: String,
        context: String?,
        recentMessages: [ChatMessage] = [],
        conversationSummary: String? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(OllamaError.configuration("No base URL or model set.")))
            }
            return
        }
        guard let url = URL(string: "\(base)/api/chat") else {
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidURL)) }
            return
        }

        let body = buildChatBody(model: model, prompt: prompt, context: context,
                                 recentMessages: recentMessages, conversationSummary: conversationSummary, stream: false)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidURL)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Self.lastNetworkError = error.localizedDescription
                DispatchQueue.main.async { completion(.failure(OllamaError.network(error.localizedDescription))) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(OllamaError.noData)) }
                return
            }
            if let parsed = Self.parseChatResponse(data: data) {
                Self.lastNetworkError = nil
                DispatchQueue.main.async { completion(.success(parsed)) }
            } else {
                let msg = "Failed to parse Ollama response"
                Self.lastNetworkError = msg
                DispatchQueue.main.async { completion(.failure(OllamaError.serverError(msg))) }
            }
        }.resume()
    }

    // MARK: - Model listing

    func listModels(baseURLString: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: "\(base)/api/tags") else {
            DispatchQueue.main.async { completion(.failure(OllamaError.invalidURL)) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(OllamaError.network(error.localizedDescription))) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            let names = models.compactMap { $0["name"] as? String }
            DispatchQueue.main.async { completion(.success(names)) }
        }.resume()
    }

    // MARK: - Helpers

    private func buildChatBody(model: String, prompt: String, context: String?,
                                recentMessages: [ChatMessage], conversationSummary: String?,
                                stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        messages.append(["role": "system", "content": "You are Luna, an intelligent browser assistant. Be concise and accurate. Use Markdown when it improves clarity."])
        if let summary = conversationSummary {
            messages.append(["role": "user", "content": "Previous conversation summary: \(summary)"])
            messages.append(["role": "assistant", "content": "Understood."])
        }
        for msg in recentMessages {
            messages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.text])
        }
        let userContent: String
        if let ctx = context, !ctx.isEmpty {
            userContent = "\(prompt)\n\n---\nContext:\n\(ctx)"
        } else {
            userContent = prompt
        }
        messages.append(["role": "user", "content": userContent])
        return ["model": model, "messages": messages, "stream": stream]
    }

    private static func extractStreamToken(from jsonString: String) -> String? {
        guard !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let done = json["done"] as? Bool, !done,
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else { return nil }
        return content
    }

    private static func parseChatResponse(data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return try? JSONEncoder().encode(LLMResponse(text: content, action: nil))
    }
}

// MARK: - OllamaError

enum OllamaError: LocalizedError {
    case invalidURL
    case noData
    case configuration(String)
    case network(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Ollama URL."
        case .noData: return "No data received from Ollama."
        case .configuration(let m): return m
        case .network(let m): return "Network error: \(m)"
        case .serverError(let m): return m
        }
    }
}
