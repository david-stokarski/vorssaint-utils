// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Fork: remembers the last song for the lock screen (see
/// NotchLastPlayedSupport) and picks it up again on Play.
final class NotchLastPlayedStore: ObservableObject {
    static let shared = NotchLastPlayedStore()

    @Published private(set) var last: NotchLastPlayed?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkData: Data?
    /// Play was pressed and the player has not answered yet.
    @Published private(set) var resuming = false

    private var wasPlaying: Bool?
    private var resumeSubscription: AnyCancellable?
    private var resumeTimeout: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.vorssaint.notch.last-played", qos: .utility)

    private static var fileURL: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("LastPlayed.json")
    }

    private static var artworkURL: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("LastPlayedArtwork")
    }

    private init() {
        last = NotchLastPlayedSupport.decode(Self.fileURL.flatMap { try? Data(contentsOf: $0) })
        if last != nil, let data = Self.artworkURL.flatMap({ try? Data(contentsOf: $0) }) {
            artworkData = data
            artwork = NSImage(data: data)
        }
    }

    /// Every reading from the island's player passes through here.
    func note(_ playback: NotchPlayback?) {
        guard NotchLastPlayedSupport.isEnabled(), let playback,
              let next = NotchLastPlayedSupport.remembered(playback, at: Date()) else { return }
        let newSong = NotchLastPlayedSupport.isNewSong(next, after: last)
        let saves = NotchLastPlayedSupport.needsSave(next, after: last, wasPlaying: wasPlaying,
                                                     isPlaying: playback.isPlaying)
        wasPlaying = playback.isPlaying
        let cover = playback.track.artworkData
        let coverChanged = cover != nil && (newSong || artworkData == nil)
        guard saves || coverChanged else { return }
        last = next
        if newSong {
            artworkData = cover
            artwork = cover.flatMap(NSImage.init(data:))
        } else if coverChanged {
            artworkData = cover
            artwork = cover.flatMap(NSImage.init(data:))
        }
        let encoded = NotchLastPlayedSupport.encode(next)
        let coverToWrite = newSong || coverChanged ? cover : nil
        let clearsCover = newSong && cover == nil
        queue.async {
            guard let container = PrivateFileStore.containerURL,
                  PrivateFileStore.createDirectory(at: container) else { return }
            if let encoded, let url = Self.fileURL { PrivateFileStore.write(encoded, to: url) }
            if let coverToWrite, let url = Self.artworkURL {
                PrivateFileStore.write(coverToWrite, to: url)
            } else if clearsCover, let url = Self.artworkURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Starts the remembered song: its player is opened (hidden) if it has
    /// quit, then asked to play. A player that never reports is sent the
    /// keyboard's Play key, which macOS hands to the last app that played.
    func resume() {
        guard let last, !resuming else { return }
        resuming = true
        let music = NotchMusicService.shared
        music.start()
        var launched = false
        if let bundleID = last.bundleID,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched = true
        }
        resumeSubscription = music.$playback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playback in
                guard let self, let playback,
                      last.bundleID == nil || playback.track.appBundleIdentifier == last.bundleID else { return }
                if !playback.isPlaying, !music.send(.toggle, context: playback.commandContext) {
                    Self.postPlayKey()
                }
                self.finishResuming()
            }
        // A player that has just opened says nothing until it plays, so it
        // gets the Play key once it has had a moment to start.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.resuming else { return }
            if music.playback?.isPlaying != true { Self.postPlayKey() }
            self.finishResuming()
        }
        resumeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (launched ? 2.5 : 1.2), execute: timeout)
    }

    private func finishResuming() {
        resumeSubscription = nil
        resumeTimeout?.cancel()
        resumeTimeout = nil
        resuming = false
    }

    /// The keyboard's Play/Pause key, as the media keys send it.
    private static func postPlayKey() {
        let playKey = 16 // NX_KEYTYPE_PLAY
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (playKey << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
