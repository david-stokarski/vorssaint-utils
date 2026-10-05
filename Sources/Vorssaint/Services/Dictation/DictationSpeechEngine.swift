// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import Foundation
import Speech

/// Fork: on-device recognition with macOS's SpeechAnalyzer. Audio can arrive
/// before the analyzer is ready (the first words are never lost: they wait
/// and are converted once the recognizer's format is known). The text is
/// every finalized stretch followed by the current guess.
@available(macOS 26.0, *)
final class DictationSpeechEngine: @unchecked Sendable {
    /// The transcript so far, from the results task.
    var onText: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    /// The format `converter` reads; audio arriving in another (a Bluetooth
    /// headset changing profile mid-session) gets a converter of its own.
    private var converterInput: AVAudioFormat?
    private var analyzerFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    enum Failure: LocalizedError {
        case unsupportedLocale
        case unavailableAssets
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "Dictation doesn't support this language on this Mac."
            case .unavailableAssets: return "The speech model for this language couldn't be installed."
            }
        }
    }

    // MARK: Models

    /// The newer SpeechTranscriber where this Mac runs it, otherwise the
    /// keyboard dictation model; both stream a guess before each final stretch.
    static func module(for requested: Locale) async throws -> any SpeechModule {
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.unsupportedLocale
        }
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    /// Downloads the language's model the first time it is needed.
    static func installAssets(for module: any SpeechModule) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return
        case .unsupported: throw Failure.unavailableAssets
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw Failure.unavailableAssets }
    }

    static func prepare(locale: Locale) async throws {
        try await installAssets(for: module(for: locale))
    }

    // MARK: Session

    /// Starts recognizing audio in `naturalFormat`, the microphone's own.
    func start(locale: Locale, naturalFormat: AVAudioFormat) async throws {
        let module = try await Self.module(for: locale)
        try await Self.installAssets(for: module)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: naturalFormat)
            ?? naturalFormat
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .lingering))
        listen(to: module)
        try await analyzer.start(inputSequence: stream)
        // The held audio goes first, under the same lock the audio thread
        // feeds through, so nothing overtakes it and the converter has one user.
        lock.withLock {
            self.analyzer = analyzer
            analyzerFormat = format
            converter = format == naturalFormat ? nil : AVAudioConverter(from: naturalFormat, to: format)
            converterInput = naturalFormat
            self.continuation = continuation
            for buffer in pending { feedLocked(buffer) }
            pending.removeAll()
        }
    }

    /// From the audio thread. Held until the analyzer is ready.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else {
            if let copy = Self.copy(buffer) { pending.append(copy) }
            return
        }
        feedLocked(buffer)
    }

    /// Fork: `finish()` with a deadline. Finalizing waits on the analyzer, and
    /// an analyzer that never got audio (or never got going) may not answer;
    /// past the deadline the session is cancelled and keeps what was heard.
    func finish(timeout: TimeInterval) async -> String {
        let once = DictationOnce()
        return await withCheckedContinuation { result in
            Task {
                let text = await self.finish()
                if once.claim() { result.resume(returning: text) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard once.claim() else { return }
                let text = self.transcript
                result.resume(returning: text)
                await self.cancel()
            }
        }
    }

    /// Ends the input and waits for the last stretch to be finalized.
    func finish() async -> String {
        let (continuation, analyzer) = lock.withLock { (self.continuation, self.analyzer) }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return transcript
    }

    func cancel() async {
        let (continuation, analyzer) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            pending.removeAll()
            return (self.continuation, self.analyzer)
        }
        continuation?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return DictationSupport.append(volatile, to: finalized).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listen(to module: any SpeechModule) {
        if let transcriber = module as? SpeechTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.receive(String(result.text.characters), final: result.isFinal)
                    }
                } catch {}
            }
        } else if let transcriber = module as? DictationTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.receive(String(result.text.characters), final: result.isFinal)
                    }
                } catch {}
            }
        }
    }

    private func receive(_ text: String, final: Bool) {
        lock.lock()
        if final {
            finalized = DictationSupport.append(text, to: finalized)
            volatile = ""
        } else {
            volatile = text
        }
        lock.unlock()
        onText?(transcript)
    }

    private func feedLocked(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        if let format = analyzerFormat, buffer.format != converterInput {
            converterInput = buffer.format
            converter = buffer.format == format ? nil : AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter, let format = analyzerFormat else {
            if let copy = Self.copy(buffer) { continuation.yield(AnalyzerInput(buffer: copy)) }
            return
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outcome in
            if supplied { outcome.pointee = .noDataNow; return nil }
            supplied = true
            outcome.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let planes = buffer.format.isInterleaved ? 1 : channels
            let samples = buffer.format.isInterleaved ? frames * channels : frames
            for plane in 0..<planes { destination[plane].update(from: source[plane], count: samples) }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let planes = buffer.format.isInterleaved ? 1 : channels
            let samples = buffer.format.isInterleaved ? frames * channels : frames
            for plane in 0..<planes { destination[plane].update(from: source[plane], count: samples) }
        } else {
            return nil
        }
        return copy
    }
}

/// Lets exactly one of several racing tasks answer.
final class DictationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
