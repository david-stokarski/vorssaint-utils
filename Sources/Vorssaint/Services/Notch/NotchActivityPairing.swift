// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

// Fork: when two activities run at once, the closed island shows both, one
// each side, instead of offering a chooser on hover. Music shares the strip
// with working agents (agents' reading on the right, the song on the left)
// the way it already could with a timer or an event.

extension DefaultsKey {
    static let notchPairActivities = "notchPairActivities"
}

enum NotchActivityPairing {
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchPairActivities: true]

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.notchPairActivities) as? Bool ?? true
    }

    /// The pair shown without asking: the first one the activity in view
    /// supports. Only an explicit choice that already includes a companion
    /// wins over it.
    static func automaticCompanion(for activity: NotchCompactActivity,
                                   companions: [NotchCompactActivity]) -> NotchCompactActivity? {
        companions.first
    }
}

extension NotchCapsuleLayout {
    /// Between the song's end of the capsule and the agents' end.
    static let pairGap: CGFloat = 16

    /// Working agents beside the playing track: the cover and bars at the
    /// leading end, the agents' marks and reading at the trailing end.
    static func agentMusicSurface(reading: String, working: Int, geometry: NotchGeometry) -> CGSize {
        let music = artworkSide(geometry) + spacing + barsWidth
        let agents = agentMarksWidth(working: working) + spacing
            + width(NotchAgentSupport.readingShape(reading), font: readingFont)
        return surface(content: music + pairGap + agents, leading: artworkInset(geometry),
                       maximum: Maximum.activity + 60, geometry: geometry)
    }
}
