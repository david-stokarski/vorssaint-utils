// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import IOKit
import IOKit.ps

/// Fork: the Charge Limit's only door to the hardware, on top of the shared
/// `SMCClient`. Compiled into the app (read-only, to tell whether this Mac
/// can do it at all) and into the root daemon (which writes).
///
/// Writes go through `BatteryChargeSMC.isAllowed`: charging-related keys and
/// their fixed patterns only. A key the firmware refuses (macOS 27 gates the
/// charge keys behind an Apple entitlement, even for root) is dropped from
/// the capabilities, so the daemon falls back to switching the adapter.
final class BatteryChargeHardware {
    struct Battery: Equatable {
        var percent: Int
        var isCharging: Bool
        var externalConnected: Bool
        var fullyCharged: Bool
        var temperature: Double?
    }

    private let client: SMCClient
    /// A read-only instance refuses every write.
    let readOnly: Bool
    private(set) var capabilities: BatteryChargeCapabilities
    private var temperatureKeys: [SMCClient.Key]?

    init?(readOnly: Bool) {
        guard let client = SMCClient() else { return nil }
        self.client = client
        self.readOnly = readOnly
        capabilities = BatteryChargeCapabilities.detect { name in
            client.key(named: name).map { Int($0.dataSize) }
        }
    }

    /// The charging-related keys this Mac exposes, for the status.
    var detectedKeys: [String] {
        BatteryChargeSMC.writableKeys.union(["AC-W"]).sorted().filter { client.key(named: $0) != nil }
    }

    func readBytes(_ name: String) -> [UInt8]? {
        guard let key = client.key(named: name) else { return nil }
        return client.readBytes(key)
    }

    var chargingInhibited: Bool {
        guard let family = capabilities.inhibit else { return false }
        return BatteryChargeSMC.inhibitKeys(family).contains { BatteryChargeSMC.isActive(readBytes($0)) }
    }

    var adapterDisabled: Bool {
        guard let family = capabilities.adapter else { return false }
        return BatteryChargeSMC.isActive(readBytes(BatteryChargeSMC.adapterKey(family)))
    }

    /// `AC-W` is positive while an adapter is connected.
    var adapterConnected: Bool? {
        guard let bytes = readBytes("AC-W"), bytes.count == 1 else { return nil }
        return Int8(bitPattern: bytes[0]) > 0
    }

    // MARK: - Battery

    static var hasInternalBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let installed = IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (installed as? Bool) != false
    }

    /// Whether the hub may install the feature: a battery and a key that
    /// can hold a limit.
    static let isSupported: Bool = {
        guard hasInternalBattery, let hardware = BatteryChargeHardware(readOnly: true) else { return false }
        return hardware.capabilities.mode != .unsupported
    }()

    /// The same AppleSmartBattery properties the system monitor reads.
    func readBattery() -> Battery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = properties?.takeRetainedValue() as? [String: Any],
              let capacity = props["CurrentCapacity"] as? Int,
              let maxCapacity = props["MaxCapacity"] as? Int, maxCapacity > 0 else { return nil }
        let percent = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
        // Either source is enough: the registry may drop the connection
        // while the adapter is switched off, the SMC key may be missing.
        let external = adapterConnected == true || ((props["ExternalConnected"] as? Bool) ?? false)
        return Battery(percent: min(max(percent, 0), 100),
                       isCharging: (props["IsCharging"] as? Bool) ?? false,
                       externalConnected: external,
                       fullyCharged: (props["FullyCharged"] as? Bool) ?? false,
                       temperature: batteryTemperature(fallback: props["Temperature"] as? Int))
    }

    /// The hottest battery cell sensor, as the system monitor reads it
    /// (`TB[0-9]T`, plausible range only). AppleSmartBattery's own reading,
    /// in hundredths of a degree, stands in when the SMC has none.
    func batteryTemperature(fallback centiDegrees: Int? = nil) -> Double? {
        if temperatureKeys == nil {
            temperatureKeys = client.keys { $0.range(of: "^TB[0-9]T$", options: .regularExpression) != nil }
        }
        let values = (temperatureKeys ?? []).compactMap { key -> Double? in
            guard let value = client.readValue(key), value > 1, value < 125 else { return nil }
            return value
        }
        if let hottest = values.max() { return hottest }
        guard let centiDegrees, centiDegrees > 100, centiDegrees < 12_500 else { return nil }
        return Double(centiDegrees) / 100
    }

    func reading() -> BatteryChargeReading? {
        guard let battery = readBattery() else { return nil }
        return BatteryChargeReading(percent: battery.percent,
                                    isCharging: battery.isCharging,
                                    pluggedIn: battery.externalConnected,
                                    temperature: battery.temperature,
                                    chargingInhibited: chargingInhibited,
                                    adapterDisabled: adapterDisabled)
    }

    // MARK: - Writes

    enum WriteFailure: Error, CustomStringConvertible {
        case readOnly
        case notAllowed(String)
        case missingKey(String)
        case refused(String, kern_return_t)
        case controller(String, UInt8)
        case invalid(String)

        var description: String {
            switch self {
            case .readOnly: return "read-only"
            case .notAllowed(let key): return "\(key): write not allowed"
            case .missingKey(let key): return "\(key): key missing"
            case .refused(let key, let code): return "\(key): refused (0x\(String(UInt32(bitPattern: code), radix: 16)))"
            case .controller(let key, let code): return "\(key): SMC error \(code)"
            case .invalid(let key): return "\(key): invalid payload"
            }
        }

        /// The firmware will never accept this key from us.
        var isPermanent: Bool {
            if case .refused(_, let code) = self { return code == kIOReturnNotPrivileged }
            if case .missingKey = self { return true }
            return false
        }
    }

    private func write(_ write: BatteryChargeSMC.Write) throws {
        guard !readOnly else { throw WriteFailure.readOnly }
        guard BatteryChargeSMC.isAllowed(write) else { throw WriteFailure.notAllowed(write.key) }
        guard let key = client.key(named: write.key) else { throw WriteFailure.missingKey(write.key) }
        do {
            try client.writeBytes(write.bytes, to: key)
        } catch SMCClient.WriteError.transport(let code) {
            throw WriteFailure.refused(write.key, code)
        } catch SMCClient.WriteError.controller(let code) {
            throw WriteFailure.controller(write.key, code)
        } catch {
            throw WriteFailure.invalid(write.key)
        }
    }

    /// Inhibits or allows charging. A key the firmware refuses for good is
    /// dropped, so the next decision falls back to the adapter.
    func setChargingInhibited(_ inhibit: Bool) throws {
        guard let family = capabilities.inhibit else { return }
        do {
            for item in BatteryChargeSMC.inhibitWrites(family, inhibit: inhibit) { try write(item) }
        } catch let failure as WriteFailure {
            if failure.isPermanent { capabilities.inhibit = nil }
            throw failure
        }
    }

    func setAdapterDisabled(_ disable: Bool) throws {
        guard let family = capabilities.adapter else { return }
        do {
            for item in BatteryChargeSMC.adapterWrites(family, disable: disable) { try write(item) }
        } catch let failure as WriteFailure {
            if failure.isPermanent { capabilities.adapter = nil }
            throw failure
        }
    }

    func setLED(_ led: BatteryChargeLED) throws {
        guard capabilities.magSafeLED else { return }
        do {
            try write(BatteryChargeSMC.ledWrite(led))
        } catch let failure as WriteFailure {
            if failure.isPermanent { capabilities.magSafeLED = false }
            throw failure
        }
    }

    /// The fail-safe: charging allowed, adapter on, MagSafe light back to
    /// macOS. Each step is tried even when an earlier one fails. Returns the
    /// failures, empty when everything is back.
    @discardableResult
    func restore(led: Bool = true) -> [String] {
        var failures: [String] = []
        // The adapter first: a Mac left running from its battery is the
        // state that matters most.
        if let family = capabilities.adapter {
            for item in BatteryChargeSMC.adapterWrites(family, disable: false) {
                do { try write(item) } catch { failures.append("\(error)") }
            }
        }
        if let family = capabilities.inhibit {
            for item in BatteryChargeSMC.inhibitWrites(family, inhibit: false) {
                do { try write(item) } catch { failures.append("\(error)") }
            }
        }
        if led, capabilities.magSafeLED {
            do { try write(BatteryChargeSMC.ledWrite(.system)) } catch { failures.append("\(error)") }
        }
        return failures
    }
}
