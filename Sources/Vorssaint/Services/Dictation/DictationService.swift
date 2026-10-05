// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import Speech

/// Fork: one dictation at a time. The shortcut starts recording from the
/// microphone Audio Priority ranks first; the island (or a small panel when
/// the island is off) shows the waveform and the words as they are heard.
/// Tapped, the shortcut listens hands-free until it is tapped again, Return
/// is pressed or a pause runs out; held, letting go pastes. Escape throws
/// the dictation away. Everything runs on this Mac.
final class DictationService: ObservableObject, @unchecked Sendable {
    static let shared = DictationService()

    enum Phase: Equatable {
        case idle, recording, finishing, polishing
        case error(String)
    }

    enum ModelState: Equatable {
        case unknown, checking, installing, ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels = [Float](repeating: 0, count: DictationSupport.barCount)
    @Published private(set) var transcript = ""
    /// The microphone this session records from.
    @Published private(set) var inputName: String?
    @Published private(set) var shortcutRegistrationFailed = false
    @Published private(set) var modelState: ModelState = .unknown
    /// How far the current pause has run toward auto-stop, 0...1.
    @Published private(set) var silenceProgress: Double = 0
    @Published private(set) var startedAt: Date?

    private let hotkey = DictationHotkey()
    private let escapeKey = QuickToolHotkey(id: 63)
    private let returnKey = QuickToolHotkey(id: 64)
    private let capture = DictationAudioCapture()
    /// A `DictationSpeechEngine`; untyped so the service builds before macOS 26.
    private var engine: AnyObject?
    private var session = UUID()
    private var pausedMedia = false
    private var errorWork: DispatchWorkItem?
    private var presentedInIsland = false
    private let hud = DictationHUD()
    private var monitor: Timer?
    private var lastWords: CFTimeInterval = 0
    private var pressedAt: CFTimeInterval?
    /// The press being held is the one that started this dictation.
    private var pressStarted = false

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    private init() {
        hotkey.onPress = { [weak self] in self?.shortcutPressed() }
        hotkey.onRelease = { [weak self] in self?.shortcutReleased() }
        escapeKey.onPress = { [weak self] in self?.cancel() }
        returnKey.onPress = { [weak self] in self?.stop(paste: true) }
        capture.onLevels = { [weak self] levels in
            guard self?.phase == .recording else { return }
            self?.levels = levels
        }
    }

    // MARK: Preferences

    func syncWithPreferences() {
        let available = AppFeature.dictation.isAvailable
        let enabled = available && UserDefaults.standard.bool(forKey: DefaultsKey.dictationShortcutEnabled)
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.dictationShortcut, fallback: .dictationDefault)
        shortcutRegistrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut,
                                                  storageKey: DefaultsKey.dictationShortcut)
        if !available { cancel() }
        if enabled, modelState == .unknown { prepareModel() }
    }

    func suspend() {
        hotkey.unregister()
        cancel()
    }

    /// Makes sure the language's speech model is on this Mac, downloading it if not.
    func prepareModel() {
        guard #available(macOS 26.0, *) else {
            modelState = .failed("Dictation needs macOS 26 or later.")
            return
        }
        guard modelState != .checking, modelState != .installing else { return }
        modelState = .checking
        let locale = Self.locale
        Task {
            do {
                let module = try await DictationSpeechEngine.module(for: locale)
                let installed = await AssetInventory.status(forModules: [module]) == .installed
                if !installed { await MainActor.run { self.modelState = .installing } }
                try await DictationSpeechEngine.installAssets(for: module)
                await MainActor.run { self.modelState = .ready }
            } catch {
                await MainActor.run { self.modelState = .failed(error.localizedDescription) }
            }
        }
    }

    func languageChanged() {
        modelState = .unknown
        prepareModel()
    }

    static var locale: Locale {
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.dictationLocale) ?? ""
        return saved.isEmpty ? Locale.current : Locale(identifier: saved)
    }

    // MARK: Session

    private func shortcutPressed() {
        pressedAt = CACurrentMediaTime()
        switch phase {
        case .idle, .error:
            pressStarted = true
            begin()
        case .recording:
            pressStarted = false
            stop(paste: true)
        case .finishing, .polishing: break
        }
    }

    /// Letting go of a held shortcut pastes; a tap keeps listening.
    private func shortcutReleased() {
        defer { pressStarted = false; pressedAt = nil }
        guard pressStarted, phase == .recording, let pressedAt,
              CACurrentMediaTime() - pressedAt >= DictationSupport.holdToTalkThreshold else { return }
        stop(paste: true)
    }

    private var holding: Bool { pressStarted && pressedAt != nil }

    func toggle() {
        switch phase {
        case .idle, .error: begin()
        case .recording: stop(paste: true)
        case .finishing, .polishing: break
        }
    }

    private func begin() {
        guard #available(macOS 26.0, *) else { fail("Dictation needs macOS 26 or later."); return }
        guard AppFeature.dictation.isAvailable else { return }
        guard AXIsProcessTrusted() else {
            Permissions.shared.requestAccessibility()
            fail("Allow Accessibility so dictation can paste.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Permissions.shared.requestMicrophone { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.begin() } }
            }
            return
        case .denied, .restricted:
            Permissions.shared.openMicrophoneSettings()
            fail("Allow microphone access for Vorssaint.")
            return
        default: break
        }

        errorWork?.cancel()
        let token = UUID()
        session = token
        transcript = ""
        levels = [Float](repeating: 0, count: DictationSupport.barCount)

        let defaults = UserDefaults.standard
        capture.minimumVoiceLevel = Float(defaults.double(forKey: DefaultsKey.dictationSilenceThreshold))
        silenceProgress = 0
        lastWords = CACurrentMediaTime()
        let device = Self.inputDeviceUID()
        inputName = device.flatMap(DictationAudioDevices.name(forUID:)) ?? DictationAudioDevices.defaultInputName()

        let engine = DictationSpeechEngine()
        self.engine = engine
        engine.onText = { text in
            DispatchQueue.main.async {
                guard self.session == token, self.phase == .recording || self.phase == .finishing,
                      text != self.transcript else { return }
                self.transcript = text
                self.lastWords = CACurrentMediaTime()
                self.contentChanged()
            }
        }
        capture.onBuffer = { [weak engine] buffer in engine?.append(buffer) }
        pauseMedia()
        do {
            try capture.start(deviceUID: device)
        } catch {
            self.engine = nil
            resumeMedia()
            fail(error.localizedDescription)
            return
        }
        guard let format = capture.format else { cancel(); return }
        phase = .recording
        startedAt = Date()
        present()
        registerSessionKeys()
        startMonitor()
        // Audio waits in the engine while the model loads; nothing said is lost.
        let locale = Self.locale
        Task {
            do {
                try await engine.start(locale: locale, naturalFormat: format)
                await MainActor.run { if self.modelState != .ready { self.modelState = .ready } }
            } catch {
                await MainActor.run {
                    guard self.session == token else { return }
                    self.abort(error.localizedDescription)
                }
            }
        }
    }

    /// Ends recording. With `paste`, the text is finalized, polished if asked
    /// and pasted; otherwise it is discarded.
    func stop(paste: Bool) {
        guard phase == .recording else { return }
        stopMonitor()
        unregisterSessionKeys()
        capture.stop()
        guard paste, #available(macOS 26.0, *), let engine = engine as? DictationSpeechEngine else {
            cancel()
            return
        }
        let token = session
        phase = .finishing
        contentChanged()
        Task {
            let raw = await engine.finish(timeout: 4)
            await MainActor.run { self.finish(raw, token: token) }
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        session = UUID()
        stopMonitor()
        unregisterSessionKeys()
        capture.stop()
        if #available(macOS 26.0, *), let engine = engine as? DictationSpeechEngine {
            Task { await engine.cancel() }
        }
        end()
    }

    private func finish(_ raw: String, token: UUID) {
        guard session == token else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Say why nothing was pasted when the microphone never delivered audio.
            if capture.buffersReceived == 0 {
                fail("No audio came from \(inputName ?? "the microphone"). Try again, or pick another microphone in Settings.")
            } else {
                end()
            }
            return
        }
        transcript = text
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.dictationCleanupEnabled), #available(macOS 26.0, *),
              DictationPolish.isAvailable else {
            deliver(text, token: token)
            return
        }
        phase = .polishing
        contentChanged()
        let options = DictationPolish.Options(
            styling: defaults.string(forKey: DefaultsKey.dictationCleanupStyling) ?? DictationCleanupStyling.semiFormal.rawValue,
            structure: defaults.string(forKey: DefaultsKey.dictationCleanupStructure) ?? DictationCleanupStructure.prose.rawValue,
            context: defaults.string(forKey: DefaultsKey.dictationCleanupContext) ?? DictationCleanupContext.general.rawValue)
        Task {
            // A model that fails or refuses leaves the transcript as heard.
            let polished = try? await DictationPolish.polish(text, options: options)
            let output = polished.flatMap { $0.isEmpty ? nil : $0 } ?? text
            await MainActor.run { self.deliver(output, token: token) }
        }
    }

    private func deliver(_ text: String, token: UUID) {
        guard session == token else { return }
        // A password field takes no dictation.
        guard !IsSecureEventInputEnabled() else { NSSound.beep(); end(); return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.session == token else { return }
            if !TransientPaste.shared.paste(text, didFail: { NSSound.beep() }) { NSSound.beep() }
            self.end()
        }
    }

    private func end() {
        errorWork?.cancel()
        stopMonitor()
        startedAt = nil
        silenceProgress = 0
        phase = .idle
        transcript = ""
        levels = [Float](repeating: 0, count: DictationSupport.barCount)
        engine = nil
        // Resume after the paste has landed, not over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.resumeMedia() }
        dismiss()
    }

    private func abort(_ message: String) {
        stopMonitor()
        unregisterSessionKeys()
        capture.stop()
        engine = nil
        resumeMedia()
        fail(message)
    }

    private func fail(_ message: String) {
        session = UUID()
        phase = .error(message)
        present()
        contentChanged()
        errorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if case .error = self?.phase { self?.end() }
        }
        errorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: Auto-stop

    /// Ten times a second: how long voice and new words have both been
    /// absent. A held shortcut and the auto-stop switch off keep listening.
    private func startMonitor() {
        stopMonitor()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkSilence() }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
    }

    private func stopMonitor() {
        monitor?.invalidate()
        monitor = nil
    }

    private func checkSilence() {
        guard phase == .recording else { return }
        let defaults = UserDefaults.standard
        let progress = defaults.bool(forKey: DefaultsKey.dictationAutoStop) && !holding
            ? DictationSupport.silenceProgress(heardWords: !transcript.isEmpty, now: CACurrentMediaTime(),
                                               lastVoice: capture.lastVoiceTime, lastWords: lastWords,
                                               duration: defaults.double(forKey: DefaultsKey.dictationSilenceDuration))
            : 0
        if abs(progress - silenceProgress) >= 0.02 || (progress == 0) != (silenceProgress == 0) { silenceProgress = progress }
        if progress >= 1 { stop(paste: true) }
    }

    // MARK: Microphone

    /// Audio Priority's first connected microphone unless Settings names another.
    static func inputDeviceUID() -> String? {
        let defaults = UserDefaults.standard
        let priority = AppFeature.audioPriority.isAvailable
            ? defaults.stringArray(forKey: DefaultsKey.audioPriorityInputUIDs) ?? [] : []
        let choice = defaults.string(forKey: DefaultsKey.dictationInput) ?? DictationSupport.priorityInput
        let candidates = priority + [choice]
        let available = Set(candidates.filter { DictationAudioDevices.hasInput(uid: $0) })
        return DictationSupport.inputDeviceUID(choice: choice, priority: priority, available: available)
    }

    // MARK: Media

    private func pauseMedia() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.dictationPauseMedia) else { return }
        let music = NotchMusicService.shared
        guard let playback = music.playback, playback.isPlaying, music.canPerform(.toggle) else { return }
        pausedMedia = music.send(.toggle, context: playback.commandContext)
    }

    private func resumeMedia() {
        guard pausedMedia, phase == .idle else { return }
        pausedMedia = false
        let music = NotchMusicService.shared
        guard let playback = music.playback, !playback.isPlaying, music.canPerform(.toggle) else { return }
        music.send(.toggle, context: playback.commandContext)
    }

    // MARK: Session keys

    private func registerSessionKeys() {
        escapeKey.sync(enabled: true, shortcut: GlobalShortcut(keyCode: Int64(kVK_Escape), modifiers: []),
                       storageKey: "dictationSessionEscape")
        returnKey.sync(enabled: true, shortcut: GlobalShortcut(keyCode: Int64(kVK_Return), modifiers: []),
                       storageKey: "dictationSessionReturn")
    }

    private func unregisterSessionKeys() {
        escapeKey.unregister()
        returnKey.unregister()
    }

    // MARK: Presentation

    private func present() {
        if NotchService.shared.presentDictation(true) {
            presentedInIsland = true
            hud.hide()
        } else {
            presentedInIsland = false
            hud.show()
        }
    }

    private func dismiss() {
        if presentedInIsland { NotchService.shared.presentDictation(false) }
        presentedInIsland = false
        hud.hide()
    }

    /// The surface grows with the transcript.
    private func contentChanged() {
        if presentedInIsland { NotchService.shared.dictationContentChanged() } else { hud.resize() }
    }
}

#if VORSSAINT_DEVELOPMENT
/// Developer builds only: the surface with moving bars and sample text, no
/// microphone or permissions, so it can be inspected and captured.
extension DictationService {
    func startPreview(text: String) {
        session = UUID()
        let token = session
        phase = .recording
        transcript = text
        startedAt = Date()
        silenceProgress = text.isEmpty ? 0 : 0.6
        present()
        contentChanged()
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
            guard let self, self.session == token, self.phase == .recording else { timer.invalidate(); return }
            self.levels = (0..<DictationSupport.barCount).map { _ in Float.random(in: 0.05...1) }
        }
    }

    /// The text alone, nothing presented, for rendering the surface offscreen.
    func setPreviewTranscript(_ text: String) {
        phase = .recording
        transcript = text
        startedAt = Date()
    }

    func endPreview() {
        session = UUID()
        end()
    }
}
#endif
