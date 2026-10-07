// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: AI Chat's "bring your own model". Any server that speaks OpenAI's
// chat completions (Ollama, LM Studio, OpenRouter, Gemini's compatibility
// layer, a self-hosted proxy) is an endpoint: a name, a base URL, an optional
// key in the keychain and an optional hand-typed model list. The definitions
// travel with a settings backup; the keys never do.

extension DefaultsKey {
    /// JSON array of `AIEndpoint`. No keys in here; they live in the keychain.
    static let aiChatEndpoints = "aiChatEndpoints"
}

/// Where an endpoint started from. Presets only fill in the form; once added,
/// every field is the person's own.
enum AIEndpointPreset: String, Codable, CaseIterable, Identifiable {
    case ollama
    case lmStudio
    case openRouter
    case gemini
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .custom: return "Custom"
        }
    }

    var baseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: return ""
        }
    }

    /// Whether the service wants a key at all. A custom server may or may
    /// not; its key field is offered and can stay empty.
    var needsKey: Bool {
        switch self {
        case .openRouter, .gemini: return true
        case .ollama, .lmStudio, .custom: return false
        }
    }

    var offersKey: Bool { self != .ollama && self != .lmStudio }

    var keyURL: URL? {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .ollama, .lmStudio, .custom: return nil
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openRouter: return "sk-or-…"
        case .gemini: return "AIza…"
        case .ollama, .lmStudio, .custom: return "Optional"
        }
    }

    var hint: String {
        switch self {
        case .ollama: return "Runs on this Mac. Start Ollama and pull a model first."
        case .lmStudio: return "Runs on this Mac. Start LM Studio's local server first."
        case .openRouter: return "Hundreds of models behind one key."
        case .gemini: return "Gemini through Google's OpenAI-compatible endpoint."
        case .custom: return "Any server that speaks OpenAI's chat completions."
        }
    }
}

/// One OpenAI-compatible server the person added.
struct AIEndpoint: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var preset: AIEndpointPreset
    var baseURL: String
    /// Typed by hand. When not empty it replaces whatever the server lists,
    /// for servers that list nothing or list far too much.
    var models: [String]
    /// The model a new chat on this endpoint starts with; empty picks the
    /// first one known.
    var defaultModel: String

    init(id: UUID = UUID(), name: String, preset: AIEndpointPreset, baseURL: String,
         models: [String] = [], defaultModel: String = "") {
        self.id = id
        self.name = name
        self.preset = preset
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
    }

    init(preset: AIEndpointPreset) {
        self.init(name: preset == .custom ? "Custom Server" : preset.title,
                  preset: preset, baseURL: preset.baseURL)
    }

    /// Tolerant, so a field added later, or an edited backup, never drops
    /// the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        preset = (try? container.decode(AIEndpointPreset.self, forKey: .preset)) ?? .custom
        baseURL = (try? container.decode(String.self, forKey: .baseURL)) ?? ""
        models = (try? container.decode([String].self, forKey: .models)) ?? []
        defaultModel = (try? container.decode(String.self, forKey: .defaultModel)) ?? ""
    }

    /// The id that groups this endpoint's models, names its keychain item and
    /// its model cache, and prefixes its models' stored choices.
    var sourceID: String { AIModelChoice.endpointPrefix + id.uuidString }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.title : trimmed
    }

    var normalizedBaseURL: URL? { AIEndpointURL.normalized(baseURL) }

    /// Hand-typed models, cleaned: trimmed, no blanks, no repeats.
    var manualModels: [String] { AIEndpointURL.modelList(models.joined(separator: "\n")) }
}

/// Base URL handling for OpenAI-compatible servers: what people paste is
/// rarely the exact base the API wants.
enum AIEndpointURL {
    /// The API base: a scheme, no trailing slash, no `/chat/completions` or
    /// `/models` pasted along, and `/v1` when only a host was given. A path
    /// that is already there (`/api/v1`, `/v1beta/openai`) is kept.
    static func normalized(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") {
            text = (isLocalHost(hostPart(of: text)) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/completions", "/models"]
        where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.isEmpty ? "/v1" : path
        return components.url
    }

    static func chatURL(base: URL) -> URL { base.appendingPathComponent("chat/completions") }
    static func modelsURL(base: URL) -> URL { base.appendingPathComponent("models") }

    /// The host of something typed without a scheme: `localhost:11434/v1`
    /// reads as `localhost`.
    private static func hostPart(of text: String) -> String {
        let authority = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if authority.hasPrefix("[") {
            return authority.split(separator: "]").first.map { String($0) + "]" } ?? authority
        }
        return authority.split(separator: ":").first.map(String.init) ?? authority
    }

    /// This Mac or the local network, where plain http is allowed (the app
    /// carries the local-networking transport exception for exactly these).
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }
        if !host.contains(".") && !host.contains(":") && !host.isEmpty { return true }  // unqualified
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    static func isLocal(_ url: URL) -> Bool { url.host.map(isLocalHost) ?? false }

    /// Plain http to somewhere on the internet, which macOS refuses outright.
    static func isInsecureRemote(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && !isLocal(url)
    }

    /// Model ids typed one per line or comma separated.
    static func modelList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension AIChatSupport {
    static func endpoints(_ defaults: UserDefaults = .standard) -> [AIEndpoint] {
        decodeEndpoints(defaults.string(forKey: DefaultsKey.aiChatEndpoints))
    }

    static func endpoint(_ id: UUID?, defaults: UserDefaults = .standard) -> AIEndpoint? {
        guard let id else { return nil }
        return endpoints(defaults).first { $0.id == id }
    }

    static func decodeEndpoints(_ raw: String?) -> [AIEndpoint] {
        guard let data = raw?.data(using: .utf8), !data.isEmpty else { return [] }
        // One damaged entry must not take the others with it.
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var seen = Set<UUID>()
        return items.compactMap { item in
            guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let endpoint = try? JSONDecoder().decode(AIEndpoint.self, from: itemData),
                  seen.insert(endpoint.id).inserted else { return nil }
            return endpoint
        }
    }

    static func encodeEndpoints(_ endpoints: [AIEndpoint]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(endpoints) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ids from an OpenAI-compatible `/models` listing, in the server's order.
    /// Gemini prefixes its ids with `models/`, which its chat endpoint does
    /// not need; embedding models cannot chat and are left out.
    static func compatibleModels(fromListing data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return entries.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { id in
                let lower = id.lowercased()
                return !id.isEmpty && !lower.contains("embed") && seen.insert(id).inserted
            }
    }
}
