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

// MARK: - Hover

extension DefaultsKey {
    /// How long the pointer must be away before a hover-opened island closes.
    static let notchHoverCloseDelay = "notchHoverCloseDelay"
    /// The least time a hover-opened island stays open, however soon the pointer leaves.
    static let notchHoverMinimumOpen = "notchHoverMinimumOpen"
}

/// Fork: how the island answers the pointer leaving it.
enum NotchHoverTuning {
    static let defaultCloseDelay = 0.18
    static let closeDelayRange = 0.0...2.0
    static let minimumOpenRange = 0.0...3.0
    /// When the island last opened, on the media clock.
    private(set) static var openedAt: TimeInterval = 0

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.notchHoverCloseDelay: defaultCloseDelay,
        DefaultsKey.notchHoverMinimumOpen: 0.0,
    ]

    static func noteOpened(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) { openedAt = time }

    static func closeDelay(in defaults: UserDefaults = .standard) -> TimeInterval {
        value(DefaultsKey.notchHoverCloseDelay, closeDelayRange, defaultCloseDelay, defaults)
    }

    static func minimumOpen(in defaults: UserDefaults = .standard) -> TimeInterval {
        value(DefaultsKey.notchHoverMinimumOpen, minimumOpenRange, 0, defaults)
    }

    /// How long to wait before closing an open island the pointer just left:
    /// the close delay, or longer while the minimum open time is still running.
    static func exitDelay(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                          in defaults: UserDefaults = .standard) -> TimeInterval {
        max(closeDelay(in: defaults), minimumOpen(in: defaults) - (now - openedAt))
    }

    private static func value(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double,
                              _ defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let raw = defaults.double(forKey: key)
        return raw.isFinite ? min(range.upperBound, max(range.lowerBound, raw)) : fallback
    }
}

// MARK: - Closed size beside a camera

extension DefaultsKey {
    /// Points the closed island extends past the camera on each side, in total.
    static let notchClosedExtraWidth = "notchClosedExtraWidth"
    /// Points the closed island hangs below the camera.
    static let notchClosedExtraHeight = "notchClosedExtraHeight"
}

/// Fork: a closed island larger than the camera it covers, on displays with
/// one. A floating capsule has its own fit (NotchCapsuleFit).
struct NotchClosedSize: Equatable {
    var extraWidth: CGFloat
    var extraHeight: CGFloat

    static let widthRange = 0.0...80.0
    static let heightRange = 0.0...12.0
    static let zero = NotchClosedSize(extraWidth: 0, extraHeight: 0)
    /// What the geometry reads; reloaded with the island's preferences.
    static var current = zero

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.notchClosedExtraWidth: 0.0,
        DefaultsKey.notchClosedExtraHeight: 0.0,
    ]

    static func reload(from defaults: UserDefaults = .standard) {
        func value(_ key: String, _ range: ClosedRange<Double>) -> CGFloat {
            let raw = defaults.double(forKey: key)
            return raw.isFinite ? CGFloat(min(range.upperBound, max(range.lowerBound, raw))) : 0
        }
        // Even widths keep the island centred on the camera's pixels.
        current = NotchClosedSize(extraWidth: (value(DefaultsKey.notchClosedExtraWidth, widthRange) / 2).rounded() * 2,
                                  extraHeight: value(DefaultsKey.notchClosedExtraHeight, heightRange).rounded())
    }
}

// MARK: - Shape

extension DefaultsKey {
    /// The inverse curve where the island's top meets the screen edge.
    static let notchShapeShoulder = "notchShapeShoulder"
    /// The radius of the hanging island's bottom corners.
    static let notchShapeBottomRadius = "notchShapeBottomRadius"
    /// The floating capsule's corner radius.
    static let notchShapeFloatingRadius = "notchShapeFloatingRadius"
    static let dictationShapeShoulder = "dictationShapeShoulder"
    static let dictationShapeBottomRadius = "dictationShapeBottomRadius"
    static let dictationShapeFloatingRadius = "dictationShapeFloatingRadius"
}

/// Fork: the island's silhouette. A larger top curve also widens the page's
/// side margins by as much, so content keeps its room inside it. Dictation
/// has its own curves, in force while it is on screen.
struct NotchShapeTuning: Equatable {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var floatingRadius: CGFloat

    static let classic = NotchShapeTuning(shoulder: 14, bottomRadius: 28, floatingRadius: 28)
    static let shoulderRange = 0.0...36.0
    static let bottomRadiusRange = 8.0...44.0
    static let floatingRadiusRange = 6.0...44.0
    /// What the silhouette reads now: the island's, or dictation's while it shows.
    static var current = classic
    private(set) static var island = classic
    private(set) static var dictation = classic
    private(set) static var dictationActive = false

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.notchShapeShoulder: 22.0,
        DefaultsKey.notchShapeBottomRadius: 30.0,
        DefaultsKey.notchShapeFloatingRadius: 28.0,
        DefaultsKey.dictationShapeShoulder: 22.0,
        DefaultsKey.dictationShapeBottomRadius: 30.0,
        DefaultsKey.dictationShapeFloatingRadius: 28.0,
    ]

    static func reload(from defaults: UserDefaults = .standard) {
        func value(_ key: String, _ range: ClosedRange<Double>, _ fallback: CGFloat) -> CGFloat {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let raw = defaults.double(forKey: key)
            return raw.isFinite ? CGFloat(min(range.upperBound, max(range.lowerBound, raw))).rounded() : fallback
        }
        island = NotchShapeTuning(shoulder: value(DefaultsKey.notchShapeShoulder, shoulderRange, classic.shoulder),
                                  bottomRadius: value(DefaultsKey.notchShapeBottomRadius, bottomRadiusRange, classic.bottomRadius),
                                  floatingRadius: value(DefaultsKey.notchShapeFloatingRadius, floatingRadiusRange, classic.floatingRadius))
        dictation = NotchShapeTuning(shoulder: value(DefaultsKey.dictationShapeShoulder, shoulderRange, island.shoulder),
                                     bottomRadius: value(DefaultsKey.dictationShapeBottomRadius, bottomRadiusRange, island.bottomRadius),
                                     floatingRadius: value(DefaultsKey.dictationShapeFloatingRadius, floatingRadiusRange, island.floatingRadius))
        current = dictationActive ? dictation : island
    }

    /// Dictation's curves while it is on screen, the island's otherwise.
    static func setDictationActive(_ active: Bool) {
        dictationActive = active
        current = active ? dictation : island
    }

    /// The page's side inset: upstream's 28 points, plus what the top curve adds.
    var horizontalInset: CGFloat { 28 + max(0, shoulder - Self.classic.shoulder) }
}
