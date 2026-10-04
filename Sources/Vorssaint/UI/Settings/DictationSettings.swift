// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Speech
import SwiftUI

/// Fork: the Dictation page. Shortcut and permissions, the microphone,
/// the speech model and language, auto-stop, media, and Ollama cleanup.
struct DictationSettings: View {
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var dictation = DictationService.shared

    @AppStorage(DefaultsKey.dictationShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.dictationInput) private var input = DictationSupport.priorityInput
    @AppStorage(DefaultsKey.dictationLocale) private var locale = ""
    @AppStorage(DefaultsKey.dictationAutoStop) private var autoStop = true
    @AppStorage(DefaultsKey.dictationSilenceDuration) private var silenceDuration = 1.6
    @AppStorage(DefaultsKey.dictationSilenceThreshold) private var silenceThreshold = 0.012
    @AppStorage(DefaultsKey.dictationPauseMedia) private var pauseMedia = true
    @AppStorage(DefaultsKey.dictationCleanupEnabled) private var cleanupEnabled = false
    @AppStorage(DefaultsKey.dictationOllamaHost) private var ollamaHost = DictationSupport.defaultOllamaHost
    @AppStorage(DefaultsKey.dictationOllamaModel) private var ollamaModel = DictationSupport.defaultOllamaModel
    @AppStorage(DefaultsKey.dictationCleanupStyling) private var styling = DictationCleanupStyling.semiFormal.rawValue
    @AppStorage(DefaultsKey.dictationCleanupStructure) private var structure = DictationCleanupStructure.prose.rawValue
    @AppStorage(DefaultsKey.dictationCleanupContext) private var context = DictationCleanupContext.general.rawValue

    @State private var devices: [DictationAudioDevices.Device] = []
    @State private var locales: [Locale] = []
    @State private var ollamaReachable: Bool?
    @State private var ollamaModels: [String] = []
    @State private var pullProgress: Double?
    @State private var pullStatus = ""

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
                Text("Press the shortcut to start, and again (or Return) to paste. Escape cancels. The words appear in the Dynamic Island as you speak.")
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
                Toggle("Paste when you stop speaking", isOn: $autoStop)
                if autoStop {
                    LabeledContent("Pause before stopping") {
                        HStack {
                            Slider(value: $silenceDuration, in: 0.6...4, step: 0.2)
                            Text("\(silenceDuration.formatted(.number.precision(.fractionLength(1)))) s").monospacedDigit().frame(width: 44)
                        }
                    }
                    LabeledContent("Silence level") {
                        HStack {
                            Slider(value: $silenceThreshold, in: 0.002...0.05)
                            Text(silenceThreshold.formatted(.number.precision(.fractionLength(3)))).monospacedDigit().frame(width: 44)
                        }
                    }
                    Text("Raise the silence level if background noise keeps dictation from stopping.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("While dictating") {
                Toggle("Pause music and video", isOn: $pauseMedia)
                Text("Whatever is playing pauses so the speakers don't reach the microphone, and resumes after the text is pasted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cleanup with Ollama") {
                Toggle("Polish the text with a local model", isOn: $cleanupEnabled)
                if cleanupEnabled {
                    HStack {
                        TextField("Host", text: $ollamaHost)
                        statusDot
                    }
                    HStack {
                        TextField("Model", text: $ollamaModel)
                        if !ollamaModels.isEmpty {
                            Menu("Installed") {
                                ForEach(ollamaModels, id: \.self) { name in Button(name) { ollamaModel = name } }
                            }
                            .fixedSize()
                        }
                        Button("Download") { pull() }
                            .disabled(pullProgress != nil || ollamaReachable != true)
                    }
                    if let pullProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            if pullProgress >= 0 { ProgressView(value: pullProgress) } else { ProgressView().controlSize(.small) }
                            Text(pullStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Styling", selection: $styling) {
                        ForEach(DictationCleanupStyling.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Structure", selection: $structure) {
                        ForEach(DictationCleanupStructure.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Context", selection: $context) {
                        ForEach(DictationCleanupContext.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Text("When Ollama isn't running, the transcript is pasted as heard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: cleanupEnabled) { _, enabled in if enabled { checkOllama() } }
            .onChange(of: ollamaHost) { _, _ in checkOllama() }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = DictationAudioDevices.inputDevices()
            dictation.prepareModel()
            if cleanupEnabled { checkOllama() }
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

    private var statusDot: some View {
        Circle()
            .fill(ollamaReachable == true ? Color.green : ollamaReachable == false ? Color.red : Color.secondary)
            .frame(width: 8, height: 8)
            .help(ollamaReachable == true ? "Ollama is running" : "Ollama isn't reachable")
    }

    private func checkOllama() {
        let client = DictationOllamaClient(host: ollamaHost)
        Task {
            let reachable = await client.isReachable()
            let models = reachable ? (try? await client.listModels()) ?? [] : []
            await MainActor.run {
                ollamaReachable = reachable
                ollamaModels = models
            }
        }
    }

    private func pull() {
        let client = DictationOllamaClient(host: ollamaHost)
        let model = ollamaModel
        pullProgress = -1
        pullStatus = "Starting…"
        Task {
            do {
                try await client.pull(model: model) { fraction, status in
                    Task { @MainActor in
                        pullProgress = fraction
                        pullStatus = status
                    }
                }
                await MainActor.run { pullProgress = nil; pullStatus = ""; checkOllama() }
            } catch {
                await MainActor.run { pullProgress = nil; pullStatus = error.localizedDescription }
            }
        }
    }
}
