// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

// Fork: once a new song's notice has named it, the floating capsule sings
// along. The line being sung takes the capsule's middle, alone or with
// working agents just past it. A song without synced lyrics keeps the strip
// as it was.

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

    /// Air between the line and the wings of a drawn camera's gap.
    static let gapInset: CGFloat = 12

    /// The room the line takes in a drawn camera's gap.
    static func gapRoom(_ lyrics: NotchLyrics) -> CGFloat {
        width(lyrics, in: capsuleWidthRange) + gapInset * 2
    }
}

extension NotchCapsuleLayout {
    // A floating capsule is laid out like the island around a camera: the
    // line sits in the middle, where a camera would be, between two wings of
    // one width, so it stays at the display's centre. A hanging island
    // without a camera sings in its drawn camera's gap instead; beside a real
    // camera the middle is hidden, so it shows no line.

    /// Between the line's room and what stands beside it.
    static let lyricGap: CGFloat = 10

    /// The cover at the leading end, or the bars at the trailing end.
    static func lyricMusicWing(geometry: NotchGeometry) -> CGFloat {
        max(artworkInset(geometry) + artworkSide(geometry), barsWidth + endPadding) + lyricGap
    }

    /// The cover and bars at the leading end, or the agents just past the line.
    static func lyricAgentWing(reading: String, working: Int, geometry: NotchGeometry) -> CGFloat {
        let music = artworkInset(geometry) + artworkSide(geometry) + spacing + barsWidth
        let agents = agentMarksWidth(working: working) + spacing
            + width(NotchAgentSupport.readingShape(reading), font: readingFont) + endPadding
        return max(music, agents) + lyricGap
    }

    static func lyricMusicSurface(lineWidth: CGFloat, geometry: NotchGeometry) -> CGSize {
        surface(content: lyricMusicWing(geometry: geometry) * 2 + lineWidth, leading: 0, trailing: 0,
                maximum: Maximum.music + NotchCompactLyrics.capsuleWidthRange.upperBound, geometry: geometry)
    }

    static func agentLyricSurface(reading: String, working: Int, lineWidth: CGFloat, geometry: NotchGeometry) -> CGSize {
        let wing = lyricAgentWing(reading: reading, working: working, geometry: geometry)
        return surface(content: wing * 2 + lineWidth, leading: 0, trailing: 0,
                       maximum: Maximum.activity + 60 + NotchCompactLyrics.capsuleWidthRange.upperBound,
                       geometry: geometry)
    }
}
