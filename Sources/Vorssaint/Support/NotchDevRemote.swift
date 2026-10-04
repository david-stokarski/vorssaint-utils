// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

#if VORSSAINT_DEVELOPMENT
import Foundation

/// Developer builds only: drives the island from outside the app, so its
/// pages can be captured without a hand on the pointer. Post
/// `com.vorssaint.dev.notch` with an object of `open`, `home`, `collapse`,
/// `sections` or a section's raw value.
enum NotchDevRemote {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.vorssaint.dev.notch"), object: nil, queue: .main) { note in
            let service = NotchService.shared
            switch note.object as? String ?? "open" {
            case "open": service.open(pinned: true)
            case "home": service.open(pinned: true); service.showHome()
            case "collapse": service.collapse()
            case "sections": service.open(pinned: true); service.toggleSections()
            case "dictation": DictationService.shared.startPreview(text: "")
            case "dictation-text":
                DictationService.shared.startPreview(text: "Okay so the plan for tomorrow is to finish the island redesign, then wire dictation into the settings page and test it with the AirPods.")
            case "dictation-end": DictationService.shared.endPreview()
            case let raw:
                if let module = NotchModule(rawValue: raw) { service.open(module, pinned: true) }
            }
        }
    }
}
#endif

#if VORSSAINT_DEVELOPMENT
import AVFoundation

/// Developer builds only: `--dictation-file PATH` runs an audio file through
/// the dictation engine in microphone-sized buffers and prints what it heard.
enum DictationFileProbe {
    static func runIfRequestedAndExit() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--dictation-file"), arguments.indices.contains(flag + 1) else { return }
        guard #available(macOS 26.0, *) else { print("DICTATION needs macOS 26"); exit(1) }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        Task {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let engine = DictationSpeechEngine()
                engine.onText = { print("partial: \($0)") }
                // Feed some audio before the analyzer is ready, as a session does.
                var buffers: [AVAudioPCMBuffer] = []
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { break }
                    try file.read(into: buffer, frameCount: 2048)
                    buffers.append(buffer)
                }
                let early = min(10, buffers.count)
                for buffer in buffers[..<early] { engine.append(buffer) }
                try await engine.start(locale: Locale(identifier: "en-US"), naturalFormat: format)
                for buffer in buffers[early...] { engine.append(buffer) }
                let text = await engine.finish()
                print("DICTATION: \(text)")
                exit(text.isEmpty ? 1 : 0)
            } catch {
                print("DICTATION failed: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
#endif
