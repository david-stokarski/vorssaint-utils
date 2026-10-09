// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the closed island sings the line being sung, and a finished run's
/// cost leads its notice.
enum NotchSingAlongTests {
    static func run(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.singAlong")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.singAlong")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.singAlong") }
        suite.expect(!NotchCompactLyrics.isOn(in: defaults), "the closed island stays quiet by default")
        suite.expect(!NotchAgentCostFlash.isOn(in: defaults), "the cost does not flash by default")

        let lyrics = NotchLyrics(lines: [NotchLyricLine(time: 10, text: "First line"), NotchLyricLine(time: 20, text: "  "),
                                         NotchLyricLine(time: 30, text: "A much longer third line of the song")],
                                 plain: "", instrumental: false)
        suite.expect(NotchCompactLyrics.line(lyrics, at: 5, offset: 0) == NotchCompactLyrics.rest, "a rest before the first line")
        suite.expect(NotchCompactLyrics.line(lyrics, at: 12, offset: 0) == "First line", "the line being sung")
        suite.expect(NotchCompactLyrics.line(lyrics, at: 22, offset: 0) == NotchCompactLyrics.rest, "a rest through a break")
        suite.expect(NotchCompactLyrics.line(lyrics, at: 9.6, offset: -0.5) == "First line", "the offset moves a line earlier")

        let track = RadialNowPlayingSnapshot(title: "Song", artist: "Artist", album: nil,
                                             artworkData: nil, appBundleIdentifier: "org.example.player", appPID: 42)
        let playback = NotchPlayback(track: track, isPlaying: true, elapsed: 0, duration: 200, rate: 1,
                                     sampledAt: Date(timeIntervalSinceReferenceDate: 0), canSeek: false)
        suite.expect(NotchCompactLyrics.singable(lyrics, playback: playback) == lyrics, "synced lines are sung")
        suite.expect(NotchCompactLyrics.singable(NotchLyrics(lines: [], plain: "words", instrumental: false),
                                                 playback: playback) == nil, "plain lyrics are not")
        suite.expect(NotchCompactLyrics.singable(NotchLyrics(lines: lyrics.lines, plain: "", instrumental: true),
                                                 playback: playback) == nil, "an instrumental is not")
        var unplaced = playback
        unplaced.hasPosition = false
        suite.expect(NotchCompactLyrics.singable(lyrics, playback: unplaced) == nil, "a player without a position is not")

        let range = NotchCompactLyrics.capsuleWidthRange
        let width = NotchCompactLyrics.width(lyrics, in: range)
        suite.expect(range.contains(width) && width > range.lowerBound, "the line's room fits the longest line, within range")
        let short = NotchLyrics(lines: [NotchLyricLine(time: 0, text: "Hi")], plain: "", instrumental: false)
        suite.expect(NotchCompactLyrics.width(short, in: range) == range.lowerBound, "a short song keeps the least room")

        suite.expect(NotchDrawnCamera.width(in: defaults) == 0, "the drawn notch is automatic by default")
        defaults.set(9999.0, forKey: DefaultsKey.notchDrawnCameraWidth)
        suite.expect(NotchDrawnCamera.width(in: defaults) == CGFloat(NotchDrawnCamera.range.upperBound),
                     "a chosen notch width stays in range")
        suite.expect(NotchDisplayProfiles.keys.contains(DefaultsKey.notchDrawnCameraWidth), "each display keeps its own notch width")
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var automaticNotch = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, silhouette: .notch)
        var chosenNotch = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, silhouette: .notch, drawnCameraWidth: 300)
        suite.expect(chosenNotch.cameraWidth == 300, "a chosen width draws the notch that wide")
        automaticNotch.lyricRoom = 400
        chosenNotch.lyricRoom = 400
        suite.expect(automaticNotch.musicCameraGap == 400, "an automatic notch widens for a sung line")
        suite.expect(chosenNotch.musicCameraGap == 300, "a chosen width stays put, and the line scrolls")
        let notched = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 185, drawnCameraWidth: 300)
        suite.expect(notched.cameraWidth == 185, "a real camera keeps its own width")

        let cost = AgentFormat.cost(0.42)
        suite.expect(NotchAgentCostFlash.detail(duration: "3m", cost: 0.42, flashes: true) == "\(cost) · 3m",
                     "a flash leads with the cost")
        suite.expect(NotchAgentCostFlash.detail(duration: "3m", cost: 0.42, flashes: false) == "3m · \(cost)",
                     "otherwise the length leads")
        suite.expect(NotchAgentCostFlash.detail(duration: "3m", cost: 0, flashes: true) == "3m", "an unpriced run shows its length")
    }
}
