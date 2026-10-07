// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

#if VORSSAINT_DEVELOPMENT
import AVFoundation
import AppKit

/// Fork, developer builds only:
/// `--recorder-overlay-render OUT.mp4 [--gif OUT.gif] [--studio]`
/// builds a synthetic take (a drawn screen, a pointer path, clicks, keys and a
/// drawn camera), runs it through the production exporter and exits. It needs
/// no Screen Recording, camera or keyboard access, and touches no preferences.
enum RecorderOverlayProbe {
    static func runIfRequestedAndExit() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--recorder-overlay-render"),
              arguments.indices.contains(flag + 1) else { return }
        let output = URL(fileURLWithPath: arguments[flag + 1])
        let gif = arguments.firstIndex(of: "--gif").flatMap {
            arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil
        }
        // The studio look adds a background, rounded card and click zooms, to
        // check the overlays' layering against them.
        let studio = arguments.contains("--studio")
        Task.detached {
            let status = await run(output: output, gif: gif, studio: studio)
            exit(status)
        }
        RunLoop.main.run()
    }

    static let size = CGSize(width: 1280, height: 720)
    static let duration = 4.0

    private static func run(output: URL, gif: URL?, studio: Bool) async -> Int32 {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-overlay-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let take = RecorderTakeStore.Take(id: UUID(), folder: folder)
            try await writeVideo(to: take.videoURL, size: size, frameRate: 30, draw: drawScreen)
            try await writeVideo(to: take.cameraURL, size: CGSize(width: 640, height: 480), frameRate: 30,
                                 draw: drawCamera)
            try pointerTrack().encoded().write(to: take.pointerURL)
            try clickTrack().encoded()?.write(to: take.clicksURL)
            try keystrokeTrack().encoded()?.write(to: take.keystrokesURL)

            var document = RecorderEditDocument()
            document.zoomEnabled = false
            if studio {
                document = document.applying(.studio).restoringAutomaticZooms(
                    clicks: pointerTrack().clicks, duration: duration)
                document.overlays.camera.shape = .roundedRect
                document.overlays.camera.corner = .topRight
                document.overlays.keystrokes.style = .light
            }
            document.overlays.keystrokes.mode = .all
            document.overlays.clicks.style = .ripple
            document.overlays.clicks.pointerEffect = .halo
            for (url, kind) in [(output, RecorderExporter.Output.video)] + (gif.map { [($0, .gif)] } ?? []) {
                try? FileManager.default.removeItem(at: url)
                let failure = await RecorderExporter().export(take: take, document: document, output: kind,
                                                              to: url, progress: { _ in })
                if let failure {
                    print("RECORDER OVERLAY RENDER failed: \(failure)")
                    return 1
                }
                print("RECORDER OVERLAY RENDER wrote \(url.path)")
            }
            return 0
        } catch {
            print("RECORDER OVERLAY RENDER failed: \(error)")
            return 1
        }
    }

    // MARK: - Synthetic take

    /// The pointer path: a slow loop over the screen, through each click.
    static func pointer(at time: Double) -> CGPoint {
        CGPoint(x: 0.5 + 0.3 * cos(time * 1.4), y: 0.45 + 0.25 * sin(time * 1.9))
    }

    static let clickTimes: [(time: Double, button: RecorderClickEvent.Button)] = [
        (0.6, .left), (1.5, .right), (2.5, .left), (3.3, .left),
    ]

    private static func pointerTrack() -> RecorderPointerTrack {
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 125).map {
            RecorderMotion.Sample(time: $0, point: pointer(at: $0))
        }
        let clicks = clickTimes.flatMap { [RecorderMotion.Click(time: $0.time, isDown: true),
                                           RecorderMotion.Click(time: $0.time + 0.1, isDown: false)] }
        return RecorderPointerTrack(samples: samples, clicks: clicks)
    }

    private static func clickTrack() -> RecorderClickTrack {
        RecorderClickTrack(events: clickTimes.flatMap { click -> [RecorderClickEvent] in
            let point = pointer(at: click.time)
            return [RecorderClickEvent(time: click.time, x: point.x, y: point.y, button: click.button, isDown: true),
                    RecorderClickEvent(time: click.time + 0.1, x: point.x, y: point.y, button: click.button,
                                       isDown: false)]
        })
    }

    private static func keystrokeTrack() -> RecorderKeystrokeTrack {
        var strokes = [RecorderKeystroke(time: 0.3, key: "4", modifiers: [.command, .shift], kind: .shortcut)]
        for (index, character) in "hello".enumerated() {
            strokes.append(RecorderKeystroke(time: 1.2 + Double(index) * 0.12, key: String(character).uppercased(),
                                             kind: .text, text: String(character)))
        }
        strokes.append(RecorderKeystroke(time: 2.4, key: "S", modifiers: [.command], kind: .shortcut))
        for index in 0..<3 {
            strokes.append(RecorderKeystroke(time: 3.0 + Double(index) * 0.15, key: "Z", modifiers: [.command],
                                             kind: .shortcut))
        }
        return RecorderKeystrokeTrack(capture: .all, strokes: strokes)
    }

    /// A desktop-ish screen: a gradient with a window and a few lines of text.
    private static func drawScreen(_ context: CGContext, _ size: CGSize, _ time: Double) {
        let colors = [CGColor(srgbRed: 0.22, green: 0.42, blue: 0.62, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.32, blue: 0.55, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                       options: [])
        }
        let window = CGRect(x: size.width * 0.12, y: size.height * 0.14, width: size.width * 0.62,
                            height: size.height * 0.7)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.addPath(CGPath(roundedRect: window, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 30))
        for line in 0..<8 {
            let width = window.width * (0.45 + 0.4 * abs(sin(Double(line) * 1.7 + time * 0.5)))
            context.setFillColor(CGColor(gray: 0.55, alpha: 1))
            context.fill(CGRect(x: window.minX + 32, y: window.maxY - 90 - CGFloat(line) * 42,
                                width: width, height: 14))
        }
    }

    /// A stand-in face: skin-toned circle on a backdrop that shifts hue with
    /// time, with a marker on the right so mirroring can be seen.
    private static func drawCamera(_ context: CGContext, _ size: CGSize, _ time: Double) {
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.5 + 0.3 * sin(time), blue: 0.35, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.78, blue: 0.62, alpha: 1))
        context.fillEllipse(in: CGRect(x: size.width / 2 - 120, y: size.height / 2 - 150, width: 240, height: 300))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: size.width / 2 - 60, y: size.height / 2 + 30, width: 28, height: 28))
        context.fillEllipse(in: CGRect(x: size.width / 2 + 32, y: size.height / 2 + 30, width: 28, height: 28))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: size.width - 90, y: size.height / 2 - 30, width: 60, height: 60))
    }

    private enum ProbeFailure: Error { case writer }

    private static func writeVideo(to url: URL, size: CGSize, frameRate: Int,
                                   draw: (CGContext, CGSize, Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(size.width)
        let height = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ProbeFailure.writer }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(frameRate))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var maybe: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw ProbeFailure.writer }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe)
            guard let pixels = maybe else { throw ProbeFailure.writer }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                           | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(context, size, Double(frame) / Double(frameRate))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame),
                                                                       timescale: CMTimeScale(frameRate)))
            else { throw ProbeFailure.writer }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ProbeFailure.writer }
    }
}
#endif
