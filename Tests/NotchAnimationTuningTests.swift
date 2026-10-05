// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: the island's tuned motion. Liquid stretch lets one side lead, a
/// closing squish never uncovers the camera, and settings round-trip.
enum NotchAnimationTuningTests {
    static func run(_ suite: TestSuite) {
        let saved = NotchAnimationTuning.current
        defer { NotchAnimationTuning.current = saved }
        let closed = CGSize(width: 200, height: 32)
        let open = CGSize(width: 600, height: 230)

        NotchAnimationTuning.current = .classic
        let early = NotchMotion.size(at: 0.08, from: closed, to: open)
        let classicWidth = (early.width - closed.width) / (open.width - closed.width)
        let classicHeight = (early.height - closed.height) / (open.height - closed.height)
        suite.expect(abs(classicWidth - classicHeight) < 0.2, "classic moves both sides together")

        guard let liquid = NotchAnimationTuning.Preset.liquid.tuning else { suite.expect(false, "liquid preset exists"); return }
        NotchAnimationTuning.current = liquid
        let opening = NotchMotion.size(at: liquid.stretch * 0.9, from: closed, to: open)
        suite.expect(opening.width > closed.width + 20 && abs(opening.height - closed.height) < 0.5,
                     "opening, the width leads while the height waits")
        let closing = NotchMotion.size(at: liquid.stretch * 0.9, from: open, to: closed)
        suite.expect(closing.height < open.height - 10 && abs(closing.width - open.width) < 0.5,
                     "closing, the height draws up while the width waits")
        let frames = NotchMotion.frames(from: open, to: closed)
        suite.expect(frames.sizes.allSatisfy { $0.width >= closed.width - NotchAnimationTuning.closeOvershootLimit - 0.5 },
                     "a closing squish stays within its limit")
        suite.expect(frames.sizes.last == closed, "closing ends exactly at the resting size")
        suite.expect(NotchMotion.frames(from: closed, to: open).sizes.last == open, "opening ends exactly at the open size")
        suite.expect(NotchMotion.duration(from: closed, to: open)
                     >= liquid.openDuration * NotchAnimationTuning.heightRatio + liquid.stretch - 0.001,
                     "the trailing side's wait counts toward the motion")

        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.notch-animation")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.notch-animation")
        suite.expect(NotchAnimationTuning.stored(in: defaults) == .classic, "no preference keeps upstream's motion")
        defaults.set(NotchAnimationTuning.Preset.snappy.rawValue, forKey: DefaultsKey.notchAnimationPreset)
        suite.expect(NotchAnimationTuning.stored(in: defaults) == NotchAnimationTuning.Preset.snappy.tuning,
                     "a preset supplies every value")
        defaults.set(NotchAnimationTuning.Preset.custom.rawValue, forKey: DefaultsKey.notchAnimationPreset)
        defaults.set(9.0, forKey: DefaultsKey.notchAnimationOpenDuration)
        defaults.set(-1.0, forKey: DefaultsKey.notchAnimationCloseBounce)
        let custom = NotchAnimationTuning.stored(in: defaults)
        suite.expect(custom.openDuration == NotchAnimationTuning.durationRange.upperBound
                     && custom.closeBounce == NotchAnimationTuning.closeBounceRange.lowerBound,
                     "custom values are kept within their ranges")
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.notch-animation")

        // Hover timing: the close delay, stretched while the minimum open time runs.
        suite.expect(NotchHoverTuning.closeDelay(in: defaults) == NotchHoverTuning.defaultCloseDelay,
                     "no preference keeps the usual close delay")
        defaults.set(0.5, forKey: DefaultsKey.notchHoverCloseDelay)
        defaults.set(2.0, forKey: DefaultsKey.notchHoverMinimumOpen)
        NotchHoverTuning.noteOpened(at: 100)
        suite.expect(abs(NotchHoverTuning.exitDelay(now: 100.5, in: defaults) - 1.5) < 0.0001,
                     "leaving early waits out the minimum open time")
        suite.expect(NotchHoverTuning.exitDelay(now: 105, in: defaults) == 0.5,
                     "after the minimum, only the close delay applies")
        defaults.set(9.0, forKey: DefaultsKey.notchHoverCloseDelay)
        suite.expect(NotchHoverTuning.closeDelay(in: defaults) == NotchHoverTuning.closeDelayRange.upperBound,
                     "close delays stay within range")
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.notch-animation")

        // Closed size beside a camera.
        let savedSize = NotchClosedSize.current
        defaults.set(33.0, forKey: DefaultsKey.notchClosedExtraWidth)
        defaults.set(99.0, forKey: DefaultsKey.notchClosedExtraHeight)
        NotchClosedSize.reload(from: defaults)
        suite.expect(NotchClosedSize.current.extraWidth.truncatingRemainder(dividingBy: 2) == 0,
                     "extra width stays even so the island stays centred")
        suite.expect(NotchClosedSize.current.extraHeight == CGFloat(NotchClosedSize.heightRange.upperBound),
                     "extra height stays within range")
        NotchClosedSize.current = savedSize
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.notch-animation")
    }
}
