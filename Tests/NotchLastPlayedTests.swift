// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the last song for the lock screen is remembered where it stood,
/// written only when something worth keeping changed, and read back safely.
enum NotchLastPlayedTests {
    static func run(_ suite: TestSuite) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ title: String?, playing: Bool, elapsed: Double = 30, at date: Date = start) -> NotchPlayback {
            NotchPlayback(track: RadialNowPlayingSnapshot(title: title, artist: "Artist", album: "Album",
                                                          artworkData: nil, appBundleIdentifier: "com.spotify.client",
                                                          appPID: 42),
                          isPlaying: playing, elapsed: elapsed, duration: 200, rate: 1, sampledAt: date, canSeek: true)
        }

        suite.expect(NotchLastPlayedSupport.remembered(nil, at: start) == nil
                        && NotchLastPlayedSupport.remembered(reading("  ", playing: true), at: start) == nil,
                     "nothing, or a song without a title, is not remembered")
        let later = start.addingTimeInterval(10)
        let kept = NotchLastPlayedSupport.remembered(reading("Song", playing: true), at: later)!
        suite.expect(kept.elapsed == 40 && kept.bundleID == "com.spotify.client" && kept.duration == 200,
                     "a playing song is remembered where it has got to, with its player")

        let shown = kept.playback()
        suite.expect(!shown.isPlaying && shown.commandContext == nil && shown.position(at: later.addingTimeInterval(60)) == 40
                        && shown.track.title == "Song",
                     "the remembered song shows paused where it stopped")

        suite.expect(NotchLastPlayedSupport.needsSave(kept, after: nil, wasPlaying: nil, isPlaying: true),
                     "the first song is written")
        var moved = kept
        moved.savedAt = later.addingTimeInterval(5)
        suite.expect(!NotchLastPlayedSupport.needsSave(moved, after: kept, wasPlaying: true, isPlaying: true),
                     "a few seconds on, nothing is written")
        suite.expect(NotchLastPlayedSupport.needsSave(moved, after: kept, wasPlaying: true, isPlaying: false),
                     "pausing is written")
        moved.savedAt = later.addingTimeInterval(NotchLastPlayedSupport.saveInterval)
        suite.expect(NotchLastPlayedSupport.needsSave(moved, after: kept, wasPlaying: true, isPlaying: true),
                     "the place is written now and then while playing")
        var other = kept
        other.title = "Next song"
        suite.expect(NotchLastPlayedSupport.needsSave(other, after: kept, wasPlaying: true, isPlaying: true)
                        && NotchLastPlayedSupport.isNewSong(other, after: kept)
                        && !NotchLastPlayedSupport.isNewSong(moved, after: kept),
                     "a new song is written with its cover")

        let data = NotchLastPlayedSupport.encode(kept)
        suite.expect(NotchLastPlayedSupport.decode(data) == kept, "the song round-trips through disk")
        suite.expect(NotchLastPlayedSupport.decode(Data("nonsense".utf8)) == nil && NotchLastPlayedSupport.decode(nil) == nil,
                     "a damaged file is ignored")

        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.lastPlayed")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.lastPlayed")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.lastPlayed") }
        suite.expect(!NotchLastPlayedSupport.isEnabled(in: defaults), "unset keeps upstream's lock screen")
    }
}
