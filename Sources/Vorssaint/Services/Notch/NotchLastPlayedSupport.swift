// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: the lock screen keeps a player even with nothing playing. The last
// song heard is remembered (its title, artist, cover, player and where it
// was), shown paused on the lock screen with its lyrics, and Play picks it
// up again, opening its player first if it has quit.

extension DefaultsKey {
    static let notchLockScreenRemembersMusic = "notchLockScreenRemembersMusic"
}

struct NotchLastPlayed: Codable, Equatable {
    var title: String
    var artist: String?
    var album: String?
    var bundleID: String?
    var duration: Double
    var elapsed: Double
    var savedAt: Date

    /// Where the song stands, as a paused reading the players' own views take.
    func playback(artwork: Data? = nil) -> NotchPlayback {
        NotchPlayback(track: RadialNowPlayingSnapshot(title: title, artist: artist, album: album,
                                                      artworkData: artwork, appBundleIdentifier: bundleID,
                                                      appPID: nil),
                      isPlaying: false, elapsed: min(max(0, elapsed), max(0, duration)), duration: max(0, duration),
                      rate: 1, sampledAt: savedAt, canSeek: false, hasPosition: duration > 0)
    }
}

enum NotchLastPlayedSupport {
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchLockScreenRemembersMusic: true]
    /// How often a playing song's place is written down.
    static let saveInterval: TimeInterval = 15

    /// Unset reads as off, so a suite without the app's registered values
    /// keeps upstream's lock screen.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.notchLockScreenRemembersMusic)
    }

    /// What to remember of a reading, or nil when it has no song to name.
    static func remembered(_ playback: NotchPlayback?, at now: Date) -> NotchLastPlayed? {
        guard let playback, let title = playback.track.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let duration = playback.duration.isFinite ? max(0, playback.duration) : 0
        let position = playback.position(at: now)
        return NotchLastPlayed(title: title, artist: playback.track.artist, album: playback.track.album,
                               bundleID: playback.track.appBundleIdentifier, duration: duration,
                               elapsed: position.isFinite ? position : 0, savedAt: now)
    }

    /// Written when the song or its playing changes, or its place has moved
    /// on long enough; never on every reading.
    static func needsSave(_ next: NotchLastPlayed, after previous: NotchLastPlayed?,
                          wasPlaying: Bool?, isPlaying: Bool) -> Bool {
        guard let previous else { return true }
        if previous.title != next.title || previous.artist != next.artist
            || previous.album != next.album || previous.bundleID != next.bundleID { return true }
        if wasPlaying != isPlaying { return true }
        return next.savedAt.timeIntervalSince(previous.savedAt) >= saveInterval
    }

    /// Whether a new song's cover must be written: only when the song changed.
    static func isNewSong(_ next: NotchLastPlayed, after previous: NotchLastPlayed?) -> Bool {
        previous.map { $0.title != next.title || $0.artist != next.artist || $0.album != next.album
            || $0.bundleID != next.bundleID } ?? true
    }

    static func decode(_ data: Data?) -> NotchLastPlayed? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let last = try? decoder.decode(NotchLastPlayed.self, from: data),
              !last.title.isEmpty, last.duration.isFinite, last.elapsed.isFinite else { return nil }
        return last
    }

    static func encode(_ last: NotchLastPlayed) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(last)
    }
}
