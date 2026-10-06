// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the standing lyrics offset stays in range, on its step, and adds to
/// each song's own nudge.
enum NotchLyricsTimingTests {
    static func run(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.lyricsTiming")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.lyricsTiming")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.lyricsTiming") }
        suite.expect(NotchLyricsTiming.defaultOffset(in: defaults) == 0, "no offset by default")
        defaults.set(-0.4, forKey: DefaultsKey.notchLyricsDefaultOffset)
        suite.expect(NotchLyricsTiming.defaultOffset(in: defaults) == -0.4, "a stored offset reads back")
        defaults.set(99.0, forKey: DefaultsKey.notchLyricsDefaultOffset)
        suite.expect(NotchLyricsTiming.defaultOffset(in: defaults) == 5, "a stored offset stays in range")
        suite.expect(NotchLyricsTiming.clamped(0.33) == 0.35 && NotchLyricsTiming.clamped(.nan) == 0,
                     "offsets land on the step and nonsense is none")
        suite.expect(NotchLyricsTiming.effective(song: 0.25, standing: -0.5) == -0.25,
                     "a song's nudge adds to the standing offset")

        let lyrics = NotchLyrics(lines: [NotchLyricLine(time: 10, text: "a"), NotchLyricLine(time: 20, text: "b")],
                                 plain: "", instrumental: false)
        suite.expect(lyrics.activeIndex(at: 9.6, offset: NotchLyricsTiming.effective(song: 0, standing: -0.5)) == 0,
                     "an earlier offset shows a line before its time")
        suite.expect(lyrics.activeIndex(at: 10.2, offset: NotchLyricsTiming.effective(song: 0, standing: 0.5)) == nil,
                     "a later offset holds it back")
    }
}
