// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreServices

/// Fork: App Icons' file work. A custom icon is the one Finder's Get Info
/// makes: an `Icon\r` file inside the app plus a flag on it. Apps the person
/// owns are changed directly; apps installed by the App Store or an installer
/// belong to the system and are changed with one administrator prompt for
/// the whole batch. Every icon set here is kept in Application Support, and
/// a file-system watch on the app folders puts it back when an update
/// replaces the app.
final class AppIconService: ObservableObject {
    static let shared = AppIconService()

    struct App: Identifiable, Equatable {
        let path: String
        let name: String
        let bundleID: String
        /// On the sealed system volume: cannot change.
        let isProtected: Bool
        /// Owned by the system: changing it asks for an administrator.
        let needsAdmin: Bool
        var id: String { path }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var records: [AppIconRecord] = []
    @Published private(set) var isScanning = false
    /// Paths being changed right now.
    @Published private(set) var busy: Set<String> = []
    /// Customized apps whose icon an update took and that need an
    /// administrator to put back.
    @Published private(set) var pendingRestore: [App] = []
    /// The last thing worth telling the person, nil when all went well.
    @Published var message: String?
    /// macOS's App Management protection refused a change: the page offers
    /// the way to the setting.
    @Published var needsAppManagement = false
    /// Bumped whenever an icon on disk changes, so the grid redraws it.
    @Published private(set) var iconRevision = 0

    private let queue = DispatchQueue(label: "com.vorssaint.app-icons", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private var reconcileWork: DispatchWorkItem?
    private var notifiedPending: Set<String> = []
    private let iconCache = NSCache<NSString, NSImage>()

    private init() {
        records = AppIconSupport.records()
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        records = AppIconSupport.records()
        let wanted = AppFeature.appIcons.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.appIconsEnabled)
        if wanted, !records.isEmpty {
            startWatching()
            scheduleReconcile(after: 2)
        } else {
            stopWatching()
        }
    }

    // MARK: - Apps

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            let found = Self.findApps()
            DispatchQueue.main.async {
                self?.apps = found
                self?.isScanning = false
            }
        }
    }

    private static func findApps() -> [App] {
        let manager = FileManager.default
        var seen = Set<String>(), apps: [App] = []
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  seen.insert(bundleID).inserted else { return }
            let name = manager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let isProtected = AppIconSupport.isProtected(path: url.resolvingSymlinksInPath().path)
            apps.append(App(path: url.path, name: name, bundleID: bundleID, isProtected: isProtected,
                            needsAdmin: !manager.isWritableFile(atPath: url.path)))
        }
        for folder in AppIconSupport.searchFolders() {
            guard let items = try? manager.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          item.lastPathComponent != "Utilities",
                          let inner = try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) {
                    // A vendor folder ("Native Instruments", "Setapp"…), one level deep.
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func record(for app: App) -> AppIconRecord? { records.first { $0.bundleID == app.bundleID } }

    static func hasCustomIcon(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Icon\r")
    }

    /// What the app shows now.
    func currentIcon(for app: App) -> NSImage {
        let key = "\(app.path)#\(iconRevision)" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// The app's own icon, whatever it wears now.
    func naturalIcon(for app: App) -> NSImage {
        if let data = try? Data(contentsOf: storeURL("originals").appendingPathComponent(
            AppIconSupport.fileName(for: app.bundleID))), let image = NSImage(data: data) {
            return image
        }
        return Self.bundleIcon(at: app.path, allowWorkspace: !Self.hasCustomIcon(app.path))
    }

    /// An older app's own `.icns` (macOS 26 would otherwise box it in a gray
    /// tile), or the icon macOS draws for an app with a modern icon.
    static func bundleIcon(at path: String, allowWorkspace: Bool) -> NSImage {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let iconName = info["CFBundleIconName"] as? String
        if iconName == nil || !allowWorkspace, var file = info["CFBundleIconFile"] as? String {
            if (file as NSString).pathExtension.isEmpty { file += ".icns" }
            if let image = NSImage(contentsOfFile: path + "/Contents/Resources/" + file) { return image }
        }
        if !allowWorkspace, let iconName, let image = bundle?.image(forResource: iconName) { return image }
        return NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: - Changing icons

    /// Sets `image` as the icon of every app in `apps`.
    func setIcon(_ image: NSImage, style: AppIconRecord.Style, for apps: [App]) {
        let targets = apps.filter { !$0.isProtected }
        guard !targets.isEmpty else { return }
        busy.formUnion(targets.map(\.path))
        message = nil
        needsAppManagement = false
        queue.async { [weak self] in
            guard let self else { return }
            var jobs: [(App, NSImage)] = []
            for app in targets {
                self.keepOriginal(of: app)
                jobs.append((app, image))
            }
            self.write(jobs, style: style)
        }
    }

    /// Gives every app in `apps` the dark version of its own icon.
    func makeDark(_ apps: [App]) {
        let targets = apps.filter { !$0.isProtected }
        guard !targets.isEmpty else { return }
        busy.formUnion(targets.map(\.path))
        message = nil
        needsAppManagement = false
        queue.async { [weak self] in
            guard let self else { return }
            var jobs: [(App, NSImage)] = []
            for app in targets {
                self.keepOriginal(of: app)
                // Off the main thread: a whole Applications folder takes a few seconds.
                if let dark = AppIconRenderer.darkIcon(from: self.naturalIcon(for: app)) {
                    jobs.append((app, dark))
                }
            }
            self.write(jobs, style: .dark)
        }
    }

    func restore(_ apps: [App]) {
        let targets = apps.filter { !$0.isProtected }
        guard !targets.isEmpty else { return }
        busy.formUnion(targets.map(\.path))
        message = nil
        queue.async { [weak self] in
            guard let self else { return }
            var needAdmin: [App] = []
            var done: [App] = []
            for app in targets {
                if !Self.hasCustomIcon(app.path) || NSWorkspace.shared.setIcon(nil, forFile: app.path, options: []) {
                    done.append(app)
                } else {
                    needAdmin.append(app)
                }
            }
            let finish = { (adminDone: [App]) in
                DispatchQueue.main.async {
                    let restored = done + adminDone
                    self.forget(restored)
                    self.busy.subtract(targets.map(\.path))
                    let failed = targets.count - restored.count
                    if failed > 0, self.message == nil {
                        self.message = "\(failed) icon\(failed == 1 ? "" : "s") couldn't be restored."
                    }
                    self.iconsChanged(restored)
                }
            }
            guard !needAdmin.isEmpty else { return finish([]) }
            let command = needAdmin.map { AppIconSupport.adminRemoveCommand(appPath: $0.path) }.joined(separator: " ; ")
            self.runAdmin(command, prompt: "Vorssaint wants to restore the original icon of \(Self.list(needAdmin)).") { _ in
                finish(needAdmin.filter { !Self.hasCustomIcon($0.path) })
            }
        }
    }

    /// Writes each picture onto its app, directly where possible and with
    /// one administrator prompt for the rest. Runs on `queue`.
    private func write(_ jobs: [(App, NSImage)], style: AppIconRecord.Style, restoring: Bool = false) {
        var written: [App] = [], adminJobs: [(App, String)] = [], blocked: [App] = []
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vorssaint-icons-\(UUID().uuidString)")
        for (app, original) in jobs {
            // Encoded the way an icon file expects: 512 points at 2x.
            let image = AppIconRenderer.iconImage(from: original)
            if let png = AppIconRenderer.pngData(image) {
                let folder = storeURL("icons")
                PrivateFileStore.createDirectory(at: folder)
                PrivateFileStore.write(png, to: folder.appendingPathComponent(AppIconSupport.fileName(for: app.bundleID)))
            }
            if !app.needsAdmin, NSWorkspace.shared.setIcon(image, forFile: app.path, options: []) {
                written.append(app)
                continue
            }
            if !app.needsAdmin {
                // The app is the person's own, yet macOS refused: App Management.
                blocked.append(app)
                continue
            }
            // Made on a scratch folder, then copied in as an administrator.
            let holder = scratch.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            if NSWorkspace.shared.setIcon(image, forFile: holder.path, options: []) {
                adminJobs.append((app, holder.path + "/Icon\r"))
            } else {
                blocked.append(app)
            }
        }
        let finish = { (adminWritten: [App]) in
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async {
                let done = written + adminWritten
                self.remember(done, style: style, restoring: restoring)
                self.busy.subtract(jobs.map(\.0.path))
                self.pendingRestore.removeAll { app in done.contains { $0.bundleID == app.bundleID } }
                self.iconsChanged(done)
                if !blocked.isEmpty {
                    self.blockedByAppManagement(blocked)
                } else if done.count < jobs.count, self.message == nil {
                    let missed = jobs.count - done.count
                    self.message = "\(missed) icon\(missed == 1 ? " wasn't" : "s weren't") changed."
                }
            }
        }
        guard !adminJobs.isEmpty else { return finish([]) }
        let command = adminJobs.map { AppIconSupport.adminInstallCommand(iconFile: $0.1, appPath: $0.0.path) }
            .joined(separator: " ; ")
        let apps = adminJobs.map(\.0)
        runAdmin(command, prompt: "Vorssaint wants to change the icon of \(Self.list(apps)).") { _ in
            let written = apps.filter { Self.hasCustomIcon($0.path) }
            let missed = apps.filter { !Self.hasCustomIcon($0.path) }
            if !missed.isEmpty, AppIconService.lastAdminRefusedByMacOS {
                DispatchQueue.main.async { self.blockedByAppManagement(missed) }
            }
            finish(written)
        }
    }

    private func blockedByAppManagement(_ apps: [App]) {
        needsAppManagement = true
        message = "macOS's App Management protection stopped Vorssaint from changing \(Self.list(apps)). Turn on Vorssaint under Privacy & Security › App Management, then try again."
    }

    /// Set by the last administrator run: macOS itself refused a write
    /// ("Operation not permitted" even as root), which is App Management.
    private static var lastAdminRefusedByMacOS = false

    /// Runs `command` as an administrator, as Vorssaint's own child process
    /// (so App Management credits Vorssaint) and off the main thread (so the
    /// app stays responsive while macOS asks for the password). The
    /// command's errors are kept to tell a refusal from a cancelled prompt.
    private func runAdmin(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        let errors = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-icons-\(UUID().uuidString).log")
        let wrapped = "{ \(command) ; } 2> \(AppIconSupport.quoted(errors.path))"
        // The password dialog opens in front of an agent app only once it is active.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = AppIconPrivileged.run(wrapped, prompt: prompt)
            let text = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: errors)
            Self.lastAdminRefusedByMacOS = text.localizedCaseInsensitiveContains("operation not permitted")
            if outcome != .finished {
                DispatchQueue.main.async {
                    guard self.message == nil else { return }
                    if outcome == .cancelled {
                        self.message = "The password prompt was cancelled, so nothing changed."
                    } else if case .failed(let status) = outcome {
                        self.message = "macOS couldn't ask for an administrator (error \(status)), so nothing changed."
                    }
                }
            }
            completion(outcome == .finished)
        }
    }

    /// The app's own icon, saved the first time it is customized so it can
    /// be made dark again or shown later whatever the app wears.
    private func keepOriginal(of app: App) {
        let url = storeURL("originals").appendingPathComponent(AppIconSupport.fileName(for: app.bundleID))
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let image = Self.bundleIcon(at: app.path, allowWorkspace: !Self.hasCustomIcon(app.path))
        guard let png = AppIconRenderer.pngData(image) else { return }
        PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
        PrivateFileStore.write(png, to: url)
    }

    private func remember(_ apps: [App], style: AppIconRecord.Style, restoring: Bool) {
        var updated = AppIconSupport.records()
        for app in apps {
            if restoring, var existing = updated.first(where: { $0.bundleID == app.bundleID }) {
                existing.path = app.path
                existing.restores += 1
                updated = AppIconSupport.upserting(existing, into: updated)
            } else {
                updated = AppIconSupport.upserting(
                    AppIconRecord(bundleID: app.bundleID, path: app.path, style: style, appliedAt: Date()),
                    into: updated)
            }
        }
        save(updated)
    }

    private func forget(_ apps: [App]) {
        let ids = Set(apps.map(\.bundleID))
        for id in ids {
            try? FileManager.default.removeItem(at: storeURL("icons").appendingPathComponent(AppIconSupport.fileName(for: id)))
        }
        save(AppIconSupport.records().filter { !ids.contains($0.bundleID) })
    }

    private func save(_ updated: [AppIconRecord]) {
        UserDefaults.standard.set(AppIconSupport.encode(updated), forKey: DefaultsKey.appIconsRecords)
        records = updated
        syncWithPreferences()
    }

    private func iconsChanged(_ apps: [App]) {
        for app in apps { NSWorkspace.shared.noteFileSystemChanged(app.path) }
        iconCache.removeAllObjects()
        iconRevision += 1
    }

    /// Restarts the Dock so it shows the new icons of apps kept in it.
    func refreshDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    /// The stored picture of every customized app, for a settings backup.
    func backupImages() -> [String: Data] {
        AppIconSupport.records().reduce(into: [:]) { out, record in
            out[record.bundleID] = try? Data(contentsOf: storeURL("icons").appendingPathComponent(record.iconFileName))
        }
    }

    /// Puts a backup's pictures where `reconcile` looks for them; after the
    /// relaunch it applies each one to its app.
    func restoreBackupImages(_ images: [String: Data]) {
        guard !images.isEmpty else { return }
        let folder = storeURL("icons")
        PrivateFileStore.createDirectory(at: folder)
        for (bundleID, png) in images {
            PrivateFileStore.write(png, to: folder.appendingPathComponent(AppIconSupport.fileName(for: bundleID)))
        }
    }

    private func storeURL(_ folder: String) -> URL {
        (PrivateFileStore.containerURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("App Icons", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    private static func list(_ apps: [App]) -> String {
        let names = apps.map(\.name)
        switch names.count {
        case 0: return "no apps"
        case 1: return names[0]
        case 2...3: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        default: return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        }
    }

    // MARK: - After updates

    private func scheduleReconcile(after delay: TimeInterval) {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Puts back every custom icon an update took. Apps the person owns are
    /// fixed at once; the rest wait for a password, with a notification.
    func reconcile() {
        let current = AppIconSupport.records()
        guard !current.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var direct: [(App, NSImage)] = [], admin: [(App, NSImage)] = []
            for record in current {
                let outcome = AppIconSupport.reconcile(
                    record,
                    exists: { FileManager.default.fileExists(atPath: $0) },
                    hasCustomIcon: Self.hasCustomIcon,
                    locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path })
                guard case .reapply(let path) = outcome,
                      !AppIconSupport.isProtected(path: path),
                      let data = try? Data(contentsOf: self.storeURL("icons").appendingPathComponent(record.iconFileName)),
                      let image = NSImage(data: data) else { continue }
                let app = App(path: path, name: FileManager.default.displayName(atPath: path)
                                .replacingOccurrences(of: ".app", with: ""),
                              bundleID: record.bundleID, isProtected: false,
                              needsAdmin: !FileManager.default.isWritableFile(atPath: path))
                if app.needsAdmin { admin.append((app, image)) } else { direct.append((app, image)) }
            }
            if !direct.isEmpty {
                self.write(direct, style: .custom, restoring: true)
            }
            DispatchQueue.main.async {
                self.pendingRestore = admin.map(\.0)
                let fresh = admin.map(\.0).filter { !self.notifiedPending.contains($0.bundleID) }
                guard !fresh.isEmpty else { return }
                self.notifiedPending.formUnion(fresh.map(\.bundleID))
                Notifier.post(title: "App icons to put back",
                              body: "\(Self.list(fresh)) updated and lost \(fresh.count == 1 ? "its" : "their") custom icon. Open Vorssaint › App Icons to put \(fresh.count == 1 ? "it" : "them") back.")
            }
        }
    }

    /// Puts back the icons that need an administrator, in one prompt.
    func restorePending() {
        let pending = pendingRestore
        guard !pending.isEmpty else { return }
        busy.formUnion(pending.map(\.path))
        queue.async { [weak self] in
            guard let self else { return }
            let jobs = pending.compactMap { app -> (App, NSImage)? in
                guard let data = try? Data(contentsOf: self.storeURL("icons").appendingPathComponent(
                    AppIconSupport.fileName(for: app.bundleID))), let image = NSImage(data: data) else { return nil }
                return (app, image)
            }
            self.write(jobs, style: .custom, restoring: true)
        }
    }

    // MARK: - Watching the app folders

    private func startWatching() {
        guard stream == nil else { return }
        let paths = AppIconSupport.searchFolders().filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let service = Unmanaged<AppIconService>.fromOpaque(info).takeUnretainedValue()
            // An update writes many files; act once it has settled.
            DispatchQueue.main.async { service.scheduleReconcile(after: 4) }
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
