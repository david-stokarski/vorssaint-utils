// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
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

// Fork: a lyric line too long for the island scrolls through instead of
// ending in "…". It waits a beat, then glides to its end in step with the
// time the line has left, so the last words are on screen while they are sung.

enum NotchLyricMarquee {
    /// Points per second when nothing says how long the line lasts.
    static let naturalSpeed: CGFloat = 40
    static let fastestSpeed: CGFloat = 140
    static let slowestSpeed: CGFloat = 14
    static let lead: Double = 0.5

    /// The pause before the line starts moving.
    static func delay(remaining: Double?) -> Double {
        guard let remaining, remaining.isFinite, remaining > 0 else { return lead }
        return min(lead, remaining * 0.15)
    }

    /// How long the glide to the line's end takes, or nil when it fits.
    static func duration(overflow: CGFloat, remaining: Double?) -> Double? {
        guard overflow.isFinite, overflow > 0.5 else { return nil }
        let fastest = Double(overflow / fastestSpeed)
        let slowest = Double(overflow / slowestSpeed)
        guard let remaining, remaining.isFinite, remaining > 0 else {
            return Double(overflow / naturalSpeed)
        }
        // Finish with a fifth of the line still to go, so the end is read.
        let available = remaining * 0.8 - delay(remaining: remaining)
        return min(max(available, fastest), slowest)
    }

    /// Seconds until the line after `index` is due, at the playback rate.
    static func remaining(after index: Int, times: [Double], position: Double,
                          offset: Double, rate: Double) -> Double? {
        let next = index + 1
        guard times.indices.contains(next), position.isFinite, offset.isFinite,
              rate.isFinite, rate > 0 else { return nil }
        let left = (times[next] + offset - position) / rate
        return left > 0 ? left : nil
    }
}
