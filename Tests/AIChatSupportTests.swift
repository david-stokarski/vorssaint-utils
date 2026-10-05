// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: AI Chat's model ids, request bodies, stream parsing and Markdown
/// blocks, for both providers.
enum AIChatSupportTests {
    static func run(_ suite: TestSuite) {
        // Model choices round-trip, and a model id may itself contain colons.
        let choice = AIModelChoice(provider: .anthropic, model: "claude-opus-5-5")
        suite.expect(AIModelChoice(storageValue: choice.storageValue) == choice, "model choice round-trips")
        suite.expect(AIModelChoice(storageValue: "openai:ft:gpt-5:me")?.model == "ft:gpt-5:me",
                     "a model id keeps its own colons")
        suite.expect(AIModelChoice(storageValue: "nope:gpt") == nil, "an unknown provider is refused")
        suite.expect(AIModelChoice(storageValue: "openai:") == nil, "an empty model is refused")
        suite.expect(AIChatSupport.displayName(forModel: "claude-opus-5-5") == "Claude Opus 5.5",
                     "Claude ids read as names")
        suite.expect(AIChatSupport.displayName(forModel: "claude-haiku-4-5-20251001") == "Claude Haiku 4.5",
                     "a dated Claude id drops the date")
        suite.expect(AIChatSupport.displayName(forModel: "gpt-5") == "gpt-5", "other ids are left alone")

        // Titles.
        suite.expect(AIChatSupport.title(from: "  hello there\nsecond line") == "hello there",
                     "the title is the first line")
        let long = AIChatSupport.title(from: String(repeating: "word ", count: 40))
        suite.expect(long.count <= AIChatSupport.titleLength && long.hasSuffix("…"), "long titles are trimmed")

        // Requests.
        let messages = [AIChatMessage(role: .user, text: "Hi"),
                        AIChatMessage(role: .assistant, text: ""),
                        AIChatMessage(role: .user, text: "Again")]
        let anthropic = AIChatSupport.request(for: choice, apiKey: "k", system: "Be brief", messages: messages)
        let anthropicBody = body(anthropic)
        suite.expect(anthropic.url?.host == "api.anthropic.com"
                        && anthropic.value(forHTTPHeaderField: "x-api-key") == "k"
                        && anthropic.value(forHTTPHeaderField: "anthropic-version") != nil,
                     "Anthropic request carries its headers")
        suite.expect(anthropicBody["system"] as? String == "Be brief"
                        && anthropicBody["max_tokens"] as? Int == AIChatSupport.anthropicMaxTokens
                        && anthropicBody["stream"] as? Bool == true,
                     "Anthropic body has system, max_tokens and stream")
        suite.expect((anthropicBody["messages"] as? [[String: String]])?.count == 2,
                     "an empty assistant turn is not sent")
        let gpt = AIModelChoice(provider: .openai, model: "gpt-5")
        let openai = AIChatSupport.request(for: gpt, apiKey: "k", system: "Be brief", messages: messages)
        let openaiMessages = body(openai)["messages"] as? [[String: String]]
        suite.expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer k",
                     "OpenAI request uses a bearer token")
        suite.expect(openaiMessages?.first?["role"] == "system" && openaiMessages?.count == 3,
                     "OpenAI gets the system prompt as the first message")
        let noSystem = body(AIChatSupport.request(for: gpt, apiKey: "k", system: "  ", messages: messages))
        suite.expect((noSystem["messages"] as? [[String: String]])?.count == 2, "a blank system prompt is left out")

        // Streams.
        let delta = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#
        suite.expect(AIChatSupport.streamEvent(fromLine: delta, provider: .anthropic) == .text("Hel"),
                     "Anthropic text delta")
        suite.expect(AIChatSupport.streamEvent(fromLine: "event: ping", provider: .anthropic) == nil,
                     "event names are skipped")
        suite.expect(AIChatSupport.streamEvent(fromLine: #"data: {"type":"message_stop"}"#, provider: .anthropic) == .done,
                     "Anthropic stop")
        let overloaded = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        suite.expect(AIChatSupport.streamEvent(fromLine: overloaded, provider: .anthropic) == .failure("Overloaded"),
                     "Anthropic stream error")
        let chunk = #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#
        suite.expect(AIChatSupport.streamEvent(fromLine: chunk, provider: .openai) == .text("lo"), "OpenAI delta")
        suite.expect(AIChatSupport.streamEvent(fromLine: "data: [DONE]", provider: .openai) == .done, "OpenAI done")
        suite.expect(AIChatSupport.streamEvent(fromLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
                                               provider: .openai) == nil, "a role-only chunk says nothing")
        suite.expect(AIChatSupport.errorMessage(fromBody: #"{"error":{"message":"Invalid key"}}"#, status: 401)
                        == "Invalid key", "error bodies are read")
        suite.expect(AIChatSupport.errorMessage(fromBody: "<html>", status: 401) == "The API key was rejected.",
                     "unreadable 401 bodies get a plain sentence")

        // Model listings.
        let listing = #"{"data":[{"id":"gpt-4o"},{"id":"gpt-5"},{"id":"text-embedding-3-small"},{"id":"gpt-4o-realtime-preview"},{"id":"o3"},{"id":"dall-e-3"}]}"#
        let chat = AIChatSupport.chatModels(fromListing: Data(listing.utf8), provider: .openai)
        suite.expect(chat.contains("gpt-5") && chat.contains("o3") && chat.contains("gpt-4o"),
                     "OpenAI chat models are kept")
        suite.expect(!chat.contains(where: { $0.contains("embedding") || $0.contains("realtime") || $0.contains("dall") }),
                     "OpenAI non-chat models are dropped")
        suite.expect(chat.first == "gpt-5", "newest OpenAI models come first")

        // Markdown blocks.
        let reply = "# Title\nSome *text*\n- one\n\n```swift\nlet x = 1\n```\nAfter"
        suite.expect(AIChatSupport.blocks(from: reply) == [
            .heading(level: 1, text: "Title"),
            .prose("Some *text*\n- one"),
            .code(language: "swift", text: "let x = 1"),
            .prose("After"),
        ], "replies split into headings, prose and code")
        suite.expect(AIChatSupport.blocks(from: "Look:\n```\npartial") == [.prose("Look:"), .code(language: "", text: "partial")],
                     "an open fence mid-stream is still code")
        suite.expect(AIChatSupport.blocks(from: "#hashtag") == [.prose("#hashtag")], "a hash without a space is prose")
        suite.expect(AIChatSupport.proseLine("  - item") == "  • item", "list markers become bullets")

        // Stored chats decode.
        var conversation = AIChatConversation(model: choice)
        conversation.messages = messages
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try? encoder.encode(conversation)
        let decoded = data.flatMap { try? decoder.decode(AIChatConversation.self, from: $0) }
        suite.expect(decoded?.messages.map(\.text) == messages.map(\.text) && decoded?.model == choice,
                     "a chat round-trips through its file format")
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }
}
