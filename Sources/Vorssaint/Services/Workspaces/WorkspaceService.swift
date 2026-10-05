// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Combine

/// Fork: virtual workspaces. Hotkeys switch between them and send the focused
/// window to one; windows of the other workspaces are parked in a screen
/// corner through Accessibility, the way AeroSpace does it, so no Space has to
/// be created or private API touched. Full-screen windows are left to macOS.
///
/// Accessibility calls can stall on an app that is busy, so every one of them
/// runs on a private serial queue, which also owns the assignment. AppKit
/// state (screens, running apps, the frontmost app) is read on the main thread
/// first and handed over as a `Context`.
final class WorkspaceService: ObservableObject {
    static let shared = WorkspaceService()

    @Published private(set) var isRunning = false
    @Published private(set) var activeWorkspaceID: String?
    /// Storage keys of shortcuts another app already holds.
    @Published private(set) var refusedShortcuts: Set<String> = []
    /// Two window managers parking windows would fight over them, so nothing
    /// runs while AeroSpace does; importing from it is the way across.
    @Published private(set) var waitsForAeroSpace = false

    static let aeroSpaceBundleID = "bobko.aerospace"

    private let queue = DispatchQueue(label: "com.vorssaint.workspaces", qos: .userInteractive)
    /// Queue-owned.
    private var state: WorkspaceState?
    private var definitions: [WorkspaceDefinition] = []
    private var hotkeys: [QuickToolHotkey] = []
    private var activationObserver: NSObjectProtocol?
    private var aeroSpaceObservers: [NSObjectProtocol] = []
    private var terminationSource: DispatchSourceSignal?
    private var permissionSink: AnyCancellable?
    /// Our own activations must not read as the user focusing a window.
    private var followSuppressedUntil = Date.distantPast

    private init() {
        permissionSink = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            aeroSpaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.aeroSpaceBundleID else { return }
                self?.syncWithPreferences()
                // The process list can still carry an app as its quit is
                // announced; look again once it has caught up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.syncWithPreferences() }
            })
        }
    }

    static var aeroSpaceRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: aeroSpaceBundleID).contains { !$0.isTerminated }
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        definitions = WorkspaceSupport.definitions()
        let wanted = AppFeature.workspaces.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.workspacesEnabled)
            && AXIsProcessTrusted()
        let blocked = wanted && Self.aeroSpaceRunning
        if waitsForAeroSpace != blocked { waitsForAeroSpace = blocked }
        if wanted, !blocked { start() } else { stop() }
    }

    private func start() {
        registerHotkeys()
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in self?.applicationActivated(note) }
        }
        installTerminationRestore()
        let firstStart = !isRunning
        isRunning = true
        let definitions = definitions
        let context = Context.current()
        queue.async { [weak self] in self?.reconcile(definitions: definitions, context: context, firstStart: firstStart) }
    }

    private func stop() {
        for hotkey in hotkeys { hotkey.unregister() }
        hotkeys = []
        if !refusedShortcuts.isEmpty { refusedShortcuts = [] }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        removeTerminationRestore()
        guard isRunning else { return }
        isRunning = false
        activeWorkspaceID = nil
        // Turned off: every window comes back and nothing is remembered, so
        // turning it on later does not make windows vanish.
        let context = Context.current()
        queue.async { [weak self] in
            self?.unparkAll(context: context)
            self?.state = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.workspacesState)
        }
    }

    /// Quitting: bring every window back but keep the assignment, so the next
    /// launch parks them again. Waits, because the process is about to end.
    func restoreForTermination() {
        guard isRunning else { return }
        let context = Context.current()
        queue.sync { unparkAll(context: context, keepAssignments: true) }
    }

    /// SIGTERM ends the process without `applicationWillTerminate`, which
    /// would leave parked windows in their corner until the next launch.
    private func installTerminationRestore() {
        guard terminationSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.restoreForTermination()
            exit(0)
        }
        source.resume()
        terminationSource = source
    }

    private func removeTerminationRestore() {
        terminationSource?.cancel()
        terminationSource = nil
        signal(SIGTERM, SIG_DFL)
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        for hotkey in hotkeys { hotkey.unregister() }
        hotkeys = []
        var refused = Set<String>()
        var index: UInt32 = 0
        func register(_ raw: String, key: String, action: @escaping () -> Void) {
            guard let shortcut = GlobalShortcut(storageValue: raw, requiringModifier: false),
                  WorkspaceSupport.isUsable(shortcut) else { return }
            let hotkey = QuickToolHotkey(id: WorkspaceSupport.hotkeyIDBase + index)
            index += 1
            hotkey.onPress = action
            if !hotkey.sync(enabled: true, shortcut: shortcut, storageKey: key) { refused.insert(key) }
            hotkeys.append(hotkey)
        }
        for definition in definitions {
            let id = definition.id
            register(definition.switchShortcut, key: "workspaces.\(id).switch") { [weak self] in self?.switchTo(id) }
            register(definition.moveShortcut, key: "workspaces.\(id).move") { [weak self] in self?.moveFocusedWindow(to: id) }
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: DefaultsKey.workspacesBackAndForthEnabled),
           let raw = defaults.string(forKey: DefaultsKey.workspacesBackAndForthShortcut) {
            register(raw, key: DefaultsKey.workspacesBackAndForthShortcut) { [weak self] in self?.switchBack() }
        }
        if refused != refusedShortcuts { refusedShortcuts = refused }
    }

    // MARK: - Commands

    func switchTo(_ workspaceID: String) {
        guard isRunning else { return }
        let context = Context.current()
        queue.async { [weak self] in self?.performSwitch(to: workspaceID, context: context, focus: true) }
    }

    func switchBack() {
        guard isRunning else { return }
        let context = Context.current()
        queue.async { [weak self] in
            guard let self, let previous = self.state?.previous else { return }
            self.performSwitch(to: previous, context: context, focus: true)
        }
    }

    func moveFocusedWindow(to workspaceID: String) {
        guard isRunning else { return }
        let context = Context.current()
        let follows = UserDefaults.standard.bool(forKey: DefaultsKey.workspacesMoveFollows)
        queue.async { [weak self] in self?.performMove(to: workspaceID, context: context, follows: follows) }
    }

    /// Every window to the workspace in view.
    func gatherAll() {
        guard isRunning else { return }
        let context = Context.current()
        queue.async { [weak self] in
            guard let self, var state = self.state else { return }
            for key in state.windows.keys { state.windows[key]?.workspace = state.active }
            self.state = state
            self.unparkAll(context: context, keepAssignments: true)
            self.showHUD(message: "All windows on \(self.name(of: state.active))", icon: "rectangle.stack")
        }
    }

    // MARK: - Work on the queue

    private func reconcile(definitions: [WorkspaceDefinition], context: Context, firstStart: Bool) {
        var state = WorkspaceSupport.reconciled(state ?? WorkspaceSupport.state(), with: definitions)
        var snapshot = Snapshot.take(context)
        if firstStart {
            for (index, window) in snapshot.windows.enumerated() where !window.isFullscreen {
                let key = String(window.id)
                let looksParked = WorkspaceSupport.looksParked(window.frame, screens: context.screens)
                if state.windows[key]?.parkedFrom != nil, !looksParked {
                    // Brought back when Vorssaint last quit; it is in view.
                    state.windows[key]?.parkedFrom = nil
                } else if state.windows[key]?.parkedFrom == nil, looksParked,
                          let element = snapshot.elements[window.id],
                          let screen = WorkspaceSupport.screen(for: window.frame, in: context.screens) {
                    // Left in a corner with no record of where it was: a
                    // crash, or another window manager quitting. Center it.
                    let origin = WorkspaceSupport.centered(window.frame.size, in: screen)
                    Self.setOrigin(origin, of: element)
                    snapshot.windows[index].frame.origin = origin
                }
            }
        }
        let plan = WorkspaceSupport.plan(&state, windows: snapshot.windows, existing: snapshot.existing,
                                         target: state.active)
        apply(plan, to: &state, snapshot: snapshot, context: context)
        commit(state)
    }

    private func performSwitch(to target: String, context: Context, focus: Bool) {
        guard var state else { return }
        let snapshot = Snapshot.take(context)
        if let pid = context.frontmostPID, let focused = WindowActivator.focusedWindowID(for: pid),
           state.workspace(of: focused) == state.active {
            state.lastFocused[state.active] = focused
        }
        let plan = WorkspaceSupport.plan(&state, windows: snapshot.windows, existing: snapshot.existing, target: target)
        // Bring the new workspace in first, so the screen is never empty.
        apply(WorkspacePlan(unpark: plan.unpark), to: &state, snapshot: snapshot, context: context)
        if focus { focusWorkspace(target, state: state, snapshot: snapshot, excluding: nil) }
        apply(WorkspacePlan(park: plan.park), to: &state, snapshot: snapshot, context: context)
        commit(state)
        showHUD(message: name(of: target), icon: "rectangle.3.group")
    }

    private func performMove(to target: String, context: Context, follows: Bool) {
        guard var state, let pid = context.frontmostPID,
              let windowID = WindowActivator.focusedWindowID(for: pid) else { return }
        let snapshot = Snapshot.take(context)
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return }
        if window.isFullscreen {
            showHUD(message: "Full-screen windows keep their own Space", icon: "arrow.up.left.and.arrow.down.right")
            return
        }
        let key = String(windowID)
        let entry = state.windows[key] ?? WorkspaceWindowState(workspace: state.active, pid: window.pid)
        state.windows[key] = WorkspaceWindowState(workspace: target, pid: entry.pid,
                                                  parkedFrom: entry.parkedFrom, size: entry.size)
        state.lastFocused[target] = windowID
        guard target != state.active else {
            commit(state)
            return
        }
        if follows {
            // The window stays in view and its new workspace comes to it.
            commit(state)
            performSwitch(to: target, context: context, focus: true)
            return
        }
        apply(WorkspacePlan(park: [windowID]), to: &state, snapshot: snapshot, context: context)
        focusWorkspace(state.active, state: state, snapshot: snapshot, excluding: windowID)
        commit(state)
        showHUD(message: "Moved to \(name(of: target))", icon: "arrow.right.square")
    }

    /// A window on another workspace was activated: go to it.
    private func applicationActivated(_ note: Notification) {
        guard isRunning, Date() >= followSuppressedUntil,
              UserDefaults.standard.bool(forKey: DefaultsKey.workspacesFollowFocus),
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        let context = Context.current()
        queue.async { [weak self] in
            guard let self, let state = self.state,
                  let windowID = WindowActivator.focusedWindowID(for: pid),
                  let workspace = state.workspace(of: windowID),
                  workspace != state.active, state.isParked(windowID) else { return }
            self.performSwitch(to: workspace, context: context, focus: false)
        }
    }

    private func unparkAll(context: Context, keepAssignments: Bool = false) {
        guard var state else { return }
        let snapshot = Snapshot.take(context)
        let parked = snapshot.windows.filter { state.isParked($0.id) }.map(\.id)
        apply(WorkspacePlan(unpark: parked), to: &state, snapshot: snapshot, context: context)
        if keepAssignments { commit(state) }
    }

    private func apply(_ plan: WorkspacePlan, to state: inout WorkspaceState, snapshot: Snapshot, context: Context) {
        for id in plan.unpark {
            let key = String(id)
            guard let entry = state.windows[key], let relative = entry.parkedFrom,
                  let element = snapshot.elements[id], let window = snapshot.window(id) else { continue }
            let screen = WorkspaceSupport.parkedScreen(for: window.frame, in: context.screens)
                ?? WorkspaceSupport.screen(for: window.frame, in: context.screens) ?? context.screens.first
            if let screen {
                let size = entry.size ?? window.frame.size
                Self.setOrigin(WorkspaceSupport.restoredOrigin(relative, size: size, in: screen), of: element)
            }
            state.windows[key]?.parkedFrom = nil
        }
        for id in plan.park {
            let key = String(id)
            guard let element = snapshot.elements[id], let window = snapshot.window(id),
                  let screen = WorkspaceSupport.screen(for: window.frame, in: context.screens) else { continue }
            let others = context.screens.filter { $0 != screen }
            let zoom = context.bundleIDs[window.pid] == "us.zoom.xos"
            state.windows[key]?.parkedFrom = WorkspaceSupport.relativeOrigin(window.frame.origin, in: screen)
            state.windows[key]?.size = window.frame.size
            Self.setOrigin(WorkspaceSupport.parkingOrigin(size: window.frame.size, screen: screen,
                                                          otherScreens: others, zeroOffset: zoom), of: element)
        }
    }

    /// The window last used on the workspace, else its frontmost one. With
    /// none, Finder takes focus so typing does not land in a parked window.
    private func focusWorkspace(_ workspace: String, state: WorkspaceState, snapshot: Snapshot, excluding: UInt32?) {
        let members = Set(snapshot.windows.filter {
            $0.id != excluding && !$0.isMinimized && !$0.isAppHidden && !$0.isFullscreen
                && state.workspace(of: $0.id) == workspace
        }.map(\.id))
        let remembered = state.lastFocused[workspace].flatMap { members.contains($0) ? $0 : nil }
        let target = remembered ?? snapshot.frontToBack.first(where: members.contains)
        let window = target.flatMap(snapshot.window)
        DispatchQueue.main.async { [weak self] in
            self?.followSuppressedUntil = Date().addingTimeInterval(0.8)
            if let window, let app = NSRunningApplication(processIdentifier: window.pid) {
                WindowActivator.activate(pid: window.pid, windowID: window.id,
                                         appName: app.localizedName ?? "")
            } else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                    .first?.activate()
            }
        }
    }

    private func commit(_ state: WorkspaceState) {
        self.state = state
        UserDefaults.standard.set(WorkspaceSupport.encode(state), forKey: DefaultsKey.workspacesState)
        let active = state.active
        DispatchQueue.main.async { [weak self] in
            if self?.activeWorkspaceID != active { self?.activeWorkspaceID = active }
        }
    }

    private func name(of workspace: String) -> String {
        let name = definitions.first { $0.id == workspace }?.name ?? workspace
        return Int(name) != nil ? "Workspace \(name)" : name
    }

    private func showHUD(message: String, icon: String) {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.workspacesShowHUD) else { return }
        QuickToolHUD.show(icon: icon, message: message)
    }

    private static func setOrigin(_ origin: CGPoint, of element: AXUIElement) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        let suspension = EnhancedUserInterfaceSuspension.suspend(forAppOf: element)
        defer { suspension?.resume() }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    // MARK: - AeroSpace

    /// Takes over from AeroSpace: reads which window is on which workspace,
    /// quits it (it centers every window on the way out) and stops it opening
    /// at login, puts the windows that were in view back where they were, then
    /// starts and parks the rest.
    func importFromAeroSpace(completion: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { completion("Vorssaint needs Accessibility first."); return }
        let definitions = WorkspaceSupport.definitions()
        let context = Context.current()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func finish(_ message: String) {
                DispatchQueue.main.async {
                    self.syncWithPreferences()
                    completion(message)
                }
            }
            guard let cli = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
                .first(where: FileManager.default.isExecutableFile(atPath:)) else {
                finish("The aerospace command isn't installed, so nothing was imported.")
                return
            }
            let listing = Self.run(cli, ["list-windows", "--all", "--format", "%{window-id}|%{workspace}"]) ?? ""
            let focused = Self.run(cli, ["list-workspaces", "--focused"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let byName = Dictionary(definitions.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
            var assignment: [UInt32: String] = [:]
            for line in listing.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let id = UInt32(parts[0]), let workspace = byName[parts[1]] else { continue }
                assignment[id] = workspace
            }
            let active = focused.flatMap { byName[$0] } ?? definitions.first?.id ?? ""
            // AeroSpace centers every window as it quits; the ones in view
            // get their frames back.
            let inView = Snapshot.take(context).windows.filter {
                !$0.isFullscreen && !WorkspaceSupport.looksParked($0.frame, screens: context.screens)
            }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.aeroSpaceBundleID) {
                app.terminate()
            }
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, Self.aeroSpaceRunning { Thread.sleep(forTimeInterval: 0.1) }
            guard !Self.aeroSpaceRunning else {
                finish("AeroSpace didn't quit. Quit it from its menu, then try again.")
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
            _ = Self.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete (every login item whose name is \"AeroSpace\")"])
            let after = Snapshot.take(context)
            for window in inView {
                guard let element = after.elements[window.id] else { continue }
                var size = window.frame.size
                if let value = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
                }
                Self.setOrigin(window.frame.origin, of: element)
            }
            var state = WorkspaceState(active: active)
            for (id, workspace) in assignment where after.existing.contains(id) {
                state.windows[String(id)] = WorkspaceWindowState(workspace: workspace, pid: after.window(id)?.pid ?? 0)
            }
            self.queue.sync {
                self.state = state
                UserDefaults.standard.set(WorkspaceSupport.encode(state), forKey: DefaultsKey.workspacesState)
            }
            finish("Imported \(state.windows.count) windows from AeroSpace and quit it. It won't open at login anymore.")
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: - Reading the screen

extension WorkspaceService {
    /// AppKit state, read on the main thread before work moves to the queue.
    struct Context {
        /// Visible frames, Accessibility coordinates.
        var screens: [CGRect]
        var apps: [(pid: pid_t, isHidden: Bool)]
        var bundleIDs: [pid_t: String]
        var frontmostPID: pid_t?

        static func current() -> Context {
            let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height ?? 0
            let own = ProcessInfo.processInfo.processIdentifier
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return Context(
                screens: NSScreen.screens.map { WorkspaceSupport.axRect($0.visibleFrame, primaryHeight: primaryHeight) },
                apps: apps.map { ($0.processIdentifier, $0.isHidden) },
                bundleIDs: Dictionary(apps.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier, $0) } },
                                      uniquingKeysWith: { first, _ in first }),
                frontmostPID: frontmost == own ? nil : frontmost)
        }
    }

    /// Every workspace window Accessibility can see right now.
    struct Snapshot {
        var windows: [WorkspaceWindow] = []
        var elements: [UInt32: AXUIElement] = [:]
        /// Every window the window server has, on any Space, so windows
        /// Accessibility cannot see from here are not forgotten.
        var existing: Set<UInt32> = []
        /// On-screen windows, front to back.
        var frontToBack: [UInt32] = []

        func window(_ id: UInt32) -> WorkspaceWindow? { windows.first { $0.id == id } }

        static func take(_ context: Context) -> Snapshot {
            var snapshot = Snapshot()
            for app in context.apps {
                let axApp = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(axApp, 0.25)
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
                      let list = raw as? [AXUIElement] else { continue }
                for element in list {
                    AXUIElementSetMessagingTimeout(element, 0.25)
                    let subrole = stringAttribute(element, kAXSubroleAttribute)
                    guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole,
                          let id = AXWindowResolver.windowID(for: element),
                          let frame = frame(of: element), frame.width > 1, frame.height > 1 else { continue }
                    snapshot.elements[id] = element
                    snapshot.windows.append(WorkspaceWindow(
                        id: id, pid: app.pid, frame: frame,
                        isFullscreen: boolAttribute(element, "AXFullScreen"),
                        isMinimized: boolAttribute(element, kAXMinimizedAttribute),
                        isAppHidden: app.isHidden))
                }
            }
            let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            snapshot.existing = Set(all.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] ?? []
            snapshot.frontToBack = onScreen.compactMap { info in
                (info[kCGWindowLayer as String] as? Int) == 0
                    ? (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
            }
            return snapshot
        }

        private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }

        private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
            return (value as? Bool) == true
        }

        private static func frame(of element: AXUIElement) -> CGRect? {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, CFGetTypeID(position) == AXValueGetTypeID(),
                  let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: origin, size: extent)
        }
    }
}

#if VORSSAINT_DEVELOPMENT
/// Developer builds: parks and brings back the windows of one process, with
/// no hotkeys and no other window touched, and writes what Accessibility and
/// the window server saw at each step.
enum WorkspaceProbe {
    static func runIfRequestedAndExit() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--workspace-probe"), arguments.indices.contains(flag + 2),
              let pid = pid_t(arguments[flag + 1]) else { return }
        let output = URL(fileURLWithPath: arguments[flag + 2])
        var lines: [String] = ["trusted=\(AXIsProcessTrusted())"]
        var context = WorkspaceService.Context.current()
        context.apps = [(pid, false)]
        context.frontmostPID = nil
        lines.append("screens=\(context.screens)")
        let before = WorkspaceService.Snapshot.take(context)
        guard let window = before.windows.first else {
            lines.append("no window")
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
            exit(1)
        }
        lines.append("before=\(window.frame)")
        var state = WorkspaceState(active: "a", windows: [String(window.id): WorkspaceWindowState(workspace: "b", pid: pid)])
        var plan = WorkspaceSupport.plan(&state, windows: before.windows, existing: before.existing, target: "a")
        lines.append("plan.park=\(plan.park) unpark=\(plan.unpark)")
        WorkspaceService.shared.probeApply(plan, state: &state, snapshot: before, context: context)
        Thread.sleep(forTimeInterval: 0.4)
        let parked = WorkspaceService.Snapshot.take(context)
        let parkedFrame = parked.window(window.id)?.frame ?? .null
        lines.append("parked=\(parkedFrame) looksParked=\(WorkspaceSupport.looksParked(parkedFrame, screens: context.screens))")
        lines.append("server=\(serverBounds(window.id))")
        plan = WorkspaceSupport.plan(&state, windows: parked.windows, existing: parked.existing, target: "b")
        lines.append("plan.park=\(plan.park) unpark=\(plan.unpark)")
        WorkspaceService.shared.probeApply(plan, state: &state, snapshot: parked, context: context)
        Thread.sleep(forTimeInterval: 0.4)
        let after = WorkspaceService.Snapshot.take(context).window(window.id)?.frame ?? .null
        lines.append("restored=\(after) matches=\(abs(after.minX - window.frame.minX) < 1.5 && abs(after.minY - window.frame.minY) < 1.5)")
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func serverBounds(_ id: UInt32) -> String {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]]
        return "\(info?.first?[kCGWindowBounds as String] ?? "none")"
    }
}

extension WorkspaceService {
    func probeApply(_ plan: WorkspacePlan, state: inout WorkspaceState, snapshot: Snapshot, context: Context) {
        apply(plan, to: &state, snapshot: snapshot, context: context)
    }
}
#endif
