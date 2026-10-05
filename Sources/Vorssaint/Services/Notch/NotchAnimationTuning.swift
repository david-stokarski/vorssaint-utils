// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: how the island opens and closes. NotchMotion reads its springs here,
// so the presets and the Settings sliders shape every resize.

extension DefaultsKey {
    static let notchAnimationPreset = "notchAnimationPreset"
    static let notchAnimationOpenDuration = "notchAnimationOpenDuration"
    static let notchAnimationOpenBounce = "notchAnimationOpenBounce"
    static let notchAnimationCloseDuration = "notchAnimationCloseDuration"
    static let notchAnimationCloseBounce = "notchAnimationCloseBounce"
    static let notchAnimationStretch = "notchAnimationStretch"
    static let notchAnimationContentBlur = "notchAnimationContentBlur"
    static let notchAnimationContentScale = "notchAnimationContentScale"
}

struct NotchAnimationTuning: Equatable {
    /// Perceptual duration of the opening spring, in seconds.
    var openDuration: Double
    /// How far past its size the island swings when it opens, 0 (none) to 0.5.
    var openBounce: Double
    var closeDuration: Double
    /// A small squish as the island settles closed.
    var closeBounce: Double
    /// Seconds the second side trails the first: opening, the width leads and
    /// the height follows; closing, the height draws up and the width
    /// follows. The island stretches like a drop instead of scaling as a box.
    var stretch: Double
    /// Blur radius and scale the opened content arrives from.
    var contentBlur: Double
    var contentScale: Double

    /// Height springs run a little quicker than width ones, as upstream's did.
    static let heightRatio = 0.865
    /// A closing island may dip only this far under its size: a resting
    /// notch must keep covering the camera.
    static let closeOvershootLimit: CGFloat = 4

    enum Preset: String, CaseIterable, Identifiable {
        case liquid, snappy, gentle, classic, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .liquid: return "Liquid"
            case .snappy: return "Snappy"
            case .gentle: return "Gentle"
            case .classic: return "Classic"
            case .custom: return "Custom"
            }
        }

        var tuning: NotchAnimationTuning? {
            switch self {
            case .liquid: return NotchAnimationTuning(openDuration: 0.52, openBounce: 0.3, closeDuration: 0.38,
                                                      closeBounce: 0.1, stretch: 0.05, contentBlur: 14, contentScale: 0.84)
            case .snappy: return NotchAnimationTuning(openDuration: 0.34, openBounce: 0.16, closeDuration: 0.24,
                                                      closeBounce: 0, stretch: 0.02, contentBlur: 8, contentScale: 0.9)
            case .gentle: return NotchAnimationTuning(openDuration: 0.72, openBounce: 0.14, closeDuration: 0.5,
                                                      closeBounce: 0.04, stretch: 0.07, contentBlur: 16, contentScale: 0.86)
            case .classic: return .classic
            case .custom: return nil
            }
        }
    }

    /// Upstream's motion, used wherever no preference is loaded (the tests).
    static let classic = NotchAnimationTuning(openDuration: 0.44, openBounce: 0.25, closeDuration: 0.30,
                                              closeBounce: 0, stretch: 0, contentBlur: 12, contentScale: 0.86)

    static let durationRange = 0.15...1.2
    static let bounceRange = 0.0...0.5
    static let closeBounceRange = 0.0...0.3
    static let stretchRange = 0.0...0.15
    static let blurRange = 0.0...24
    static let scaleRange = 0.7...1.0

    /// What NotchMotion reads. `reload()` brings it in line with Settings.
    static var current = classic

    static func reload(from defaults: UserDefaults = .standard) {
        current = stored(in: defaults)
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        let preset = Preset(rawValue: defaults.string(forKey: DefaultsKey.notchAnimationPreset) ?? "") ?? .classic
        if let tuning = preset.tuning { return tuning }
        func value(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let raw = defaults.double(forKey: key)
            return raw.isFinite ? min(range.upperBound, max(range.lowerBound, raw)) : fallback
        }
        let base = Preset.liquid.tuning ?? .classic
        return NotchAnimationTuning(
            openDuration: value(DefaultsKey.notchAnimationOpenDuration, durationRange, base.openDuration),
            openBounce: value(DefaultsKey.notchAnimationOpenBounce, bounceRange, base.openBounce),
            closeDuration: value(DefaultsKey.notchAnimationCloseDuration, durationRange, base.closeDuration),
            closeBounce: value(DefaultsKey.notchAnimationCloseBounce, closeBounceRange, base.closeBounce),
            stretch: value(DefaultsKey.notchAnimationStretch, stretchRange, base.stretch),
            contentBlur: value(DefaultsKey.notchAnimationContentBlur, blurRange, base.contentBlur),
            contentScale: value(DefaultsKey.notchAnimationContentScale, scaleRange, base.contentScale))
    }

    /// Writes every value, so moving one slider continues from the preset shown.
    func store(in defaults: UserDefaults = .standard) {
        defaults.set(openDuration, forKey: DefaultsKey.notchAnimationOpenDuration)
        defaults.set(openBounce, forKey: DefaultsKey.notchAnimationOpenBounce)
        defaults.set(closeDuration, forKey: DefaultsKey.notchAnimationCloseDuration)
        defaults.set(closeBounce, forKey: DefaultsKey.notchAnimationCloseBounce)
        defaults.set(stretch, forKey: DefaultsKey.notchAnimationStretch)
        defaults.set(contentBlur, forKey: DefaultsKey.notchAnimationContentBlur)
        defaults.set(contentScale, forKey: DefaultsKey.notchAnimationContentScale)
    }

    static let registeredDefaults: [String: Any] = {
        let liquid = Preset.liquid.tuning ?? .classic
        return [
            DefaultsKey.notchAnimationPreset: Preset.liquid.rawValue,
            DefaultsKey.notchAnimationOpenDuration: liquid.openDuration,
            DefaultsKey.notchAnimationOpenBounce: liquid.openBounce,
            DefaultsKey.notchAnimationCloseDuration: liquid.closeDuration,
            DefaultsKey.notchAnimationCloseBounce: liquid.closeBounce,
            DefaultsKey.notchAnimationStretch: liquid.stretch,
            DefaultsKey.notchAnimationContentBlur: liquid.contentBlur,
            DefaultsKey.notchAnimationContentScale: liquid.contentScale,
        ]
    }()

    // MARK: Springs

    func spring(growing: Bool, width: Bool) -> NotchMotion.Spring {
        let duration = growing ? openDuration : closeDuration
        return NotchMotion.Spring(duration: width ? duration : duration * Self.heightRatio,
                                  bounce: growing ? openBounce : closeBounce)
    }

    /// When a side starts moving: the trailing side waits `stretch`.
    func delay(growing: Bool, width: Bool) -> TimeInterval {
        // Opening, the width leads; closing, the height leads.
        growing == width ? 0 : stretch
    }
}
