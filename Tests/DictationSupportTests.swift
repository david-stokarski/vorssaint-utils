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
