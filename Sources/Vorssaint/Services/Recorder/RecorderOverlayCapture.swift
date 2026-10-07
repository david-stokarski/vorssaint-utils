// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit

// Fork: everything one recording captures for its overlays, in one place, so
// the recorder session only gains a handful of calls. The samplers, the camera
// and its live bubble are created for this recording and gone after it.

/// Its mutable state (the bubble) is only touched on the main thread; the
/// samplers and the camera guard their own.
final class RecorderOverlayCapture: @unchecked Sendable {
    let options: RecorderOverlayCaptureOptions
    private let take: RecorderTakeStore.Take
    private let region: RecorderSupport.Region
    private let clicks: RecorderClickSampler?
    private let keys: RecorderKeystrokeSampler?
    private let camera: RecorderCameraCapture?
    private var bubble: RecorderCameraBubbleWindow?

    struct Tracks {
        var clicks: RecorderClickTrack?
        var keystrokes: RecorderKeystrokeTrack?
        var cameraWritten = false
    }

    init(take: RecorderTakeStore.Take,
         region: RecorderSupport.Region,
         pauseClock: RecorderPauseClock,
         options: RecorderOverlayCaptureOptions = .current()) {
        self.take = take
        self.region = region
        self.options = options
        clicks = options.clicks ? RecorderClickSampler(region: region, pauseClock: pauseClock) : nil
        keys = options.keystrokes
            ? RecorderKeystrokeSampler(pauseClock: pauseClock, capture: options.keystrokeCapture)
            : nil
        // Asked for before the countdown; a camera still not allowed here is
        // simply left out rather than prompting mid-recording.
        camera = options.camera && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            ? RecorderCameraCapture(url: take.cameraURL, pauseClock: pauseClock)
            : nil
    }

    /// Main thread, before the stream starts: the live bubble has to exist by
    /// then so the capture filter can name it and leave it out.
    func prepare() {
        guard let camera, bubble == nil else { return }
        let bubble = RecorderCameraBubbleWindow(session: camera.session, region: region)
        bubble.show()
        self.bubble = bubble
        camera.start { [weak self] started in
            DispatchQueue.main.async {
                guard let self else { return }
                if started {
                    self.bubble?.cameraDidStart()
                } else {
                    self.bubble?.hide()
                    self.bubble = nil
                    QuickToolHUD.show(icon: "video.slash", message: "Camera unavailable")
                }
            }
        }
    }

    var excludedWindowNumbers: [Int] {
        bubble?.windowNumber.map { [$0] } ?? []
    }

    /// Main thread, with the pointer and typing samplers.
    func startSamplers() {
        clicks?.start()
        keys?.start()
    }

    /// Stops everything at the moment the recording stopped and hands back
    /// what was collected. Nothing is written yet.
    func stop(at end: CMTime) async -> Tracks {
        let (clickTrack, keyTrack) = await MainActor.run { () -> (RecorderClickTrack?, RecorderKeystrokeTrack?) in
            bubble?.hide()
            bubble = nil
            return (clicks?.stop(), keys?.stop())
        }
        let cameraWritten = await camera?.stop(at: end) ?? false
        return Tracks(clicks: clickTrack, keystrokes: keyTrack, cameraWritten: cameraWritten)
    }

    /// Writes the small tracks beside the master once it is known to be good.
    func write(_ tracks: Tracks) {
        if let track = tracks.clicks, !track.isEmpty, let data = track.encoded() {
            try? data.write(to: take.clicksURL, options: .atomic)
        }
        if let track = tracks.keystrokes, !track.isEmpty, let data = track.encoded() {
            try? data.write(to: take.keystrokesURL, options: .atomic)
        }
    }

    /// A recording that never started: nothing is kept and nothing stays up.
    func discard() async {
        _ = await stop(at: CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: take.cameraURL)
    }
}

/// The camera permission, asked before the countdown the way the microphone
/// is, so the prompt never lands in the middle of a recording.
enum RecorderCameraPermission {
    /// True when a prompt was started; `completion` then runs on the main
    /// thread once the person answered.
    static func requestIfNeeded(wanted: Bool, completion: @escaping () -> Void) -> Bool {
        guard wanted, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return false }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                Permissions.shared.refresh()
                completion()
            }
        }
        return true
    }
}
