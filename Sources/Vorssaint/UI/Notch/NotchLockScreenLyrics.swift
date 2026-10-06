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

    var body: some View {
        // Always there, even with nothing to show, so it asks for the lyrics.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
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
                            .id("current-\(active ?? -1)")
                        Text(next)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                            .id("next-\(active ?? -1)")
                    }
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: active)
                }
                .frame(height: 66, alignment: .center)
                .padding(.top, 12)
            }
        }
        .onAppear { load() }
        .onChange(of: NotchMusicIdentity(playback)) { load() }
        // The player tries several layouts, so one leaving is no reason to
        // let the lyrics go; the lock screen lets them go as it closes.
    }

    private func load() {
        NotchLyricsService.shared.update(playback: playback, visible: true)
    }
}
