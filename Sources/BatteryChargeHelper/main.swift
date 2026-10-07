// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

// Fork: the Charge Limit daemon. Runs as root from /Library/LaunchDaemons so
// the limit holds while the app is quit and around sleep, the way AlDente's
// helper does. It reads one small JSON file the app writes (validated and
// clamped; nothing in it names a key or a value), decides through
// `BatteryChargePolicy`, and writes only the charging keys of
// `BatteryChargeSMC`. Whenever the configuration is missing, invalid or off,
// and on every way out, the charger is restored: charging allowed, adapter on.
//
//   --config <path> --owner <uid>   run (root)
//   --restore                       restore the charger and exit (root)
//   --probe [--config <path>]       print what it sees and would do; never writes
//   --selftest                      check the pure policy and exit

private let log = Logger(subsystem: BatteryChargeIdentifiers.daemonLabel, category: "BatteryCharge")

private func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Reads the configuration only if it is a small regular file owned by the
/// person who installed the daemon, and never through a symbolic link.
private func readConfigData(path: String, owner: uid_t?) -> Data? {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size <= off_t(BatteryChargeConfig.maximumFileSize) else { return nil }
    if let owner, info.st_uid != owner, info.st_uid != 0 { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    guard count == Int(info.st_size) else { return nil }
    return Data(buffer)
}

private final class BatteryChargeController {
    private let hardware: BatteryChargeHardware
    private let configPath: String
    private let owner: uid_t
    private var memory = BatteryChargeMemory()
    private var completedTopUpToken: String?
    private var lastError: String?
    private var lockDescriptor: Int32 = -1
    /// The charger was put back to defaults since the last active decision,
    /// so an idle daemon never fights another tool over the keys.
    private var restoredForIdle = false
    private var ledTouched = false
    private var timer: Timer?
    private var configWatch: DispatchSourceFileSystemObject?
    private var pendingTick: DispatchWorkItem?
    /// Set between "will sleep" and "powered on"; a wake that never
    /// reported itself does not keep the daemon quiet for long.
    private var sleepingSince: Date?
    private var lastLED: BatteryChargeLED?
    private(set) var lastState: BatteryChargeState = .off

    init(hardware: BatteryChargeHardware, configPath: String, owner: uid_t) {
        self.hardware = hardware
        self.configPath = configPath
        self.owner = owner
        if let data = FileManager.default.contents(atPath: BatteryChargeIdentifiers.statusPath),
           let previous = BatteryChargeStatus.decode(data) {
            memory = previous.memory
            completedTopUpToken = previous.completedTopUpToken
        }
    }

    // MARK: Lifecycle

    func start() {
        watchConfig()
        scheduleTimer(interval: 30)
        tick(reason: "start")
    }

    /// Only one daemon (the release or the Developer app's) drives the
    /// charger; another one waits and retries.
    private func holdLock() -> Bool {
        if lockDescriptor >= 0 { return true }
        let descriptor = open(BatteryChargeIdentifiers.lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o600))
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    func shutdown() {
        if lockDescriptor >= 0 {
            let failures = hardware.restore(led: ledTouched)
            if !failures.isEmpty { log.error("restore on exit: \(failures.joined(separator: ", "), privacy: .public)") }
            lastError = failures.isEmpty ? nil : failures.joined(separator: ", ")
            writeStatus(state: .off, reading: hardware.reading(), config: nil)
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick(reason: "timer")
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Writes to the app's folder (an atomic save renames into it) wake the
    /// daemon at once instead of at the next timer.
    private func watchConfig() {
        let directory = (configPath as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.requestTick(after: 0.5, reason: "config") }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        configWatch = source
    }

    func requestTick(after delay: TimeInterval, reason: String) {
        pendingTick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick(reason: reason) }
        pendingTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Deciding

    private func loadConfig() -> BatteryChargeConfig? {
        guard let data = readConfigData(path: configPath, owner: owner) else { return nil }
        return BatteryChargeConfig.decode(data)
    }

    func tick(reason: String) {
        if let sleepingSince {
            guard Date().timeIntervalSince(sleepingSince) > 120 else { return }
            self.sleepingSince = nil
        }
        let config = loadConfig()
        guard holdLock() else {
            writeStatus(state: .waiting, reading: hardware.reading(), config: config)
            scheduleTimer(interval: 60)
            return
        }
        guard let reading = hardware.reading() else {
            // Nothing to decide with: never leave the charger stopped or the
            // adapter off on a guess.
            if !restoredForIdle {
                restoredForIdle = hardware.restore(led: ledTouched).isEmpty
            }
            lastError = "battery unreadable"
            writeStatus(state: .unsupported, reading: nil, config: config)
            return
        }
        guard let config, config.enabled else {
            idle(reading: reading, config: config)
            return
        }
        restoredForIdle = false
        scheduleTimer(interval: 30)
        let now = Date()
        let topUpActive = BatteryChargePolicy.topUpActive(config, completedToken: completedTopUpToken, now: now)
        if topUpActive, let token = config.topUp?.token, reading.percent >= 100 {
            completedTopUpToken = token
        }
        let active = topUpActive && completedTopUpToken != config.topUp?.token
        let decision = BatteryChargePolicy.decide(config: config, reading: reading,
                                                  capabilities: hardware.capabilities,
                                                  memory: memory, topUpActive: active)
        apply(decision, reading: reading, config: config)
        if lastState != decision.state {
            log.info("\(reason, privacy: .public): \(decision.state.rawValue, privacy: .public) at \(reading.percent)%")
        }
    }

    private func idle(reading: BatteryChargeReading, config: BatteryChargeConfig?) {
        memory = BatteryChargeMemory()
        if !restoredForIdle {
            let failures = hardware.restore(led: ledTouched)
            ledTouched = false
            lastLED = nil
            lastError = failures.isEmpty ? nil : failures.joined(separator: ", ")
            restoredForIdle = failures.isEmpty
        }
        scheduleTimer(interval: 60)
        writeStatus(state: .off, reading: hardware.reading() ?? reading, config: config)
    }

    private func apply(_ decision: BatteryChargeDecision, reading: BatteryChargeReading,
                       config: BatteryChargeConfig) {
        var failures: [String] = []
        let writes = BatteryChargePolicy.needsWrite(decision, reading: reading,
                                                    capabilities: hardware.capabilities)
        // The adapter goes back on before the charger is stopped, never the
        // other way round, so the Mac is never left with neither.
        if writes.adapter && !decision.disableAdapter {
            do { try hardware.setAdapterDisabled(false) } catch { failures.append("\(error)") }
        }
        if writes.inhibit {
            do { try hardware.setChargingInhibited(decision.inhibitCharging) } catch { failures.append("\(error)") }
        }
        if writes.adapter && decision.disableAdapter {
            do { try hardware.setAdapterDisabled(true) } catch { failures.append("\(error)") }
        }
        let led = decision.led ?? (ledTouched ? .system : nil)
        if let led, led != lastLED {
            do {
                try hardware.setLED(led)
                lastLED = led
                ledTouched = led != .system
            } catch { failures.append("\(error)") }
        }
        memory = decision.memory
        if !failures.isEmpty {
            log.error("write: \(failures.joined(separator: ", "), privacy: .public)")
            // A refused key changed the capabilities: decide again with what is left.
            if hardware.capabilities.mode != .unsupported, failures.count < 4 {
                requestTick(after: 2, reason: "retry")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: ", ")
        writeStatus(state: decision.state, reading: hardware.reading() ?? reading, config: config)
    }

    // MARK: Sleep

    func willSleep() {
        sleepingSince = Date()
        pendingTick?.cancel()
        guard lockDescriptor >= 0, let config = loadConfig(), config.enabled,
              let reading = hardware.reading() else { return }
        let topUpActive = BatteryChargePolicy.topUpActive(config, completedToken: completedTopUpToken, now: Date())
        let decision = BatteryChargePolicy.beforeSleep(config: config, reading: reading,
                                                       capabilities: hardware.capabilities,
                                                       memory: memory, topUpActive: topUpActive)
        apply(decision, reading: reading, config: config)
    }

    func didWake() {
        sleepingSince = nil
        requestTick(after: 3, reason: "wake")
    }

    // MARK: Status

    private func writeStatus(state: BatteryChargeState, reading: BatteryChargeReading?,
                             config: BatteryChargeConfig?) {
        lastState = state
        let status = BatteryChargeStatus(updatedAt: Date().timeIntervalSince1970,
                                         state: state,
                                         mode: hardware.capabilities.mode,
                                         limit: config?.limit,
                                         percent: reading?.percent,
                                         isCharging: reading?.isCharging,
                                         pluggedIn: reading?.pluggedIn,
                                         temperature: reading?.temperature,
                                         chargingInhibited: reading?.chargingInhibited ?? false,
                                         adapterDisabled: reading?.adapterDisabled ?? false,
                                         keys: hardware.detectedKeys,
                                         memory: memory,
                                         completedTopUpToken: completedTopUpToken,
                                         lastError: lastError)
        let directory = BatteryChargeIdentifiers.statusDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let temporary = directory + "/.status.json.tmp"
        let data = status.encoded()
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o644]) else { return }
        _ = rename(temporary, BatteryChargeIdentifiers.statusPath)
    }
}

// MARK: - Power notifications

private var controller: BatteryChargeController?
private var rootPort: io_connect_t = 0

// iokit_common_msg values, which Swift does not import.
private let messageCanSystemSleep: natural_t = 0xE000_0270
private let messageSystemWillSleep: natural_t = 0xE000_0280
private let messageSystemHasPoweredOn: natural_t = 0xE000_0300
private let messageSystemWillPowerOn: natural_t = 0xE000_0320

private func registerForSleep() {
    var notifier: io_object_t = 0
    let callback: IOServiceInterestCallback = { _, _, messageType, argument in
        switch messageType {
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemWillSleep:
            controller?.willSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemWillPowerOn, messageSystemHasPoweredOn:
            controller?.didWake()
        default:
            break
        }
    }
    var port: IONotificationPortRef?
    rootPort = IORegisterForSystemPower(nil, &port, callback, &notifier)
    if rootPort != 0, let port {
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    } else {
        log.error("IORegisterForSystemPower failed")
    }
}

/// Plugging in, unplugging and every percent the battery moves.
private func registerForPowerSources() {
    let callback: IOPowerSourceCallbackType = { _ in
        controller?.requestTick(after: 1, reason: "power")
    }
    guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}

// MARK: - Entry points

private func runSelfTest() -> Bool {
    let capabilities = BatteryChargeCapabilities(inhibit: nil, adapter: .chie, magSafeLED: true)
    let config = BatteryChargeConfig(enabled: true)
    let reading = BatteryChargeReading(percent: 85, isCharging: false, pluggedIn: true, temperature: 30,
                                       chargingInhibited: false, adapterDisabled: false)
    let decision = BatteryChargePolicy.decide(config: config, reading: reading, capabilities: capabilities,
                                              memory: BatteryChargeMemory(), topUpActive: false)
    guard BatteryChargeIdentifiers.daemonLabel.hasSuffix(".battery"),
          decision.disableAdapter, decision.state == .discharging,
          BatteryChargeSMC.isAllowed(.init(key: "CHIE", bytes: [0x08])),
          !BatteryChargeSMC.isAllowed(.init(key: "F0Md", bytes: [0x01])),
          BatteryChargeConfig.decode(Data("{\"version\":1,\"enabled\":true,\"limit\":5}".utf8))?.limit == 50
    else { return false }
    print("battery-charge-helper: ok")
    return true
}

/// Read-only: what this Mac exposes and what the daemon would do.
private func runProbe() -> Never {
    guard let hardware = BatteryChargeHardware(readOnly: true) else {
        print("AppleSMC unavailable")
        exit(EXIT_FAILURE)
    }
    print("keys:", hardware.detectedKeys.joined(separator: " "))
    for key in hardware.detectedKeys {
        let bytes = hardware.readBytes(key).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "unreadable"
        print("  \(key) = \(bytes)")
    }
    let capabilities = hardware.capabilities
    print("inhibit:", capabilities.inhibit?.rawValue ?? "none",
          "adapter:", capabilities.adapter?.rawValue ?? "none",
          "led:", capabilities.magSafeLED, "mode:", capabilities.mode.rawValue)
    guard let reading = hardware.reading() else {
        print("battery: unreadable")
        exit(EXIT_FAILURE)
    }
    print("battery:", "\(reading.percent)%", reading.isCharging ? "charging" : "not charging",
          reading.pluggedIn ? "plugged in" : "on battery",
          reading.temperature.map { String(format: "%.1f °C", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "no temperature",
          "inhibited:", reading.chargingInhibited, "adapter off:", reading.adapterDisabled)
    let config = argument(after: "--config")
        .flatMap { readConfigData(path: $0, owner: nil) }
        .flatMap(BatteryChargeConfig.decode)
        ?? BatteryChargeConfig(enabled: true)
    let decision = BatteryChargePolicy.decide(config: config, reading: reading, capabilities: capabilities,
                                              memory: BatteryChargeMemory(), topUpActive: false)
    print("with limit \(config.limit)%:", BatteryChargeSupport.label(decision.state, limit: config.limit),
          "- inhibit:", decision.inhibitCharging, "adapter off:", decision.disableAdapter)
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest() ? EXIT_SUCCESS : EXIT_FAILURE)
}
if CommandLine.arguments.contains("--probe") {
    runProbe()
}

guard geteuid() == 0 else {
    log.error("The battery charge helper must run as root")
    fputs("must run as root\n", stderr)
    exit(EXIT_FAILURE)
}

if CommandLine.arguments.contains("--restore") {
    guard let hardware = BatteryChargeHardware(readOnly: false) else { exit(EXIT_FAILURE) }
    let failures = hardware.restore()
    failures.forEach { fputs("\($0)\n", stderr) }
    exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
}

guard let configPath = argument(after: "--config"), configPath.hasPrefix("/"),
      let ownerText = argument(after: "--owner"), let ownerUID = uid_t(ownerText) else {
    log.error("Missing --config or --owner")
    exit(EXIT_FAILURE)
}
guard let hardware = BatteryChargeHardware(readOnly: false) else {
    log.error("AppleSMC unavailable")
    exit(EXIT_FAILURE)
}

controller = BatteryChargeController(hardware: hardware, configPath: configPath, owner: ownerUID)
registerForSleep()
registerForPowerSources()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    controller?.shutdown()
    exit(EXIT_SUCCESS)
}
termination.resume()
private let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruption.setEventHandler {
    controller?.shutdown()
    exit(EXIT_SUCCESS)
}
interruption.resume()

controller?.start()
RunLoop.main.run()
