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
        case .notConfigured: return "Set up a model in AI Chat's settings first."
        case .failed(let message): return message
        }
    }
}

enum SelectionAI {
    /// The swap point. Replace with another `SelectionAIEngine` to move the
    /// bar onto a different client.
    static var engine: SelectionAIEngine = AIChatSelectionEngine()
}

/// The default engine: AI Chat's default model through `AIChatClient`, so
/// every provider and endpoint AI Chat knows works here too. One user turn,
/// no history kept.
final class AIChatSelectionEngine: SelectionAIEngine {
    var isConfigured: Bool {
        AIChatClient.setupProblem(for: AIChatSupport.defaultModel()) == nil
    }

    func complete(system: String, prompt: String) async throws -> String {
        try await stream(system: system, prompt: prompt, onText: { _ in })
    }

    func stream(system: String, prompt: String, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let choice = AIChatSupport.defaultModel()
        if let problem = AIChatClient.setupProblem(for: choice) { throw SelectionAIError.failed(problem) }
        var reply = ""
        var pending = ""
        var lastFlush = Date()
        do {
            for try await piece in AIChatClient.stream(system: system, prompt: prompt, model: choice) {
                reply += piece
                pending += piece
                if Date().timeIntervalSince(lastFlush) > 0.05 {
                    let chunk = pending
                    pending = ""
                    lastFlush = Date()
                    await onText(chunk)
                }
            }
        } catch let failure as AIChatClient.Failure {
            throw failure.kind == .notSetUp ? SelectionAIError.notConfigured : SelectionAIError.failed(failure.message)
        }
        try Task.checkCancellation()
        if !pending.isEmpty { await onText(pending) }
        return reply
    }

    func openSettings() {
        AIChatService.shared.show()
        AIChatService.shared.showsSettings = true
    }
}
