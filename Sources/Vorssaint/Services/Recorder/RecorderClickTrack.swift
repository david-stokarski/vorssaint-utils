// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore

// Fork: the presses a recording saw, with the button and where it landed, for
// the editor's click highlights. The pointer track already keeps press times
// for its zooms; this one keeps what a highlight needs and nothing else.

struct RecorderClickEvent: Codable, Equatable {
    enum Button: String, Codable {
        case left, right, other
    }

    var time: Double
    /// Normalized to the recorded area with a top-left origin, the same space
    /// the pointer track uses, so a crop or export size never moves it.
    var x: Double
    var y: Double
    var button: Button
    var isDown: Bool
}

struct RecorderClickTrack: Codable, Equatable {
    var events: [RecorderClickEvent] = []
    /// Pixels per point of the recorded display, so a highlight sized in
    /// points lands at the size it would have had on screen.
    var displayScale: Double = 2

    var isEmpty: Bool { events.isEmpty }

    /// Presses only, in order, ready for the renderer's binary search.
    var presses: [RecorderClickEvent] {
        events.filter { $0.isDown && $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(_ data: Data?) -> RecorderClickTrack {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}

/// A mouse-only global monitor, which needs no permission. It exists only
/// while a recording runs.
final class RecorderClickSampler {
    private let region: RecorderSupport.Region
    private let displayBounds: CGRect
    private let pauseClock: RecorderPauseClock
    private let lock = NSLock()
    private var events: [RecorderClickEvent] = []
    private var globalMonitor: Any?

    init(region: RecorderSupport.Region, pauseClock: RecorderPauseClock) {
        self.region = region
        self.pauseClock = pauseClock
        displayBounds = CGDisplayBounds(region.displayID)
    }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp]
        // Global only, as the pointer sampler's: a press on the recorder's
        // own controls (stop, pause) is not part of what was recorded.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
        }
    }

    func stop() -> RecorderClickTrack {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        return lock.withLock {
            let track = RecorderClickTrack(events: events,
                                           displayScale: region.scale > 0 ? Double(region.scale) : 2)
            events.removeAll()
            return track
        }
    }

    private func record(_ event: NSEvent) {
        guard let time = pauseClock.eventTime(CACurrentMediaTime()),
              let location = event.cgEvent?.location ?? CGEvent(source: nil)?.location
        else { return }
        let scale = region.scale > 0 ? region.scale : 1
        let width = region.pixelRect.width / scale
        let height = region.pixelRect.height / scale
        guard width > 0, height > 0 else { return }
        let x = (location.x - displayBounds.origin.x - region.pixelRect.origin.x / scale) / width
        let y = (location.y - displayBounds.origin.y - region.pixelRect.origin.y / scale) / height
        let button: RecorderClickEvent.Button
        switch event.type {
        case .leftMouseDown, .leftMouseUp: button = .left
        case .rightMouseDown, .rightMouseUp: button = .right
        default: button = .other
        }
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
            || event.type == .otherMouseDown
        lock.withLock {
            events.append(RecorderClickEvent(time: time, x: Double(x), y: Double(y),
                                             button: button, isDown: isDown))
        }
    }

    deinit {
        _ = stop()
    }
}
