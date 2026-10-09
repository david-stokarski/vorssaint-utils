// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: the island's size belongs to the display it is on. Each display keeps
// its own island size (the size choice, the custom width and height, the
// closed island's extra size and the camera and capsule fits); everything
// else, the glass, colours and behaviour, stays shared. Settings edit the
// display the island is on, and moving to another display swaps its sizes in.
//
// The sizes stay in their usual preferences, so every reader of them works
// unchanged: a display's sizes are saved away as it is left and written back
// as it is reached. A display seen for the first time starts from the saved
// sizes of its kind (built-in or external), otherwise from what is in place.

extension DefaultsKey {
    static let notchDisplayProfilesEnabled = "notchDisplayProfilesEnabled"
    /// [display: [preference: value]].
    static let notchDisplayProfiles = "notchDisplayProfiles"
    /// The display whose sizes are in place now.
    static let notchDisplayProfileActive = "notchDisplayProfileActive"
}

enum NotchDisplayProfiles {
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchDisplayProfilesEnabled: true]

    /// The preferences that make up a display's island size.
    static let keys = [
        DefaultsKey.notchSize, DefaultsKey.notchCustomWidth, DefaultsKey.notchCustomHeight,
        DefaultsKey.notchClosedExtraWidth, DefaultsKey.notchClosedExtraHeight,
        DefaultsKey.notchCameraFitWidth, DefaultsKey.notchCameraFitHeight,
        DefaultsKey.notchCapsuleFitWidth, DefaultsKey.notchCapsuleFitHeight, DefaultsKey.notchCapsuleFitDrop,
        DefaultsKey.notchDrawnCameraWidth,
    ]

    /// The starting sizes for a kind of display, used once per new display.
    static func kindKey(builtIn: Bool) -> String { builtIn ? "kind:built-in" : "kind:external" }

    /// Unset reads as off, so a suite without the app's registered values
    /// keeps one size for every display.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.notchDisplayProfilesEnabled)
    }

    static func profiles(in defaults: UserDefaults) -> [String: [String: Any]] {
        (defaults.dictionary(forKey: DefaultsKey.notchDisplayProfiles) as? [String: [String: Any]]) ?? [:]
    }

    /// The sizes in place now.
    static func current(in defaults: UserDefaults) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { values[key] = value } }
        return values
    }

    /// Makes `display` the one whose sizes are in place. Returns whether the
    /// sizes in place changed, so the island can measure itself again.
    @discardableResult
    static func activate(_ display: String, builtIn: Bool, in defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(in: defaults), !display.isEmpty else { return false }
        var all = profiles(in: defaults)
        let active = defaults.string(forKey: DefaultsKey.notchDisplayProfileActive)
        let inPlace = current(in: defaults)
        if active == display {
            // Still here: whatever Settings changed belongs to this display.
            guard !same(all[display], inPlace) else { return false }
            all[display] = inPlace
            defaults.set(all, forKey: DefaultsKey.notchDisplayProfiles)
            return false
        }
        // Leaving: the sizes in place go with the display they were made for.
        if let active, !active.isEmpty { all[active] = inPlace }
        let incoming = all[display] ?? all[kindKey(builtIn: builtIn)]
        all[display] = incoming ?? inPlace
        defaults.set(all, forKey: DefaultsKey.notchDisplayProfiles)
        defaults.set(display, forKey: DefaultsKey.notchDisplayProfileActive)
        guard let incoming, !same(incoming, inPlace) else { return false }
        for key in keys {
            if let value = incoming[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        return true
    }

    /// Records starting sizes for a kind of display that has none of its own yet.
    static func seed(_ values: [String: Any], builtIn: Bool, in defaults: UserDefaults = .standard) {
        var all = profiles(in: defaults)
        all[kindKey(builtIn: builtIn)] = values.filter { keys.contains($0.key) }
        defaults.set(all, forKey: DefaultsKey.notchDisplayProfiles)
    }

    private static func same(_ a: [String: Any]?, _ b: [String: Any]) -> Bool {
        guard let a else { return false }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }
}
