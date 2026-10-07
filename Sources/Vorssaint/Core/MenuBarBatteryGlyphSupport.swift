// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

extension DefaultsKey {
    /// Fork: the menu bar battery reads as a glyph whose fill is the charge,
    /// without the percentage beside it.
    static let menuBarBatteryIconOnly = "menuBarBatteryIconOnly"
}

/// Fork: the decisions behind the icon-only menu bar battery, kept apart
/// from the drawing so they can be tested without AppKit.
enum MenuBarBatteryGlyphSupport {
    enum Level: String, Equatable {
        case normal, low, critical
    }

    static let title = "Battery as Icon Only"
    static let caption = "Shows the charge as the battery's fill instead of a percentage. The fill turns yellow below 20% and red below 10%."

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.menuBarBatteryIconOnly: true,
    ]

    static func isIconOnly(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.menuBarBatteryIconOnly) as? Bool ?? true
    }

    /// Red below 10%, yellow below 20%, the plain label color otherwise.
    static func level(percent: Int) -> Level {
        let clamped = max(0, min(100, percent))
        if clamped < 10 { return .critical }
        if clamped < 20 { return .low }
        return .normal
    }

    /// How much of the inner width the fill covers. Any charge at all keeps
    /// a sliver visible, so a nearly empty battery never reads as missing.
    static func fillWidth(percent: Int, innerWidth: Double, minimum: Double = 1.5) -> Double {
        let clamped = max(0, min(100, percent))
        guard clamped > 0, innerWidth > 0 else { return 0 }
        return min(innerWidth, max(minimum, innerWidth * Double(clamped) / 100))
    }
}
