// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: Live Wallpaper. The mode picks the palette the appearance asks for,
/// every scene has both palettes over the same plain colors and its own
/// shader number, the person's factors stay in range, the fade lands on its
/// target, the field texture stays small, and the plain pictures are told
/// apart from the person's own.
enum LiveWallpaperSupportTests {
    static func run(_ suite: TestSuite) {
        modes(suite)
        scenes(suite)
        adjustments(suite)
        blurPlans(suite)
        mixing(suite)
        fieldSize(suite)
        stills(suite)
        animation(suite)
    }

    private static func modes(_ suite: TestSuite) {
        suite.expect(LiveWallpaperMode.sanitized(nil) == .automatic, "no mode is Match Appearance")
        suite.expect(LiveWallpaperMode.sanitized("bogus") == .automatic, "an unknown mode is Match Appearance")
        suite.expect(LiveWallpaperMode.automatic.kind(darkAppearance: true) == .dark, "dark mode shows the dark palette")
        suite.expect(LiveWallpaperMode.automatic.kind(darkAppearance: false) == .light, "light mode shows the light one")
        suite.expect(LiveWallpaperMode.dark.kind(darkAppearance: false) == .dark, "Dark holds in light mode")
        suite.expect(LiveWallpaperMode.light.kind(darkAppearance: true) == .light, "Light holds in dark mode")
        suite.expect(LiveWallpaperStyle.dark.base.bytes == (0, 0, 0), "the dark wallpaper is pure black")
    }

    private static func scenes(_ suite: TestSuite) {
        suite.expect(LiveWallpaperScene.sanitized(nil) == .mist, "no scene is Mist, as before scenes")
        suite.expect(LiveWallpaperScene.sanitized("bogus") == .mist, "an unknown scene is Mist")
        let indexes = LiveWallpaperScene.allCases.map(\.shaderIndex)
        suite.expect(indexes == Array(0..<UInt32(indexes.count)), "shader numbers are 0, 1, 2… in order")
        for scene in LiveWallpaperScene.allCases {
            let dark = LiveWallpaperStyle(scene: scene, kind: .dark)
            let light = LiveWallpaperStyle(scene: scene, kind: .light)
            suite.expect(dark.base == LiveWallpaperStyle.darkBase && light.base == LiveWallpaperStyle.lightBase,
                         "\(scene.title) sits on the same plain colors, so one picture fits the lock screen")
            suite.expect(dark.strength > 0 && dark.strength <= 0.5 && light.strength > 0 && light.strength <= 0.5,
                         "\(scene.title) stays faint in both palettes")
            suite.expect(scene.pace > 0, "\(scene.title) moves")
        }
        suite.expect(!LiveWallpaperScene.mist.isSharp && LiveWallpaperScene.contours.isSharp,
                     "fog is drawn at points, lines at full resolution")
    }

    private static func adjustments(_ suite: TestSuite) {
        let style = LiveWallpaperStyle.dark
        suite.expect(style.adjusted(intensity: 1) == style, "an intensity of 1 changes nothing")
        suite.expect(style.adjusted(intensity: 100).strength == style.strength * 2,
                     "intensity stops at twice the design")
        suite.expect(style.adjusted(intensity: 0).strength == style.strength * 0.25, "and at a quarter")
        suite.expect(style.adjusted(intensity: .infinity) == style, "a broken factor is 1")
        suite.expect(style.adjusted(intensity: 1, blur: 3).blur == 1, "blur stops at its strongest")
        suite.expect(style.adjusted(intensity: 1, blur: -1).blur == 0, "and at sharp")
        suite.expect(style.adjusted(intensity: 1, blur: .nan).blur == 0, "a broken blur is sharp")
    }

    private static func blurPlans(_ suite: TestSuite) {
        suite.expect(LiveWallpaperStyle.blurPlan(sigma: 0, width: 3840, height: 1080) == nil, "no blur draws as before")
        suite.expect(LiveWallpaperStyle.blurPlan(sigma: 0.3, width: 3840, height: 1080) == nil, "nor does an invisible one")
        if let light = LiveWallpaperStyle.blurPlan(sigma: 2, width: 3840, height: 1080) {
            suite.expect(light.width == 1920 && light.height == 540, "a light blur draws at half size")
            suite.expect(abs(light.sigma - 1) < 0.01, "with the spread halved to match")
        } else {
            suite.expect(false, "a light blur has a plan")
        }
        let strongest = LiveWallpaperSupport.maximumBlurPixels(height: 1080)
        if let heavy = LiveWallpaperStyle.blurPlan(sigma: strongest, width: 3840, height: 1080) {
            suite.expect(heavy.sigma <= 2.01, "the spread fits the thirteen taps")
            suite.expect(heavy.height < 1080 / 4, "the strongest blur draws at under a quarter size")
            suite.expect(abs(heavy.sigma * 1080 / Double(heavy.height) - strongest) < 0.5,
                         "and still spreads as far on the screen")
        } else {
            suite.expect(false, "the strongest blur has a plan")
        }
        suite.expect(LiveWallpaperSupport.blurPixels(0, height: 1080) == 0, "Blur off spreads nothing")
        suite.expect(LiveWallpaperSupport.blurPixels(1, height: 1080) == strongest, "full Blur is the strongest")
        suite.expect(LiveWallpaperSupport.blurPixels(0.5, height: 1080) < strongest / 2, "the low half is the fine half")
        if let tiny = LiveWallpaperStyle.blurPlan(sigma: 500, width: 40, height: 30) {
            suite.expect(tiny.width >= 8 && tiny.height >= 8, "never below 8 pixels")
        }
    }

    private static func mixing(_ suite: TestSuite) {
        let dark = LiveWallpaperStyle.dark, light = LiveWallpaperStyle.light
        suite.expect(dark.mixedBase(with: light, progress: 0) == dark.base, "the fade starts on the old color")
        suite.expect(dark.mixedBase(with: light, progress: 1) == light.base, "and lands on the new one")
        let middle = dark.mixedBase(with: light, progress: 0.5)
        suite.expect(middle.red > 0.4 && middle.red < 0.5, "halfway is halfway")
        suite.expect(dark.mixedBase(with: light, progress: 7) == light.base, "progress is clamped")
    }

    private static func fieldSize(_ suite: TestSuite) {
        let wide = LiveWallpaperStyle.fieldSize(forWidth: 3840, height: 1080)
        suite.expect(wide.width == 960 && wide.height == 270, "a quarter of the screen, same shape")
        let huge = LiveWallpaperStyle.fieldSize(forWidth: 7680, height: 4320)
        suite.expect(huge.width == 1024, "never above 1024 across")
        let tiny = LiveWallpaperStyle.fieldSize(forWidth: 40, height: 30)
        suite.expect(tiny.width == 32 && tiny.height >= 16, "never below 32 across")
        let empty = LiveWallpaperStyle.fieldSize(forWidth: 0, height: 0)
        suite.expect(empty.width == 1 && empty.height == 1, "an empty target gets a pixel")
    }

    private static func stills(_ suite: TestSuite) {
        let dark = LiveWallpaperSupport.stillFileName(for: .dark)
        let light = LiveWallpaperSupport.stillFileName(for: .light)
        suite.expect(dark == "Live Wallpaper Dark 000000.png", "the dark picture is named for its color")
        suite.expect(dark != light, "each style has its own picture")
        suite.expect(LiveWallpaperSupport.isOwnStill("/x/" + light), "our pictures are recognized")
        suite.expect(!LiveWallpaperSupport.isOwnStill("/Users/me/Desktop/Screenshot.png"), "the person's are not")
        suite.expect(!LiveWallpaperSupport.isOwnStill(nil), "nor is no picture")
    }

    private static func animation(_ suite: TestSuite) {
        suite.expect(LiveWallpaperSupport.shouldAnimate(enabled: true, sessionActive: true, displaysAsleep: false,
                                                        lowPowerMode: false), "draws when all is well")
        suite.expect(!LiveWallpaperSupport.shouldAnimate(enabled: true, sessionActive: true, displaysAsleep: true,
                                                         lowPowerMode: false), "holds still while displays sleep")
        suite.expect(!LiveWallpaperSupport.shouldAnimate(enabled: true, sessionActive: false, displaysAsleep: false,
                                                         lowPowerMode: false), "and for another user's session")
        suite.expect(!LiveWallpaperSupport.shouldAnimate(enabled: true, sessionActive: true, displaysAsleep: false,
                                                         lowPowerMode: true), "and in Low Power Mode")
    }
}
