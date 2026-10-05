// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: Settings › Workspaces. The list of workspaces with the key that goes
/// to each and the key that sends the focused window there, plus how
/// switching behaves.
struct WorkspaceSettings: View {
    @ObservedObject private var service = WorkspaceService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.workspacesEnabled) private var enabled = true
    @AppStorage(DefaultsKey.workspacesDefinitions) private var definitionsRaw = ""
    @AppStorage(DefaultsKey.workspacesBackAndForthEnabled) private var backAndForth = true
    @AppStorage(DefaultsKey.workspacesBackAndForthShortcut) private var backAndForthShortcut = ""
    @AppStorage(DefaultsKey.workspacesFollowFocus) private var followFocus = true
    @AppStorage(DefaultsKey.workspacesMoveFollows) private var moveFollows = false
    @AppStorage(DefaultsKey.workspacesShowHUD) private var showHUD = true
    @State private var message: String?
    @State private var importing = false

    private var definitions: [WorkspaceDefinition] {
        _ = definitionsRaw  // Read so a change redraws the list.
        return WorkspaceSupport.definitions()
    }

    private func importAeroSpace() {
        importing = true
        service.importFromAeroSpace { result in
            importing = false
            message = result
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Workspaces", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("Each window belongs to one workspace. Switching tucks the other workspaces' windows into a screen corner and brings the chosen ones back where they were. Full-screen windows leave their workspace and get their own macOS Space; when they leave full screen they join the workspace in view.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !permissions.accessibility { PermissionRow(kind: .accessibility) }
                if service.waitsForAeroSpace {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AeroSpace is running, so Workspaces is waiting. Two window managers would fight over the same windows.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(importing ? "Importing…" : "Import from AeroSpace and Quit It") { importAeroSpace() }
                            .disabled(importing || !permissions.accessibility)
                        Text("Keeps every window on the workspace it's on now, quits AeroSpace, stops it opening at login, and starts Workspaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if service.isRunning, let active = service.activeWorkspaceID,
                   let current = definitions.first(where: { $0.id == active }) {
                    LabeledContent("Now showing", value: current.name)
                }
            } header: {
                Text(WorkspaceSupport.title)
            }

            Section {
                HStack {
                    Text("Name").frame(width: 110, alignment: .leading)
                    Text("Go to").frame(width: 150, alignment: .leading)
                    Text("Send window").frame(width: 150, alignment: .leading)
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(definitions) { definition in
                    row(definition)
                }
                HStack {
                    Button("Add Workspace") { add() }
                        .disabled(definitions.count >= WorkspaceSupport.maximumWorkspaces)
                    Spacer()
                    Text("\(definitions.count) of \(WorkspaceSupport.maximumWorkspaces)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Workspaces and keys")
            } footer: {
                Text("Page Up, Page Down, Home and End can be used on their own. Other keys need ⌥, ⌃ or ⌘.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Go back to the previous workspace", isOn: $backAndForth)
                    .onChange(of: backAndForth) { _, _ in service.syncWithPreferences() }
                if backAndForth {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        recorder(backAndForthShortcut, refusedKey: DefaultsKey.workspacesBackAndForthShortcut) {
                            backAndForthShortcut = $0
                        }
                    }
                }
                Toggle("Switch to a window's workspace when it's activated", isOn: $followFocus)
                Text("Choosing a window with ⌘Tab, the Dock or a notification takes you to its workspace.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Follow a window you send to another workspace", isOn: $moveFollows)
                Toggle("Show the workspace name when switching", isOn: $showHUD)
                Toggle("Show workspaces in the menu bar", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: DefaultsKey.menuBarWorkspaces) },
                    set: { UserDefaults.standard.set($0, forKey: DefaultsKey.menuBarWorkspaces); WorkspaceMenuBarItem.shared.sync() }))
            }

            Section {
                Button("Bring All Windows Here") { service.gatherAll() }
                    .disabled(!service.isRunning)
            } header: {
                Text("Windows")
            } footer: {
                Text("Turning Workspaces off or quitting Vorssaint brings every window back into view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ definition: WorkspaceDefinition) -> some View {
        HStack(spacing: 10) {
            TextField("Name", text: Binding(
                get: { definition.name },
                set: { name in update(definition.id) { $0.name = name } }))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 110)
            recorder(definition.switchShortcut, refusedKey: "workspaces.\(definition.id).switch") { raw in
                update(definition.id) { $0.switchShortcut = raw }
            }
            recorder(definition.moveShortcut, refusedKey: "workspaces.\(definition.id).move") { raw in
                update(definition.id) { $0.moveShortcut = raw }
            }
            Spacer()
            Button { remove(definition.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(definitions.count <= 1)
                .help("Remove workspace")
        }
    }

    private func recorder(_ raw: String, refusedKey: String, set: @escaping (String) -> Void) -> some View {
        let shortcut = GlobalShortcut(storageValue: raw, requiringModifier: false)
        return HStack(spacing: 4) {
            ShortcutRecorderButton(
                shortcut: shortcut ?? GlobalShortcut(keyCode: 0, modifiers: [.option]),
                isEnabled: true,
                waitingTitle: l10n.s.shortcutPressKeys,
                requiresModifier: false,
                emptyTitle: shortcut == nil ? "Record" : nil,
                clearAction: { set(""); apply() },
                notCapturedAction: { message = l10n.s.shortcutNotCaptured },
                recordingChanged: { if $0 { message = nil } },
                invalidAction: { message = l10n.s.shortcutInvalid },
                captureAction: { captured in
                    guard WorkspaceSupport.isUsable(captured) else {
                        message = "Use ⌥, ⌃ or ⌘ with that key, or one of Page Up, Page Down, Home and End."
                        return
                    }
                    if let clash = clash(captured, except: refusedKey) {
                        message = "\(captured.displayString) is already used by \(clash)."
                        return
                    }
                    set(captured.storageValue)
                    apply()
                })
                .frame(width: 130)
            if service.refusedShortcuts.contains(refusedKey) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(l10n.s.shortcutUnavailable)
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    /// Another workspace key, or one of Vorssaint's own shortcuts.
    private func clash(_ shortcut: GlobalShortcut, except key: String) -> String? {
        for definition in definitions {
            if "workspaces.\(definition.id).switch" != key,
               GlobalShortcut(storageValue: definition.switchShortcut, requiringModifier: false) == shortcut {
                return "Go to \(definition.name)"
            }
            if "workspaces.\(definition.id).move" != key,
               GlobalShortcut(storageValue: definition.moveShortcut, requiringModifier: false) == shortcut {
                return "Send window to \(definition.name)"
            }
        }
        if key != DefaultsKey.workspacesBackAndForthShortcut, backAndForth,
           GlobalShortcut(storageValue: backAndForthShortcut, requiringModifier: false) == shortcut {
            return "Previous workspace"
        }
        return GlobalShortcutRole.conflict(for: shortcut, excluding: nil)?.title(l10n.s)
    }

    private func update(_ id: String, _ change: (inout WorkspaceDefinition) -> Void) {
        var list = definitions
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        definitionsRaw = WorkspaceSupport.encode(list)
        apply()
    }

    private func add() {
        var list = definitions
        guard list.count < WorkspaceSupport.maximumWorkspaces else { return }
        list.append(WorkspaceSupport.definition(number: WorkspaceSupport.nextNumber(after: list)))
        definitionsRaw = WorkspaceSupport.encode(list)
        apply()
    }

    private func remove(_ id: String) {
        var list = definitions
        guard list.count > 1 else { return }
        list.removeAll { $0.id == id }
        definitionsRaw = WorkspaceSupport.encode(list)
        apply()
    }

    private func apply() {
        service.syncWithPreferences()
    }
}

/// Fork: the Monitor page's switch for the workspaces menu bar item.
struct WorkspaceMenuBarSetting: View {
    @AppStorage(DefaultsKey.menuBarWorkspaces) private var shown = false
    @ObservedObject private var service = WorkspaceService.shared

    var body: some View {
        SettingsRow(symbol: "square.stack.3d.up", title: "Workspaces",
                    caption: service.isRunning
                        ? "A square for each workspace with windows: filled for the one you're on. Click one to go there."
                        : "Turn on Workspaces to show them here.") {
            Toggle("Workspaces", isOn: $shown)
                .labelsHidden()
                .onChange(of: shown) { _, _ in WorkspaceMenuBarItem.shared.sync() }
        }
    }
}
