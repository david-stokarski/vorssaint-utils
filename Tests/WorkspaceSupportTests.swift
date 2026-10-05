// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Fork: workspaces. Defaults match AeroSpace's, the switch plan parks and
/// returns the right windows, full screen stays out of it, and parking
/// geometry round-trips.
enum WorkspaceSupportTests {
    static func run(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.workspaces")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.workspaces")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.workspaces") }

        // Definitions.
        let stock = WorkspaceSupport.definitions(in: defaults)
        suite.expect(stock.map(\.name) == ["1", "2", "3", "4"], "four workspaces by default")
        suite.expect(stock.map(\.id) == WorkspaceSupport.definitions(in: defaults).map(\.id),
                     "default ids are stable across reads")
        suite.expect(GlobalShortcut(storageValue: stock[0].switchShortcut)
                        == GlobalShortcut(keyCode: Int64(kVK_ANSI_1), modifiers: [.option]),
                     "⌥1 goes to workspace 1")
        suite.expect(GlobalShortcut(storageValue: stock[3].moveShortcut)
                        == GlobalShortcut(keyCode: Int64(kVK_ANSI_4), modifiers: [.option, .shift]),
                     "⌥⇧4 sends a window to workspace 4")
        var custom = stock
        custom[1].name = "Mail"
        defaults.set(WorkspaceSupport.encode(custom), forKey: DefaultsKey.workspacesDefinitions)
        suite.expect(WorkspaceSupport.definitions(in: defaults) == custom, "definitions round-trip")
        suite.expect(WorkspaceSupport.nextNumber(after: custom) == 2, "the first free number is reused")
        suite.expect(WorkspaceSupport.isUsable(GlobalShortcut(keyCode: Int64(kVK_PageUp), modifiers: [])),
                     "Page Up works alone")
        suite.expect(WorkspaceSupport.isUsable(GlobalShortcut(keyCode: Int64(kVK_End), modifiers: [.shift])),
                     "⇧End works")
        suite.expect(!WorkspaceSupport.isUsable(GlobalShortcut(keyCode: Int64(kVK_ANSI_A), modifiers: [])),
                     "a bare letter does not")

        // The plan.
        let one = stock[0].id, two = stock[1].id
        var state = WorkspaceState(active: one)
        let chrome = WorkspaceWindow(id: 10, pid: 1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let slack = WorkspaceWindow(id: 11, pid: 2, frame: CGRect(x: 200, y: 120, width: 600, height: 500))
        var plan = WorkspaceSupport.plan(&state, windows: [chrome, slack], existing: [10, 11], target: two)
        suite.expect(plan.park.sorted() == [10, 11] && plan.unpark.isEmpty,
                     "new windows join the workspace being left and park")
        suite.expect(state.active == two && state.previous == one, "the switch is recorded")
        state.windows["10"]?.parkedFrom = CGPoint(x: 0.1, y: 0.1)
        state.windows["11"]?.parkedFrom = CGPoint(x: 0.2, y: 0.1)
        let terminal = WorkspaceWindow(id: 12, pid: 3, frame: CGRect(x: 0, y: 30, width: 500, height: 400))
        plan = WorkspaceSupport.plan(&state, windows: [chrome, slack, terminal], existing: [10, 11, 12], target: one)
        suite.expect(plan.unpark.sorted() == [10, 11] && plan.park == [12],
                     "going back returns workspace 1 and parks what opened on 2")
        suite.expect(state.workspace(of: 12) == two, "a window opened on 2 belongs to 2")

        // Full screen and other states.
        var fullscreen = chrome
        fullscreen.isFullscreen = true
        plan = WorkspaceSupport.plan(&state, windows: [fullscreen, slack, terminal], existing: [10, 11, 12], target: two)
        suite.expect(state.workspace(of: 10) == nil && !plan.park.contains(10) && !plan.unpark.contains(10),
                     "a full-screen window leaves its workspace and is never moved")
        var minimized = slack
        minimized.isMinimized = true
        state = WorkspaceState(active: one, windows: ["11": WorkspaceWindowState(workspace: one, pid: 2)])
        plan = WorkspaceSupport.plan(&state, windows: [minimized], existing: [11], target: two)
        suite.expect(plan.park.isEmpty && state.workspace(of: 11) == one,
                     "a minimized window keeps its workspace without being moved")
        state = WorkspaceState(active: one, windows: ["99": WorkspaceWindowState(workspace: two, pid: 9)])
        _ = WorkspaceSupport.plan(&state, windows: [], existing: [], target: one)
        suite.expect(state.windows.isEmpty, "closed windows are forgotten")
        state = WorkspaceState(active: one, windows: ["98": WorkspaceWindowState(workspace: two, pid: 9)])
        _ = WorkspaceSupport.plan(&state, windows: [], existing: [98], target: one)
        suite.expect(state.workspace(of: 98) == two, "a window Accessibility can't see from here is kept")

        // Reconciling with edited definitions.
        let stale = WorkspaceState(active: "gone", previous: "gone",
                                   windows: ["5": WorkspaceWindowState(workspace: "gone", pid: 1)],
                                   lastFocused: ["gone": 5])
        let fixed = WorkspaceSupport.reconciled(stale, with: stock)
        suite.expect(fixed.active == one && fixed.previous == nil && fixed.workspace(of: 5) == one
                        && fixed.lastFocused.isEmpty,
                     "a removed workspace hands its windows to the first one")
        let roundTrip = WorkspaceSupport.state(in: {
            defaults.set(WorkspaceSupport.encode(fixed), forKey: DefaultsKey.workspacesState)
            return defaults
        }())
        suite.expect(roundTrip == fixed, "state round-trips through defaults")

        // Geometry (Accessibility coordinates).
        let main = CGRect(x: 0, y: 25, width: 1512, height: 957)
        let size = CGSize(width: 800, height: 600)
        let parked = WorkspaceSupport.parkingOrigin(size: size, screen: main, otherScreens: [])
        suite.expect(parked == CGPoint(x: 1511, y: 981), "a window parks one pixel inside the bottom-right corner")
        suite.expect(WorkspaceSupport.parkingOrigin(size: size, screen: main, otherScreens: [], zeroOffset: true)
                        == CGPoint(x: 1512, y: 982), "Zoom parks with no offset")
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let leftward = WorkspaceSupport.parkingOrigin(size: size, screen: main, otherScreens: [right])
        suite.expect(leftward.x == -799, "a display to the right sends the window to the bottom-left")
        suite.expect(WorkspaceSupport.looksParked(CGRect(origin: parked, size: size), screens: [main])
                        && WorkspaceSupport.looksParked(CGRect(origin: leftward, size: size), screens: [main])
                        && !WorkspaceSupport.looksParked(CGRect(x: 100, y: 100, width: 800, height: 600), screens: [main]),
                     "parked windows are recognized")
        let origin = CGPoint(x: 300, y: 200)
        let relative = WorkspaceSupport.relativeOrigin(origin, in: main)
        let back = WorkspaceSupport.restoredOrigin(relative, size: size, in: main)
        suite.expect(abs(back.x - origin.x) < 0.001 && abs(back.y - origin.y) < 0.001, "positions round-trip")
        let clamped = WorkspaceSupport.restoredOrigin(CGPoint(x: 0.95, y: 0.95), size: size, in: main)
        suite.expect(clamped.x == main.maxX - size.width && clamped.y == main.maxY - size.height,
                     "a restored window stays on its screen")
        suite.expect(WorkspaceSupport.parkedScreen(for: CGRect(origin: leftward, size: size), in: [main, right]) == main
                        && WorkspaceSupport.parkedScreen(for: CGRect(origin: parked, size: size), in: [right, main]) == main,
                     "a parked window still belongs to the screen it was parked on")
        suite.expect(WorkspaceSupport.axRect(CGRect(x: 0, y: 0, width: 1512, height: 957), primaryHeight: 982)
                        == CGRect(x: 0, y: 25, width: 1512, height: 957),
                     "screen frames flip into Accessibility coordinates")
    }
}
