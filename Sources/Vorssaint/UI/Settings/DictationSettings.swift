// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Speech
import SwiftUI

/// Fork: the Dictation page. Shortcut and permissions, the microphone,
/// the speech model and language, auto-stop, media, and on-device polish.
struct DictationSettings: View {
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var dictation = DictationService.shared

    @AppStorage(DefaultsKey.dictationShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.dictationInput) private var input = DictationSupport.priorityInput
    @AppStorage(DefaultsKey.dictationLocale) private var locale = ""
    @AppStorage(DefaultsKey.dictationAutoStop) private var autoStop = true
    @AppStorage(DefaultsKey.dictationSilenceDuration) private var silenceDuration = DictationSupport.defaultSilenceDuration
    @AppStorage(DefaultsKey.dictationSilenceThreshold) private var silenceThreshold = DictationSupport.defaultMinimumVoiceLevel
    @AppStorage(DefaultsKey.dictationPauseMedia) private var pauseMedia = true
    @AppStorage(DefaultsKey.dictationTranslucent) private var translucent = true
    @AppStorage(DefaultsKey.dictationCleanupEnabled) private var cleanupEnabled = false
    @AppStorage(DefaultsKey.dictationCleanupStyling) private var styling = DictationCleanupStyling.semiFormal.rawValue
    @AppStorage(DefaultsKey.dictationCleanupStructure) private var structure = DictationCleanupStructure.prose.rawValue
    @AppStorage(DefaultsKey.dictationCleanupContext) private var context = DictationCleanupContext.general.rawValue

    @State private var devices: [DictationAudioDevices.Device] = []
    @State private var locales: [Locale] = []

    var body: some View {
        Form {
            Section {
                Toggle("Dictation shortcut", isOn: $shortcutEnabled)
                    .onChange(of: shortcutEnabled) { _, _ in dictation.syncWithPreferences() }
                ShortcutPreferenceRow(role: .dictation, isEnabled: shortcutEnabled) {
                    dictation.syncWithPreferences()
                }
                if shortcutEnabled, dictation.shortcutRegistrationFailed {
                    Text("Another app is using this shortcut.").font(.caption).foregroundStyle(.orange)
                }
                Text("Tap the shortcut to dictate hands-free, then tap again or press Return to paste. Or hold it while you talk and let go to paste. Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if permissions.microphone != .granted { PermissionRow(kind: .microphone) }
                if !permissions.accessibility { PermissionRow(kind: .accessibility) }
            } header: {
                Text(DictationSupport.title)
            }

            Section("Microphone") {
                Picker("Record from", selection: $input) {
                    Text("Audio Priority order").tag(DictationSupport.priorityInput)
                    Text("System default").tag(DictationSupport.systemInput)
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in Text(device.name).tag(device.uid) }
                    if input != DictationSupport.priorityInput, input != DictationSupport.systemInput,
                       !devices.contains(where: { $0.uid == input }) {
                        Text("Disconnected device").tag(input)
                    }
                }
                Text(microphoneCaption).font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech") {
                Picker("Language", selection: $locale) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))").tag("")
                    ForEach(locales, id: \.identifier) { item in
                        Text(Locale.current.localizedString(forIdentifier: item.identifier) ?? item.identifier).tag(item.identifier)
                    }
                }
                .onChange(of: locale) { _, _ in dictation.languageChanged() }
                HStack {
                    Text("Speech model")
                    Spacer()
                    modelStatus
                }
                Text("Recognition runs on this Mac with Apple's speech model. Nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Auto-stop") {
                Toggle("Paste after a pause", isOn: $autoStop)
                if autoStop {
                    LabeledContent("Pause length") {
                        HStack {
                            Slider(value: $silenceDuration, in: DictationSupport.silenceDurationRange, step: 0.5)
                            Text("\(silenceDuration.formatted(.number.precision(.fractionLength(1)))) s")
                                .monospacedDigit().frame(width: 44)
                        }
                    }
                    LabeledContent("Voice sensitivity") {
                        HStack {
                            Text("High").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $silenceThreshold, in: 0.002...0.03)
                            Text("Low").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Dictation waits for words, then stops only after this long with no voice and no new words. Pauses between sentences don't count. The ring around the recording dot fills as the pause runs out. Holding the shortcut never auto-stops.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("While dictating") {
                Toggle("See-through background", isOn: $translucent)
                Text("Blurs what's behind the island instead of filling it with black. Reduce Transparency keeps it black.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pause music and video", isOn: $pauseMedia)
                Text("Whatever is playing pauses so the speakers don't reach the microphone, and resumes after the text is pasted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Polish") {
                Toggle("Clean up with Apple Intelligence", isOn: $cleanupEnabled)
                    .disabled(polishUnavailableReason != nil && !cleanupEnabled)
                if cleanupEnabled {
                    Picker("Styling", selection: $styling) {
                        ForEach(DictationCleanupStyling.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Structure", selection: $structure) {
                        ForEach(DictationCleanupStructure.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Context", selection: $context) {
                        ForEach(DictationCleanupContext.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                if let reason = polishUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                Text("Fixes punctuation and removes filler words with the on-device model. Adds a moment before pasting; nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = DictationAudioDevices.inputDevices()
            dictation.prepareModel()
        }
        .task {
            guard #available(macOS 26.0, *) else { return }
            let supported = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales
                : await DictationTranscriber.supportedLocales
            locales = supported.sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
        }
    }

    private var microphoneCaption: String {
        let current = DictationService.inputDeviceUID().flatMap(DictationAudioDevices.name(forUID:))
            ?? DictationAudioDevices.defaultInputName()
        let now = current.map { " Right now: \($0)." } ?? ""
        switch input {
        case DictationSupport.priorityInput:
            return (AppFeature.audioPriority.isAvailable
                ? "Uses the first connected microphone in your Audio Priority list."
                : "Install Audio Priority to rank microphones; until then the system default is used.") + now
        case DictationSupport.systemInput:
            return "Uses whichever input macOS has selected." + now
        default:
            return "Falls back to the Audio Priority order while this microphone is disconnected." + now
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch dictation.modelState {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking: ProgressView().controlSize(.small)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…").foregroundStyle(.secondary) }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).foregroundStyle(.orange).lineLimit(2)
                Button("Retry") { dictation.languageChanged() }
            }
        case .unknown:
            Button("Download") { dictation.prepareModel() }
        }
    }

    private var polishUnavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "Needs macOS 26 or later." }
        return DictationPolish.unavailableReason
    }
}
