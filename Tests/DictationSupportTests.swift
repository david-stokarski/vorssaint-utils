// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: dictation's pure decisions: when a pause stops it, what counts as
/// voice, which microphone records, and how finalized stretches join.
enum DictationSupportTests {
    static func run(_ suite: TestSuite) {
        let duration = 3.0
        func progress(words: Bool = true, now: Double, voice: Double, text: Double) -> Double {
            DictationSupport.silenceProgress(heardWords: words, now: now, lastVoice: voice, lastWords: text,
                                             duration: duration)
        }
        suite.expect(progress(words: false, now: 60, voice: 0, text: 0) == 0,
                     "silence before any words never stops dictation")
        suite.expect(progress(now: 11.5, voice: 10, text: 10) == 0.5,
                     "a pause runs from the later of voice and words")
        suite.expect(progress(now: 12, voice: 10, text: 11.5) < 1,
                     "a sentence finalized after the voice stopped restarts the pause")
        suite.expect(progress(now: 12.5, voice: 12, text: 9) < 1,
                     "voice without new words still holds dictation open")
        suite.expect(progress(now: 14, voice: 10, text: 10) == 1, "the full pause stops dictation")
        suite.expect(progress(now: 9, voice: 10, text: 10) == 0, "a clock behind activity reads as no pause")

        suite.expect(DictationSupport.voiceThreshold(floor: 0.001, minimum: 0.006) == 0.006,
                     "a quiet room uses the minimum voice level")
        suite.expect(DictationSupport.voiceThreshold(floor: 0.01, minimum: 0.006) == 0.03,
                     "a noisy room raises the voice level above its floor")

        let priority = ["buds:input", "BuiltInMicrophoneDevice", "webcam"]
        suite.expect(DictationSupport.inputDeviceUID(choice: DictationSupport.priorityInput, priority: priority,
                                                     available: ["BuiltInMicrophoneDevice", "webcam"]) == "BuiltInMicrophoneDevice",
                     "priority order picks the first connected microphone")
        suite.expect(DictationSupport.inputDeviceUID(choice: DictationSupport.priorityInput, priority: priority,
                                                     available: []) == nil,
                     "no ranked microphone connected falls back to the system default")
        suite.expect(DictationSupport.inputDeviceUID(choice: DictationSupport.systemInput, priority: priority,
                                                     available: Set(priority)) == nil,
                     "the system choice ignores the priority list")
        suite.expect(DictationSupport.inputDeviceUID(choice: "webcam", priority: priority,
                                                     available: Set(priority)) == "webcam",
                     "a chosen connected microphone records")
        suite.expect(DictationSupport.inputDeviceUID(choice: "gone", priority: priority,
                                                     available: ["webcam"]) == "webcam",
                     "a chosen microphone that is gone falls back to the priority order")

        suite.expect(DictationSupport.append("world.", to: "Hello") == "Hello world.", "stretches join with a space")
        suite.expect(DictationSupport.append(", then", to: "Hello") == "Hello, then", "punctuation joins without one")
        suite.expect(DictationSupport.append(" again", to: "Hello") == "Hello again", "existing spaces are kept")
        suite.expect(DictationSupport.append("Hi", to: "") == "Hi", "the first stretch starts the transcript")
    }
}

/// Fork: the shared spectrum. Below the cutoff stays dark, a tone lights its
/// own band, silence settles to nothing, and the two tunings stay distinct.
enum SpectrumAnalyzerTests {
    static func tone(_ frequencies: [(Double, Float)], count: Int, rate: Double, offset: Int) -> [Float] {
        (0..<count).map { index in
            let t = Double(index + offset) / rate
            return frequencies.reduce(Float(0)) { $0 + $1.1 * Float(sin(2 * .pi * $1.0 * t)) }
        }
    }

    static func settle(_ configuration: SpectrumConfiguration, _ signal: [(Double, Float)]) -> [Float] {
        let rate = 48_000.0
        guard let analyzer = SpectrumAnalyzer(configuration: configuration, sampleRate: rate) else { return [] }
        var levels: [Float] = []
        for frame in 0..<40 {
            levels = analyzer.process(tone(signal, count: configuration.inputLength, rate: rate, offset: frame * 512))
        }
        return levels
    }

    static func run(_ suite: TestSuite) {
        for configuration in [SpectrumConfiguration.dictation, .media] {
            let bins = SpectrumAnalyzer.bandBins(configuration, sampleRate: 48_000)
            let width = 48_000 / Double(configuration.size)
            suite.expect(bins.count == configuration.bands, "every band has bins")
            suite.expect(bins.allSatisfy { Double($0.lowerBound) * width >= configuration.minimumFrequency },
                         "no band reads below \(Int(configuration.minimumFrequency)) Hz")
            suite.expect(zip(bins, bins.dropFirst()).allSatisfy { $0.lowerBound <= $1.lowerBound },
                         "bands rise from low to high")
            suite.expect(settle(configuration, []).allSatisfy { $0 < 0.02 }, "silence leaves the bars empty")
        }
        suite.expect(SpectrumConfiguration.dictation.minimumFrequency == 100, "the microphone cuts below 100 Hz")
        suite.expect(SpectrumConfiguration.media.minimumFrequency == 40, "music cuts below 40 Hz")

        let voice = settle(.dictation, [(50, 0.6), (1_000, 0.05)])
        let voiceBins = SpectrumAnalyzer.bandBins(.dictation, sampleRate: 48_000)
        let voiceBand = voiceBins.firstIndex { Double($0.upperBound + 1) * 48_000 / 1024 > 1_000 } ?? 0
        suite.expect(voice.indices.max { voice[$0] < voice[$1] } == voiceBand,
                     "a loud hum under the cutoff doesn't outshine quiet speech")
        suite.expect((voice.first ?? 1) < 0.3, "the lowest microphone bar stays down under hum")

        let music = settle(.media, [(20, 0.6), (2_000, 0.05)])
        suite.expect((music.first ?? 1) < 0.3, "sub-bass under 40 Hz leaves the bass bar down")
        suite.expect((music.max() ?? 0) > 0.6, "audible music still fills its band")
    }
}

/// Fork: the assignable Back and Forward mouse buttons.
enum MouseNavigationButtonTests {
    static func run(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.mouse-navigation")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.mouse-navigation")
        defer {
            defaults.removePersistentDomain(forName: "com.vorssaint.tests.mouse-navigation")
            MouseNavigationSupport.reload(from: defaults)
        }
        MouseNavigationSupport.reload(from: defaults)
        suite.expect(MouseNavigationSupport.direction(forButtonNumber: 3) == .back
                     && MouseNavigationSupport.direction(forButtonNumber: 4) == .forward,
                     "without a choice the standard side buttons navigate")
        defaults.set(5, forKey: DefaultsKey.mouseNavigationBackButton)
        defaults.set(6, forKey: DefaultsKey.mouseNavigationForwardButton)
        MouseNavigationSupport.reload(from: defaults)
        suite.expect(MouseNavigationSupport.direction(forButtonNumber: 5) == .back
                     && MouseNavigationSupport.direction(forButtonNumber: 6) == .forward
                     && MouseNavigationSupport.direction(forButtonNumber: 3) == nil,
                     "recorded buttons replace the standard ones")
        defaults.set(0, forKey: DefaultsKey.mouseNavigationBackButton)
        defaults.set(99, forKey: DefaultsKey.mouseNavigationForwardButton)
        MouseNavigationSupport.reload(from: defaults)
        suite.expect(MouseNavigationSupport.backButtonNumber == MouseNavigationSupport.defaultBackButtonNumber
                     && MouseNavigationSupport.forwardButtonNumber == MouseNavigationSupport.defaultForwardButtonNumber,
                     "a left click or an impossible button falls back to the standard ones")
    }
}
