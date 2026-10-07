// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the icon-only menu bar battery's colors and fill, and the padding-free
/// length every Vorssaint menu bar item takes.
enum MenuBarBatteryGlyphTests {
    static func run(_ suite: TestSuite) {
        typealias Glyph = MenuBarBatteryGlyphSupport
        suite.expect(Glyph.level(percent: 100) == .normal, "a full battery is plain")
        suite.expect(Glyph.level(percent: 20) == .normal, "20% is still plain")
        suite.expect(Glyph.level(percent: 19) == .low, "below 20% turns yellow")
        suite.expect(Glyph.level(percent: 10) == .low, "10% is still yellow")
        suite.expect(Glyph.level(percent: 9) == .critical, "below 10% turns red")
        suite.expect(Glyph.level(percent: -5) == .critical, "a bad reading below zero reads as empty")
        suite.expect(Glyph.level(percent: 140) == .normal, "a bad reading above 100 reads as full")

        suite.expect(Glyph.fillWidth(percent: 0, innerWidth: 20) == 0, "an empty battery has no fill")
        suite.expect(Glyph.fillWidth(percent: 1, innerWidth: 20) == 1.5, "any charge keeps a sliver")
        suite.expect(Glyph.fillWidth(percent: 50, innerWidth: 20) == 10, "the fill follows the charge")
        suite.expect(Glyph.fillWidth(percent: 100, innerWidth: 20) == 20, "a full battery fills the body")
        suite.expect(Glyph.fillWidth(percent: 150, innerWidth: 20) == 20, "the fill never overflows")

        let defaults = UserDefaults(suiteName: "MenuBarBatteryGlyphTests")!
        defaults.removePersistentDomain(forName: "MenuBarBatteryGlyphTests")
        suite.expect(Glyph.isIconOnly(defaults), "icon-only is the default")
        defaults.set(false, forKey: DefaultsKey.menuBarBatteryIconOnly)
        suite.expect(!Glyph.isIconOnly(defaults), "the percentage style can be chosen back")
        defaults.removePersistentDomain(forName: "MenuBarBatteryGlyphTests")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.menuBarBatteryIconOnly] as? Bool == true,
                     "the choice is registered, so settings backup carries it")

        typealias Tight = MenuBarTightLengthSupport
        suite.expect(Tight.length(layout: .titleOnly, imageWidth: 0, titleWidth: 27.2) == 30,
                     "a title-only item hugs its title")
        suite.expect(Tight.length(layout: .imageOnly, imageWidth: 18, titleWidth: 0) == 20,
                     "an image-only item hugs its image")
        suite.expect(Tight.length(layout: .imageAndTitle, imageWidth: 18, titleWidth: 30) == 52,
                     "an image and title keep the cell's gap between them")
        suite.expect(Tight.length(layout: .imageAndTitle, imageWidth: 18, titleWidth: 0) == 20,
                     "no gap without a title")
        suite.expect(Tight.length(layout: .titleOnly, imageWidth: 0, titleWidth: 0) == nil,
                     "an empty item keeps macOS's own sizing")
    }
}
