// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import CoreGraphics
import Foundation

// Fork: virtual workspaces, in the spirit of AeroSpace. Every window belongs
// to one workspace; switching parks the others in a screen corner, one pixel
// in view, and brings the chosen workspace's windows back where they were.
// Full-screen windows are left to macOS: they live in their own Space and
// belong to no workspace. Preferences, geometry and the switch plan live here,
// where the tests compile them; Accessibility and hotkeys are in
// Services/Workspaces.

extension DefaultsKey {
    static let workspacesEnabled = "workspacesEnabled"
    /// JSON list of `WorkspaceDefinition`.
    static let workspacesDefinitions = "workspacesDefinitions"
    static let workspacesBackAndForthEnabled = "workspacesBackAndForthEnabled"
    static let workspacesBackAndForthShortcut = "workspacesBackAndForthShortcut"
    /// Activating a window that lives on another workspace switches to it.
    static let workspacesFollowFocus = "workspacesFollowFocus"
    /// Moving a window to a workspace also switches there.
    static let workspacesMoveFollows = "workspacesMoveFollows"
    static let workspacesShowHUD = "workspacesShowHUD"
    /// The live assignment, so a relaunch keeps every window where it was.
    static let workspacesState = "workspacesState"
    /// A menu bar item with a square per workspace that has windows.
    static let menuBarWorkspaces = "menuBarWorkspaces"
}

/// One square in the menu bar item.
struct WorkspaceMenuBarSquare: Equatable {
    var id: String
    var label: String
    var isActive: Bool
}

struct WorkspaceDefinition: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// `GlobalShortcut` storage values; empty means none.
    var switchShortcut: String
    var moveShortcut: String
}

/// A window as the switch plan needs to see it.
struct WorkspaceWindow: Equatable {
    var id: UInt32
    var pid: Int32
    /// Accessibility coordinates: top-left origin, y grows downward.
    var frame: CGRect
    var isFullscreen = false
    var isMinimized = false
    var isAppHidden = false
}

struct WorkspaceWindowState: Codable, Equatable {
    var workspace: String
    var pid: Int32
    /// Where the window sat, as a fraction of its screen, while it is parked.
    /// Nil while the window is in view.
    var parkedFrom: CGPoint?
    var size: CGSize?
}

struct WorkspaceState: Codable, Equatable {
    var active: String
    var previous: String?
    /// Window id (as text, for JSON) to its assignment.
    var windows: [String: WorkspaceWindowState] = [:]
    /// The window last focused on each workspace.
    var lastFocused: [String: UInt32] = [:]

    func workspace(of window: UInt32) -> String? { windows[String(window)]?.workspace }
    func isParked(_ window: UInt32) -> Bool { windows[String(window)]?.parkedFrom != nil }
}

/// What a switch has to do to the windows on screen.
struct WorkspacePlan: Equatable {
    var park: [UInt32] = []
    var unpark: [UInt32] = []
}

enum WorkspaceSupport {
    static let title = "Workspaces"
    static let hubDescription = "Switch between virtual workspaces with a key, and send windows to them. Full-screen windows keep their own Space."
    static let maximumWorkspaces = 10
    /// Carbon hotkey ids, clear of every other feature's.
    static let hotkeyIDBase: UInt32 = 900

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.workspacesEnabled: true,
        DefaultsKey.workspacesBackAndForthEnabled: true,
        DefaultsKey.workspacesBackAndForthShortcut: GlobalShortcut(keyCode: Int64(kVK_Tab), modifiers: [.option]).storageValue,
        DefaultsKey.workspacesFollowFocus: true,
        DefaultsKey.workspacesMoveFollows: false,
        DefaultsKey.workspacesShowHUD: true,
        DefaultsKey.menuBarWorkspaces: false,
    ]

    /// The workspaces that hold windows, in their own order, plus the one in
    /// view even when it is empty, so the bar always says where you are.
    static func menuBarSquares(_ definitions: [WorkspaceDefinition], active: String?,
                               occupied: Set<String>) -> [WorkspaceMenuBarSquare] {
        definitions.filter { occupied.contains($0.id) || $0.id == active }.map { definition in
            let name = definition.name.trimmingCharacters(in: .whitespaces)
            return WorkspaceMenuBarSquare(id: definition.id,
                                          label: name.isEmpty ? "•" : String(name.prefix(1)).uppercased(),
                                          isActive: definition.id == active)
        }
    }

    /// Workspaces with at least one window assigned.
    static func occupied(_ state: WorkspaceState) -> Set<String> {
        Set(state.windows.values.map(\.workspace))
    }

    // MARK: - Definitions

    private static let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                           kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]

    /// Workspace n (1-based): ⌥n to go there, ⌥⇧n to send a window, as
    /// AeroSpace's default config has them.
    static func definition(number: Int, id: String = UUID().uuidString) -> WorkspaceDefinition {
        let key = digitKeys.indices.contains(number - 1) ? digitKeys[number - 1] : nil
        return WorkspaceDefinition(
            id: id,
            name: String(number),
            switchShortcut: key.map { GlobalShortcut(keyCode: Int64($0), modifiers: [.option]).storageValue } ?? "",
            moveShortcut: key.map { GlobalShortcut(keyCode: Int64($0), modifiers: [.option, .shift]).storageValue } ?? "")
    }

    static var defaultDefinitions: [WorkspaceDefinition] {
        // Fixed ids: the defaults are read many times before they are saved.
        (1...4).map { definition(number: $0, id: "workspace-\($0)") }
    }

    static func definitions(in defaults: UserDefaults = .standard) -> [WorkspaceDefinition] {
        guard let raw = defaults.string(forKey: DefaultsKey.workspacesDefinitions),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode([WorkspaceDefinition].self, from: data)
        else { return defaultDefinitions }
        var seen = Set<String>()
        let unique = stored.filter { seen.insert($0.id).inserted }
        return unique.isEmpty ? defaultDefinitions : Array(unique.prefix(maximumWorkspaces))
    }

    static func encode(_ definitions: [WorkspaceDefinition]) -> String {
        let data = (try? JSONEncoder().encode(Array(definitions.prefix(maximumWorkspaces)))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The lowest number not already used as a name, for a new workspace.
    static func nextNumber(after definitions: [WorkspaceDefinition]) -> Int {
        let used = Set(definitions.compactMap { Int($0.name) })
        return (1...).first { !used.contains($0) } ?? definitions.count + 1
    }

    /// Navigation keys work alone here: a keyboard that sends Page Up for a
    /// workspace is exactly how some people drive them. Letters and digits
    /// still need a modifier, or typing would switch workspaces.
    static let standaloneKeys: Set<Int64> = Set(([kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End,
                                                  kVK_ForwardDelete, kVK_Help] as [Int]).map(Int64.init))

    static func isUsable(_ shortcut: GlobalShortcut) -> Bool {
        shortcut.isValid || (shortcut.hasUsableKeyCode && standaloneKeys.contains(shortcut.keyCode))
    }

    // MARK: - State

    static func state(in defaults: UserDefaults = .standard) -> WorkspaceState? {
        guard let raw = defaults.string(forKey: DefaultsKey.workspacesState),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceState.self, from: data)
    }

    static func encode(_ state: WorkspaceState) -> String {
        String(decoding: (try? JSONEncoder().encode(state)) ?? Data(), as: UTF8.self)
    }

    /// A state that still makes sense for these definitions: the active
    /// workspace exists and windows on removed workspaces fall back to it.
    static func reconciled(_ state: WorkspaceState?, with definitions: [WorkspaceDefinition]) -> WorkspaceState {
        let ids = Set(definitions.map(\.id))
        let first = definitions.first?.id ?? ""
        var state = state ?? WorkspaceState(active: first)
        if !ids.contains(state.active) { state.active = first }
        if let previous = state.previous, !ids.contains(previous) { state.previous = nil }
        for (key, window) in state.windows where !ids.contains(window.workspace) {
            state.windows[key]?.workspace = state.active
        }
        state.lastFocused = state.lastFocused.filter { ids.contains($0.key) }
        return state
    }

    /// Brings the assignment up to date with the windows that exist and says
    /// which to park and which to bring back for `target` to be in view.
    ///
    /// - Windows the window server no longer has are forgotten.
    /// - Full-screen windows belong to no workspace; macOS gives them a Space.
    /// - A window seen for the first time joins the workspace that was in view
    ///   when it appeared, which is the one being left.
    /// - Minimized windows and windows of hidden apps keep their workspace but
    ///   are not moved; macOS already has them out of the way.
    static func plan(_ state: inout WorkspaceState, windows: [WorkspaceWindow],
                     existing: Set<UInt32>, target: String) -> WorkspacePlan {
        state.windows = state.windows.filter { key, _ in UInt32(key).map(existing.contains) ?? false }
        var plan = WorkspacePlan()
        for window in windows {
            let key = String(window.id)
            if window.isFullscreen {
                state.windows[key] = nil
                continue
            }
            if state.windows[key] == nil {
                state.windows[key] = WorkspaceWindowState(workspace: state.active, pid: window.pid)
            }
            guard let entry = state.windows[key], !window.isMinimized, !window.isAppHidden else { continue }
            if entry.workspace == target {
                if entry.parkedFrom != nil { plan.unpark.append(window.id) }
            } else if entry.parkedFrom == nil {
                plan.park.append(window.id)
            }
        }
        if state.active != target {
            state.previous = state.active
            state.active = target
        }
        return plan
    }

    // MARK: - Geometry

    /// An `NSScreen` frame (bottom-left origin) in Accessibility coordinates.
    static func axRect(_ screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY,
               width: screenFrame.width, height: screenFrame.height)
    }

    /// Where a window parks on `screen`: its top-left one pixel inside the
    /// bottom-right corner, or the bottom-left when another display sits to
    /// the right and would show the window. Zoom jumps away from the
    /// one-pixel offset, so it gets none (AeroSpace issue 527).
    static func parkingOrigin(size: CGSize, screen: CGRect, otherScreens: [CGRect],
                              zeroOffset: Bool = false) -> CGPoint {
        let inset: CGFloat = zeroOffset ? 0 : 1
        let right = CGPoint(x: screen.maxX - inset, y: screen.maxY - inset)
        let rightSpill = CGRect(x: right.x + 1, y: right.y + 1,
                                width: max(1, size.width - 1), height: max(1, size.height - 1))
        if !otherScreens.contains(where: { $0.intersects(rightSpill) }) { return right }
        let left = CGPoint(x: screen.minX - size.width + inset, y: screen.maxY - inset)
        let leftSpill = CGRect(x: left.x, y: left.y + 1,
                               width: max(1, size.width - 1), height: max(1, size.height - 1))
        return otherScreens.contains(where: { $0.intersects(leftSpill) }) ? right : left
    }

    /// True when `origin` is where a window would have been parked on one of
    /// `screens`, give or take a few points. Used to find windows a crash left
    /// in a corner.
    static func looksParked(_ frame: CGRect, screens: [CGRect]) -> Bool {
        parkedScreen(for: frame, in: screens) != nil
    }

    /// The screen whose corner a parked window sits in. Overlap would mislead:
    /// a parked window can cover more of the display beside it than of its own.
    static func parkedScreen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
        // macOS keeps a sliver of the title bar on screen, so a window asked
        // to sit at the very bottom stops a little above it (about 30 points
        // on macOS 27). Only the edge it hangs off is exact.
        screens.first { screen in
            let right = abs(frame.minX - (screen.maxX - 1)) <= 3
            let left = abs(frame.maxX - (screen.minX + 1)) <= 3
            return (right || left) && frame.minY >= screen.maxY - 80 && frame.minY <= screen.maxY + 2
        }
    }

    /// The window's top-left as a fraction of its screen, so it comes back to
    /// the same place even if the display changed size meanwhile.
    static func relativeOrigin(_ origin: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: (origin.x - screen.minX) / max(1, screen.width),
                y: (origin.y - screen.minY) / max(1, screen.height))
    }

    /// Back from a fraction to a point, kept on the screen.
    static func restoredOrigin(_ relative: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        let x = screen.minX + relative.x * screen.width
        let y = screen.minY + relative.y * screen.height
        return CGPoint(x: min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                       y: min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    /// The screen a frame mostly sits on; the first one when it is off all.
    static func screen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { $0.contains(center) }) { return containing }
        return screens.max { $0.intersection(frame).area < $1.intersection(frame).area }
            .flatMap { $0.intersection(frame).area > 0 ? $0 : nil } ?? screens.first
    }

    static func centered(_ size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: screen.midX - min(size.width, screen.width) / 2,
                y: screen.midY - min(size.height, screen.height) / 2)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
