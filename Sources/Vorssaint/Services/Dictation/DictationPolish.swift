// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Accelerate
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

// MARK: - Waveform

/// Spectral energy in `bars` bands, low to high, normalized to 0...1 so quiet
/// speech still moves the bars.
final class DictationFFT {
    private let size: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(size: Int = 1024) {
        self.size = size
        halfSize = size / 2
        log2n = vDSP_Length(log2(Float(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(from input: [Float], bars: Int) -> [Float] {
        guard !input.isEmpty, bars > 0 else { return [Float](repeating: 0, count: max(0, bars)) }
        var frame = [Float](repeating: 0, count: size)
        let take = min(size, input.count)
        let start = input.count - take
        for index in 0..<take { frame[index] = input[start + index] }
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Voice energy sits low in the spectrum; give it most of the bars.
        let usable = max(bars, halfSize / 2)
        let perBar = max(1, usable / bars)
        var result = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            let lower = bar * perBar
            let upper = min(lower + perBar, magnitudes.count)
            guard lower < upper else { continue }
            var sum: Float = 0
            for index in lower..<upper { sum += magnitudes[index] }
            result[bar] = log10(1 + sum / Float(upper - lower) * 40)
        }
        let ceiling = max(result.max() ?? 0, 0.6)
        return result.map { min(1, $0 / ceiling) }
    }
}
