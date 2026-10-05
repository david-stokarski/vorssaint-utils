// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: a chat window for AI assistants that is not tied to one vendor, and
// the Command Bar's "Ask AI" fallback. Preferences, the stored chat format,
// request building and stream parsing live here, where the tests compile them;
// the window, the keychain and the network are in Services/AIChat.

extension DefaultsKey {
    /// `provider:model`, the model a new chat and "Ask AI" start with.
    static let aiChatDefaultModel = "aiChatDefaultModel"
    static let aiChatSystemPrompt = "aiChatSystemPrompt"
    /// Offer "Ask AI" in the Command Bar when a search finds nothing.
    static let commandBarAskAI = "commandBarAskAI"
    /// Comma-separated model ids last listed by each provider.
    static func aiChatModelCache(_ provider: AIProvider) -> String { "aiChatModelCache.\(provider.rawValue)" }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Shown until the provider has listed its own models once.
    var fallbackModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"]
        case .openai: return ["gpt-5"]
        }
    }
}

struct AIModelChoice: Hashable, Codable, Identifiable {
    var provider: AIProvider
    var model: String

    var id: String { storageValue }
    var storageValue: String { "\(provider.rawValue):\(model)" }

    init(provider: AIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    init?(storageValue: String?) {
        guard let storageValue, let colon = storageValue.firstIndex(of: ":"),
              let provider = AIProvider(rawValue: String(storageValue[..<colon])) else { return nil }
        let model = String(storageValue[storageValue.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        self.init(provider: provider, model: model)
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
    static let registeredDefaults: [String: Any] = [
        DefaultsKey.aiChatDefaultModel: AIModelChoice.fallbackDefault.storageValue,
        DefaultsKey.aiChatSystemPrompt: "",
        DefaultsKey.commandBarAskAI: true,
    ]

    static let anthropicVersion = "2023-06-01"
    static let anthropicMaxTokens = 16_000
    static let titleLength = 60

    static func defaultModel(_ defaults: UserDefaults = .standard) -> AIModelChoice {
        AIModelChoice(storageValue: defaults.string(forKey: DefaultsKey.aiChatDefaultModel))
            ?? .fallbackDefault
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

    /// The streaming request for one turn. Replies that failed before saying
    /// anything are left out, so a retry does not send an empty assistant turn.
    static func request(for choice: AIModelChoice, apiKey: String, system: String,
                        messages: [AIChatMessage]) -> URLRequest {
        let turns = messages.filter { !$0.text.isEmpty }
            .map { ["role": $0.role.rawValue, "content": $0.text] }
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["model": choice.model, "stream": true]
        var request: URLRequest
        switch choice.provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = anthropicMaxTokens
            body["messages"] = turns
            if !system.isEmpty { body["system"] = system }
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body["messages"] = (system.isEmpty ? [] : [["role": "system", "content": system]]) + turns
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 120
        return request
    }

    static func modelsRequest(for provider: AIProvider, apiKey: String) -> URLRequest {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
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
        case .openai:
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
        switch status {
        case 401: return "The API key was rejected."
        case 429: return "Rate limited. Try again in a moment."
        default: return "The request failed (HTTP \(status))."
        }
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
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return [] }
        let ids = entries.compactMap { $0["id"] as? String }
        switch provider {
        case .anthropic:
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
