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

/// Fork: a long lyric line scrolls in step with the time it has left.
enum NotchLyricMarqueeTests {
    static func run(_ suite: TestSuite) {
        suite.expect(NotchLyricMarquee.duration(overflow: 0, remaining: 3) == nil, "a line that fits stays put")
        suite.expect(NotchLyricMarquee.duration(overflow: 80, remaining: nil) == 2, "no timing scrolls at the natural pace")
        let paced = NotchLyricMarquee.duration(overflow: 80, remaining: 5)!
        suite.expect(abs(paced - (5 * 0.8 - 0.5)) < 0.001, "a timed line ends its scroll before the next one")
        suite.expect(NotchLyricMarquee.duration(overflow: 280, remaining: 0.5)! >= 2 - 0.001,
                     "a short line still scrolls no faster than can be read")
        suite.expect(NotchLyricMarquee.duration(overflow: 14, remaining: 60)! <= 1.001,
                     "a long line does not crawl")
        suite.expect(NotchLyricMarquee.delay(remaining: 1) == 0.15 && NotchLyricMarquee.delay(remaining: nil) == 0.5,
                     "the pause shrinks for quick lines")
        let times = [10.0, 14.0, 20.0]
        suite.expect(NotchLyricMarquee.remaining(after: 0, times: times, position: 11, offset: 0, rate: 1) == 3,
                     "time left runs to the next line")
        suite.expect(NotchLyricMarquee.remaining(after: 0, times: times, position: 11, offset: 0.5, rate: 2) == 1.75,
                     "the offset and playback rate count")
        suite.expect(NotchLyricMarquee.remaining(after: 2, times: times, position: 21, offset: 0, rate: 1) == nil
                        && NotchLyricMarquee.remaining(after: 0, times: times, position: 11, offset: 0, rate: 0) == nil,
                     "the last line, or a paused song, has no deadline")
    }
}
