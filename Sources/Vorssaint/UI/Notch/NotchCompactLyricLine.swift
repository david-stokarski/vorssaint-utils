// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the line being sung, in the closed island. It changes only at the
/// song's line boundaries, fading from one line to the next, and a line too
/// long for its room scrolls to its end the way the player's lyrics do,
/// paced to finish before the next line.
struct NotchCompactLyricLine: View {
    let lyrics: NotchLyrics
    let playback: NotchPlayback
    var size: CGFloat = NotchCompactLyrics.font.pointSize
    var alignment: Alignment = .center
    @ObservedObject private var service = NotchLyricsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.explicit(lyrics.changeDates(for: playback, offset: service.offset, from: .now))) { context in
            let position = playback.position(at: context.date)
            let index = lyrics.activeIndex(at: position, offset: service.offset)
            let line = NotchCompactLyrics.line(lyrics, at: position, offset: service.offset)
            ZStack(alignment: alignment) {
                NotchMarqueeText(text: line,
                                 remaining: index.flatMap {
                                     NotchLyricMarquee.remaining(after: $0, times: lyrics.lines.map(\.time),
                                                                 position: position, offset: service.offset,
                                                                 rate: playback.isPlaying ? playback.rate : 0)
                                 },
                                 alignment: alignment)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(line == NotchCompactLyrics.rest ? 0.55 : 0.95))
                    .id(index ?? -1)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: index)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
