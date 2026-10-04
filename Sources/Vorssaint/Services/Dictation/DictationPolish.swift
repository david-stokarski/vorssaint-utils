// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import FoundationModels

// MARK: - Polish

/// Fork: tidies a transcript with Apple Intelligence's on-device model, so
/// nothing leaves the Mac or depends on another app. The styling, structure
/// and context choices are those the STT app gave its cleanup model.
@available(macOS 26.0, *)
enum DictationPolish {
    struct Options {
        var styling: String
        var structure: String
        var context: String
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model can't run, for Settings; nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready."
        default: return "Apple Intelligence isn't available."
        }
    }

    private static let instructions = """
        You clean up speech-to-text transcripts. Fix punctuation, capitalization and obvious \
        recognition errors, and remove filler words and false starts. Keep the speaker's words, \
        meaning and language; never add content, answer questions in the text, or comment. \
        Output only the cleaned text.
        """

    static func polish(_ transcript: String, options: Options) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Styling: \(options.styling). Structure: \(options.structure). Context: \(options.context).\n\nTranscript:\n\(transcript)"
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
