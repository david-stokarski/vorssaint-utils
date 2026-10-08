// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: Live Wallpaper. A plain wallpaper, black in dark mode and a soft
// paper white in light mode, with a faint field drifting across it that never
// repeats. The desktop shows it through a window behind the icons; the lock
// screen gets the same drift over the plain color, which is also set as the
// Mac's own wallpaper so the lock screen, Mission Control and a Mac without
// Vorssaint running all match. Styles and preferences live here, where the
// tests compile them; the drawing is in Services/LiveWallpaper.

extension DefaultsKey {
    static let liveWallpaperEnabled = "liveWallpaperEnabled"
    /// `LiveWallpaperMode` raw value.
    static let liveWallpaperMode = "liveWallpaperMode"
    /// `LiveWallpaperScene` raw value.
    static let liveWallpaperScene = "liveWallpaperScene"
    /// Draw the drift over the lock screen too.
    static let liveWallpaperLockScreen = "liveWallpaperLockScreen"
    /// Set the plain color as the Mac's wallpaper on every desktop.
    static let liveWallpaperSetsSystem = "liveWallpaperSetsSystem"
    /// 0.25 … 2: how fast the field drifts, 1 being the designed pace.
    static let liveWallpaperSpeed = "liveWallpaperSpeed"
    /// 0.25 … 2: how visible the field is, 1 being the designed strength.
    static let liveWallpaperIntensity = "liveWallpaperIntensity"
    /// 0 … 1: how soft every scene is drawn, 0 being sharp.
    static let liveWallpaperBlur = "liveWallpaperBlur"
    /// The picture that was the Mac's wallpaper before this one, put back
    /// when the feature is turned off.
    static let liveWallpaperPreviousImage = "liveWallpaperPreviousImage"
}

/// Which of the two palettes shows.
enum LiveWallpaperMode: String, CaseIterable, Identifiable {
    /// Dark in dark mode, light in light mode.
    case automatic
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Match Appearance"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    static func sanitized(_ raw: String?) -> LiveWallpaperMode {
        raw.flatMap(Self.init(rawValue:)) ?? .automatic
    }

    func kind(darkAppearance: Bool) -> LiveWallpaperStyle.Kind {
        switch self {
        case .automatic: return darkAppearance ? .dark : .light
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// What moves across the wallpaper. Every scene has a dark and a light
/// palette over the same two plain colors.
enum LiveWallpaperScene: String, CaseIterable, Identifiable {
    /// Smoke or ink in water.
    case mist
    /// The level lines of a slowly shifting landscape.
    case contours
    /// A ribbon of thin threads, turning over like silk.
    case waves
    /// A few large soft glows wandering past each other.
    case halo
    /// A fine grid of dots a slow swell passes through.
    case dots
    /// Rings drifting outward from a wandering center.
    case ripple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mist: return "Mist"
        case .contours: return "Contours"
        case .waves: return "Waves"
        case .halo: return "Halo"
        case .dots: return "Dots"
        case .ripple: return "Ripple"
        }
    }

    static func sanitized(_ raw: String?) -> LiveWallpaperScene {
        raw.flatMap(Self.init(rawValue:)) ?? .mist
    }

    /// The scene's number in the shader.
    var shaderIndex: UInt32 {
        switch self {
        case .mist: return 0
        case .contours: return 1
        case .waves: return 2
        case .halo: return 3
        case .dots: return 4
        case .ripple: return 5
        }
    }

    /// How fast its field moves for a second of the clock, so every scene
    /// feels about as calm at the same Speed.
    var pace: Float {
        switch self {
        case .mist: return 1
        case .contours: return 0.8
        case .waves: return 1
        case .halo: return 1
        case .dots: return 1
        case .ripple: return 1
        }
    }

    /// Thin lines and dots are drawn at the screen's full resolution; the
    /// soft scenes look the same at a quarter of the pixels.
    var isSharp: Bool {
        switch self {
        case .mist, .halo: return false
        case .contours, .waves, .dots, .ripple: return true
        }
    }
}

/// One wallpaper's look. Colors are sRGB components from 0 to 1.
struct LiveWallpaperStyle: Equatable {
    struct RGB: Equatable {
        var red: Float, green: Float, blue: Float

        var vector: SIMD4<Float> { SIMD4(red, green, blue, 1) }

        /// Eight-bit components, for the plain picture.
        var bytes: (UInt8, UInt8, UInt8) {
            func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
            return (byte(red), byte(green), byte(blue))
        }

        func mixed(with other: RGB, progress: Float) -> RGB {
            RGB(red: red + (other.red - red) * progress, green: green + (other.green - green) * progress,
                blue: blue + (other.blue - blue) * progress)
        }
    }

    enum Kind: String { case dark, light }

    var scene: LiveWallpaperScene
    var kind: Kind
    var base: RGB
    /// The scene blends between these two inks.
    var inkA: RGB
    var inkB: RGB
    /// Peak coverage of the ink over the base.
    var strength: Float
    /// Noise units across the screen's height: larger is finer.
    var scale: Float
    /// 0 … 1 of `maximumBlur`, the person's softness for every scene.
    var blur: Float = 0

    /// Pure black: the screen still reads as black under every scene.
    static let darkBase = RGB(red: 0, green: 0, blue: 0)
    /// Warm paper.
    static let lightBase = RGB(red: 0.925, green: 0.918, blue: 0.902)

    init(scene: LiveWallpaperScene, kind: Kind) {
        self.scene = scene
        self.kind = kind
        base = kind == .dark ? Self.darkBase : Self.lightBase
        scale = 1.15
        switch (scene, kind) {
        // Cold blue-grey smoke and a warmer grey.
        case (.mist, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.42, green: 0.50, blue: 0.66), RGB(red: 0.58, green: 0.55, blue: 0.60), 0.20)
        case (.mist, .light):
            (inkA, inkB, strength) = (RGB(red: 0.56, green: 0.60, blue: 0.68), RGB(red: 0.70, green: 0.66, blue: 0.62), 0.20)
        // Hairlines, every fifth one stronger, as on a survey map.
        case (.contours, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.50, green: 0.56, blue: 0.68), RGB(red: 0.66, green: 0.64, blue: 0.70), 0.26)
            scale = 0.9
        case (.contours, .light):
            (inkA, inkB, strength) = (RGB(red: 0.38, green: 0.42, blue: 0.50), RGB(red: 0.50, green: 0.45, blue: 0.42), 0.24)
            scale = 0.9
        // Threads with a hint of violet along their length.
        case (.waves, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.50, green: 0.60, blue: 0.78), RGB(red: 0.70, green: 0.60, blue: 0.76), 0.34)
        case (.waves, .light):
            (inkA, inkB, strength) = (RGB(red: 0.36, green: 0.42, blue: 0.56), RGB(red: 0.52, green: 0.42, blue: 0.52), 0.30)
        // The one scene with color: deep indigo and rose on black, pale sky
        // and peach on paper.
        case (.halo, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.26, green: 0.32, blue: 0.62), RGB(red: 0.56, green: 0.30, blue: 0.40), 0.24)
        case (.halo, .light):
            (inkA, inkB, strength) = (RGB(red: 0.62, green: 0.74, blue: 0.92), RGB(red: 0.96, green: 0.74, blue: 0.64), 0.40)
        // Grey dots; the swell brightens and grows them.
        case (.dots, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.58, green: 0.62, blue: 0.70), RGB(red: 0.70, green: 0.68, blue: 0.70), 0.50)
            scale = 1.0
        case (.dots, .light):
            (inkA, inkB, strength) = (RGB(red: 0.32, green: 0.35, blue: 0.42), RGB(red: 0.42, green: 0.38, blue: 0.36), 0.40)
            scale = 1.0
        // Rings, cooler toward the outside.
        case (.ripple, .dark):
            (inkA, inkB, strength) = (RGB(red: 0.62, green: 0.64, blue: 0.70), RGB(red: 0.44, green: 0.52, blue: 0.70), 0.26)
        case (.ripple, .light):
            (inkA, inkB, strength) = (RGB(red: 0.40, green: 0.42, blue: 0.48), RGB(red: 0.40, green: 0.48, blue: 0.62), 0.24)
        }
    }

    static let dark = LiveWallpaperStyle(scene: .mist, kind: .dark)
    static let light = LiveWallpaperStyle(scene: .mist, kind: .light)

    /// The same look with the person's intensity and blur applied.
    func adjusted(intensity: Double, blur: Double = 0) -> LiveWallpaperStyle {
        var style = self
        style.strength = min(1, style.strength * Float(LiveWallpaperSupport.clampedFactor(intensity)))
        style.blur = blur.isFinite ? Float(max(0, min(1, blur))) : 0
        return style
    }

    /// The strongest blur's spread (one standard deviation), as a share of
    /// the screen's height, so a small preview blurs as its screen does.
    static let maximumBlur = 0.011

    /// How a blur of `sigma` target pixels is drawn: the scene at a smaller
    /// size, so the blur stays within thirteen taps there, and the spread in
    /// that size's pixels. Nil when the blur is too small to see.
    static func blurPlan(sigma: Double, width: Int, height: Int)
        -> (width: Int, height: Int, sigma: Double)? {
        guard sigma.isFinite, sigma >= 0.5, width > 0, height > 0 else { return nil }
        // Two pixels of spread at the small size reach ±3σ with six taps a side.
        let shrink = max(2, sigma / 2)
        let small = (width: max(8, Int((Double(width) / shrink).rounded())),
                     height: max(8, Int((Double(height) / shrink).rounded())))
        return (small.width, small.height, sigma * Double(small.height) / Double(height))
    }

    /// The plain color part way to `other`'s, for the fade between them.
    func mixedBase(with other: LiveWallpaperStyle, progress: Double) -> RGB {
        base.mixed(with: other.base, progress: Float(max(0, min(1, progress))))
    }

    /// The field texture for a target of this many pixels: about a quarter
    /// of the width, never above 1024 across, never below 32.
    static func fieldSize(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let across = min(1024, max(32, width / 4))
        let down = max(16, Int((Double(across) * Double(height) / Double(width)).rounded()))
        return (across, down)
    }
}

enum LiveWallpaperSupport {
    static let title = "Live Wallpaper"
    static let hubDescription = "A plain black or paper-white wallpaper with faint mist, lines, waves, glows, dots or ripples drifting across it, never repeating, on the desktop and the lock screen."

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.liveWallpaperEnabled: true,
        DefaultsKey.liveWallpaperMode: LiveWallpaperMode.automatic.rawValue,
        DefaultsKey.liveWallpaperScene: LiveWallpaperScene.mist.rawValue,
        DefaultsKey.liveWallpaperLockScreen: true,
        DefaultsKey.liveWallpaperSetsSystem: true,
        DefaultsKey.liveWallpaperSpeed: 1.0,
        DefaultsKey.liveWallpaperIntensity: 1.0,
        DefaultsKey.liveWallpaperBlur: 0.0,
    ]

    static let factorRange: ClosedRange<Double> = 0.25...2

    static func clampedFactor(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(factorRange.upperBound, max(factorRange.lowerBound, value))
    }

    /// The window server layer the lock screen's drift is drawn in: the one
    /// the lock screen's notifications use, like the island's player. It sits
    /// over the clock too, which the drift's faintness makes no difference to.
    static let lockScreenSpaceLevel: Int32 = 400

    /// The strongest blur's spread in pixels on a screen this many pixels tall.
    static func maximumBlurPixels(height: Int) -> Double {
        LiveWallpaperStyle.maximumBlur * Double(height)
    }

    /// The spread in pixels for a Blur setting from 0 to 1. Eased, so the
    /// low end of the slider is the fine one: lines and dots soften well
    /// before they melt away.
    static func blurPixels(_ blur: Float, height: Int) -> Double {
        let amount = Double(max(0, min(1, blur)))
        return pow(amount, 1.5) * maximumBlurPixels(height: height)
    }

    /// Frames per second while drawing. The drift is slow; more would only
    /// spend power.
    static let framesPerSecond = 30

    /// The plain picture's file name for a style, versioned by its color so
    /// a changed base is a new file and macOS refreshes.
    static func stillFileName(for style: LiveWallpaperStyle) -> String {
        let (r, g, b) = style.base.bytes
        return String(format: "Live Wallpaper %@ %02X%02X%02X.png", style.kind.rawValue.capitalized, r, g, b)
    }

    /// Whether the drift should be drawn now. In Low Power Mode it holds
    /// still on its current frame.
    static func shouldAnimate(enabled: Bool, sessionActive: Bool, displaysAsleep: Bool,
                              lowPowerMode: Bool) -> Bool {
        enabled && sessionActive && !displaysAsleep && !lowPowerMode
    }

    /// Whether a picture is one of the plain ones this feature sets, so it is
    /// never remembered as the wallpaper to go back to.
    static func isOwnStill(_ path: String?) -> Bool {
        guard let path else { return false }
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("Live Wallpaper ") && name.hasSuffix(".png")
    }

    /// How long a change of style takes to fade across.
    static let transitionDuration: Double = 1.6
}
