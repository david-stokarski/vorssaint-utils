// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Fork: the app's half of the Charge Limit. It never touches the SMC: it
/// writes the configuration the root daemon reads, installs and removes that
/// daemon with one administrator prompt each, and reads the daemon's status
/// back for Settings and the menu panel. At rest it does nothing; the status
/// is only polled while a view showing it is on screen.
///
/// Why a launch daemon rather than the fan helper's SMAppService route: that
/// helper only accepts an app signed by upstream's Developer ID team, which a
/// locally signed build can never be. A plain daemon in /Library, installed
/// by the person once, needs no code-signing trust between the two, and it
/// keeps the limit while the app is quit and around sleep.
final class BatteryChargeService: ObservableObject {
    static let shared = BatteryChargeService()

    @Published private(set) var status: BatteryChargeStatus?
    @Published private(set) var helperState: BatteryChargeHelperState = .notInstalled
    @Published private(set) var isWorking = false
    /// The last thing worth telling the person, nil when all went well.
    @Published var message: String?

    private var observers = 0
    private var timer: Timer?
    private var offeredRemovalThisSession = false

    private init() {
        refresh()
    }

    // MARK: - Paths

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(BatteryChargeIdentifiers.appBundleID, isDirectory: true)
            .appendingPathComponent(BatteryChargeIdentifiers.configFileName)
    }

    static var bundledBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent(BatteryChargeIdentifiers.bundledBinaryRelativePath).path
    }

    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: BatteryChargeIdentifiers.installedPlistPath)
            || FileManager.default.fileExists(atPath: BatteryChargeIdentifiers.installedBinaryPath)
    }

    private static var matchCache: (stamp: String, matches: Bool)?

    /// The installed daemon is the one this build carries. Compared byte for
    /// byte, once per change of the installed file.
    static var installedHelperMatchesBundle: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: BatteryChargeIdentifiers.installedBinaryPath)
        guard let attributes else { return false }
        let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((attributes[.size] as? NSNumber)?.intValue ?? 0)"
        if let matchCache, matchCache.stamp == stamp { return matchCache.matches }
        let installed = FileManager.default.contents(atPath: BatteryChargeIdentifiers.installedBinaryPath)
        let bundled = FileManager.default.contents(atPath: bundledBinaryPath)
        let matches = installed != nil && installed == bundled
        matchCache = (stamp, matches)
        return matches
    }

    // MARK: - Lifecycle

    var isAvailable: Bool { AppFeature.batteryCharge.isAvailable }

    /// Writes what the daemon should do. Leaving the hub turns the daemon
    /// idle at once (it restores the charger) and offers to remove it.
    func syncWithPreferences() {
        writeConfig()
        refresh()
        if !isAvailable, Self.isHelperInstalled, !offeredRemovalThisSession {
            offeredRemovalThisSession = true
            DispatchQueue.main.async { [weak self] in self?.removeHelper() }
        }
    }

    func writeConfig() {
        let config = BatteryChargePreferences.config(in: .standard, available: isAvailable)
        let url = Self.configURL
        // Nothing to say to a daemon that is not there, and no reason to
        // leave a file behind for a feature never used.
        guard Self.isHelperInstalled || FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try config.encoded().write(to: url, options: .atomic)
        } catch {
            message = "Couldn't save the charge limit: \(error.localizedDescription)"
        }
    }

    /// Settings and the panel row call these while they are visible.
    func beginObserving() {
        observers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endObserving() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let data = FileManager.default.contents(atPath: BatteryChargeIdentifiers.statusPath)
        let status = data.flatMap(BatteryChargeStatus.decode)
        let state = BatteryChargeSupport.helperState(installed: Self.isHelperInstalled,
                                                     matchesBundle: Self.installedHelperMatchesBundle,
                                                     status: status, now: Date())
        if self.status != status { self.status = status }
        if helperState != state { helperState = state }
        clearFinishedTopUp(status)
    }

    // MARK: - Top up

    var isTopUpPending: Bool {
        guard let topUp = BatteryChargePreferences.topUp(in: .standard) else { return false }
        return status?.completedTopUpToken != topUp.token
            && Date().timeIntervalSince1970 - topUp.requestedAt < BatteryChargeConfig.topUpMaximumAge
    }

    func topUp() {
        let topUp = BatteryChargeTopUp(token: UUID().uuidString, requestedAt: Date().timeIntervalSince1970)
        BatteryChargePreferences.setTopUp(topUp, in: .standard)
        writeConfig()
        objectWillChange.send()
    }

    func cancelTopUp() {
        BatteryChargePreferences.setTopUp(nil, in: .standard)
        writeConfig()
        objectWillChange.send()
    }

    /// A top-up the daemon finished (or one that expired) leaves the
    /// configuration, so the next one starts clean.
    private func clearFinishedTopUp(_ status: BatteryChargeStatus?) {
        guard let topUp = BatteryChargePreferences.topUp(in: .standard) else { return }
        let finished = status?.completedTopUpToken == topUp.token
        let expired = Date().timeIntervalSince1970 - topUp.requestedAt >= BatteryChargeConfig.topUpMaximumAge
        guard finished || expired else { return }
        BatteryChargePreferences.setTopUp(nil, in: .standard)
        writeConfig()
    }

    // MARK: - Install and remove

    func installHelper() {
        guard !isWorking else { return }
        let bundled = Self.bundledBinaryPath
        guard FileManager.default.isExecutableFile(atPath: bundled) else {
            message = "This copy of Vorssaint doesn't include the battery helper. Rebuild it with build.sh."
            return
        }
        let plist = BatteryChargeSupport.launchdPlist(configPath: Self.configURL.path, ownerUID: getuid())
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                                  format: .xml, options: 0) else { return }
        // The daemon reads its configuration from the first moment.
        writeConfigForInstall()
        isWorking = true
        message = nil
        let command = BatteryChargeSupport.installCommand(bundledBinary: bundled, plistData: plistData)
        AdminShell.run(command, prompt: "Vorssaint wants to install its battery helper, which holds the charge limit.") { ok in
            DispatchQueue.main.async {
                self.isWorking = false
                if !ok { self.message = "The battery helper wasn't installed." }
                self.refresh()
                // The first status takes a moment to appear.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
            }
        }
    }

    private func writeConfigForInstall() {
        let url = Self.configURL
        let config = BatteryChargePreferences.config(in: .standard, available: isAvailable)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? config.encoded().write(to: url, options: .atomic)
    }

    func removeHelper(completion: ((Bool) -> Void)? = nil) {
        guard !isWorking, Self.isHelperInstalled else { completion?(true); return }
        isWorking = true
        AdminShell.run(BatteryChargeSupport.uninstallCommand(),
                       prompt: "Vorssaint wants to remove its battery helper and let the battery charge normally.") { ok in
            DispatchQueue.main.async {
                self.isWorking = false
                let removed = ok && !Self.isHelperInstalled
                if !removed {
                    self.message = "The battery helper is still installed. It lets the battery charge normally while Charge Limit is off."
                }
                self.refresh()
                completion?(removed)
            }
        }
    }

    /// For the full uninstall, off the main thread: the configuration is
    /// turned off first, so a refused prompt still leaves the charger free.
    static func removeForUninstall() -> Bool {
        guard isHelperInstalled else { return true }
        let url = configURL
        try? BatteryChargeConfig(enabled: false).encoded().write(to: url, options: .atomic)
        _ = AdminShell.runSync(BatteryChargeSupport.uninstallCommand(),
                               prompt: "Vorssaint wants to remove its battery helper before it is uninstalled.")
        return !isHelperInstalled
    }

    // MARK: - Presentation

    /// The line the panel and Settings show.
    var stateLabel: String {
        let limit = UserDefaults.standard.integer(forKey: DefaultsKey.batteryChargeLimit)
        switch helperState {
        case .notInstalled: return "Helper not installed"
        case .needsUpdate: return "Helper needs an update"
        case .notResponding: return "Helper not responding"
        case .running:
            guard let status else { return "Helper not responding" }
            return BatteryChargeSupport.label(status.state, limit: status.limit ?? limit)
        }
    }
}
