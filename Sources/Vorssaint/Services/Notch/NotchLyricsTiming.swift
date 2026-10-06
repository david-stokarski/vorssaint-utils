// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: a standing lyrics offset. Every song starts from it, and the
// island's per-song − / + buttons nudge on top. Negative shows each line
// earlier, positive later.

extension DefaultsKey {
    /// Seconds; negative moves lines earlier.
    static let notchLyricsDefaultOffset = "notchLyricsDefaultOffset"
}

enum NotchLyricsTiming {
    static let range: ClosedRange<Double> = -5...5
    static let step = 0.05
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchLyricsDefaultOffset: 0.0]

    static func defaultOffset(in defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.double(forKey: DefaultsKey.notchLyricsDefaultOffset))
    }

    /// Within range and on the slider's step; anything unreadable is none.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let stepped = (min(max(value, range.lowerBound), range.upperBound) / step).rounded() * step
        return (stepped * 100).rounded() / 100
    }

    /// The song's own nudge on top of the standing offset.
    static func effective(song: Double, standing: Double) -> Double {
        let total = song + standing
        return total.isFinite ? total : 0
    }
}
