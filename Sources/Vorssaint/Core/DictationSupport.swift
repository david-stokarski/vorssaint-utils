// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: dictation, ported from the standalone STT app. Its preferences and
// pure decisions live here, where the tests compile them; capture,
// recognition, cleanup and the session are in Services/Dictation.

extension DefaultsKey {
    static let dictationShortcut = "dictationShortcut"
    static let dictationShortcutEnabled = "dictationShortcutEnabled"
    /// `priority` (the Audio Priority microphone list), `system` or a device UID.
    static let dictationInput = "dictationInput"
    static let dictationLocale = "dictationLocale"
    static let dictationAutoStop = "dictationAutoStop"
    /// The quietest level that counts as voice; the room's noise floor raises it.
    static let dictationSilenceThreshold = "dictationSilenceThreshold"
    static let dictationSilenceDuration = "dictationSilenceDuration"
    static let dictationPauseMedia = "dictationPauseMedia"
    /// Polish the text with Apple Intelligence's on-device model.
    static let dictationCleanupEnabled = "dictationCleanupEnabled"
    static let dictationCleanupStyling = "dictationCleanupStyling"
    static let dictationCleanupStructure = "dictationCleanupStructure"
    static let dictationCleanupContext = "dictationCleanupContext"
}

enum DictationSupport {
    static let title = "Dictation"
    static let hubDescription = "Speak and the text appears where you type, transcribed on this Mac."
    static let priorityInput = "priority"
    static let systemInput = "system"
    /// Matches `SpectrumConfiguration.dictation.bands`.
    static let barCount = 9
    static let defaultSilenceDuration = 3.0
    static let silenceDurationRange = 1.0...8.0
    static let defaultMinimumVoiceLevel = 0.006
    /// A press held this long is hold-to-talk: letting go pastes.
    static let holdToTalkThreshold: TimeInterval = 0.35

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.dictationShortcut: GlobalShortcut.dictationDefault.storageValue,
        DefaultsKey.dictationShortcutEnabled: true,
        DefaultsKey.dictationInput: priorityInput,
        DefaultsKey.dictationLocale: "",
        DefaultsKey.dictationAutoStop: true,
        DefaultsKey.dictationSilenceThreshold: defaultMinimumVoiceLevel,
        DefaultsKey.dictationSilenceDuration: defaultSilenceDuration,
        DefaultsKey.dictationPauseMedia: true,
        DefaultsKey.dictationCleanupEnabled: false,
        DefaultsKey.dictationCleanupStyling: DictationCleanupStyling.semiFormal.rawValue,
        DefaultsKey.dictationCleanupStructure: DictationCleanupStructure.prose.rawValue,
        DefaultsKey.dictationCleanupContext: DictationCleanupContext.general.rawValue,
    ]

    /// The microphone a session records from: the first connected device in
    /// the Audio Priority list, a chosen device while it is connected, or nil
    /// for the system's default input.
    static func inputDeviceUID(choice: String, priority: [String], available: Set<String>) -> String? {
        switch choice {
        case systemInput: return nil
        case priorityInput: return priority.first(where: available.contains)
        default: return available.contains(choice) ? choice : priority.first(where: available.contains)
        }
    }

    /// The dictation surface lets what is behind it show (NotchAppearance).
    static var translucent: Bool { NotchSurfaceAppearance.dictation().material.seeThrough }

    /// Voice stands clearly above the room: three times its floor, and never
    /// below the chosen minimum.
    static func voiceThreshold(floor: Float, minimum: Float) -> Float {
        max(minimum, floor * 3)
    }

    /// Auto-stop waits for words first, then for a pause with neither voice
    /// nor new words for `duration`. The result is how far that pause has
    /// run, 0...1; 1 stops.
    static func silenceProgress(heardWords: Bool, now: TimeInterval, lastVoice: TimeInterval,
                                lastWords: TimeInterval, duration: TimeInterval) -> Double {
        guard heardWords, duration > 0 else { return 0 }
        let quiet = now - max(lastVoice, lastWords)
        return min(1, max(0, quiet / duration))
    }

    /// Joins a newly finalized stretch onto what came before it.
    static func append(_ text: String, to transcript: String) -> String {
        guard !text.isEmpty else { return transcript }
        guard let last = transcript.last, let first = text.first else { return transcript + text }
        return last.isWhitespace || first.isWhitespace || ",.;:!?)".contains(first) ? transcript + text : transcript + " " + text
    }
}

enum DictationCleanupStyling: String, CaseIterable, Identifiable {
    case casual, semiCasual = "semi-casual", semiFormal = "semi-formal", formal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .casual: return "Casual"
        case .semiCasual: return "Semi-casual"
        case .semiFormal: return "Semi-formal"
        case .formal: return "Formal"
        }
    }
}

enum DictationCleanupStructure: String, CaseIterable, Identifiable {
    case prose, lists
    var id: String { rawValue }
    var label: String { self == .prose ? "Prose" : "Lists" }
}

enum DictationCleanupContext: String, CaseIterable, Identifiable {
    case general, email
    var id: String { rawValue }
    var label: String { self == .general ? "General" : "Email" }
}
