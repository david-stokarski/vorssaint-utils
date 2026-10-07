// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: asking a model, with no window involved. The chat window streams
/// through here, and so can any other feature that wants an answer (a text
/// action on a selection, a summary): pick a model or take the default, get
/// the reply streamed or whole. Every provider and endpoint works the same
/// way; keys are read from the keychain at the moment of asking.
enum AIChatClient {
    struct Failure: LocalizedError, Equatable {
        enum Kind: Equatable {
            /// No key for a provider that needs one, or an endpoint that is gone.
            case notSetUp
            /// The server said no; `status` is its HTTP status, 0 for an
            /// error inside an otherwise good stream.
            case server(status: Int)
            /// The model answered with nothing.
            case empty
        }

        let kind: Kind
        let message: String

        var errorDescription: String? { message }
    }

    /// One question, one whole answer. Throws `Failure`, a `URLError`, or a
    /// `CancellationError` when the calling task is cancelled.
    ///
    ///     let reply = try await AIChatClient.complete(system: "Fix the grammar.", prompt: selection)
    static func complete(system: String = "", prompt: String, images: [AIChatImage] = [],
                         model: AIModelChoice? = nil) async throws -> String {
        var reply = ""
        for try await piece in stream(system: system, prompt: prompt, images: images, model: model) {
            reply += piece
        }
        try Task.checkCancellation()
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(kind: .empty, message: "The model sent back an empty reply.")
        }
        return reply
    }

    /// The same question, answered piece by piece as the model writes.
    /// Images can be made from a `CGImage` with `AIChatAttachments.encode(_:)`.
    static func stream(system: String = "", prompt: String, images: [AIChatImage] = [],
                       model: AIModelChoice? = nil) -> AsyncThrowingStream<String, Error> {
        stream(model ?? AIChatSupport.defaultModel(), system: system,
               turns: [AIChatTurn(role: .user, text: prompt, images: images)])
    }

    /// Why `choice` cannot be asked right now, or nil when it can. Reads no
    /// secret, so it never shows the keychain's prompt.
    static func setupProblem(for choice: AIModelChoice, defaults: UserDefaults = .standard) -> String? {
        switch choice.provider {
        case .anthropic, .openai:
            return AIChatKeychain.hasKey(for: choice.provider)
                ? nil : "Add an \(choice.provider.title) API key in AI Chat's settings."
        case .compatible:
            guard let endpoint = AIChatSupport.endpoint(choice.endpointID, defaults: defaults) else {
                return "That endpoint was removed. Pick another model."
            }
            return endpoint.normalizedBaseURL == nil ? "\(endpoint.displayName) has no valid URL." : nil
        }
    }

    /// A whole conversation, streamed. The work stops when the consumer stops
    /// listening or its task is cancelled.
    static func stream(_ choice: AIModelChoice, system: String,
                       turns: [AIChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(choice, system: system, turns: turns) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ choice: AIModelChoice, system: String, turns: [AIChatTurn],
                            yield: (String) -> Void) async throws {
        if let problem = setupProblem(for: choice) { throw Failure(kind: .notSetUp, message: problem) }
        let endpoint = AIChatSupport.endpoint(choice.endpointID)
        guard let request = AIChatSupport.request(for: choice, endpoint: endpoint,
                                                  apiKey: AIChatKeychain.key(for: choice),
                                                  system: system, turns: turns) else {
            throw Failure(kind: .notSetUp, message: "That endpoint has no valid URL.")
        }
        let sentImages = turns.contains { !$0.images.isEmpty }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 20_000 { break }
            }
            let message = AIChatSupport.errorMessage(fromBody: body, status: status)
            throw Failure(kind: .server(status: status),
                          message: AIChatSupport.failureMessage(message, status: status, sentImages: sentImages))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch AIChatSupport.streamEvent(fromLine: line, provider: choice.provider) {
            case .text(let text): yield(text)
            case .done: return
            case .failure(let message):
                throw Failure(kind: .server(status: 0),
                              message: AIChatSupport.failureMessage(message, status: 400, sentImages: sentImages))
            case nil: continue
            }
        }
    }

    /// The model ids a source offers, from its own listing.
    static func listModels(for provider: AIProvider) async throws -> [String] {
        guard let key = AIChatKeychain.key(for: provider) else {
            throw Failure(kind: .notSetUp, message: "No key saved.")
        }
        return try await models(AIChatSupport.modelsRequest(for: provider, apiKey: key), provider: provider)
    }

    static func listModels(for endpoint: AIEndpoint) async throws -> [String] {
        guard let request = AIChatSupport.modelsRequest(for: endpoint, apiKey: AIChatKeychain.key(for: endpoint))
        else { throw Failure(kind: .notSetUp, message: "Enter a valid URL.") }
        return try await models(request, provider: .compatible)
    }

    private static func models(_ request: URLRequest, provider: AIProvider) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(kind: .server(status: status), message: AIChatSupport.errorMessage(
                fromBody: String(decoding: data, as: UTF8.self), status: status))
        }
        return AIChatSupport.chatModels(fromListing: data, provider: provider)
    }
}
