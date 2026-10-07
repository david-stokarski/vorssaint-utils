// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
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
        let oldFile = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"","created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z","model":{"provider":"anthropic","model":"claude-opus-5-5"},"messages":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F0","role":"user","text":"Hi","date":"2026-01-01T00:00:00Z"}]}"#
        let old = try? decoder.decode(AIChatConversation.self, from: Data(oldFile.utf8))
        suite.expect(old?.messages.first?.attachments == nil && old?.model.endpointID == nil,
                     "a chat saved before endpoints and attachments still opens")

        endpoints(suite)
        attachments(suite, encoder: encoder, decoder: decoder)
    }

    private static func endpoints(_ suite: TestSuite) {
        // Stored choices for endpoint models.
        let id = UUID()
        let local = AIModelChoice(endpoint: id, model: "llama3.2:latest")
        suite.expect(local.storageValue == "compatible.\(id.uuidString):llama3.2:latest"
                        && AIModelChoice(storageValue: local.storageValue) == local,
                     "an endpoint model round-trips and keeps the colons in its id")
        suite.expect(AIModelChoice(storageValue: "compatible:llama3") == nil
                        && AIModelChoice(storageValue: "compatible.not-a-uuid:llama3") == nil,
                     "an endpoint model needs its endpoint")
        suite.expect(local.sourceID != AIModelChoice(endpoint: UUID(), model: "llama3.2:latest").sourceID
                        && AIModelChoice(provider: .openai, model: "gpt-5").sourceID == "openai",
                     "each endpoint is its own source; built-in providers keep their old ids")
        suite.expect(DefaultsKey.aiChatModelCache(.anthropic) == "aiChatModelCache.anthropic",
                     "the built-in model cache keeps its old key")

        // Base URLs.
        func normalized(_ raw: String) -> String? { AIEndpointURL.normalized(raw)?.absoluteString }
        suite.expect(normalized("http://localhost:11434/v1/") == "http://localhost:11434/v1",
                     "a trailing slash is dropped")
        suite.expect(normalized("localhost:11434") == "http://localhost:11434/v1",
                     "a bare local host gets http and /v1")
        suite.expect(normalized("openrouter.ai/api/v1") == "https://openrouter.ai/api/v1",
                     "a bare remote host gets https and keeps its path")
        suite.expect(normalized("https://openrouter.ai/api/v1/chat/completions") == "https://openrouter.ai/api/v1",
                     "a pasted chat completions URL becomes the base")
        suite.expect(normalized("http://127.0.0.1:1234/v1/models") == "http://127.0.0.1:1234/v1",
                     "a pasted models URL becomes the base")
        suite.expect(normalized(AIEndpointPreset.gemini.baseURL + "/")
                        == "https://generativelanguage.googleapis.com/v1beta/openai",
                     "a path that is not /v1 is kept")
        suite.expect(normalized("") == nil && normalized("ftp://host/v1") == nil && normalized("not a url") == nil,
                     "empty, non-web and spaced addresses are refused")
        suite.expect(AIEndpointURL.isLocalHost("localhost") && AIEndpointURL.isLocalHost("192.168.1.20")
                        && AIEndpointURL.isLocalHost("10.0.0.2") && AIEndpointURL.isLocalHost("mac-studio.local")
                        && AIEndpointURL.isLocalHost("[::1]") && !AIEndpointURL.isLocalHost("openrouter.ai")
                        && !AIEndpointURL.isLocalHost("8.8.8.8") && !AIEndpointURL.isLocalHost("172.40.0.1"),
                     "local hosts are this Mac and the local network")
        suite.expect(AIEndpointURL.isInsecureRemote(URL(string: "http://example.com/v1")!)
                        && !AIEndpointURL.isInsecureRemote(URL(string: "http://localhost:11434/v1")!),
                     "plain http to the internet is flagged")
        suite.expect(AIEndpointURL.modelList(" a\nb, a\n\n c ") == ["a", "b", "c"],
                     "hand-typed models are trimmed and deduplicated")
        for preset in AIEndpointPreset.allCases where preset != .custom {
            suite.expect(AIEndpointURL.normalized(preset.baseURL)?.absoluteString == preset.baseURL,
                         "the \(preset.title) preset is already normalized")
        }

        // Stored endpoints.
        var ollama = AIEndpoint(preset: .ollama)
        ollama.models = ["llama3.2:latest"]
        let router = AIEndpoint(preset: .openRouter)
        let encoded = AIChatSupport.encodeEndpoints([ollama, router])
        suite.expect(AIChatSupport.decodeEndpoints(encoded) == [ollama, router], "endpoints round-trip")
        suite.expect(!encoded.contains("sk-") && !encoded.lowercased().contains("key"),
                     "no key is written with the endpoints")
        let damaged = "[\(AIChatSupport.encodeEndpoints([ollama]).dropFirst().dropLast()),{\"name\":\"no id\"}]"
        suite.expect(AIChatSupport.decodeEndpoints(damaged) == [ollama], "a damaged entry leaves the others")
        let sparse = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","baseURL":"http://h:1/v1","preset":"later"}]"#
        suite.expect(AIChatSupport.decodeEndpoints(sparse).first?.preset == .custom
                        && AIChatSupport.decodeEndpoints(sparse).first?.displayName == "Custom",
                     "an endpoint with missing or unknown fields still loads")
        suite.expect(AIChatSupport.decodeEndpoints(nil).isEmpty && AIChatSupport.decodeEndpoints("{").isEmpty,
                     "nothing stored is no endpoints")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.aiChatEndpoints),
                     "endpoints travel with a settings backup")
        suite.expect(!SettingsBackupSupport.exportKeys().contains { $0.hasPrefix("aiChatModelCache") },
                     "listed models stay on this Mac")

        if let defaults = UserDefaults(suiteName: "vorss.tests.aichat") {
            defaults.removePersistentDomain(forName: "vorss.tests.aichat")
            defaults.set(AIModelChoice(endpoint: ollama.id, model: "llama3.2:latest").storageValue,
                         forKey: DefaultsKey.aiChatDefaultModel)
            suite.expect(AIChatSupport.defaultModel(defaults) == .fallbackDefault,
                         "a default on a missing endpoint falls back to Claude")
            defaults.set(AIChatSupport.encodeEndpoints([ollama]), forKey: DefaultsKey.aiChatEndpoints)
            suite.expect(AIChatSupport.defaultModel(defaults).endpointID == ollama.id,
                         "a default on an endpoint that exists is kept")
            defaults.removePersistentDomain(forName: "vorss.tests.aichat")
        }

        // Endpoint requests.
        let turns = [AIChatTurn(role: .user, text: "Hi")]
        let localChoice = AIModelChoice(endpoint: ollama.id, model: "llama3.2:latest")
        let localRequest = AIChatSupport.request(for: localChoice, endpoint: ollama, apiKey: nil,
                                                 system: "Be brief", turns: turns)
        suite.expect(localRequest?.url?.absoluteString == "http://localhost:11434/v1/chat/completions"
                        && localRequest?.value(forHTTPHeaderField: "Authorization") == nil,
                     "a local endpoint gets chat completions and no authorization")
        let localMessages = localRequest.map(body)?["messages"] as? [[String: String]]
        suite.expect(localMessages?.first?["role"] == "system" && localMessages?.count == 2
                        && localRequest.map(body)?["model"] as? String == "llama3.2:latest",
                     "an endpoint request is shaped like OpenAI's")
        let routerChoice = AIModelChoice(endpoint: router.id, model: "openai/gpt-4o")
        let routerRequest = AIChatSupport.request(for: routerChoice, endpoint: router, apiKey: " k ",
                                                  system: "", turns: turns)
        suite.expect(routerRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer k",
                     "an endpoint key is sent as a bearer token")
        suite.expect(AIChatSupport.request(for: routerChoice, endpoint: ollama, apiKey: nil, system: "", turns: turns) == nil
                        && AIChatSupport.request(for: routerChoice, endpoint: nil, apiKey: nil, system: "", turns: turns) == nil,
                     "an endpoint model is never sent to another endpoint")
        suite.expect(AIChatSupport.modelsRequest(for: ollama, apiKey: nil)?.url?.absoluteString
                        == "http://localhost:11434/v1/models",
                     "models are listed from {base}/models")
        let chunk = #"data: {"choices":[{"index":0,"delta":{"content":"hey"}}]}"#
        suite.expect(AIChatSupport.streamEvent(fromLine: chunk, provider: .compatible) == .text("hey")
                        && AIChatSupport.streamEvent(fromLine: #"data: {"error":"model not found"}"#,
                                                     provider: .compatible) == .failure("model not found"),
                     "endpoint streams read like OpenAI's, errors included")

        // Listings.
        let ollamaListing = #"{"object":"list","data":[{"id":"llama3.2:latest"},{"id":"nomic-embed-text:latest"},{"id":"qwen3:8b"}]}"#
        suite.expect(AIChatSupport.chatModels(fromListing: Data(ollamaListing.utf8), provider: .compatible)
                        == ["llama3.2:latest", "qwen3:8b"],
                     "endpoint listings keep their order and drop embedding models")
        let geminiListing = #"{"object":"list","data":[{"id":"models/gemini-2.5-flash"},{"id":"models/text-embedding-004"}]}"#
        suite.expect(AIChatSupport.chatModels(fromListing: Data(geminiListing.utf8), provider: .compatible)
                        == ["gemini-2.5-flash"], "Gemini's models/ prefix is dropped")
        suite.expect(AIChatSupport.errorMessage(fromBody: #"[{"error":{"message":"API key not valid"}}]"#, status: 400)
                        == "API key not valid", "an error wrapped in a list is read")
    }

    private static func attachments(_ suite: TestSuite, encoder: JSONEncoder, decoder: JSONDecoder) {
        // Text attachments become fenced blocks ahead of the question.
        let selection = AIChatAttachment.text("let a = 1", title: "Selection from Xcode", origin: .selection)
        suite.expect(AIChatAttachments.composedText("What does this do?", attachments: [selection])
                        == "Selection from Xcode:\n```\nlet a = 1\n```\n\nWhat does this do?",
                     "a text attachment is a fenced block before the question")
        suite.expect(AIChatAttachments.fence(for: "has ``` inside") == "````"
                        && AIChatAttachments.fence(for: "plain") == "```",
                     "the fence outgrows any backticks in the text")
        suite.expect(AIChatAttachments.composedText("", attachments: [selection]).hasSuffix("```"),
                     "an attachment can be sent without a question")
        let blank = AIChatAttachment.text("  \n", title: "Empty", origin: .selection)
        suite.expect(AIChatAttachments.composedText("Hi", attachments: [blank]) == "Hi", "blank text adds nothing")
        suite.expect(AIChatAttachments.clipped(String(repeating: "x", count: AIChatAttachments.maximumTextLength + 10))
                        .count < AIChatAttachments.maximumTextLength + 60,
                     "very long text is cut")

        // Turns: images are resolved, failed replies dropped.
        let image = AIChatImage(mediaType: "image/jpeg", data: Data([1, 2, 3]))
        let shot = AIChatAttachment(kind: .image, origin: .area, title: "Screenshot", file: "a.jpg",
                                    mediaType: "image/jpeg")
        let gone = AIChatAttachment(kind: .image, origin: .window, title: "Gone", file: "b.jpg",
                                    mediaType: "image/jpeg")
        let messages = [AIChatMessage(role: .user, text: "Look", attachments: [shot, gone, selection]),
                        AIChatMessage(role: .assistant, text: ""),
                        AIChatMessage(role: .user, text: "", attachments: [shot])]
        let turns = AIChatAttachments.turns(from: messages) { $0.file == "a.jpg" ? image : nil }
        suite.expect(turns.count == 2 && turns[0].images == [image] && turns[0].text.hasSuffix("Look")
                        && turns[0].text.contains("let a = 1") && turns[1].text.isEmpty && turns[1].images.count == 1,
                     "turns carry their images and text blocks; a missing image file is skipped")

        // Image content blocks.
        let anthropic = AIChatSupport.anthropicMessage(turns[0])
        let blocks = anthropic["content"] as? [[String: Any]]
        let source = blocks?.first?["source"] as? [String: Any]
        suite.expect(blocks?.first?["type"] as? String == "image" && source?["type"] as? String == "base64"
                        && source?["media_type"] as? String == "image/jpeg"
                        && source?["data"] as? String == image.data.base64EncodedString()
                        && blocks?.last?["type"] as? String == "text",
                     "Anthropic gets base64 image blocks before the text")
        let openai = AIChatSupport.openAIMessage(turns[0])
        let parts = openai["content"] as? [[String: Any]]
        suite.expect(parts?.first?["type"] as? String == "text"
                        && (parts?.last?["image_url"] as? [String: Any])?["url"] as? String
                            == "data:image/jpeg;base64,\(image.data.base64EncodedString())",
                     "OpenAI and compatible endpoints get image_url data URLs")
        suite.expect((AIChatSupport.anthropicMessage(turns[1])["content"] as? [[String: Any]])?.count == 1
                        && (AIChatSupport.openAIMessage(turns[1])["content"] as? [[String: Any]])?.count == 1,
                     "an image-only question sends no empty text block")
        suite.expect(AIChatSupport.openAIMessage(AIChatTurn(role: .user, text: "Hi"))["content"] as? String == "Hi",
                     "a question without images stays plain text")

        // A failure with images gets a hint, others do not.
        let hinted = AIChatSupport.failureMessage("Bad request", status: 400, sentImages: true)
        suite.expect(hinted.hasPrefix("Bad request") && hinted.contains("images"), "an image failure says what to try")
        suite.expect(AIChatSupport.failureMessage("Bad request", status: 400, sentImages: false) == "Bad request"
                        && AIChatSupport.failureMessage("Bad key", status: 401, sentImages: true) == "Bad key",
                     "no hint without images or for a rejected key")

        // Images are scaled to fit and encoded.
        let scaled = AIChatAttachments.scaledSize(width: 3136, height: 1000)
        suite.expect(scaled.width == AIChatAttachments.maximumImageEdge && scaled.height == 500,
                     "the long edge is scaled to the maximum")
        suite.expect(AIChatAttachments.scaledSize(width: 800, height: 600) == (800, 600),
                     "small images are not enlarged")
        func make(width: Int, height: Int, alpha: Bool) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                            : CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        if let opaque = make(width: 3000, height: 1500, alpha: false),
           let encoded = AIChatAttachments.encode(opaque),
           let back = AIChatAttachments.image(fromData: encoded.data) {
            suite.expect(encoded.mediaType == "image/jpeg" && back.width == 1568 && back.height == 784,
                         "an opaque image is sent as a JPEG within the maximum")
        } else {
            suite.expect(false, "an opaque image encodes")
        }
        if let clear = make(width: 200, height: 100, alpha: true),
           let encoded = AIChatAttachments.encode(clear),
           let back = AIChatAttachments.image(fromData: encoded.data) {
            suite.expect(encoded.mediaType == "image/png" && back.width == 200,
                         "an image with transparency stays PNG at its own size")
        } else {
            suite.expect(false, "a transparent image encodes")
        }
        suite.expect(AIChatAttachments.text(fromFileData: Data("hello".utf8)) == "hello"
                        && AIChatAttachments.text(fromFileData: Data([0x89, 0x50, 0x00, 0x47])) == nil,
                     "text files are read and binary files are not")

        // Attachments persist by file name, not by content.
        var conversation = AIChatConversation(model: .fallbackDefault)
        conversation.messages = [AIChatMessage(role: .user, text: "Look", attachments: [shot, selection])]
        let data = try? encoder.encode(conversation)
        let decoded = data.flatMap { try? decoder.decode(AIChatConversation.self, from: $0) }
        suite.expect(decoded?.messages.first?.attachments == [shot, selection],
                     "attachments round-trip through the chat file")
        suite.expect(data.map { String(decoding: $0, as: UTF8.self) }?.contains("base64") == false,
                     "no image data is written into the chat file")
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }
}
