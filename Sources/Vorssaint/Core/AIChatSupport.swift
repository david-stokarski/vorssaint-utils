// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: a chat window for AI assistants that is not tied to one vendor, and
// the Command Bar's "Ask AI" fallback. Endpoints are in AIChatEndpoints.swift
// and attachments in AIChatAttachments.swift. Preferences, the stored chat format,
// request building and stream parsing live here, where the tests compile them;
// the window, the keychain and the network are in Services/AIChat.

extension DefaultsKey {
    /// `source:model`, the model a new chat and "Ask AI" start with.
    static let aiChatDefaultModel = "aiChatDefaultModel"
    static let aiChatSystemPrompt = "aiChatSystemPrompt"
    /// Offer "Ask AI" in the Command Bar when a search finds nothing.
    static let commandBarAskAI = "commandBarAskAI"
    /// "Ask about selection": a global shortcut that opens a chat with the
    /// text selected in the app in front already attached.
    static let aiChatSelectionShortcut = "aiChatSelectionShortcut"
    static let aiChatSelectionShortcutEnabled = "aiChatSelectionShortcutEnabled"
    /// Comma-separated model ids last listed by each provider.
    static func aiChatModelCache(_ provider: AIProvider) -> String { aiChatModelCache(source: provider.rawValue) }
    /// The same, for any source: a built-in provider or one endpoint.
    static func aiChatModelCache(source: String) -> String { "aiChatModelCache.\(source)" }
}

/// The wire a model is reached through. Anthropic and OpenAI are built in,
/// with one key each; `compatible` is any number of OpenAI-compatible
/// endpoints the person adds (see `AIEndpoint`).
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case compatible

    /// The providers with a key row of their own.
    static let builtIn: [AIProvider] = [.anthropic, .openai]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .compatible: return "OpenAI-compatible"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .compatible: return "Optional"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai, .compatible: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Shown until the provider has listed its own models once.
    var fallbackModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"]
        case .openai: return ["gpt-5"]
        case .compatible: return []
        }
    }

    /// Whether requests use Anthropic's Messages API rather than OpenAI's
    /// chat completions.
    var usesMessagesAPI: Bool { self == .anthropic }
}

struct AIModelChoice: Hashable, Codable, Identifiable {
    static let endpointPrefix = "compatible."

    var provider: AIProvider
    var model: String
    /// The endpoint an OpenAI-compatible model is served by; nil otherwise.
    var endpointID: UUID?

    var id: String { storageValue }
    /// What groups models in the picker and names the keychain item and the
    /// model cache: `anthropic`, `openai` or `compatible.<endpoint id>`.
    var sourceID: String {
        guard provider == .compatible, let endpointID else { return provider.rawValue }
        return Self.endpointPrefix + endpointID.uuidString
    }
    var storageValue: String { "\(sourceID):\(model)" }

    init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    init(endpoint: UUID, model: String) {
        self.provider = .compatible
        self.model = model
        self.endpointID = endpoint
    }

    /// `anthropic:claude-…`, `openai:gpt-…` or `compatible.<uuid>:llama3.2:latest`.
    /// Only the first colon separates; model ids keep their own.
    init?(storageValue: String?) {
        guard let storageValue, let colon = storageValue.firstIndex(of: ":") else { return nil }
        let source = String(storageValue[..<colon])
        let model = String(storageValue[storageValue.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        if source.hasPrefix(Self.endpointPrefix) {
            guard let id = UUID(uuidString: String(source.dropFirst(Self.endpointPrefix.count))) else { return nil }
            self.init(endpoint: id, model: model)
        } else {
            guard let provider = AIProvider(rawValue: source), provider != .compatible else { return nil }
            self.init(provider: provider, model: model)
        }
    }

    /// "claude-opus-5-5" reads as "Claude Opus 5.5"; ids it does not know are
    /// shown as they are.
    var displayName: String { AIChatSupport.displayName(forModel: model) }

    static let fallbackDefault = AIModelChoice(provider: .anthropic, model: "claude-opus-5-5")
}

struct AIChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    /// The model that wrote an assistant reply.
    var model: String?
    /// Why a reply stopped short; shown under it and not sent back.
    var error: String?
    /// What the question carried: selections, screenshots, files. Optional
    /// so chats saved before attachments still open.
    var attachments: [AIChatAttachment]?
}

struct AIChatConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var created = Date()
    var updated = Date()
    var model: AIModelChoice
    var messages: [AIChatMessage] = []

    var displayTitle: String { title.isEmpty ? "New Chat" : title }
}

/// One thing a provider's event stream said.
enum AIStreamEvent: Equatable {
    case text(String)
    case done
    case failure(String)
}

enum AIChatSupport {
    static let title = "AI Chat"
    static let askSelectionTitle = "Ask AI About Selection"
    static let hubDescription = "Chat with Claude, GPT, local models and any OpenAI-compatible server using your own keys, with your selection, a window or a screenshot attached."
    static let registeredDefaults: [String: Any] = [
        DefaultsKey.aiChatDefaultModel: AIModelChoice.fallbackDefault.storageValue,
        DefaultsKey.aiChatSystemPrompt: "",
        DefaultsKey.commandBarAskAI: true,
        DefaultsKey.aiChatEndpoints: "[]",
        DefaultsKey.aiChatSelectionShortcut: GlobalShortcut.aiChatSelectionDefault.storageValue,
        DefaultsKey.aiChatSelectionShortcutEnabled: false,
    ]

    static let anthropicVersion = "2023-06-01"
    static let anthropicMaxTokens = 16_000
    static let titleLength = 60

    /// A default on an endpoint that was since removed falls back to Claude.
    static func defaultModel(_ defaults: UserDefaults = .standard) -> AIModelChoice {
        guard let choice = AIModelChoice(storageValue: defaults.string(forKey: DefaultsKey.aiChatDefaultModel))
        else { return .fallbackDefault }
        if choice.provider == .compatible, endpoint(choice.endpointID, defaults: defaults) == nil {
            return .fallbackDefault
        }
        return choice
    }

    /// The first line of the first thing asked, trimmed to fit a sidebar row.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > titleLength else { return trimmed }
        return String(trimmed.prefix(titleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func displayName(forModel model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return model }
        // claude-<family>-<major>-<minor>[-<date>]
        var words = ["Claude", parts[1].capitalized]
        let numbers = parts.dropFirst(2).filter { $0.count < 8 && Int($0) != nil }
        if !numbers.isEmpty { words.append(numbers.joined(separator: ".")) }
        return words.joined(separator: " ")
    }

    // MARK: - Requests

    /// The streaming request for one turn, from stored messages. Text
    /// attachments are folded in; images are not, since they are read from
    /// disk (the chat window loads them and uses the `turns:` variant). An
    /// endpoint model's endpoint is looked up in preferences.
    static func request(for choice: AIModelChoice, apiKey: String, system: String,
                        messages: [AIChatMessage]) -> URLRequest {
        let turns = AIChatAttachments.turns(from: messages, imageData: { _ in nil })
        if let request = request(for: choice, endpoint: endpoint(choice.endpointID), apiKey: apiKey,
                                 system: system, turns: turns) {
            return request
        }
        // An endpoint that is gone: a request that fails plainly, not one
        // sent somewhere else.
        var request = URLRequest(url: URL(string: "vorssaint-missing-endpoint:")!)
        request.httpMethod = "POST"
        return request
    }

    /// The request for a list of turns. Nil only for an endpoint model whose
    /// endpoint is missing or has no usable base URL. An empty key sends no
    /// authorization at all, which is what local servers expect.
    static func request(for choice: AIModelChoice, endpoint: AIEndpoint?, apiKey: String?,
                        system: String, turns: [AIChatTurn], stream: Bool = true) -> URLRequest? {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["model": choice.model, "stream": stream]
        var request: URLRequest
        switch choice.provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = anthropicMaxTokens
            body["messages"] = turns.map(anthropicMessage)
            if !system.isEmpty { body["system"] = system }
        case .openai, .compatible:
            if choice.provider == .openai {
                request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            } else {
                guard let endpoint, endpoint.id == choice.endpointID,
                      let base = endpoint.normalizedBaseURL else { return nil }
                request = URLRequest(url: AIEndpointURL.chatURL(base: base))
                if endpoint.preset == .openRouter {
                    request.setValue("Vorssaint", forHTTPHeaderField: "X-Title")
                }
            }
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body["messages"] = (system.isEmpty ? [] : [["role": "system", "content": system]])
                + turns.map(openAIMessage)
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // A local model can take a while to load before its first word.
        request.timeoutInterval = choice.provider == .compatible ? 300 : 120
        return request
    }

    /// Plain text stays a string; with images it becomes content blocks,
    /// images first as Anthropic recommends.
    static func anthropicMessage(_ turn: AIChatTurn) -> [String: Any] {
        guard turn.role == .user, !turn.images.isEmpty else {
            return ["role": turn.role.rawValue, "content": turn.text]
        }
        var content: [[String: Any]] = turn.images.map { image in
            ["type": "image",
             "source": ["type": "base64", "media_type": image.mediaType,
                        "data": image.data.base64EncodedString()]]
        }
        if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
        return ["role": turn.role.rawValue, "content": content]
    }

    static func openAIMessage(_ turn: AIChatTurn) -> [String: Any] {
        guard turn.role == .user, !turn.images.isEmpty else {
            return ["role": turn.role.rawValue, "content": turn.text]
        }
        var content: [[String: Any]] = turn.text.isEmpty ? [] : [["type": "text", "text": turn.text]]
        content += turn.images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
        return ["role": turn.role.rawValue, "content": content]
    }

    static func modelsRequest(for provider: AIProvider, apiKey: String) -> URLRequest {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai, .compatible:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        return request
    }

    /// GET {base}/models for an endpoint; nil without a usable base URL.
    static func modelsRequest(for endpoint: AIEndpoint, apiKey: String?) -> URLRequest? {
        guard let base = endpoint.normalizedBaseURL else { return nil }
        var request = URLRequest(url: AIEndpointURL.modelsURL(base: base))
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 10
        return request
    }

    // MARK: - Responses

    /// One line of a server-sent event stream. Only `data:` lines carry
    /// anything; event names, comments and keep-alives return nil.
    static func streamEvent(fromLine line: String, provider: AIProvider) -> AIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let message = errorMessage(in: object) { return .failure(message) }
        switch provider {
        case .anthropic:
            switch object["type"] as? String {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                guard delta?["type"] as? String == "text_delta",
                      let text = delta?["text"] as? String else { return nil }
                return .text(text)
            case "message_stop":
                return .done
            default:
                return nil
            }
        case .openai, .compatible:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
            if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                return .text(text)
            }
            return nil
        }
    }

    /// The readable part of an error body, from either provider.
    static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["type"] as? String) ?? "Unknown error"
        }
        if let error = object["error"] as? String { return error }
        return nil
    }

    static func errorMessage(fromBody body: String, status: Int) -> String {
        if let data = body.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = errorMessage(in: object) {
            return message
        }
        // Some servers wrap the error object in a list.
        if let data = body.data(using: .utf8),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let message = list.lazy.compactMap(errorMessage).first {
            return message
        }
        switch status {
        case 401, 403: return "The API key was rejected."
        case 404: return "Nothing answered at that address. Check the endpoint's URL and the model name."
        case 429: return "Rate limited. Try again in a moment."
        default: return "The request failed (HTTP \(status))."
        }
    }

    /// A failed request that carried images most often failed because the
    /// model cannot read them. The server's own words come first; the hint
    /// only says what to try. No list of which model sees what is kept here,
    /// since that changes faster than the app does.
    static func failureMessage(_ message: String, status: Int, sentImages: Bool) -> String {
        guard sentImages, status >= 400, ![401, 403, 429].contains(status) else { return message }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.last.map { ".!?".contains($0) } == true ? trimmed : trimmed + "."
        return sentence + " If this model can't read images, remove them or pick another model."
    }

    // MARK: - Markdown

    enum Block: Equatable {
        case prose(String)
        case heading(level: Int, text: String)
        case code(language: String, text: String)
    }

    /// A reply split into the pieces drawn differently: fenced code, headings
    /// and the prose between them. A fence still open (mid-stream) runs to
    /// the end, so code looks like code while it is being written.
    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushProse()
                blocks.append(.heading(level: hashes,
                                       text: String(trimmed.dropFirst(hashes + 1))))
                continue
            }
            prose.append(line)
        }
        if let lines = code {
            blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
        }
        flushProse()
        return blocks
    }

    /// List markers drawn as bullets; the rest is left to inline Markdown.
    static func proseLine(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return indent + "• " + rest.dropFirst(2)
        }
        return line
    }

    /// Model ids a chat can use, newest first as the provider lists them.
    /// OpenAI lists every model it has, so speech, image, embedding and
    /// realtime models are left out.
    static func chatModels(fromListing data: Data, provider: AIProvider) -> [String] {
        if provider == .compatible { return compatibleModels(fromListing: data) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return [] }
        let ids = entries.compactMap { $0["id"] as? String }
        switch provider {
        case .anthropic, .compatible:
            return ids
        case .openai:
            let excluded = ["audio", "realtime", "transcribe", "tts", "image", "embedding",
                            "search", "moderation", "instruct", "codex", "dall-e", "whisper"]
            let chat = ids.filter { id in
                (id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-")
                    || ["o1", "o3", "o4"].contains(where: { id == $0 || id.hasPrefix($0 + "-") }))
                    && !excluded.contains(where: id.contains)
            }
            // GPT models first, then the o-series, newest first within each.
            func family(_ id: String) -> Int { id.hasPrefix("gpt-") ? 0 : id.hasPrefix("o") ? 1 : 2 }
            return chat.sorted {
                family($0) != family($1) ? family($0) < family($1)
                    : $0.localizedStandardCompare($1) == .orderedDescending
            }
        }
    }
}
