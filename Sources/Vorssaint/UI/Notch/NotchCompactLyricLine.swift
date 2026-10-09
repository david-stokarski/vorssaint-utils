// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the line being sung, in the closed island. It changes only at the
/// song's line boundaries, fading from one line to the next.
struct NotchCompactLyricLine: View {
    let lyrics: NotchLyrics
    let playback: NotchPlayback
    var size: CGFloat = NotchCompactLyrics.font.pointSize
    var alignment: Alignment = .center
    @ObservedObject private var service = NotchLyricsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.explicit(lyrics.changeDates(for: playback, offset: service.offset, from: .now))) { context in
            let line = NotchCompactLyrics.line(lyrics, at: playback.position(at: context.date), offset: service.offset)
            ZStack(alignment: alignment) {
                Text(line)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(line == NotchCompactLyrics.rest ? 0.55 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .id(line)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: line)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
