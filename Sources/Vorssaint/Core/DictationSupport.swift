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
    static let dictationSilenceThreshold = "dictationSilenceThreshold"
    static let dictationSilenceDuration = "dictationSilenceDuration"
    static let dictationPauseMedia = "dictationPauseMedia"
    static let dictationCleanupEnabled = "dictationCleanupEnabled"
    static let dictationOllamaHost = "dictationOllamaHost"
    static let dictationOllamaModel = "dictationOllamaModel"
    static let dictationCleanupStyling = "dictationCleanupStyling"
    static let dictationCleanupStructure = "dictationCleanupStructure"
    static let dictationCleanupContext = "dictationCleanupContext"
}

enum DictationSupport {
    static let title = "Dictation"
    static let hubDescription = "Speak and the text appears where you type, transcribed on this Mac."
    static let priorityInput = "priority"
    static let systemInput = "system"
    static let defaultOllamaHost = "http://127.0.0.1:11434"
    static let defaultOllamaModel = "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"
    static let barCount = 26

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.dictationShortcut: GlobalShortcut.dictationDefault.storageValue,
        DefaultsKey.dictationShortcutEnabled: true,
        DefaultsKey.dictationInput: priorityInput,
        DefaultsKey.dictationLocale: "",
        DefaultsKey.dictationAutoStop: true,
        DefaultsKey.dictationSilenceThreshold: 0.012,
        DefaultsKey.dictationSilenceDuration: 1.6,
        DefaultsKey.dictationPauseMedia: true,
        DefaultsKey.dictationCleanupEnabled: false,
        DefaultsKey.dictationOllamaHost: defaultOllamaHost,
        DefaultsKey.dictationOllamaModel: defaultOllamaModel,
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
