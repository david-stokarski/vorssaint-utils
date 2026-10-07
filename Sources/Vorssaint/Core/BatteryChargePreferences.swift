// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: the Charge Limit's preferences. They live apart from
// BatteryChargeSupport because the daemon compiles that file and has no
// DefaultsKey. Every key here except the top-up request is registered, so
// settings backup carries it; the top-up request is a moment on one Mac and
// stays out by never being registered.

extension DefaultsKey {
    static let batteryChargeEnabled = "batteryChargeEnabled"
    static let batteryChargeLimit = "batteryChargeLimit"
    static let batteryChargeSailing = "batteryChargeSailing"
    static let batteryChargeHeatProtection = "batteryChargeHeatProtection"
    static let batteryChargeHeatThreshold = "batteryChargeHeatThreshold"
    static let batteryChargeDischarge = "batteryChargeDischarge"
    static let batteryChargeMagSafeLED = "batteryChargeMagSafeLED"
    /// JSON `BatteryChargeTopUp` of a pending "charge to 100% now". Machine
    /// state: not registered, so never exported.
    static let batteryChargeTopUp = "batteryChargeTopUp"
}

enum BatteryChargePreferences {
    static let registeredDefaults: [String: Any] = [
        DefaultsKey.batteryChargeEnabled: false,
        DefaultsKey.batteryChargeLimit: BatteryChargeConfig.defaultLimit,
        DefaultsKey.batteryChargeSailing: BatteryChargeConfig.defaultSailing,
        DefaultsKey.batteryChargeHeatProtection: true,
        DefaultsKey.batteryChargeHeatThreshold: BatteryChargeConfig.defaultHeatThreshold,
        DefaultsKey.batteryChargeDischarge: false,
        DefaultsKey.batteryChargeMagSafeLED: false,
    ]

    /// The configuration the daemon gets. Unavailable in the hub means off.
    static func config(in defaults: UserDefaults, available: Bool) -> BatteryChargeConfig {
        BatteryChargeConfig(
            enabled: available && defaults.bool(forKey: DefaultsKey.batteryChargeEnabled),
            limit: defaults.integer(forKey: DefaultsKey.batteryChargeLimit),
            sailing: defaults.integer(forKey: DefaultsKey.batteryChargeSailing),
            heatProtection: defaults.bool(forKey: DefaultsKey.batteryChargeHeatProtection),
            heatThreshold: defaults.integer(forKey: DefaultsKey.batteryChargeHeatThreshold),
            dischargeToLimit: defaults.bool(forKey: DefaultsKey.batteryChargeDischarge),
            magSafeLED: defaults.bool(forKey: DefaultsKey.batteryChargeMagSafeLED),
            topUp: topUp(in: defaults)
        ).sanitized()
    }

    static func topUp(in defaults: UserDefaults) -> BatteryChargeTopUp? {
        guard let raw = defaults.string(forKey: DefaultsKey.batteryChargeTopUp),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BatteryChargeTopUp.self, from: data)
    }

    static func setTopUp(_ topUp: BatteryChargeTopUp?, in defaults: UserDefaults) {
        guard let topUp, let data = try? JSONEncoder().encode(topUp) else {
            defaults.removeObject(forKey: DefaultsKey.batteryChargeTopUp)
            return
        }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: DefaultsKey.batteryChargeTopUp)
    }
}
