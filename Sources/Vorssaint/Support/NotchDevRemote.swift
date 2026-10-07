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
            case "dictation-long":
                DictationService.shared.startPreview(text: (1...24).map { "Sentence \($0) of a long dictation that keeps going so the oldest lines scroll away." }.joined(separator: " "))
            case "dictation-end": DictationService.shared.endPreview()
            case "commandbar": CommandBarService.shared.show()
            case "clipboard": ClipboardHistoryService.shared.toggleHistoryWindow()
            case "lockscreen-player": LockScreenPlayerPreview.show()
            case "lockscreen-player-remembered":
                NotchMusicService.shared.stop()
                LockScreenPlayerPreview.show()
            case "lyrics-state":
                let lyrics = NotchLyricsService.shared
                let line = "state=\(lyrics.state) lines=\(lyrics.lyrics?.lines.count ?? -1) "
                    + "playback=\(NotchMusicService.shared.playback != nil) enabled=\(NotchLyricsSupport.isEnabled())\n"
                try? line.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("vorssaint-lyrics-state.txt"),
                                atomically: true, encoding: .utf8)
            case "commandbar-guides":
                CommandBarService.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let bar = NSApp.windows.first(where: { $0.isVisible && $0.title == "Vorssaint" && $0.level == .floating })
                    else { return }
                    CommandBarDragController.shared.previewSnap(window: bar)
                }
            case "commandbar-guides-end": CommandBarDragController.shared.endPreview()
            case "aichat": AIChatService.shared.show()
            case "settings-commandbar":
                SettingsRouter.shared.request(FeatureSettingsDestination(.commandBar), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "settings-workspaces":
                SettingsRouter.shared.request(FeatureSettingsDestination(.workspaces), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "snapwheel-end": SnapWheelOverlay.shared.hide(placed: false)  // Fork
            case let raw where raw.hasPrefix("snapwheel:"):  // Fork: "snapwheel:left" or "snapwheel:left:2"
                SnapWheelOverlay.shared.devPreview(String(raw.dropFirst("snapwheel:".count)))
            // Fork: meetings, with a made-up Zoom meeting whose Join opens nothing.
            case "meeting-alert": MeetingAlertService.shared.showPreview()
            case "meeting-soon": NotchCalendarService.shared.previewMeeting(startingIn: 3 * 60)
            case "meeting-live": NotchCalendarService.shared.previewMeeting(startingIn: -5 * 60)
            case "meeting-soon-end": NotchCalendarService.shared.previewMeeting(startingIn: nil)
            case "settings-calendar":
                SettingsRouter.shared.request(FeatureSettingsDestination(.notch), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "settings-appicons":  // Fork
                SettingsRouter.shared.request(FeatureSettingsDestination(.appIcons), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "settings-snapwheel":
                SettingsRouter.shared.request(FeatureSettingsDestination(.snapWheel), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "settings-aichat":
                SettingsRouter.shared.request(FeatureSettingsDestination(.aiChat), targetFeature: nil, sidebarFeature: nil)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            case "aichat-settings": AIChatService.shared.show(); AIChatService.shared.showsSettings = true
            case let raw where raw.hasPrefix("aichat:"):
                AIChatService.shared.ask(String(raw.dropFirst("aichat:".count)))
            case let raw where raw.hasPrefix("commandbar:"):
                CommandBarService.shared.show()
                CommandBarService.shared.query = String(raw.dropFirst("commandbar:".count))
            case let raw:
                if let module = NotchModule(rawValue: raw) { service.open(module, pinned: true) }
            }
        }
    }
}
#endif

#if VORSSAINT_DEVELOPMENT
import AppKit
import SwiftUI

/// Developer builds only: the lock screen's player in an ordinary window, so
/// its layout can be seen without locking the Mac.
enum LockScreenPlayerPreview {
    private static var window: NSWindow?

    static func show() {
        let model = NotchLockScreenModel()
        model.gates = NotchLockScreenModel.Gates(music: true, remembers: true)
        let size = CGSize(width: NotchLockScreenLayout.playerWidth, height: 470)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Lock screen player"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NotchLockScreenPlayer(model: model, size: size)
            .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)))
        window.center()
        window.orderFrontRegardless()
        self.window = window
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
        // Any further files follow the first, as a headset changing profile
        // mid-session changes the rate the audio arrives at.
        let urls = arguments[(flag + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        Task {
            do {
                var format: AVAudioFormat?
                var buffers: [AVAudioPCMBuffer] = []
                for url in urls {
                    let file = try AVAudioFile(forReading: url)
                    format = format ?? file.processingFormat
                    while file.framePosition < file.length {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { break }
                        try file.read(into: buffer, frameCount: 2048)
                        buffers.append(buffer)
                    }
                }
                guard let format else { exit(1) }
                let engine = DictationSpeechEngine()
                engine.onText = { print("partial: \($0)") }
                let early = min(10, buffers.count)
                for buffer in buffers[..<early] { engine.append(buffer) }
                try await engine.start(locale: Locale(identifier: "en-US"), naturalFormat: format)
                for buffer in buffers[early...] { engine.append(buffer) }
                let text = await engine.finish(timeout: 8)
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

#if VORSSAINT_DEVELOPMENT
import SwiftUI

/// Developer builds only: `--dictation-render PATH LINES` draws the dictation
/// surface offscreen with that many sentences, for checking its layout.
enum DictationRenderProbe {
    static func runIfRequestedAndExit() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--dictation-render"), arguments.indices.contains(flag + 2),
              let count = Int(arguments[flag + 2]) else { return }
        let text = (1...max(1, count)).map { "Sentence \($0) of a long dictation that keeps going." }.joined(separator: " ")
        DictationService.shared.setPreviewTranscript(text)
        let size = DictationLayout.size(text: text, width: DictationLayout.width, top: 12)
        let view = DictationContent(width: DictationLayout.width)
            .padding(.horizontal, DictationLayout.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, DictationLayout.bottomInset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.black)
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[flag + 1]) as CFURL,
                                                                    "public.png" as CFString, 1, nil) else { exit(1) }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("rendered \(size)")
            exit(0)
        }
    }
}
#endif
