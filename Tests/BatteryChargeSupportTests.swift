// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the Charge Limit's daemon decisions. The limit and its sailing
/// drift, heat pauses, top-ups, discharging, both key families, sleep, the
/// fail-safe on a bad configuration, the only SMC writes it may make, and the
/// preferences the app hands over.
enum BatteryChargeSupportTests {
    static func run(_ suite: TestSuite) {
        configuration(suite)
        capabilities(suite)
        smcWrites(suite)
        inhibitMode(suite)
        adapterMode(suite)
        heat(suite)
        topUp(suite)
        sleep(suite)
        statusAndInstall(suite)
        preferences(suite)
    }

    private static let inhibitOnly = BatteryChargeCapabilities(inhibit: .chte, adapter: nil, magSafeLED: true)
    private static let inhibitAndAdapter = BatteryChargeCapabilities(inhibit: .chte, adapter: .chie, magSafeLED: true)
    private static let adapterOnly = BatteryChargeCapabilities(inhibit: nil, adapter: .chie, magSafeLED: true)

    private static func reading(_ percent: Int, plugged: Bool = true, charging: Bool = false,
                                temperature: Double? = 30, inhibited: Bool = false,
                                adapterOff: Bool = false) -> BatteryChargeReading {
        BatteryChargeReading(percent: percent, isCharging: charging, pluggedIn: plugged, temperature: temperature,
                             chargingInhibited: inhibited, adapterDisabled: adapterOff)
    }

    private static func decide(_ config: BatteryChargeConfig?, _ reading: BatteryChargeReading,
                               _ capabilities: BatteryChargeCapabilities,
                               memory: BatteryChargeMemory = BatteryChargeMemory(),
                               topUp: Bool = false) -> BatteryChargeDecision {
        BatteryChargePolicy.decide(config: config, reading: reading, capabilities: capabilities,
                                   memory: memory, topUpActive: topUp)
    }

    private static func configuration(_ suite: TestSuite) {
        let decoded = BatteryChargeConfig.decode(Data(#"{"version":1,"enabled":true,"limit":12,"sailing":90,"heatThreshold":200}"#.utf8))
        suite.expect(decoded?.limit == 50 && decoded?.sailing == 20 && decoded?.heatThreshold == 50,
                     "every configured value is pulled into its range")
        suite.expect(decoded?.heatProtection == true && decoded?.dischargeToLimit == false,
                     "missing values take their defaults")
        suite.expect(BatteryChargeConfig.decode(Data(#"{"version":2,"enabled":true}"#.utf8)) == nil,
                     "another version is not a configuration")
        suite.expect(BatteryChargeConfig.decode(Data("not json".utf8)) == nil
                        && BatteryChargeConfig.decode(Data(#"{"version":1}"#.utf8)) == nil,
                     "garbage or a missing switch is not a configuration")
        suite.expect(BatteryChargeConfig.decode(Data(repeating: 0x20, count: BatteryChargeConfig.maximumFileSize + 1)) == nil,
                     "an oversized file is never parsed")
        let badToken = BatteryChargeConfig(enabled: true, topUp: BatteryChargeTopUp(token: "a b;rm", requestedAt: 1))
        suite.expect(badToken.sanitized().topUp == nil, "a top-up with a malformed token is dropped")
        let config = BatteryChargeConfig(enabled: true, limit: 77, sailing: 4)
        suite.expect(BatteryChargeConfig.decode(config.encoded()) == config, "a configuration survives the file")

        // The fail-safe: no configuration, a bad one, or one switched off,
        // all mean charging allowed and the adapter on.
        for config in [nil, BatteryChargeConfig(enabled: false)] {
            let decision = decide(config, reading(95, inhibited: true, adapterOff: true), inhibitAndAdapter)
            suite.expect(!decision.inhibitCharging && !decision.disableAdapter && decision.state == .off,
                         "an absent or disabled configuration restores the charger")
        }
        suite.expect(decide(BatteryChargeConfig(enabled: true), reading(90),
                            BatteryChargeCapabilities()).state == .unsupported,
                     "a Mac with no charging keys is unsupported and never written")
    }

    private static func capabilities(_ suite: TestSuite) {
        let sizes: [String: Int] = ["CHIE": 1, "ACLC": 1, "AC-W": 1]
        let thisMac = BatteryChargeCapabilities.detect { sizes[$0] }
        suite.expect(thisMac.inhibit == nil && thisMac.adapter == .chie && thisMac.magSafeLED
                        && thisMac.mode == .adapter,
                     "macOS 27 firmware exposes only the adapter key: the limit holds through the adapter")
        let tahoe = BatteryChargeCapabilities.detect { ["CHTE": 4, "CHIE": 1][$0] }
        suite.expect(tahoe.inhibit == .chte && tahoe.adapter == .chie && tahoe.mode == .inhibit,
                     "macOS 15/26 firmware inhibits with CHTE")
        let legacy = BatteryChargeCapabilities.detect { ["CH0B": 1, "CH0C": 1, "CH0I": 1][$0] }
        suite.expect(legacy.inhibit == .ch0bc && legacy.adapter == .ch0i, "older firmware uses CH0B/CH0C and CH0I")
        suite.expect(BatteryChargeCapabilities.detect { ["CHTE": 1, "CH0B": 1][$0] }.inhibit == nil,
                     "a key of the wrong size or half a pair is not used")
    }

    private static func smcWrites(_ suite: TestSuite) {
        suite.expect(BatteryChargeSMC.inhibitWrites(.chte, inhibit: true) == [.init(key: "CHTE", bytes: [1, 0, 0, 0])]
                        && BatteryChargeSMC.inhibitWrites(.chte, inhibit: false) == [.init(key: "CHTE", bytes: [0, 0, 0, 0])],
                     "CHTE takes 1 to inhibit and 0 to allow")
        suite.expect(BatteryChargeSMC.inhibitWrites(.ch0bc, inhibit: true)
                        == [.init(key: "CH0B", bytes: [2]), .init(key: "CH0C", bytes: [2])],
                     "CH0B and CH0C take 0x02 together")
        suite.expect(BatteryChargeSMC.adapterWrites(.chie, disable: true) == [.init(key: "CHIE", bytes: [0x08])]
                        && BatteryChargeSMC.adapterWrites(.chie, disable: false) == [.init(key: "CHIE", bytes: [0])],
                     "CHIE takes 0x08 to switch the adapter off and 0 to switch it on")
        suite.expect(BatteryChargeSMC.isAllowed(.init(key: "ACLC", bytes: [0x03])),
                     "the MagSafe colors are allowed")
        for forbidden in [BatteryChargeSMC.Write(key: "F0Md", bytes: [1]),
                          .init(key: "CHIE", bytes: [0xff]),
                          .init(key: "CHTE", bytes: [2, 0, 0, 0]),
                          .init(key: "BCLM", bytes: [80]),
                          .init(key: "ACLC", bytes: [0x07])] {
            suite.expect(!BatteryChargeSMC.isAllowed(forbidden), "\(forbidden.key) \(forbidden.bytes) is never written")
        }
        suite.expect(BatteryChargeSMC.isActive([0, 0, 0, 1]) && !BatteryChargeSMC.isActive([0])
                        && !BatteryChargeSMC.isActive(nil),
                     "a key is active on any non-zero byte, an unreadable one is inactive")
    }

    private static func inhibitMode(_ suite: TestSuite) {
        let config = BatteryChargeConfig(enabled: true, limit: 80, sailing: 5)
        let below = decide(config, reading(60, charging: true), inhibitOnly)
        suite.expect(!below.inhibitCharging && below.state == .charging, "below the limit it charges to the limit")
        let reached = decide(config, reading(80), inhibitOnly)
        suite.expect(reached.inhibitCharging && !reached.disableAdapter && reached.state == .limited
                        && reached.memory.holding,
                     "at the limit the charger stops and the adapter keeps the Mac running")
        let drifting = decide(config, reading(77, inhibited: true), inhibitOnly, memory: reached.memory)
        suite.expect(drifting.inhibitCharging && drifting.state == .limited,
                     "inside the sailing drift it stays stopped instead of micro-charging")
        let resumed = decide(config, reading(75, inhibited: true), inhibitOnly, memory: drifting.memory)
        suite.expect(!resumed.inhibitCharging && !resumed.memory.holding,
                     "at the bottom of the drift charging resumes")
        let climbing = decide(config, reading(78, charging: true), inhibitOnly, memory: resumed.memory)
        suite.expect(!climbing.inhibitCharging && climbing.state == .charging,
                     "and keeps going until the limit again")
        let noSailing = BatteryChargeConfig(enabled: true, limit: 80, sailing: 0)
        suite.expect(!decide(noSailing, reading(79, inhibited: true), inhibitOnly,
                             memory: BatteryChargeMemory(holding: true)).inhibitCharging,
                     "with sailing off it resumes one percent below the limit")

        let above = reading(92)
        suite.expect(decide(config, above, inhibitAndAdapter).disableAdapter == false
                        && decide(config, above, inhibitAndAdapter).state == .limited,
                     "above the limit it only holds unless discharging is on")
        var discharging = config
        discharging.dischargeToLimit = true
        let down = decide(discharging, above, inhibitAndAdapter)
        suite.expect(down.disableAdapter && down.inhibitCharging && down.state == .discharging,
                     "discharging runs the Mac from the battery while above the limit")
        let arrived = decide(discharging, reading(80, inhibited: true, adapterOff: true), inhibitAndAdapter,
                             memory: down.memory)
        suite.expect(!arrived.disableAdapter && arrived.inhibitCharging && arrived.state == .limited,
                     "at the limit the adapter comes back and the charger stays stopped")
        suite.expect(!decide(discharging, above, inhibitOnly).disableAdapter,
                     "without an adapter key there is nothing to discharge with")

        let unplugged = decide(config, reading(85, plugged: false), inhibitOnly)
        suite.expect(unplugged.state == .onBattery && !unplugged.disableAdapter, "unplugged it just reports the battery")
        let floor = decide(config, reading(15, inhibited: true), inhibitOnly, memory: BatteryChargeMemory(holding: true))
        suite.expect(!floor.inhibitCharging && !floor.disableAdapter,
                     "below the safety floor it always charges")
        let noLimit = decide(BatteryChargeConfig(enabled: true, limit: 100), reading(99), inhibitOnly)
        suite.expect(!noLimit.inhibitCharging, "a limit of 100% never stops the charger")
        let heldByMacOS = decide(config, reading(70, charging: false), inhibitOnly)
        suite.expect(heldByMacOS.state == .notCharging && !heldByMacOS.inhibitCharging,
                     "allowed to charge but not charging is macOS holding it, and says so")
    }

    private static func adapterMode(_ suite: TestSuite) {
        let config = BatteryChargeConfig(enabled: true, limit: 80, sailing: 5)
        let start = decide(config, reading(95), adapterOnly)
        suite.expect(start.disableAdapter && !start.inhibitCharging && start.state == .discharging,
                     "above the limit the adapter goes off, as nothing else can stop the charge")
        let atLimit = decide(config, reading(80, adapterOff: true), adapterOnly, memory: start.memory)
        suite.expect(atLimit.disableAdapter && atLimit.state == .limited,
                     "at the limit it keeps sailing down on the battery")
        let bottom = decide(config, reading(75, plugged: false, adapterOff: true), adapterOnly, memory: atLimit.memory)
        suite.expect(!bottom.disableAdapter && !bottom.memory.holding,
                     "at the bottom of the drift the adapter comes back on, even when its connection is not reported")
        let charging = decide(config, reading(78, charging: true), adapterOnly, memory: bottom.memory)
        suite.expect(!charging.disableAdapter && charging.state == .charging, "and the battery charges back to the limit")
        let tight = BatteryChargeConfig(enabled: true, limit: 80, sailing: 0)
        suite.expect(BatteryChargePolicy.resumeLevel(tight, capabilities: adapterOnly) == 77
                        && BatteryChargePolicy.resumeLevel(tight, capabilities: inhibitOnly) == 79,
                     "switching the adapter never cycles the battery in a band under three percent")
        let unplugged = decide(config, reading(90, plugged: false), adapterOnly)
        suite.expect(!unplugged.disableAdapter && unplugged.state == .onBattery,
                     "with no adapter connected there is nothing to switch off")
        let led = decide(BatteryChargeConfig(enabled: true, magSafeLED: true), reading(80, adapterOff: true), adapterOnly,
                         memory: BatteryChargeMemory(holding: true))
        suite.expect(led.led == .green, "the MagSafe light shows green while the limit holds")
        suite.expect(decide(config, reading(82), adapterOnly).led == nil, "the light is left alone unless asked for")
    }

    private static func heat(_ suite: TestSuite) {
        let config = BatteryChargeConfig(enabled: true, limit: 80, heatThreshold: 35)
        let hot = decide(config, reading(50, charging: true, temperature: 36), inhibitOnly)
        suite.expect(hot.inhibitCharging && hot.state == .pausedHot && hot.memory.hot,
                     "a hot battery pauses charging")
        let cooling = decide(config, reading(50, temperature: 34, inhibited: true), inhibitOnly, memory: hot.memory)
        suite.expect(cooling.inhibitCharging && cooling.state == .pausedHot,
                     "a degree under the threshold is not cool enough yet")
        let cooled = decide(config, reading(50, temperature: 33, inhibited: true), inhibitOnly, memory: cooling.memory)
        suite.expect(!cooled.inhibitCharging && !cooled.memory.hot, "two degrees under, charging resumes")
        let adapterHot = decide(config, reading(50, temperature: 40), adapterOnly)
        suite.expect(adapterHot.disableAdapter && adapterHot.state == .pausedHot,
                     "without a charge key the adapter goes off to stop the heat")
        let drained = decide(config, reading(BatteryChargePolicy.adapterHeatFloor, temperature: 40, adapterOff: true),
                             adapterOnly)
        suite.expect(!drained.disableAdapter && drained.memory.hot,
                     "a heat pause on the battery ends at its floor instead of draining under load")
        var off = config
        off.heatProtection = false
        suite.expect(!decide(off, reading(50, temperature: 45), inhibitOnly).inhibitCharging,
                     "heat protection off ignores the temperature")
        suite.expect(!decide(config, reading(50, temperature: nil), inhibitOnly).inhibitCharging,
                     "no temperature reading is not a hot battery")
        suite.expect(!decide(config, reading(18, temperature: 45), inhibitOnly).inhibitCharging,
                     "the safety floor wins over heat")
    }

    private static func topUp(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var config = BatteryChargeConfig(enabled: true, limit: 80)
        config.topUp = BatteryChargeTopUp(token: "abc", requestedAt: now.timeIntervalSince1970 - 60)
        suite.expect(BatteryChargePolicy.topUpActive(config, completedToken: nil, now: now),
                     "a fresh top-up is active")
        suite.expect(!BatteryChargePolicy.topUpActive(config, completedToken: "abc", now: now),
                     "a finished top-up is not repeated")
        suite.expect(!BatteryChargePolicy.topUpActive(config, completedToken: nil,
                                                     now: now.addingTimeInterval(BatteryChargeConfig.topUpMaximumAge)),
                     "a forgotten top-up ends on its own")
        var disabled = config
        disabled.enabled = false
        suite.expect(!BatteryChargePolicy.topUpActive(disabled, completedToken: nil, now: now),
                     "no top-up while the feature is off")
        let decision = decide(config, reading(85, inhibited: true), inhibitOnly,
                              memory: BatteryChargeMemory(holding: true), topUp: true)
        suite.expect(!decision.inhibitCharging && decision.state == .toppingUp && !decision.memory.holding,
                     "a top-up charges past the limit")
        let afterwards = decide(config, reading(100), adapterOnly, memory: decision.memory)
        suite.expect(afterwards.disableAdapter && afterwards.state == .discharging,
                     "once full it goes back down to the limit")
        let hotTopUp = decide(BatteryChargeConfig(enabled: true), reading(85, temperature: 40), inhibitOnly, topUp: true)
        suite.expect(hotTopUp.state == .pausedHot, "a top-up still waits for a hot battery to cool")
    }

    private static func sleep(_ suite: TestSuite) {
        let config = BatteryChargeConfig(enabled: true, limit: 80, sailing: 5)
        let inDrift = BatteryChargePolicy.beforeSleep(config: config, reading: reading(76, charging: true),
                                                      capabilities: inhibitAndAdapter,
                                                      memory: BatteryChargeMemory(), topUpActive: false)
        suite.expect(inDrift.inhibitCharging && !inDrift.disableAdapter,
                     "before sleep, at or above limit minus sailing, charging is stopped and the adapter stays on")
        let low = BatteryChargePolicy.beforeSleep(config: config, reading: reading(70, charging: true),
                                                  capabilities: inhibitAndAdapter,
                                                  memory: BatteryChargeMemory(), topUpActive: false)
        suite.expect(!low.inhibitCharging, "below the drift it may charge while asleep")
        var discharging = config
        discharging.dischargeToLimit = true
        let wasDischarging = BatteryChargePolicy.beforeSleep(config: discharging, reading: reading(90),
                                                             capabilities: inhibitAndAdapter,
                                                             memory: BatteryChargeMemory(), topUpActive: false)
        suite.expect(wasDischarging.inhibitCharging && !wasDischarging.disableAdapter,
                     "a discharge stops for sleep: the Mac sleeps on the adapter, holding its level")
        let adapter = BatteryChargePolicy.beforeSleep(config: config, reading: reading(78, charging: true),
                                                      capabilities: adapterOnly,
                                                      memory: BatteryChargeMemory(), topUpActive: false)
        suite.expect(adapter.disableAdapter, "with only the adapter key the Mac sleeps on its battery above the drift")
        let topUp = BatteryChargePolicy.beforeSleep(config: config, reading: reading(85, charging: true),
                                                    capabilities: inhibitOnly,
                                                    memory: BatteryChargeMemory(), topUpActive: true)
        suite.expect(!topUp.inhibitCharging, "a top-up keeps charging through sleep")
    }

    private static func statusAndInstall(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let status = BatteryChargeStatus(updatedAt: now.timeIntervalSince1970 - 10, state: .limited, mode: .adapter,
                                         limit: 80, percent: 80, isCharging: false, pluggedIn: true,
                                         temperature: 30, chargingInhibited: false, adapterDisabled: true,
                                         keys: ["CHIE"], memory: BatteryChargeMemory(holding: true),
                                         completedTopUpToken: nil, lastError: nil)
        suite.expect(BatteryChargeStatus.decode(status.encoded()) == status, "the status survives the file")
        suite.expect(BatteryChargeSupport.helperState(installed: true, matchesBundle: true, status: status, now: now) == .running
                        && BatteryChargeSupport.helperState(installed: true, matchesBundle: true, status: status,
                                                            now: now.addingTimeInterval(600)) == .notResponding
                        && BatteryChargeSupport.helperState(installed: true, matchesBundle: false, status: status, now: now) == .needsUpdate
                        && BatteryChargeSupport.helperState(installed: false, matchesBundle: false, status: status, now: now) == .notInstalled,
                     "the helper reads as running only with a fresh status from the installed build")
        suite.expect(BatteryChargeSupport.label(.limited, limit: 80) == "Limited at 80%"
                        && BatteryChargeSupport.label(.charging, limit: 80) == "Charging to 80%"
                        && BatteryChargeSupport.label(.pausedHot, limit: 80) == "Paused: hot"
                        && BatteryChargeSupport.label(.discharging, limit: 80) == "Discharging to 80%"
                        && BatteryChargeSupport.label(.toppingUp, limit: 80) == "Topping up",
                     "the panel names each state")

        let plist = BatteryChargeSupport.launchdPlist(configPath: "/Users/me/Library/Application Support/x/battery-charge.json",
                                                      ownerUID: 501)
        suite.expect(plist["Label"] as? String == BatteryChargeIdentifiers.daemonLabel
                        && (plist["ProgramArguments"] as? [String])?.first == BatteryChargeIdentifiers.installedBinaryPath
                        && (plist["ProgramArguments"] as? [String])?.contains("501") == true
                        && plist["KeepAlive"] as? Bool == true,
                     "the daemon starts from /Library with its configuration and owner")
        let install = BatteryChargeSupport.installCommand(bundledBinary: "/Applications/Vorssaint (Developer).app/x",
                                                          plistData: Data("<plist/>".utf8))
        suite.expect(install.contains("'/Applications/Vorssaint (Developer).app/x'")
                        && install.contains("install -o root -g wheel -m 0755")
                        && install.contains("base64 -D")
                        && install.hasSuffix("/bin/launchctl bootstrap system '\(BatteryChargeIdentifiers.installedPlistPath)'"),
                     "install copies a root-owned binary and definition, then starts the daemon")
        let uninstall = BatteryChargeSupport.uninstallCommand()
        suite.expect(uninstall.hasPrefix("(/bin/launchctl bootout system/\(BatteryChargeIdentifiers.daemonLabel)")
                        && uninstall.contains("--restore")
                        && uninstall.contains("/bin/rm -f '\(BatteryChargeIdentifiers.installedPlistPath)'"),
                     "uninstall stops the daemon, restores the charger and removes its files")
        suite.expect(BatteryChargeSupport.quoted("it's") == #"'it'\''s'"#, "paths are quoted for the shell")
    }

    private static func preferences(_ suite: TestSuite) {
        let suiteName = "com.vorssaint.tests.battery-charge.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.register(defaults: BatteryChargePreferences.registeredDefaults)
        suite.expect(BatteryChargePreferences.config(in: defaults, available: true)
                        == BatteryChargeConfig(enabled: false),
                     "the defaults are off, 80%, 5% sailing and 35 °C")
        defaults.set(true, forKey: DefaultsKey.batteryChargeEnabled)
        defaults.set(30, forKey: DefaultsKey.batteryChargeLimit)
        suite.expect(BatteryChargePreferences.config(in: defaults, available: true).enabled
                        && BatteryChargePreferences.config(in: defaults, available: true).limit == 50,
                     "a stored limit below 50% is clamped")
        suite.expect(!BatteryChargePreferences.config(in: defaults, available: false).enabled,
                     "an uninstalled feature sends the daemon an off configuration")
        let topUp = BatteryChargeTopUp(token: "t-1", requestedAt: 5)
        BatteryChargePreferences.setTopUp(topUp, in: defaults)
        suite.expect(BatteryChargePreferences.config(in: defaults, available: true).topUp == topUp,
                     "a requested top-up reaches the daemon")
        BatteryChargePreferences.setTopUp(nil, in: defaults)
        suite.expect(BatteryChargePreferences.topUp(in: defaults) == nil, "and can be cancelled")

        let exported = SettingsBackupSupport.exportKeys()
        suite.expect(exported.isSuperset(of: [DefaultsKey.batteryChargeEnabled, DefaultsKey.batteryChargeLimit,
                                              DefaultsKey.batteryChargeSailing, DefaultsKey.batteryChargeHeatProtection,
                                              DefaultsKey.batteryChargeHeatThreshold, DefaultsKey.batteryChargeDischarge,
                                              DefaultsKey.batteryChargeMagSafeLED]),
                     "the charge limit settings travel in a backup")
        suite.expect(!exported.contains(DefaultsKey.batteryChargeTopUp),
                     "a pending top-up belongs to one Mac and never travels")
        suite.expect(AppFeature.batteryCharge.group == .energyDisplay
                        && !AppFeature.batteryCharge.installedByDefault
                        && AppFeature.batteryCharge.enabledKeys == [DefaultsKey.batteryChargeEnabled]
                        && AppFeature.batteryCharge.permissions.isEmpty,
                     "the feature is an opt-in energy feature with no permissions")
    }
}
