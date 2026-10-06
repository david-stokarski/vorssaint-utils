// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: what the open island and the dictation surface are made of. Each
// has its own material and tint, chosen in Settings > Dynamic Island.

extension DefaultsKey {
    static let notchIslandMaterial = "notchIslandMaterial"
    static let notchIslandTint = "notchIslandTint"
    static let dictationMaterial = "dictationMaterial"
    static let dictationTint = "dictationTint"
    /// The Command Bar's own surface, in or out of the island's drop.
    static let commandBarMaterial = "commandBarMaterial"
    static let commandBarTint = "commandBarTint"
}

enum NotchSurfaceMaterial: String, CaseIterable, Identifiable {
    /// The island's own look: black, or upstream's glass or translucent
    /// background when those switches are on.
    case classic
    case black
    /// The system's behind-window blur.
    case frosted
    /// Liquid Glass over the whole surface (macOS 26 and later).
    case glass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .black: return "Black"
        case .frosted: return "Frosted"
        case .glass: return "Glass"
        }
    }

    /// Whether the surface lets what is behind it show.
    var seeThrough: Bool { self == .frosted || self == .glass }

    static let islandChoices: [Self] = [.classic, .frosted, .glass]
    static let dictationChoices: [Self] = [.black, .frosted, .glass]
    static let commandBarChoices: [Self] = [.classic, .black, .frosted, .glass]
}

struct NotchSurfaceAppearance: Equatable {
    var material: NotchSurfaceMaterial
    /// How dark the tint over a see-through material is, 0 (clear) to 1 (black).
    var tint: Double

    static let tintRange = 0.0...0.9
    static let defaultIslandTint = 0.35
    static let defaultDictationTint = 0.3
    static let defaultCommandBarTint = 0.3

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.notchIslandMaterial: NotchSurfaceMaterial.glass.rawValue,
        DefaultsKey.notchIslandTint: defaultIslandTint,
        DefaultsKey.dictationMaterial: NotchSurfaceMaterial.glass.rawValue,
        DefaultsKey.dictationTint: defaultDictationTint,
    ]

    /// Without a preference the island is upstream's and dictation is black.
    static func island(in defaults: UserDefaults = .standard) -> Self {
        Self(material: NotchSurfaceMaterial(rawValue: defaults.string(forKey: DefaultsKey.notchIslandMaterial) ?? "") ?? .classic,
             tint: tint(DefaultsKey.notchIslandTint, defaultIslandTint, defaults))
    }

    /// Classic, the bar's own look, until another is chosen.
    static func commandBar(in defaults: UserDefaults = .standard) -> Self {
        Self(material: NotchSurfaceMaterial(rawValue: defaults.string(forKey: DefaultsKey.commandBarMaterial) ?? "") ?? .classic,
             tint: tint(DefaultsKey.commandBarTint, defaultCommandBarTint, defaults))
    }

    static func dictation(in defaults: UserDefaults = .standard) -> Self {
        var material = NotchSurfaceMaterial(rawValue: defaults.string(forKey: DefaultsKey.dictationMaterial) ?? "") ?? .black
        if material == .classic { material = .black }
        return Self(material: material, tint: tint(DefaultsKey.dictationTint, defaultDictationTint, defaults))
    }

    private static func tint(_ key: String, _ fallback: Double, _ defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let raw = defaults.double(forKey: key)
        return raw.isFinite ? min(tintRange.upperBound, max(tintRange.lowerBound, raw)) : fallback
    }

    /// Opacity of the black over the material at `depth` points below the
    /// island's top: solid over the camera strip (none without a camera),
    /// easing into the tint over `ramp` points.
    static func overlay(atDepth depth: Double, strip: Double, tint: Double, ramp: Double = 28) -> Double {
        guard strip > 0 else { return tint }
        guard depth > strip else { return 1 }
        guard ramp > 0 else { return tint }
        let t = min(1, (depth - strip) / ramp)
        let eased = t * t * (3 - 2 * t)
        return 1 - (1 - tint) * eased
    }
}
