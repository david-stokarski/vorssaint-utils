// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the one place Selection Actions talks to a model. The bar only
/// knows this protocol; `SelectionAI.engine` decides who answers. Point it
/// at another client (a shared one-shot `complete` API, a local model) by
/// assigning a different conformer there, and nothing else changes.
protocol SelectionAIEngine: AnyObject {
    /// Whether a request could be made now (a key is saved for the model's
    /// provider). Must not read the secret itself, so it never prompts.
    var isConfigured: Bool { get }
    /// The whole reply to one prompt.
    func complete(system: String, prompt: String) async throws -> String
    /// The same, with text handed over as it arrives. Engines that can't
    /// stream get the default, which delivers the reply in one piece.
    func stream(system: String, prompt: String, onText: @escaping @MainActor (String) -> Void) async throws -> String
    /// Opens wherever the engine is set up, for a request made without it.
    /// Called on the main thread.
    func openSettings()
}

extension SelectionAIEngine {
    func stream(system: String, prompt: String, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let reply = try await complete(system: system, prompt: prompt)
        await onText(reply)
        return reply
    }
}

enum SelectionAIError: LocalizedError {
    case notConfigured
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add an API key in AI Chat's settings first."
        case .failed(let message): return message
        }
    }
}

enum SelectionAI {
    /// The swap point. Replace with another `SelectionAIEngine` to move the
    /// bar onto a different client.
    static var engine: SelectionAIEngine = AIChatSelectionEngine()
}

/// The default engine: AI Chat's default model, its saved key and its
/// streaming request, one user turn, no history kept.
final class AIChatSelectionEngine: SelectionAIEngine {
    var isConfigured: Bool {
        AIChatKeychain.hasKey(for: AIChatSupport.defaultModel().provider)
    }

    func complete(system: String, prompt: String) async throws -> String {
        try await stream(system: system, prompt: prompt, onText: { _ in })
    }

    func stream(system: String, prompt: String, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let choice = AIChatSupport.defaultModel()
        guard let key = AIChatKeychain.key(for: choice.provider) else { throw SelectionAIError.notConfigured }
        let request = AIChatSupport.request(for: choice, apiKey: key, system: system,
                                            messages: [AIChatMessage(role: .user, text: prompt)])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 20_000 { break }
            }
            throw SelectionAIError.failed(AIChatSupport.errorMessage(fromBody: body, status: status))
        }
        var reply = ""
        var pending = ""
        var lastFlush = Date()
        reading: for try await line in bytes.lines {
            try Task.checkCancellation()
            switch AIChatSupport.streamEvent(fromLine: line, provider: choice.provider) {
            case .text(let text):
                reply += text
                pending += text
                if Date().timeIntervalSince(lastFlush) > 0.05 {
                    let chunk = pending
                    pending = ""
                    lastFlush = Date()
                    await onText(chunk)
                }
            case .done:
                break reading
            case .failure(let message):
                throw SelectionAIError.failed(message)
            case nil:
                continue
            }
        }
        if !pending.isEmpty { await onText(pending) }
        return reply
    }

    func openSettings() {
        AIChatService.shared.show()
        AIChatService.shared.showsSettings = true
    }
}
