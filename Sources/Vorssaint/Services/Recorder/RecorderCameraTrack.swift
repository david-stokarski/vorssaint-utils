// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import CoreImage

// Fork: the camera beside the screen. It is written to a file of its own in
// the take, on the recording's clock, so the editor can place, size, shape or
// drop the bubble afterwards and the master is never touched. The camera
// preview feature's device choice is reused: the camera macOS remembers for
// this app is the one used.

/// Records the camera while a recording runs. The session also feeds the live
/// bubble on screen, so the person can frame themselves before and during the
/// recording. Everything here is created for one recording and gone after.
final class RecorderCameraCapture: NSObject,
                                   AVCaptureVideoDataOutputSampleBufferDelegate,
                                   @unchecked Sendable {
    let session = AVCaptureSession()

    private let url: URL
    private let pauseClock: RecorderPauseClock
    private let queue = DispatchQueue(label: "com.vorssaint.recorder.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    // Confined to `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastTime = CMTime.negativeInfinity
    private var lastSample: CMSampleBuffer?
    private var frames = 0
    private var failed = false
    private var finished = false

    init(url: URL, pauseClock: RecorderPauseClock) {
        self.url = url
        self.pauseClock = pauseClock
        super.init()
    }

    static var preferredDevice: AVCaptureDevice? {
        AVCaptureDevice.userPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }

    /// Starts the camera. Frames are written only once the recording's clock
    /// has begun, so the warm-up before the first screen frame costs nothing.
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let device = Self.preferredDevice,
                  let deviceInput = try? AVCaptureDeviceInput(device: device)
            else {
                completion(false)
                return
            }
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            }
            if session.canAddInput(deviceInput) { session.addInput(deviceInput) }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            if session.canAddOutput(output) { session.addOutput(output) }
            output.setSampleBufferDelegate(self, queue: queue)
            session.commitConfiguration()
            guard !session.inputs.isEmpty, !finished else {
                completion(false)
                return
            }
            session.startRunning()
            completion(session.isRunning)
        }
    }

    /// Closes the file at the moment the recording stopped, holding the last
    /// frame to the end as the screen master does. False when nothing usable
    /// was written, in which case no file is left behind.
    func stop(at end: CMTime) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                finished = true
                output.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                for input in session.inputs { session.removeInput(input) }
                guard let writer, let input, frames > 0, !failed, writer.status == .writing else {
                    writer?.cancelWriting()
                    lastSample = nil
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: false)
                    return
                }
                let endTime = CMTime(seconds: pauseClock.elapsed(at: end.seconds),
                                     preferredTimescale: 600_000_000)
                if endTime > lastTime, input.isReadyForMoreMediaData, let tail = lastSample,
                   let retimed = RecorderSampleTiming.retimed(tail, to: endTime) {
                    input.append(retimed)
                }
                lastSample = nil
                writer.endSession(atSourceTime: max(endTime, lastTime))
                input.markAsFinished()
                writer.finishWriting {
                    let completed = writer.status == .completed
                    if !completed { try? FileManager.default.removeItem(at: self.url) }
                    continuation.resume(returning: completed)
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finished, !failed,
              let sourceClock = session.synchronizationClock,
              let synchronized = RecorderSampleTiming.converted(sampleBuffer, from: sourceClock,
                                                                to: CMClockGetHostTimeClock())
        else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(synchronized)
        guard presentation.isNumeric,
              let mapped = pauseClock.sampleTime(start: presentation.seconds, duration: 0)
        else { return }
        let time = CMTime(seconds: mapped, preferredTimescale: 600_000_000)
        guard time > lastTime else { return }
        if writer == nil, !makeWriter(for: sampleBuffer) {
            failed = true
            return
        }
        guard let input, input.isReadyForMoreMediaData,
              let retimed = RecorderSampleTiming.retimed(sampleBuffer, to: time)
        else { return }
        if input.append(retimed) {
            frames += 1
            lastTime = time
            lastSample = sampleBuffer
        } else {
            failed = true
        }
    }

    private func makeWriter(for sample: CMSampleBuffer) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        else { return false }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, width * height * 3),
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        return true
    }
}

/// Reads camera frames for the composer by recording time. Export asks for
/// frames in order, so a forward cursor serves almost every request; a short
/// cache of recent frames absorbs the composer's concurrent, slightly
/// out-of-order requests without restarting the decoder.
final class RecorderCameraFrameSource: @unchecked Sendable {
    /// The file, opened once per take and shared by every plan built from it.
    final class Asset: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: Double

        init(asset: AVURLAsset, track: AVAssetTrack, duration: Double) {
            self.asset = asset
            self.track = track
            self.duration = duration
        }

        static func load(_ url: URL) async -> Asset? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration)
            else { return nil }
            return Asset(asset: asset, track: track, duration: max(0, duration.seconds))
        }
    }

    private struct Frame {
        let time: Double
        let pixels: CVPixelBuffer
    }

    private let source: Asset
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerStart = 0.0
    private var recent: [Frame] = []
    private var pending: Frame?
    private var exhausted = false
    private static let cacheSize = 10
    /// Further ahead than this, starting over near the target beats decoding
    /// every frame in between.
    private static let seekAhead = 2.0

    init(source: Asset) {
        self.source = source
    }

    /// The frame on screen at a moment of the recording: the last one at or
    /// before it, or the first frame while the camera was still warming up.
    func image(at requested: Double) -> CIImage? {
        guard requested.isFinite else { return nil }
        // Past the end the last frame stays, as the master's does.
        let time = source.duration > 0 ? min(requested, source.duration) : requested
        return lock.withLock { () -> CIImage? in
            if let cached = cachedFrame(at: time) { return CIImage(cvPixelBuffer: cached.pixels) }
            let newest = recent.last?.time ?? readerStart
            if reader == nil || time < (recent.first?.time ?? readerStart) || time - newest > Self.seekAhead {
                restart(at: time)
            }
            while true {
                if pending == nil { pending = nextFrame() }
                guard let next = pending, next.time <= time + 0.0005 else { break }
                remember(next)
                pending = nil
            }
            if let cached = cachedFrame(at: time) { return CIImage(cvPixelBuffer: cached.pixels) }
            // Before the first frame: the first one stands in.
            return (recent.first ?? pending).map { CIImage(cvPixelBuffer: $0.pixels) }
        }
    }

    /// A cached frame answers only when the cache provably holds the frame on
    /// screen at that moment: one at or before it, and the next one after it.
    private func cachedFrame(at time: Double) -> Frame? {
        guard let index = recent.lastIndex(where: { $0.time <= time + 0.0005 }) else { return nil }
        if index + 1 < recent.count { return recent[index] }
        if let pending, pending.time > time + 0.0005 { return recent[index] }
        if exhausted { return recent[index] }
        return nil
    }

    private func remember(_ frame: Frame) {
        recent.append(frame)
        if recent.count > Self.cacheSize { recent.removeFirst(recent.count - Self.cacheSize) }
    }

    private func restart(at time: Double) {
        reader?.cancelReading()
        reader = nil
        output = nil
        recent.removeAll()
        pending = nil
        exhausted = false
        // A little before the target, so the frame showing at that moment,
        // which began earlier, is decoded too.
        readerStart = max(0, time - 0.25)
        guard let reader = try? AVAssetReader(asset: source.asset) else {
            exhausted = true
            return
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            exhausted = true
            return
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: readerStart, preferredTimescale: 600),
                                       end: .positiveInfinity)
        guard reader.startReading() else {
            exhausted = true
            return
        }
        self.reader = reader
        self.output = output
    }

    private func nextFrame() -> Frame? {
        guard !exhausted, let output else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { continue }
            return Frame(time: time, pixels: pixels)
        }
        exhausted = true
        return nil
    }

    deinit {
        reader?.cancelReading()
    }
}
