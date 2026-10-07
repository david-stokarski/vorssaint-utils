// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreImage
import Foundation

/// Fork: recording overlays. Chords read the way macOS writes them, the
/// shortcuts-only capture never keeps typed text, captions group and fade on
/// a fixed clock, click highlights animate on theirs, the camera bubble stays
/// inside the frame, older documents and takes open unchanged, and the
/// production exporter draws all three overlays into the file.
enum RecorderOverlayTests {
    static func run(_ suite: TestSuite) {
        chords(suite)
        capture(suite)
        captions(suite)
        clicks(suite)
        bubble(suite)
        documents(suite)
        preferences(suite)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await frameSource(suite)
                try await export(suite)
            } catch {
                suite.expect(false, "overlay fixture failed \(error)")
            }
            done.signal()
        }
        suite.expect(done.wait(timeout: .now() + 90) == .success, "overlay rendering finishes within its deadline")
    }

    // MARK: - Chords

    private static func chords(_ suite: TestSuite) {
        suite.expect(RecorderKeyChord.glyphs([.command, .shift, .option, .control]) == "⌃⌥⇧⌘",
                     "modifiers read in Apple's order whatever order they were pressed")
        suite.expect(RecorderKeyChord.label(modifiers: [.command, .shift], key: "4") == "⇧⌘4",
                     "the screenshot shortcut reads ⇧⌘4")
        suite.expect(RecorderKeyChord.label(modifiers: [], key: "⎋") == "⎋", "a bare key has no glyphs")
        let named: [(Int, String)] = [
            (kVK_Escape, "⎋"), (kVK_Tab, "⇥"), (kVK_Return, "↩"), (kVK_ANSI_KeypadEnter, "⌤"),
            (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
            (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"), (kVK_Space, "Space"), (kVK_Home, "↖"), (kVK_End, "↘"),
            (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"), (kVK_F1, "F1"), (kVK_F5, "F5"), (kVK_F12, "F12"),
        ]
        for (code, name) in named {
            suite.expect(RecorderKeyChord.specialName(keyCode: UInt16(code)) == name,
                         "key code \(code) is named \(name)")
        }
        suite.expect(RecorderKeyChord.specialName(keyCode: UInt16(kVK_ANSI_A)) == nil, "a letter has no special name")
        suite.expect(RecorderKeyChord.isCommandKey(keyCode: UInt16(kVK_Escape))
                        && RecorderKeyChord.isCommandKey(keyCode: UInt16(kVK_LeftArrow))
                        && !RecorderKeyChord.isCommandKey(keyCode: UInt16(kVK_Space))
                        && !RecorderKeyChord.isCommandKey(keyCode: UInt16(kVK_Delete))
                        && !RecorderKeyChord.isCommandKey(keyCode: UInt16(kVK_ANSI_A)),
                     "escape and arrows steer; space, delete and letters type")
        suite.expect(RecorderKeyChord.keyLabel(keyCode: UInt16(kVK_ANSI_S), unmodifiedCharacters: "s") == "S",
                     "a letter shows as its key cap")
        suite.expect(RecorderKeyChord.keyLabel(keyCode: UInt16(kVK_ANSI_A), unmodifiedCharacters: "\u{1}") == nil,
                     "a control character is no label")
        suite.expect(RecorderKeyChord.typedText("\u{F700}") == nil && RecorderKeyChord.typedText("é") == "é",
                     "function-key characters are not text; accented letters are")
    }

    // MARK: - Capture

    private static func stroke(_ code: Int, _ modifiers: RecorderKeyModifiers = [], _ characters: String,
                               unmodified: String? = nil,
                               capture: RecorderKeystrokeCapture, at time: Double = 1) -> RecorderKeystroke? {
        RecorderKeyChord.stroke(time: time, keyCode: UInt16(code), modifiers: modifiers,
                                unmodifiedCharacters: unmodified ?? characters.lowercased(), characters: characters,
                                capture: capture)
    }

    private static func capture(_ suite: TestSuite) {
        suite.expect(stroke(kVK_ANSI_A, [], "a", capture: .shortcuts) == nil,
                     "shortcuts-only keeps nothing of a typed letter")
        suite.expect(stroke(kVK_ANSI_A, [.shift], "A", capture: .shortcuts) == nil,
                     "shift alone is typing, not a shortcut")
        suite.expect(stroke(kVK_Space, [], " ", capture: .shortcuts) == nil
                        && stroke(kVK_Delete, [], "", capture: .shortcuts) == nil,
                     "space and delete are typing")
        let save = stroke(kVK_ANSI_S, [.command], "s", capture: .shortcuts)
        suite.expect(save?.kind == .shortcut && save?.chord == "⌘S" && save?.text == nil,
                     "a command shortcut keeps its chord and no text")
        suite.expect(stroke(kVK_Escape, [], "\u{1B}", capture: .shortcuts)?.chord == "⎋",
                     "escape is kept on its own")
        suite.expect(stroke(kVK_Tab, [.shift], "\t", capture: .shortcuts)?.chord == "⇧⇥",
                     "shift with a steering key is a shortcut")
        suite.expect(stroke(kVK_ANSI_2, [.option], "™", unmodified: "2", capture: .shortcuts)?.chord == "⌥2",
                     "option shortcuts show their key cap, not the character produced")
        let typed = stroke(kVK_ANSI_A, [.shift], "A", capture: .all)
        suite.expect(typed?.kind == .text && typed?.text == "A", "all keys keeps typed text")
        suite.expect(stroke(kVK_Delete, [], "\u{7F}", capture: .all)?.kind == .delete,
                     "all keys keeps a delete as an edit")

        // A password typed in shortcuts-only mode leaves nothing in the file.
        var strokes: [RecorderKeystroke] = []
        for (index, character) in "hunter2".enumerated() {
            let code = character == "2" ? kVK_ANSI_2 : kVK_ANSI_H
            if let kept = stroke(code, [], String(character), capture: .shortcuts, at: Double(index)) {
                strokes.append(kept)
            }
        }
        if let kept = stroke(kVK_Return, [], "\r", capture: .shortcuts, at: 8) { strokes.append(kept) }
        let data = RecorderKeystrokeTrack(capture: .shortcuts, strokes: strokes).encoded() ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        suite.expect(strokes.count == 1 && !json.contains("hunter") && !json.contains("\"text\""),
                     "a typed password never reaches a shortcuts-only track")
    }

    // MARK: - Captions

    private static func captions(_ suite: TestSuite) {
        let strokes = [
            RecorderKeystroke(time: 1.0, key: "4", modifiers: [.command, .shift], kind: .shortcut),
            RecorderKeystroke(time: 2.0, key: "H", kind: .text, text: "h"),
            RecorderKeystroke(time: 2.2, key: "I", kind: .text, text: "i"),
            RecorderKeystroke(time: 2.4, key: "X", kind: .text, text: "x"),
            RecorderKeystroke(time: 2.5, key: "⌫", kind: .delete),
            RecorderKeystroke(time: 6.0, key: "Z", modifiers: [.command], kind: .shortcut),
            RecorderKeystroke(time: 6.3, key: "Z", modifiers: [.command], kind: .shortcut),
            RecorderKeystroke(time: 6.6, key: "Z", modifiers: [.command], kind: .shortcut),
            RecorderKeystroke(time: 6.8, key: "S", modifiers: [.command], kind: .shortcut),
        ]
        let all = RecorderKeyCaptions.captions(strokes, mode: .all)
        suite.expect(all.map(\.text) == ["⇧⌘4", "hi", "⌘Z ×3", "⌘S"],
                     "typing runs join, a delete removes, and a repeated chord counts: \(all.map(\.text))")
        suite.expect(all.count == 4 && all[0].end == all[1].start,
                     "a caption that the next one replaces leaves the moment it arrives")
        suite.expectClose(all.count == 4 ? all[1].end : 0, 2.5 + RecorderKeyCaptions.hold + RecorderKeyCaptions.fadeOut,
                          "a caption left alone holds after its last key, then fades")
        suite.expect(all.count == 4 && all[2].lastKey == 6.6 && all[2].end == 6.8,
                     "a repeat extends the caption's hold from its last press")
        let shortcutsOnly = RecorderKeyCaptions.captions(strokes, mode: .shortcuts)
        suite.expect(shortcutsOnly.map(\.text) == ["⇧⌘4", "⌘Z ×3", "⌘S"],
                     "shortcuts-only display hides typed text even when it was recorded")
        let long = (0..<60).map { RecorderKeystroke(time: Double($0) * 0.05, key: "A", kind: .text, text: "a") }
        let longCaption = RecorderKeyCaptions.captions(long, mode: .all)
        suite.expect(longCaption.count == 1 && longCaption[0].text.count == RecorderKeyCaptions.maxCharacters
                        && longCaption[0].text.hasPrefix("…"),
                     "a long run keeps its newest characters")

        let caption = RecorderKeyCaption(start: 1, lastKey: 1.5, text: "⌘S", end: 1.5 + 1.1 + 0.3)
        suite.expect(RecorderKeyCaptions.opacity(of: caption, at: 0.99) == 0, "nothing before the first key")
        suite.expectClose(RecorderKeyCaptions.opacity(of: caption, at: 1.04), 0.5, "fading in", tol: 0.01)
        suite.expectClose(RecorderKeyCaptions.opacity(of: caption, at: 2.0), 1, "held solid")
        suite.expectClose(RecorderKeyCaptions.opacity(of: caption, at: 2.75), 0.5, "fading out", tol: 0.01)
        suite.expect(RecorderKeyCaptions.opacity(of: caption, at: 2.9) == 0, "gone once faded")
        suite.expect(RecorderKeyCaptions.active(all, at: 2.3)?.index == 1
                        && RecorderKeyCaptions.active(all, at: 0.5) == nil
                        && RecorderKeyCaptions.active(all, at: 5) == nil,
                     "the caption on screen is found by time")
    }

    // MARK: - Clicks

    private static func clicks(_ suite: TestSuite) {
        suite.expect(RecorderClickAnimation.progress(at: 0.99, clickTime: 1, duration: 0.5) == nil,
                     "no highlight before the press")
        suite.expectClose(RecorderClickAnimation.progress(at: 1, clickTime: 1, duration: 0.5) ?? -1, 0, "starts at the press")
        suite.expectClose(RecorderClickAnimation.progress(at: 1.25, clickTime: 1, duration: 0.5) ?? -1, 0.5, "halfway")
        suite.expect(RecorderClickAnimation.progress(at: 1.51, clickTime: 1, duration: 0.5) == nil, "gone after")
        let active = RecorderClickAnimation.active(at: 2.2, downTimes: [0.5, 1.9, 2.0, 2.15, 3], duration: 0.45)
        suite.expect(active.map(\.index) == [1, 2, 3], "every press still animating is drawn, oldest first")
        let ring = RecorderClickAnimation.ring(progress: 0)
        let ringEnd = RecorderClickAnimation.ring(progress: 1)
        suite.expect(ring.radius < ringEnd.radius && ring.alpha > 0.9 && ringEnd.alpha == 0,
                     "a ring grows and fades out completely")
        for style in RecorderOverlaySettings.ClickStyle.allCases {
            suite.expect(RecorderOverlayRenderer.clickSprite(style: style, progress: 0.2, radius: 40,
                                                             color: .yellow, dashed: true) != nil,
                         "the \(style) highlight draws")
        }
        suite.expect(RecorderOverlaySettings.Palette.blue.contrasting != .blue
                        && RecorderOverlaySettings.Palette.yellow.contrasting != .yellow,
                     "a right click never wears the left click's color")
        let track = RecorderClickTrack(events: [
            RecorderClickEvent(time: 2, x: 0.5, y: 0.5, button: .left, isDown: true),
            RecorderClickEvent(time: 2.1, x: 0.5, y: 0.5, button: .left, isDown: false),
            RecorderClickEvent(time: 1, x: 0.2, y: 0.2, button: .right, isDown: true),
        ])
        var damaged = track
        damaged.events.append(RecorderClickEvent(time: .nan, x: 0.2, y: 0.2, button: .left, isDown: true))
        suite.expect(damaged.presses.map(\.time) == [1, 2], "presses are ordered and invalid times dropped")
        suite.expect(RecorderClickTrack.decoded(track.encoded()) == track
                        && RecorderClickTrack.decoded(Data("nonsense".utf8)).isEmpty
                        && RecorderClickTrack.decoded(nil).isEmpty,
                     "a click track round-trips, and a damaged one reads as empty")
    }

    // MARK: - Bubble

    private static func bubble(_ suite: TestSuite) {
        let canvas = CGSize(width: 1920, height: 1080)
        for corner in RecorderOverlaySettings.Corner.allCases {
            for shape in RecorderOverlaySettings.BubbleShape.allCases {
                for size in [0.0, 0.1, 0.24, 0.5, 5, -.infinity, .nan] {
                    let rect = RecorderBubbleLayout.rect(canvas: canvas, shape: shape, corner: corner, size: size)
                    suite.expect(rect.width > 0 && rect.height > 0
                                    && CGRect(origin: .zero, size: canvas).contains(rect),
                                 "the bubble stays inside the frame: \(corner) \(shape) \(size) \(rect)")
                }
            }
        }
        let circle = RecorderBubbleLayout.rect(canvas: canvas, shape: .circle, corner: .bottomRight, size: 0.24)
        suite.expect(circle.width == circle.height && circle.maxX > 1800 && circle.minY < 100,
                     "a circle is square and sits bottom right")
        let topLeft = RecorderBubbleLayout.rect(canvas: canvas, shape: .roundedRect, corner: .topLeft, size: 0.24)
        suite.expect(topLeft.minX < 100 && topLeft.maxY > 980 && topLeft.width > topLeft.height,
                     "a rounded bubble is landscape and honors its corner")
        let tiny = RecorderBubbleLayout.rect(canvas: CGSize(width: 40, height: 20), shape: .circle,
                                             corner: .topRight, size: 0.5)
        suite.expect(CGRect(x: 0, y: 0, width: 40, height: 20).contains(tiny) && tiny.width >= 1,
                     "even a tiny frame keeps the bubble inside")
        let fill = RecorderBubbleLayout.aspectFill(image: CGSize(width: 640, height: 480),
                                                   into: CGRect(x: 10, y: 10, width: 200, height: 200))
        suite.expectClose(Double(fill.scale), 200.0 / 480, "the camera fills the bubble's shorter side")
        suite.expectClose(Double(fill.origin.x + 640 * fill.scale / 2), 110, "and is centered on it")
        suite.expect(RecorderBubbleLayout.clamped(CGRect(x: -50, y: 2000, width: 100, height: 100), in: canvas)
                        == CGRect(x: 0, y: 980, width: 100, height: 100),
                     "a rectangle out of the frame is pulled back in")
    }

    // MARK: - Documents

    private static func documents(_ suite: TestSuite) {
        // Written before overlays existed.
        let legacy = Data(#"{"trimStart":1,"trimEnd":0,"quality":"high","showsPointer":false}"#.utf8)
        let document = RecorderEditDocument.decoded(legacy)
        suite.expect(document.trimStart == 1 && document.quality == "high" && !document.showsPointer
                        && document.overlays == RecorderOverlaySettings(),
                     "an older document opens with default overlays and its own values")
        var edited = RecorderEditDocument()
        edited.overlays.clicks.style = .ripple
        edited.overlays.keystrokes.mode = .all
        edited.overlays.camera.corner = .topLeft
        edited.overlays.camera.size = 0.4
        suite.expect(RecorderEditDocument.decoded(edited.encoded()) == edited, "overlay settings round-trip")
        let partial = Data(#"{"overlays":{"clicks":{"style":"sparkle","size":1.5},"camera":{"shape":"circle","mirrored":false}}}"#.utf8)
        let lenient = RecorderEditDocument.decoded(partial)
        suite.expect(lenient.overlays.clicks.style == .ring && lenient.overlays.clicks.size == 1.5
                        && !lenient.overlays.camera.mirrored && lenient.overlays.camera.corner == .bottomRight
                        && lenient.overlays.keystrokes == RecorderOverlaySettings.Keystrokes(),
                     "an unknown style or a missing part falls back without losing the rest")
        var wild = RecorderEditDocument()
        wild.overlays.camera.size = 9
        wild.overlays.clicks.size = .nan
        let sane = wild.sanitized(duration: 10)
        suite.expect(sane.overlays.camera.size == RecorderOverlaySettings.Camera.sizeRange.upperBound
                        && sane.overlays.clicks.size == 1,
                     "sanitizing clamps overlay sizes")
        suite.expect(edited.affectsPicture(RecorderEditDocument()), "an overlay change redraws the preview")
        suite.expect(!edited.affectsTiming(RecorderEditDocument()), "but never rebuilds the timeline")

        let legacyPreset = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","backdrop":"","aspect":"original","showsPointer":true,"pointerSmoothing":"smooth","pointerSize":1,"showsClickRing":true,"zoomEnabled":true,"zoomAmount":1.8}"#.utf8)
        if let preset = try? JSONDecoder().decode(RecorderEditPreset.self, from: legacyPreset) {
            suite.expect(preset.overlays == nil && preset.applying(to: edited).overlays == edited.overlays,
                         "an older preset leaves the overlays alone")
        } else {
            suite.expect(false, "an older preset still decodes")
        }
        let saved = RecorderEditPreset(name: "New", document: edited)
        suite.expect(saved.applying(to: RecorderEditDocument()).overlays == edited.overlays,
                     "a new preset carries the overlays' look")

        suite.expect(RecorderKeystrokeTrack.decoded(Data("{".utf8)).isEmpty
                        && RecorderKeystrokeTrack.decoded(nil).capture == .shortcuts,
                     "a missing or damaged keystroke track reads as empty and shortcuts-only")
        let input = RecorderOverlayInput.tracks(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        suite.expect(input.isEmpty, "a take without overlay files has no overlay input")
        let plain = RecorderComposer.makePlan(document: {
            var document = RecorderEditDocument()
            document.showsPointer = false
            document.zoomEnabled = false
            return document
        }(), track: RecorderPointerTrack(), sourceSize: CGSize(width: 64, height: 64), frameRate: 30, duration: 1,
           overlays: input)
        suite.expect(plain == nil, "an old take with nothing to draw still exports through the plain path")
    }

    private static func preferences(_ suite: TestSuite) {
        suite.expect(Defaults.registeredDefaults[DefaultsKey.recorderShowKeystrokes] as? Bool == false
                        && Defaults.registeredDefaults[DefaultsKey.recorderCamera] as? Bool == false
                        && Defaults.registeredDefaults[DefaultsKey.recorderShowClicks] as? Bool == false
                        && Defaults.registeredDefaults[DefaultsKey.recorderKeystrokeCapture] as? String
                            == RecorderKeystrokeCapture.shortcuts.rawValue,
                     "every overlay starts off, and keystrokes default to shortcuts only")
        let keys = SettingsBackupSupport.exportKeys()
        suite.expect([DefaultsKey.recorderShowClicks, DefaultsKey.recorderShowKeystrokes,
                      DefaultsKey.recorderKeystrokeCapture, DefaultsKey.recorderCamera].allSatisfy(keys.contains),
                     "the overlay choices travel in backups")
        suite.expect(AppFeature.screenRecorder.permissions.contains(.camera)
                        && !AppFeature.screenRecorder.onboardingPermissions.contains(.camera),
                     "the recorder's camera permission stays contextual")
    }

    // MARK: - Rendering

    private enum FixtureFailure: Error { case write }

    /// Writes a video whose every frame is one flat color from `color(frame)`.
    private static func writeVideo(_ url: URL, width: Int, height: Int, frames: Int, fps: Int32,
                                   color: (Int, Int) -> (UInt8, UInt8, UInt8)) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var maybe: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw FixtureFailure.write }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe)
            guard let pixel = maybe else { throw FixtureFailure.write }
            CVPixelBufferLockBaseAddress(pixel, [])
            let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<height { for x in 0..<width {
                let (red, green, blue) = color(frame, x)
                let offset = y * stride + x * 4
                pointer[offset] = blue; pointer[offset + 1] = green; pointer[offset + 2] = red; pointer[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            else { throw FixtureFailure.write }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureFailure.write }
    }

    private static func meanColor(_ image: CIImage, in rect: CGRect) -> (red: Double, green: Double, blue: Double) {
        let width = Int(rect.width)
        let height = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: rect, format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var sums = (0.0, 0.0, 0.0)
        for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
            sums.0 += Double(bytes[offset])
            sums.1 += Double(bytes[offset + 1])
            sums.2 += Double(bytes[offset + 2])
        }
        let count = Double(max(1, width * height))
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }

    /// The camera reader answers by recording time, forwards, backwards and
    /// across jumps, out of order as concurrent frames ask.
    private static func frameSource(_ suite: TestSuite) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-overlay-camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("camera.mov")
        // Each frame carries its own number in binary, one bit per stripe.
        try await writeVideo(url, width: 64, height: 48, frames: 60, fps: 20) { frame, x in
            let bit = (frame >> min(5, x / 10)) & 1 == 1
            return bit ? (255, 255, 255) : (0, 0, 0)
        }
        guard let asset = await RecorderCameraFrameSource.Asset.load(url) else {
            suite.expect(false, "the camera file opens")
            return
        }
        let source = RecorderCameraFrameSource(source: asset)
        func frameIndex(at time: Double) -> Int {
            guard let image = source.image(at: time) else { return -1 }
            return (0..<6).reduce(0) { number, bit in
                let stripe = meanColor(image, in: CGRect(x: bit * 10 + 3, y: 10, width: 4, height: 28))
                return number | (stripe.green > 128 ? 1 << bit : 0)
            }
        }
        let probes: [(Double, Int)] = [(0, 0), (0.26, 5), (0.5, 10), (0.49, 9), (1.0, 20), (0.97, 19),
                                       (2.9, 58), (0.1, 2), (5, 59), (1.51, 30)]
        for (time, expected) in probes {
            let found = frameIndex(at: time)
            suite.expect(abs(found - expected) <= 0, "camera frame at \(time)s is \(expected), got \(found)")
        }
        suite.expect(await RecorderCameraFrameSource.Asset.load(folder.appendingPathComponent("none.mov")) == nil,
                     "a take without a camera file has no camera")
    }

    /// The production exporter draws the bubble, a caption and a highlight.
    private static func export(_ suite: TestSuite) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-overlay-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = RecorderTakeStore.Take(id: UUID(), folder: folder)
        try await writeVideo(take.videoURL, width: 320, height: 240, frames: 60, fps: 30) { _, _ in (128, 128, 128) }
        try await writeVideo(take.cameraURL, width: 160, height: 120, frames: 60, fps: 30) { _, _ in (0, 220, 0) }
        try RecorderClickTrack(events: [
            RecorderClickEvent(time: 0.5, x: 0.25, y: 0.25, button: .left, isDown: true),
        ], displayScale: 1).encoded()?.write(to: take.clicksURL)
        try RecorderKeystrokeTrack(capture: .shortcuts, strokes: [
            RecorderKeystroke(time: 0.4, key: "S", modifiers: [.command], kind: .shortcut),
        ]).encoded()?.write(to: take.keystrokesURL)

        var document = RecorderEditDocument()
        document.showsPointer = false
        document.zoomEnabled = false
        document.quality = RecorderSupport.Quality.high.rawValue
        document.overlays.clicks.color = .red
        document.overlays.clicks.style = .pulse
        let output = folder.appendingPathComponent("overlays.mp4")
        let failure = await RecorderExporter().export(take: take, document: document, output: .video,
                                                      to: output, progress: { _ in })
        suite.expect(failure == nil, "a take with overlays exports")
        guard failure == nil else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = CIImage(cgImage: try await generator.image(at: CMTime(seconds: 0.55, preferredTimescale: 600)).image)
        let canvas = frame.extent.size
        let bubble = RecorderBubbleLayout.rect(canvas: canvas, shape: .circle, corner: .bottomRight,
                                               size: RecorderOverlaySettings.Camera.defaultSize)
        let away = meanColor(frame, in: CGRect(x: canvas.width / 2 + 40, y: canvas.height * 0.6, width: 8, height: 8))
        suite.expect(abs(away.green - away.red) < 12 && abs(away.green - away.blue) < 12,
                     "the screen stays as recorded: \(away)")
        func same(_ color: (red: Double, green: Double, blue: Double)) -> Bool {
            abs(color.red - away.red) < 16 && abs(color.green - away.green) < 16 && abs(color.blue - away.blue) < 16
        }
        let center = meanColor(frame, in: CGRect(x: bubble.midX - 4, y: bubble.midY - 4, width: 8, height: 8))
        suite.expect(center.green > center.red + 80 && center.green > away.green + 40,
                     "the camera bubble shows the camera: \(center)")
        // The pill's dark edge, beside the chord's letters.
        let captionRect = CGRect(x: canvas.width / 2 - 17, y: canvas.height * 0.06 + 12, width: 4, height: 4)
        let caption = meanColor(frame, in: captionRect)
        suite.expect(caption.red < away.red - 50, "the shortcut caption is drawn: \(caption)")
        let click = meanColor(frame, in: CGRect(x: canvas.width * 0.25 - 3, y: canvas.height * 0.75 - 3,
                                                width: 6, height: 6))
        suite.expect(click.red > click.green + 20, "the click highlight is drawn where the press landed: \(click)")

        let later = CIImage(cgImage: try await generator.image(at: CMTime(seconds: 1.9, preferredTimescale: 600)).image)
        let clear = meanColor(later, in: CGRect(x: canvas.width * 0.25 - 3, y: canvas.height * 0.75 - 3,
                                                width: 6, height: 6))
        let noCaption = meanColor(later, in: captionRect)
        suite.expect(same(clear) && same(noCaption),
                     "highlights and captions are gone once their time has passed: \(clear) \(noCaption)")

        var hidden = document
        hidden.overlays.camera.enabled = false
        hidden.overlays.keystrokes.enabled = false
        hidden.overlays.clicks.enabled = false
        let plain = folder.appendingPathComponent("plain.mp4")
        suite.expect(await RecorderExporter().export(take: take, document: hidden, output: .video,
                                                     to: plain, progress: { _ in }) == nil,
                     "switching every overlay off still exports")
        let plainFrame = CIImage(cgImage: try await AVAssetImageGenerator(asset: AVURLAsset(url: plain))
            .image(at: CMTime(seconds: 0.55, preferredTimescale: 600)).image)
        let plainBubble = meanColor(plainFrame, in: CGRect(x: bubble.midX - 4, y: bubble.midY - 4, width: 8, height: 8))
        suite.expect(same(plainBubble), "the raw take never carries the camera: \(plainBubble)")

        let gif = folder.appendingPathComponent("overlays.gif")
        suite.expect(await RecorderExporter().export(take: take, document: document, output: .gif,
                                                     to: gif, progress: { _ in }) == nil,
                     "a GIF with overlays exports")
        if let source = CGImageSourceCreateWithURL(gif as CFURL, nil),
           CGImageSourceGetCount(source) > 7,
           let image = CGImageSourceCreateImageAtIndex(source, 7, nil) {
            let gifFrame = CIImage(cgImage: image)
            let gifBubble = RecorderBubbleLayout.rect(canvas: gifFrame.extent.size, shape: .circle,
                                                      corner: .bottomRight,
                                                      size: RecorderOverlaySettings.Camera.defaultSize)
            let color = meanColor(gifFrame, in: CGRect(x: gifBubble.midX - 2, y: gifBubble.midY - 2,
                                                       width: 4, height: 4))
            suite.expect(color.green > color.red + 80, "the GIF carries the camera bubble: \(color)")
        } else {
            suite.expect(false, "the GIF has its frames")
        }
    }
}
