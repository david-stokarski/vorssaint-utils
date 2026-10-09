// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

// Fork: once a new song's notice has named it, the closed island sings
// along. The line being sung takes the middle of the music strip, and keeps
// its place beside working agents when the two share the island. A song
// without synced lyrics keeps the strip as it was.

extension DefaultsKey {
    static let notchCompactLyrics = "notchCompactLyrics"
}

enum NotchCompactLyrics {
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchCompactLyrics: false]

    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Shown between lines, before the first and through the breaks.
    static let rest = "♪"
    /// The line's room: as wide as the song's longest line, within these, so
    /// the island keeps one width for the whole song instead of one per line.
    static let capsuleWidthRange: ClosedRange<CGFloat> = 80...240
    static let wingWidthRange: ClosedRange<CGFloat> = 60...190

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        NotchLyricsSupport.isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchCompactLyrics)
    }

    /// Synced lines worth singing in the closed island.
    static func singable(_ lyrics: NotchLyrics?, playback: NotchPlayback?) -> NotchLyrics? {
        guard let lyrics, let playback, playback.hasPosition, !lyrics.instrumental, !lyrics.lines.isEmpty,
              lyrics.lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return lyrics
    }

    static func line(_ lyrics: NotchLyrics, at position: Double, offset: Double) -> String {
        guard let index = lyrics.activeIndex(at: position, offset: offset) else { return rest }
        let text = lyrics.lines[index].text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? rest : text
    }

    /// Measured once per song; the island lays itself out far more often.
    private static var measured: (lyrics: NotchLyrics, width: CGFloat)?

    static func widestLine(_ lyrics: NotchLyrics) -> CGFloat {
        if let measured, measured.lyrics == lyrics { return measured.width }
        let width = lyrics.lines.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }
            .max().map { $0.rounded(.up) + 2 } ?? 0
        measured = (lyrics, width)
        return width
    }

    static func width(_ lyrics: NotchLyrics, in range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, widestLine(lyrics)))
    }
}

extension NotchCapsuleLayout {
    /// The cover at the leading end, the line in the middle, the bars at the other end.
    static func lyricMusicSurface(lineWidth: CGFloat, geometry: NotchGeometry) -> CGSize {
        let content = artworkSide(geometry) + endPadding + lineWidth + endPadding + barsWidth
        return surface(content: content, leading: artworkInset(geometry),
                       maximum: Maximum.music + NotchCompactLyrics.capsuleWidthRange.upperBound, geometry: geometry)
    }

    /// Working agents beside the song being sung: cover, bars and line at
    /// the leading end, the agents' marks and reading at the trailing end.
    static func agentLyricSurface(reading: String, working: Int, lineWidth: CGFloat, geometry: NotchGeometry) -> CGSize {
        let music = artworkSide(geometry) + spacing + barsWidth + groupSpacing + lineWidth
        let agents = agentMarksWidth(working: working) + spacing
            + width(NotchAgentSupport.readingShape(reading), font: readingFont)
        return surface(content: music + pairGap + agents, leading: artworkInset(geometry),
                       maximum: Maximum.activity + 60 + NotchCompactLyrics.capsuleWidthRange.upperBound,
                       geometry: geometry)
    }
}
