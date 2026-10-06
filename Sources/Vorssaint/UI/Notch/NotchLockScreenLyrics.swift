// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the song's lyrics on the lock screen's player, the line being sung
/// over the one coming next. A remembered song shows the line it stopped on.
/// Nothing shows for a song without synced lyrics.
struct NotchLockScreenLyrics: View {
    let playback: NotchPlayback
    @ObservedObject private var service = NotchLyricsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two lines of the line being sung and one of the next.
    static let height: CGFloat = 62

    var body: some View {
        // Always there and always one height, lyrics or not, loading or
        // not, so the player never changes size under them.
        ZStack {
            if NotchLyricsSupport.isEnabled(), let lyrics = service.lyrics, !lyrics.instrumental,
               !lyrics.lines.isEmpty, playback.hasPosition {
                TimelineView(.explicit(lyrics.changeDates(for: playback, offset: service.offset, from: .now))) { context in
                    let active = lyrics.activeIndex(at: playback.position(at: context.date), offset: service.offset)
                    let current = active.map { lyrics.lines[$0].text } ?? "♪"
                    let next = lyrics.lines.indices.contains((active ?? -1) + 1)
                        ? lyrics.lines[(active ?? -1) + 1].text : ""
                    VStack(spacing: 4) {
                        Text(current.isEmpty ? "♪" : current)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(2)
                            .id("current-\(active ?? -1)")
                        Text(next)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                            .id("next-\(active ?? -1)")
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: active)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipped()
        .padding(.top, 12)
        .onAppear { load() }
        .onChange(of: NotchMusicIdentity(playback)) { load() }
        // The player tries several layouts, so one leaving is no reason to
        // let the lyrics go; the lock screen lets them go as it closes.
    }

    private func load() {
        NotchLyricsService.shared.update(playback: playback, visible: true)
    }
}
