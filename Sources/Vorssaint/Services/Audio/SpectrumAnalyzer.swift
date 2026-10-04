// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Accelerate
import Foundation

/// Fork: how a live spectrum is turned into bars. Dictation and the island's
/// music bars share the analysis but not the tuning: each names its own
/// cutoffs, bar count, range and motion here.
struct SpectrumConfiguration: Equatable {
    /// FFT length, a power of two. Longer resolves lower frequencies.
    var size: Int
    /// Earlier samples run through the high-pass before each frame so it
    /// has settled by the frame; long enough for the cutoff's ripple to die.
    var preroll: Int
    var bands: Int
    /// Nothing below this reaches a bar: rumble, hum and handling noise.
    var minimumFrequency: Double
    var maximumFrequency: Double
    /// Decibels shown below the running peak; quieter reads as empty.
    var range: Float
    /// Below this, in decibels under full scale, a band is silence however
    /// loud the rest is, so a quiet room doesn't fill the bars with noise.
    var gate: Float
    /// How far the running peak relaxes per update, in decibels.
    var peakRelease: Float
    /// The share of the way a bar moves toward a louder or a quieter level
    /// per update: a fast rise, a quick but visible fall.
    var attack: Float
    var release: Float
    /// Decibels added per octave above the cutoff. Music carries far more
    /// energy low than high; leveling the slope lets every bar move with
    /// its own part of the mix instead of the bass setting the scale alone.
    var tilt: Float = 0

    /// Samples each update reads: the preroll, then the frame.
    var inputLength: Int { preroll + size }

    /// The microphone: voice from 100 Hz up, twenty bars, quick to move.
    static let dictation = Self(size: 1024, preroll: 2048, bands: 20, minimumFrequency: 100, maximumFrequency: 6000,
                                range: 42, gate: -72, peakRelease: 0.35, attack: 0.9, release: 0.4)
    /// Music: everything from 40 Hz up in the island's seven bands, read
    /// sixty times a second over a 43 ms window, with the mix's downward
    /// slope leveled so the highs move as visibly as the kick.
    static let media = Self(size: 2048, preroll: 3072, bands: 7, minimumFrequency: 40, maximumFrequency: 12_000,
                            range: 30, gate: -78, peakRelease: 0.2, attack: 0.9, release: 0.5, tilt: 3)
    /// How often the music reader analyses.
    static let mediaUpdatesPerSecond = 60.0
}

/// Not thread-safe: one analyzer per reader, used from one queue.
final class SpectrumAnalyzer {
    let configuration: SpectrumConfiguration
    let sampleRate: Double
    /// Each band's bins; every band has at least one, all at or above the cutoff.
    let bandBins: [ClosedRange<Int>]
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var frame: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var levels: [Float]
    private var peak: Float
    /// An eighth-order Butterworth-style high-pass at the cutoff, run before
    /// the FFT, so what lies below it is removed rather than merely unbinned.
    private let highPass: vDSP.Biquad<Float>?
    private var filtered: [Float]
    private let bandTilt: [Float]

    init?(configuration: SpectrumConfiguration, sampleRate: Double) {
        let size = configuration.size
        guard size >= 64, size & (size - 1) == 0, sampleRate > 0, configuration.bands > 0 else { return nil }
        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.log2n = log2n
        self.setup = setup
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
        levels = [Float](repeating: 0, count: configuration.bands)
        peak = configuration.gate + configuration.range
        bandBins = Self.bandBins(configuration, sampleRate: sampleRate)
        let binWidth = Float(sampleRate) / Float(size)
        bandTilt = bandBins.map { bins in
            let centre = Float(bins.lowerBound + bins.upperBound) / 2 * binWidth
            return configuration.tilt * log2(max(1, centre / Float(configuration.minimumFrequency)))
        }
        filtered = [Float](repeating: 0, count: configuration.inputLength)
        let section = Self.highPassSection(cutoff: configuration.minimumFrequency, sampleRate: sampleRate)
        highPass = vDSP.Biquad(coefficients: Array([[Double]](repeating: section, count: 4).joined()),
                               channelCount: 1, sectionCount: 4, ofType: Float.self)
    }

    /// One RBJ high-pass section (Q = 1/sqrt 2) as b0, b1, b2, a1, a2.
    static func highPassSection(cutoff: Double, sampleRate: Double) -> [Double] {
        let w0 = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * 0.70710678)
        let a0 = 1 + alpha
        let c = cos(w0)
        return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0]
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Log-spaced bands between the cutoffs, mapped to FFT bins. A band too
    /// narrow for the resolution takes the bin nearest its centre.
    static func bandBins(_ configuration: SpectrumConfiguration, sampleRate: Double) -> [ClosedRange<Int>] {
        let half = configuration.size / 2
        let binWidth = sampleRate / Double(configuration.size)
        let lowestBin = max(1, Int((configuration.minimumFrequency / binWidth).rounded(.up)))
        let top = min(configuration.maximumFrequency, sampleRate / 2)
        let ratio = top / configuration.minimumFrequency
        return (0..<configuration.bands).map { band in
            let lower = configuration.minimumFrequency * pow(ratio, Double(band) / Double(configuration.bands))
            let upper = configuration.minimumFrequency * pow(ratio, Double(band + 1) / Double(configuration.bands))
            var first = Int((lower / binWidth).rounded(.up))
            var last = Int((upper / binWidth).rounded(.down)) - 1
            if last < first {
                let centre = Int((sqrt(lower * upper) / binWidth).rounded())
                first = centre
                last = centre
            }
            first = min(max(first, lowestBin), half - 1)
            last = min(max(last, first), half - 1)
            return first...last
        }
    }

    /// Bars from 0 to 1 for the newest `size` samples, after the high-pass
    /// has run over the preroll before them (missing samples are silence).
    func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let size = configuration.size
        let length = configuration.inputLength
        if frame.count != length { frame = [Float](repeating: 0, count: length) }
        let take = min(length, samples.count)
        for index in 0..<length {
            frame[index] = index < length - take ? 0 : samples[samples.count - length + index]
        }
        if var highPass {
            highPass.apply(input: frame, output: &filtered)
        } else {
            filtered = frame
        }
        filtered.withUnsafeBufferPointer { all in
            vDSP_vmul(all.baseAddress! + (length - size), 1, window, 1, &windowed, 1, vDSP_Length(size))
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }
        // zrip doubles its output and a Hann window halves a tone, so a
        // full-scale sine comes out near 0 dB with this scale.
        let scale = 2 / Float(size)
        var decibels = [Float](repeating: configuration.gate - 20, count: configuration.bands)
        for (band, bins) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += power[bin] }
            let amplitude = sqrt(sum / Float(bins.count)) * scale
            decibels[band] = 20 * log10(max(amplitude, 1e-9)) + bandTilt[band]
        }
        let loudest = decibels.max() ?? configuration.gate
        // The scale follows the loudest band down slowly, so quiet speech
        // fills the bars but a pause lets them settle to nothing.
        peak = max(loudest, peak - configuration.peakRelease, configuration.gate + configuration.range * 0.5)
        let floor = max(peak - configuration.range, configuration.gate)
        let span = max(1, peak - floor)
        for band in 0..<configuration.bands {
            let target = min(1, max(0, (decibels[band] - floor) / span))
            let rate = target > levels[band] ? configuration.attack : configuration.release
            levels[band] += (target - levels[band]) * rate
        }
        return levels
    }

    func process(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { process($0) }
    }
}
