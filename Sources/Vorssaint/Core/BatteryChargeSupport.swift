// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: Battery Charge Limit, in the spirit of AlDente. A small root daemon
// holds the battery at a chosen level by inhibiting the charger through the
// SMC, or, on firmware where Apple gated those keys (macOS 27 era), by
// switching the adapter off and on around the limit. The app only writes a
// small JSON configuration and reads the daemon's status back.
//
// This file is pure and shared three ways: the app, the daemon
// (Sources/BatteryChargeHelper) and the tests compile it. Every decision the
// daemon makes about the charger lives here, so the tests pin it without
// hardware. It must not reference anything app-only (DefaultsKey, L10n, UI).

enum BatteryChargeIdentifiers {
    #if VORSSAINT_DEVELOPMENT
    static let appBundleID = "com.vorssaint.utils.dev"
    #else
    static let appBundleID = "com.vorssaint.utils"
    #endif

    /// launchd label, binary name and code signing identifier of the daemon.
    static let daemonLabel = "\(appBundleID).battery"
    static let installedBinaryPath = "/Library/PrivilegedHelperTools/\(daemonLabel)"
    static let installedPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    /// Root-owned, world-readable: the daemon's status for the app.
    static let statusDirectory = "/Library/Application Support/\(daemonLabel)"
    static let statusPath = "\(statusDirectory)/status.json"
    /// Where build.sh puts the daemon inside the app bundle.
    static let bundledBinaryRelativePath = "Contents/Library/LaunchServices/\(daemonLabel)"
    /// Inside the app's own Application Support folder, written by the app.
    static let configFileName = "battery-charge.json"
    /// One lock for both app variants: only one daemon drives the charger.
    static let lockPath = "/var/run/vorssaint-battery-charge.lock"
}

// MARK: - Configuration (app -> daemon)

/// A one-shot "charge to 100% now". It ends when the battery is full, or
/// on its own after `BatteryChargeConfig.topUpMaximumAge`.
struct BatteryChargeTopUp: Codable, Equatable {
    var token: String
    /// Seconds since 1970.
    var requestedAt: Double
}

struct BatteryChargeConfig: Codable, Equatable {
    static let currentVersion = 1
    static let limitRange = 50...100
    static let sailingRange = 0...20
    static let heatThresholdRange = 25...50
    static let defaultLimit = 80
    static let defaultSailing = 5
    static let defaultHeatThreshold = 35
    /// The daemon never reads a bigger file.
    static let maximumFileSize = 16 * 1024
    static let topUpMaximumAge: TimeInterval = 12 * 3600

    var version: Int = currentVersion
    var enabled: Bool
    /// Percent the battery is held at. 100 means no limit.
    var limit: Int = defaultLimit
    /// How far the battery may drift below the limit before charging resumes.
    var sailing: Int = defaultSailing
    var heatProtection: Bool = true
    /// Degrees Celsius.
    var heatThreshold: Int = defaultHeatThreshold
    /// Run from the battery while it is above the limit on the adapter.
    var dischargeToLimit: Bool = false
    var magSafeLED: Bool = false
    var topUp: BatteryChargeTopUp?

    init(enabled: Bool, limit: Int = defaultLimit, sailing: Int = defaultSailing,
         heatProtection: Bool = true, heatThreshold: Int = defaultHeatThreshold,
         dischargeToLimit: Bool = false, magSafeLED: Bool = false, topUp: BatteryChargeTopUp? = nil) {
        self.enabled = enabled
        self.limit = limit
        self.sailing = sailing
        self.heatProtection = heatProtection
        self.heatThreshold = heatThreshold
        self.dischargeToLimit = dischargeToLimit
        self.magSafeLED = magSafeLED
        self.topUp = topUp
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, limit, sailing, heatProtection, heatThreshold, dischargeToLimit, magSafeLED, topUp
    }

    /// Only `version` and `enabled` are required; anything else missing
    /// takes its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        sailing = try container.decodeIfPresent(Int.self, forKey: .sailing) ?? Self.defaultSailing
        heatProtection = try container.decodeIfPresent(Bool.self, forKey: .heatProtection) ?? true
        heatThreshold = try container.decodeIfPresent(Int.self, forKey: .heatThreshold) ?? Self.defaultHeatThreshold
        dischargeToLimit = try container.decodeIfPresent(Bool.self, forKey: .dischargeToLimit) ?? false
        magSafeLED = try container.decodeIfPresent(Bool.self, forKey: .magSafeLED) ?? false
        topUp = try? container.decodeIfPresent(BatteryChargeTopUp.self, forKey: .topUp)
    }

    /// Every value pulled into its range; a top-up with a malformed token is
    /// dropped. The daemon trusts nothing else.
    func sanitized() -> BatteryChargeConfig {
        var copy = self
        copy.limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        copy.sailing = min(max(sailing, Self.sailingRange.lowerBound), Self.sailingRange.upperBound)
        copy.heatThreshold = min(max(heatThreshold, Self.heatThresholdRange.lowerBound),
                                 Self.heatThresholdRange.upperBound)
        if let topUp, !Self.isValidToken(topUp.token) || !topUp.requestedAt.isFinite {
            copy.topUp = nil
        }
        return copy
    }

    static func isValidToken(_ token: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return !token.isEmpty && token.count <= 64
            && token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// nil for anything that is not a well-formed configuration of this
    /// version: the daemon then restores the charger and waits.
    static func decode(_ data: Data) -> BatteryChargeConfig? {
        guard data.count <= maximumFileSize,
              let config = try? JSONDecoder().decode(BatteryChargeConfig.self, from: data),
              config.version == currentVersion else { return nil }
        return config.sanitized()
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The lowest level the battery drifts to before charging again.
    var resumeLevel: Int { limit - max(sailing, 1) }
}

// MARK: - Hardware capabilities

/// The key family that stops the charger while the Mac keeps running on the
/// adapter.
enum BatteryChargeInhibitFamily: String, Codable, Equatable {
    /// Apple Silicon on macOS 15 and later firmware: ui32, 1 inhibits.
    case chte
    /// Earlier Apple Silicon firmware: CH0B and CH0C, 0x02 inhibits.
    case ch0bc
}

/// The key family that switches the adapter off, so the Mac runs from the
/// battery while still plugged in.
enum BatteryChargeAdapterFamily: String, Codable, Equatable {
    /// macOS 15 and later firmware: 0x08 disables.
    case chie
    /// Earlier firmware: 0x01 disables.
    case ch0i
    case ch0j
}

enum BatteryChargeMode: String, Codable, Equatable {
    /// The charger itself can be stopped; the adapter keeps powering the Mac.
    case inhibit
    /// Only the adapter can be switched: the limit holds by running from the
    /// battery down to the resume level, then charging back up. This is all
    /// macOS 27 firmware leaves, as its charge keys need an Apple entitlement.
    case adapter
    case unsupported
}

struct BatteryChargeCapabilities: Codable, Equatable {
    var inhibit: BatteryChargeInhibitFamily?
    var adapter: BatteryChargeAdapterFamily?
    var magSafeLED: Bool = false

    var canInhibit: Bool { inhibit != nil }
    var canDisableAdapter: Bool { adapter != nil }

    var mode: BatteryChargeMode {
        if canInhibit { return .inhibit }
        if canDisableAdapter { return .adapter }
        return .unsupported
    }

    /// `size` answers the byte size of a key, nil when the key is absent.
    static func detect(size: (String) -> Int?) -> BatteryChargeCapabilities {
        var capabilities = BatteryChargeCapabilities()
        if size("CHTE") == 4 {
            capabilities.inhibit = .chte
        } else if size("CH0B") == 1, size("CH0C") == 1 {
            capabilities.inhibit = .ch0bc
        }
        if size("CHIE") == 1 {
            capabilities.adapter = .chie
        } else if size("CH0I") == 1 {
            capabilities.adapter = .ch0i
        } else if size("CH0J") == 1 {
            capabilities.adapter = .ch0j
        }
        capabilities.magSafeLED = size("ACLC") == 1
        return capabilities
    }
}

/// MagSafe light values of the ACLC key.
enum BatteryChargeLED: UInt8, Codable, Equatable {
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
}

/// The only SMC writes the daemon can make: charging-related keys with the
/// fixed byte patterns below. There is no entry point for any other key or
/// value.
enum BatteryChargeSMC {
    struct Write: Equatable {
        let key: String
        let bytes: [UInt8]
    }

    static let writableKeys: Set<String> = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "ACLC"]

    static func inhibitWrites(_ family: BatteryChargeInhibitFamily, inhibit: Bool) -> [Write] {
        switch family {
        case .chte: return [Write(key: "CHTE", bytes: inhibit ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00])]
        case .ch0bc:
            let value: UInt8 = inhibit ? 0x02 : 0x00
            return [Write(key: "CH0B", bytes: [value]), Write(key: "CH0C", bytes: [value])]
        }
    }

    static func adapterWrites(_ family: BatteryChargeAdapterFamily, disable: Bool) -> [Write] {
        switch family {
        case .chie: return [Write(key: "CHIE", bytes: [disable ? 0x08 : 0x00])]
        case .ch0i: return [Write(key: "CH0I", bytes: [disable ? 0x01 : 0x00])]
        case .ch0j: return [Write(key: "CH0J", bytes: [disable ? 0x01 : 0x00])]
        }
    }

    static func ledWrite(_ led: BatteryChargeLED) -> Write {
        Write(key: "ACLC", bytes: [led.rawValue])
    }

    static func inhibitKeys(_ family: BatteryChargeInhibitFamily) -> [String] {
        inhibitWrites(family, inhibit: false).map(\.key)
    }

    static func adapterKey(_ family: BatteryChargeAdapterFamily) -> String {
        adapterWrites(family, disable: false)[0].key
    }

    /// Whether a write is one of the patterns above. The hardware layer
    /// refuses anything else.
    static func isAllowed(_ write: Write) -> Bool {
        let families: [[Write]] = [
            inhibitWrites(.chte, inhibit: true), inhibitWrites(.chte, inhibit: false),
            inhibitWrites(.ch0bc, inhibit: true), inhibitWrites(.ch0bc, inhibit: false),
            adapterWrites(.chie, disable: true), adapterWrites(.chie, disable: false),
            adapterWrites(.ch0i, disable: true), adapterWrites(.ch0i, disable: false),
            adapterWrites(.ch0j, disable: true), adapterWrites(.ch0j, disable: false),
            [BatteryChargeLED.system, .off, .green, .orange].map(ledWrite),
        ]
        return families.contains { $0.contains(write) }
    }

    /// A read key is "active" (inhibiting, or adapter off) on any non-zero
    /// byte; a key that cannot be read counts as inactive.
    static func isActive(_ bytes: [UInt8]?) -> Bool {
        bytes?.contains { $0 != 0 } ?? false
    }
}

// MARK: - Decisions

enum BatteryChargeState: String, Codable, Equatable {
    case off
    case limited
    case charging
    case notCharging
    case pausedHot
    case discharging
    case toppingUp
    case onBattery
    case unsupported
    case waiting
}

/// What the daemon reads each time it decides.
struct BatteryChargeReading: Equatable {
    var percent: Int
    var isCharging: Bool
    /// An adapter is connected (it may still be switched off by the daemon).
    var pluggedIn: Bool
    /// Degrees Celsius; nil when no sensor answered.
    var temperature: Double?
    /// The SMC says the charger is inhibited right now.
    var chargingInhibited: Bool
    /// The SMC says the adapter is switched off right now.
    var adapterDisabled: Bool
}

/// The few things a decision carries over to the next one.
struct BatteryChargeMemory: Codable, Equatable {
    /// Reached the limit and drifting down to the resume level.
    var holding = false
    /// Above the heat threshold, until it cools a little below it.
    var hot = false
}

struct BatteryChargeDecision: Equatable {
    var inhibitCharging: Bool
    var disableAdapter: Bool
    var state: BatteryChargeState
    var memory: BatteryChargeMemory
    /// nil leaves the MagSafe light to macOS.
    var led: BatteryChargeLED?

    static func allow(_ state: BatteryChargeState, memory: BatteryChargeMemory = BatteryChargeMemory()) -> Self {
        BatteryChargeDecision(inhibitCharging: false, disableAdapter: false, state: state,
                              memory: memory, led: nil)
    }
}

enum BatteryChargePolicy {
    /// Below this the battery always charges, whatever the configuration.
    static let safetyFloor = 20
    /// Cooling this far below the threshold ends a heat pause.
    static let heatHysteresis = 2.0
    /// Holding the limit by switching the adapter cycles the battery, so the
    /// drift is never narrower than this: fewer switches, fewer cycles.
    static let adapterMinimumSailing = 3
    /// Where only the adapter switches, a heat pause runs the Mac from its
    /// battery; below this level it charges again even while hot, rather
    /// than drain under a heavy load.
    static let adapterHeatFloor = 40

    /// The drift the decision actually uses.
    static func effectiveSailing(_ config: BatteryChargeConfig,
                                 capabilities: BatteryChargeCapabilities) -> Int {
        capabilities.mode == .adapter ? max(config.sailing, adapterMinimumSailing) : config.sailing
    }

    static func resumeLevel(_ config: BatteryChargeConfig,
                            capabilities: BatteryChargeCapabilities) -> Int {
        config.limit - max(effectiveSailing(config, capabilities: capabilities), 1)
    }

    static func topUpActive(_ config: BatteryChargeConfig?, completedToken: String?, now: Date) -> Bool {
        guard let config, config.enabled, let topUp = config.topUp,
              topUp.token != completedToken else { return false }
        let age = now.timeIntervalSince1970 - topUp.requestedAt
        return age > -300 && age < BatteryChargeConfig.topUpMaximumAge
    }

    /// The state machine: what the charger and adapter should be doing now.
    static func decide(config: BatteryChargeConfig?,
                       reading: BatteryChargeReading,
                       capabilities: BatteryChargeCapabilities,
                       memory: BatteryChargeMemory,
                       topUpActive: Bool) -> BatteryChargeDecision {
        guard let config, config.enabled else { return .allow(.off) }
        guard capabilities.mode != .unsupported else { return .allow(.unsupported) }

        // An adapter the daemon switched off still counts as plugged in; the
        // connection may not report it while it is off.
        let powered = reading.pluggedIn || reading.adapterDisabled
        let percent = reading.percent
        var next = memory

        if config.heatProtection, let temperature = reading.temperature {
            if temperature >= Double(config.heatThreshold) {
                next.hot = true
            } else if temperature <= Double(config.heatThreshold) - heatHysteresis {
                next.hot = false
            }
        } else {
            next.hot = false
        }
        let resume = resumeLevel(config, capabilities: capabilities)
        if percent >= config.limit {
            next.holding = true
        } else if percent <= resume {
            next.holding = false
        }

        func led(_ state: BatteryChargeState) -> BatteryChargeLED? {
            guard config.magSafeLED, capabilities.magSafeLED, reading.pluggedIn else { return nil }
            switch state {
            case .charging, .toppingUp, .notCharging: return .orange
            case .limited, .pausedHot: return .green
            case .discharging: return .off
            default: return .system
            }
        }
        func decision(inhibit: Bool, disable: Bool, _ state: BatteryChargeState) -> BatteryChargeDecision {
            BatteryChargeDecision(inhibitCharging: inhibit, disableAdapter: disable, state: state,
                                  memory: next, led: led(state))
        }
        func chargingState() -> BatteryChargeState {
            guard powered else { return .onBattery }
            // Allowed to charge, yet not charging: macOS itself is holding it
            // (its own Charge Limit, Optimized Charging, or a full battery).
            return reading.pluggedIn && !reading.isCharging && percent < 100 ? .notCharging : .charging
        }

        if percent <= safetyFloor {
            next.holding = false
            return decision(inhibit: false, disable: false, chargingState())
        }
        if next.hot && powered {
            if capabilities.canInhibit { return decision(inhibit: true, disable: false, .pausedHot) }
            if percent > adapterHeatFloor { return decision(inhibit: false, disable: true, .pausedHot) }
        }
        if topUpActive {
            next.holding = false
            return decision(inhibit: false, disable: false, powered ? .toppingUp : .onBattery)
        }
        if config.limit >= 100 {
            next.holding = false
            return decision(inhibit: false, disable: false, chargingState())
        }

        switch capabilities.mode {
        case .inhibit:
            if powered, config.dischargeToLimit, capabilities.canDisableAdapter, percent > config.limit {
                return decision(inhibit: true, disable: true, .discharging)
            }
            if next.holding {
                return decision(inhibit: true, disable: false, powered ? .limited : .onBattery)
            }
            return decision(inhibit: false, disable: false, chargingState())
        case .adapter:
            if next.holding && powered {
                return decision(inhibit: false, disable: true, percent > config.limit ? .discharging : .limited)
            }
            if next.holding { return decision(inhibit: false, disable: false, .onBattery) }
            return decision(inhibit: false, disable: false, chargingState())
        case .unsupported:
            return .allow(.unsupported)
        }
    }

    /// Just before sleep the daemon cannot watch the level, so the charger
    /// is left in a state that needs no watching: at or above the resume
    /// level it stays stopped (the adapter powers the Mac where the charger
    /// can be inhibited; where only the adapter switches, the Mac sleeps on
    /// its battery). Below it, charging is allowed.
    static func beforeSleep(config: BatteryChargeConfig?,
                            reading: BatteryChargeReading,
                            capabilities: BatteryChargeCapabilities,
                            memory: BatteryChargeMemory,
                            topUpActive: Bool) -> BatteryChargeDecision {
        var awake = decide(config: config, reading: reading, capabilities: capabilities,
                           memory: memory, topUpActive: topUpActive)
        guard let config, config.enabled, config.limit < 100, !topUpActive,
              reading.percent > safetyFloor, awake.state != .unsupported else { return awake }
        let holds = reading.percent >= resumeLevel(config, capabilities: capabilities)
        switch capabilities.mode {
        case .inhibit:
            awake.inhibitCharging = holds || awake.state == .pausedHot
            awake.disableAdapter = false
        case .adapter:
            let powered = reading.pluggedIn || reading.adapterDisabled
            awake.disableAdapter = powered && (holds || awake.state == .pausedHot)
        case .unsupported:
            break
        }
        return awake
    }

    /// Whether the read state already matches the decision.
    static func needsWrite(_ decision: BatteryChargeDecision, reading: BatteryChargeReading,
                           capabilities: BatteryChargeCapabilities) -> (inhibit: Bool, adapter: Bool) {
        (capabilities.canInhibit && decision.inhibitCharging != reading.chargingInhibited,
         capabilities.canDisableAdapter && decision.disableAdapter != reading.adapterDisabled)
    }
}

// MARK: - Status (daemon -> app)

struct BatteryChargeStatus: Codable, Equatable {
    static let currentVersion = 1
    /// After this long without a fresh status the daemon is not answering.
    static let staleAfter: TimeInterval = 180

    var version: Int = currentVersion
    /// Seconds since 1970.
    var updatedAt: Double
    var state: BatteryChargeState
    var mode: BatteryChargeMode
    var limit: Int?
    var percent: Int?
    var isCharging: Bool?
    var pluggedIn: Bool?
    var temperature: Double?
    var chargingInhibited: Bool
    var adapterDisabled: Bool
    /// Charging-related SMC keys this Mac exposes to the daemon.
    var keys: [String]
    var memory: BatteryChargeMemory
    var completedTopUpToken: String?
    var lastError: String?

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince1970 - updatedAt > Self.staleAfter
    }

    static func decode(_ data: Data) -> BatteryChargeStatus? {
        guard data.count <= 64 * 1024,
              let status = try? JSONDecoder().decode(BatteryChargeStatus.self, from: data),
              status.version == currentVersion else { return nil }
        return status
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data()
    }
}

// MARK: - App-side presentation and install plumbing

enum BatteryChargeHelperState: Equatable {
    case notInstalled
    /// Installed from another build of the app.
    case needsUpdate
    case notResponding
    case running
}

enum BatteryChargeSupport {
    static let title = "Charge Limit"
    static let hubDescription = "Keeps the battery at a level you choose, 80% by default, so it does not sit at 100% on the adapter. Pauses charging while the battery is hot and can top up to full when you need it."

    /// The words the panel and Settings show for a state.
    static func label(_ state: BatteryChargeState, limit: Int) -> String {
        switch state {
        case .off: return "Off"
        case .limited: return "Limited at \(limit)%"
        case .charging: return limit >= 100 ? "Charging" : "Charging to \(limit)%"
        case .notCharging: return "Not charging (held by macOS)"
        case .pausedHot: return "Paused: hot"
        case .discharging: return "Discharging to \(limit)%"
        case .toppingUp: return "Topping up"
        case .onBattery: return "On battery"
        case .unsupported: return "Not supported on this Mac"
        case .waiting: return "Waiting for another battery helper"
        }
    }

    static func helperState(installed: Bool, matchesBundle: Bool,
                            status: BatteryChargeStatus?, now: Date) -> BatteryChargeHelperState {
        guard installed else { return .notInstalled }
        guard matchesBundle else { return .needsUpdate }
        guard let status, !status.isStale(now: now) else { return .notResponding }
        return .running
    }

    /// The daemon's launchd definition. The configuration path and its
    /// owner are fixed at install time; the daemon reads nothing else.
    static func launchdPlist(configPath: String, ownerUID: UInt32) -> [String: Any] {
        [
            "Label": BatteryChargeIdentifiers.daemonLabel,
            "ProgramArguments": [BatteryChargeIdentifiers.installedBinaryPath,
                                 "--config", configPath, "--owner", String(ownerUID)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ExitTimeOut": 20,
        ]
    }

    /// One administrator batch: copies the daemon out of the bundle, writes
    /// its definition and starts it. An older copy is stopped first, which
    /// makes it restore the charger before the new one takes over.
    /// The definition travels as base64, so no quoting can change it.
    static func installCommand(bundledBinary: String, plistData: Data) -> String {
        let label = BatteryChargeIdentifiers.daemonLabel
        let binary = BatteryChargeIdentifiers.installedBinaryPath
        let plist = BatteryChargeIdentifiers.installedPlistPath
        let status = BatteryChargeIdentifiers.statusDirectory
        return [
            "(/bin/launchctl bootout system/\(label) 2>/dev/null || true)",
            "/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons \(quoted(status))",
            "/usr/sbin/chown root:wheel \(quoted(status))",
            "/bin/chmod 0755 \(quoted(status))",
            "/usr/bin/install -o root -g wheel -m 0755 \(quoted(bundledBinary)) \(quoted(binary))",
            "/usr/bin/printf '%s' \(quoted(plistData.base64EncodedString())) | /usr/bin/base64 -D > \(quoted(plist))",
            "/usr/sbin/chown root:wheel \(quoted(plist))",
            "/bin/chmod 0644 \(quoted(plist))",
            "/bin/launchctl bootstrap system \(quoted(plist))",
        ].joined(separator: " && ")
    }

    /// Stops the daemon (it restores the charger on the way out), restores
    /// once more through the binary itself, then removes every file.
    static func uninstallCommand() -> String {
        let label = BatteryChargeIdentifiers.daemonLabel
        let binary = quoted(BatteryChargeIdentifiers.installedBinaryPath)
        return [
            "(/bin/launchctl bootout system/\(label) 2>/dev/null || true)",
            "([ -x \(binary) ] && \(binary) --restore >/dev/null 2>&1 || true)",
            "/bin/rm -f \(quoted(BatteryChargeIdentifiers.installedPlistPath)) \(binary)",
            "/bin/rm -rf \(quoted(BatteryChargeIdentifiers.statusDirectory))",
        ].joined(separator: " ; ")
    }

    /// Single-quoted for /bin/sh, safe for any text.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
