// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import QuartzCore

// Fork: the keys a recording saw, for KeyCastr-style captions. What is kept is
// decided at the moment of the press: in shortcuts-only mode a plain typed
// character never reaches the track, and nothing at all is kept while macOS
// Secure Event Input is on, which is what a password field turns on.

struct RecorderKeystrokeTrack: Codable, Equatable {
    /// What the recording was allowed to keep. The editor can show less than
    /// this, never more.
    var capture: RecorderKeystrokeCapture = .shortcuts
    var strokes: [RecorderKeystroke] = []

    var isEmpty: Bool { strokes.isEmpty }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(_ data: Data?) -> RecorderKeystrokeTrack {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}

final class RecorderKeystrokeSampler {
    private let pauseClock: RecorderPauseClock
    private let capture: RecorderKeystrokeCapture
    private let lock = NSLock()
    private var strokes: [RecorderKeystroke] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(pauseClock: RecorderPauseClock, capture: RecorderKeystrokeCapture) {
        self.pauseClock = pauseClock
        self.capture = capture
    }

    /// Global key monitors are delivered only with Accessibility, which the
    /// recorder already requires for its typing timing.
    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func stop() -> RecorderKeystrokeTrack {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        return lock.withLock {
            let track = RecorderKeystrokeTrack(capture: capture, strokes: strokes)
            strokes.removeAll()
            return track
        }
    }

    private func record(_ event: NSEvent) {
        // Checked on every press, not once: a password field can take secure
        // input at any moment of a recording.
        guard !IsSecureEventInputEnabled(),
              let time = pauseClock.eventTime(CACurrentMediaTime())
        else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: RecorderKeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // The key cap, not what a modifier turned it into: ⌘⇧4 reads "4".
        let unmodified = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        let typed = capture == .all ? event.characters : nil
        guard let stroke = RecorderKeyChord.stroke(time: time,
                                                   keyCode: event.keyCode,
                                                   modifiers: modifiers,
                                                   unmodifiedCharacters: unmodified,
                                                   characters: typed,
                                                   capture: capture)
        else { return }
        // A held key repeats its shortcut, which is the person holding an
        // arrow; only the first press is a caption.
        guard !event.isARepeat || stroke.kind != .shortcut else { return }
        lock.withLock { strokes.append(stroke) }
    }

    deinit {
        _ = stop()
    }
}
