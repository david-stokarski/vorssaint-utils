// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: each display keeps its own island size, swapped in as the island
/// moves, while everything else stays shared.
enum NotchDisplayProfilesTests {
    static func run(_ suite: TestSuite) {
        let name = "com.vorssaint.tests.displayProfiles"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(600.0, forKey: DefaultsKey.notchCustomWidth)
        defaults.set(260.0, forKey: DefaultsKey.notchCustomHeight)
        defaults.set("custom", forKey: DefaultsKey.notchSize)
        defaults.set(true, forKey: DefaultsKey.notchOutlineEnabled)
        suite.expect(!NotchDisplayProfiles.activate("LG", builtIn: false, in: defaults)
                        && defaults.string(forKey: DefaultsKey.notchDisplayProfileActive) == nil,
                     "off unless switched on")
        defaults.set(true, forKey: DefaultsKey.notchDisplayProfilesEnabled)

        suite.expect(!NotchDisplayProfiles.activate("LG", builtIn: false, in: defaults)
                        && defaults.double(forKey: DefaultsKey.notchCustomHeight) == 260,
                     "the first display keeps the sizes in place")

        // A new built-in display starts from its kind's sizes.
        NotchDisplayProfiles.seed([DefaultsKey.notchSize: "custom", DefaultsKey.notchCustomWidth: 600.0,
                                   DefaultsKey.notchCustomHeight: 300.0], builtIn: true, in: defaults)
        suite.expect(NotchDisplayProfiles.activate("MAC", builtIn: true, in: defaults)
                        && defaults.double(forKey: DefaultsKey.notchCustomHeight) == 300,
                     "moving to a new display swaps in its kind's sizes")
        suite.expect(defaults.bool(forKey: DefaultsKey.notchOutlineEnabled), "other preferences are shared")

        defaults.set(320.0, forKey: DefaultsKey.notchCustomHeight)
        _ = NotchDisplayProfiles.activate("MAC", builtIn: true, in: defaults)
        suite.expect(NotchDisplayProfiles.profiles(in: defaults)["MAC"]?[DefaultsKey.notchCustomHeight] as? Double == 320,
                     "a change made on a display is kept for it")

        suite.expect(NotchDisplayProfiles.activate("LG", builtIn: false, in: defaults)
                        && defaults.double(forKey: DefaultsKey.notchCustomHeight) == 260,
                     "going back brings the first display's sizes back")
        suite.expect(NotchDisplayProfiles.activate("MAC", builtIn: true, in: defaults)
                        && defaults.double(forKey: DefaultsKey.notchCustomHeight) == 320,
                     "and the second display's again")

        defaults.set(10.0, forKey: DefaultsKey.notchClosedExtraWidth)
        _ = NotchDisplayProfiles.activate("MAC", builtIn: true, in: defaults)
        _ = NotchDisplayProfiles.activate("LG", builtIn: false, in: defaults)
        suite.expect(defaults.object(forKey: DefaultsKey.notchClosedExtraWidth) == nil,
                     "a size one display never set is cleared on the other")
    }
}
