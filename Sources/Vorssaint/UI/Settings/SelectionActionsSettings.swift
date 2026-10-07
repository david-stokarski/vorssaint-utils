// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: Settings › Selection Actions. When the bar appears, which actions
/// it carries and in what order, the user's own prompts, Shortcuts and
/// scripts, the search engine and translation language, and the apps it
/// stays out of.
struct SelectionActionsSettings: View {
    @ObservedObject private var service = SelectionActionsService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.selectionActionsEnabled) private var enabled = true
    @AppStorage(DefaultsKey.selectionActionsTrigger) private var trigger = SelectionTriggerMode.automatic.rawValue
    @AppStorage(DefaultsKey.selectionActionsMinLength) private var minLength = 2
    @AppStorage(DefaultsKey.selectionActionsSuppressModifier) private var suppress = SelectionSuppressModifier.none.rawValue
    @AppStorage(DefaultsKey.selectionActionsDismissDelay) private var dismissDelay = SelectionActionsSupport.defaultDismissDelay
    @AppStorage(DefaultsKey.selectionActionsClipboardFallback) private var clipboardFallback = false
    @AppStorage(DefaultsKey.selectionActionsShortcut) private var shortcutRaw = ""
    @AppStorage(DefaultsKey.selectionActionsOrder) private var orderRaw = ""
    @AppStorage(DefaultsKey.selectionActionsCustom) private var customRaw = "[]"
    @AppStorage(DefaultsKey.selectionActionsSearchEngine) private var engine = SelectionSearchEngine.google.rawValue
    @AppStorage(DefaultsKey.selectionActionsCustomSearchURL) private var customSearchURL = ""
    @AppStorage(DefaultsKey.selectionActionsTranslateTarget) private var translateTarget = ""
    @State private var excluded: [String] = SelectionExcludedApps.current()
    @State private var shortcutMessage: String?
    @State private var expandedCustom: UUID?
    @State private var availableShortcuts: [String] = []
    @State private var aiConfigured = SelectionAI.engine.isConfigured

    private var order: [SelectionActionEntry] {
        SelectionActionOrder.resolve(orderRaw.isEmpty ? nil : orderRaw, custom: custom)
    }

    private var custom: [SelectionCustomAction] { SelectionCustomAction.decode(customRaw) }

    private var scriptLinks: [CommandBarLink] {
        CommandBarLinks.decode(UserDefaults.standard.data(forKey: DefaultsKey.commandBarLinks)).filter { $0.kind == .script }
    }

    var body: some View {
        Form {
            Section {
                Toggle(SelectionActionsSupport.title, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("Select text with the pointer, by dragging or with a double or triple click, and a small bar of actions appears above it. It never takes the keyboard: keep typing, click elsewhere, scroll or press Esc and it goes away.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !permissions.accessibility { PermissionRow(kind: .accessibility) }
            } header: {
                Text(SelectionActionsSupport.title)
            }

            triggerSection
            actionsSection
            customSection
            searchSection
            aiSection
            excludedSection
        }
        .formStyle(.grouped)
        .onAppear {
            aiConfigured = SelectionAI.engine.isConfigured
            excluded = SelectionExcludedApps.current()
        }
    }

    // MARK: - Trigger

    private var triggerSection: some View {
        Section {
            Picker("Show the bar", selection: $trigger) {
                Text("When text is selected").tag(SelectionTriggerMode.automatic.rawValue)
                Text("Only with the shortcut").tag(SelectionTriggerMode.shortcutOnly.rawValue)
            }
            .onChange(of: trigger) { _, _ in service.syncWithPreferences() }
            HStack {
                Text("Shortcut")
                Spacer()
                shortcutRecorder
            }
            if let shortcutMessage {
                Text(shortcutMessage).font(.caption).foregroundStyle(.orange)
            } else if service.shortcutRegistrationFailed {
                Text(l10n.s.shortcutUnavailable).font(.caption).foregroundStyle(.orange)
            }
            if trigger == SelectionTriggerMode.automatic.rawValue {
                Stepper(value: $minLength, in: SelectionActionsSupport.minLengthRange) {
                    LabeledContent("Minimum selection", value: "\(minLength) character\(minLength == 1 ? "" : "s")")
                }
                Picker("Hold to skip the bar", selection: $suppress) {
                    ForEach(SelectionSuppressModifier.allCases, id: \.rawValue) { modifier in
                        Text(modifier.title).tag(modifier.rawValue)
                    }
                }
            }
            LabeledContent("Hide after") {
                HStack(spacing: 8) {
                    Slider(value: $dismissDelay, in: SelectionActionsSupport.dismissDelayRange, step: 1)
                        .frame(maxWidth: 220)
                    Text("\(Int(dismissDelay)) s").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Toggle("Copy the selection when an app doesn't share it", isOn: $clipboardFallback)
        } header: {
            Text("Trigger")
        } footer: {
            Text("The shortcut shows the bar for whatever is selected, however short. Some apps don't tell Accessibility what is selected; for those, the copy option presses ⌘C for a moment and puts the clipboard back as it was, marked so clipboard managers skip it. The bar never appears in a password field or while an app has secure input on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutRecorder: some View {
        let shortcut = GlobalShortcut(storageValue: shortcutRaw)
        return ShortcutRecorderButton(
            shortcut: shortcut ?? GlobalShortcut(keyCode: 0, modifiers: [.option]),
            isEnabled: enabled,
            waitingTitle: l10n.s.shortcutPressKeys,
            emptyTitle: shortcut == nil ? "Record" : nil,
            clearAction: {
                shortcutRaw = ""
                service.syncWithPreferences()
            },
            notCapturedAction: { shortcutMessage = l10n.s.shortcutNotCaptured },
            recordingChanged: { if $0 { shortcutMessage = nil } },
            invalidAction: { shortcutMessage = l10n.s.shortcutInvalid },
            captureAction: { captured in
                if let clash = GlobalShortcutRole.conflict(for: captured, excluding: nil) {
                    shortcutMessage = "\(captured.displayString) is already used by \(clash.title(l10n.s))."
                    return
                }
                shortcutRaw = captured.storageValue
                service.syncWithPreferences()
            })
            .frame(width: 150)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            let entries = order
            ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: entry))
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: Binding(get: { entry.enabled }, set: { setEnabled($0, at: index) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(for: entry))
                            if let note = note(for: entry) {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move left in the bar")
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == entries.count - 1)
                        .help("Move right in the bar")
                }
            }
            Button("Restore Default Actions") {
                orderRaw = SelectionActionOrder.encode(SelectionActionOrder.resolve(nil, custom: custom))
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("The bar shows the actions that are on, in this order, left to right. Open Link only appears for a web address and Clean Whitespace only when there is something to clean. Change case and whitespace go straight back into a text field; elsewhere the result shows to copy.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(for entry: SelectionActionEntry) -> String {
        if let id = entry.builtIn { return id.title }
        return custom.first { $0.actionKey == entry.key }?.name ?? entry.key
    }

    private func symbol(for entry: SelectionActionEntry) -> String {
        if let id = entry.builtIn { return id.symbolName }
        return custom.first { $0.actionKey == entry.key }?.kind.symbolName ?? "questionmark"
    }

    private func note(for entry: SelectionActionEntry) -> String? {
        if let id = entry.builtIn {
            if id.usesAI { return "AI" }
            if id == .translate { return "On-device on macOS 15 and later, otherwise AI" }
            return nil
        }
        return custom.first { $0.actionKey == entry.key }?.kind.title
    }

    private func setEnabled(_ value: Bool, at index: Int) {
        var entries = order
        guard entries.indices.contains(index) else { return }
        entries[index].enabled = value
        orderRaw = SelectionActionOrder.encode(entries)
    }

    private func move(_ index: Int, by offset: Int) {
        orderRaw = SelectionActionOrder.encode(SelectionActionOrder.moved(order, from: index, by: offset))
    }

    // MARK: - Custom actions

    private var customSection: some View {
        Section {
            ForEach(custom) { action in
                DisclosureGroup(isExpanded: Binding(get: { expandedCustom == action.id },
                                                    set: { expandedCustom = $0 ? action.id : nil })) {
                    customEditor(action)
                } label: {
                    Label {
                        Text(action.name.isEmpty ? "Untitled" : action.name)
                    } icon: {
                        Image(systemName: action.kind.symbolName)
                    }
                }
            }
            Menu {
                Button("AI Prompt") { addCustom(.aiPrompt) }
                Button("Shortcut") { addCustom(.shortcut) }
                Button("Command Bar Script") { addCustom(.script) }
                    .disabled(scriptLinks.isEmpty)
            } label: {
                Label("Add Action", systemImage: "plus")
            }
            .fixedSize()
        } header: {
            Text("Your Actions")
        } footer: {
            Text("An AI prompt puts the selection where it says {{text}}, or after the prompt when it doesn't; {{language}} is the translation language. A Shortcut gets the selection as its input, and a Command Bar script as its one argument. Whatever they give back shows with Copy and Replace.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func customEditor(_ action: SelectionCustomAction) -> some View {
        TextField("Name", text: customBinding(action.id, \.name))
        Picker("Kind", selection: customBinding(action.id, \.kind)) {
            ForEach(SelectionCustomAction.Kind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        switch action.kind {
        case .aiPrompt:
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: customBinding(action.id, \.value))
                    .font(.system(size: 12))
                    .frame(minHeight: 70)
            }
        case .shortcut:
            HStack {
                TextField("Shortcut name", text: customBinding(action.id, \.value))
                Menu("Choose") {
                    ForEach(availableShortcuts, id: \.self) { name in
                        Button(name) { update(action.id) { $0.value = name } }
                    }
                }
                .fixedSize()
                .disabled(availableShortcuts.isEmpty)
            }
            .onAppear(perform: loadShortcuts)
        case .script:
            Picker("Script", selection: customBinding(action.id, \.value)) {
                Text("Choose…").tag("")
                ForEach(scriptLinks) { link in
                    Text(link.name).tag(link.id.uuidString)
                }
            }
        }
        Toggle("Offer Replace for the result", isOn: customBinding(action.id, \.replaces))
        Button("Delete Action", role: .destructive) { removeCustom(action.id) }
    }

    private func customBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<SelectionCustomAction, Value>) -> Binding<Value> {
        Binding(get: {
            custom.first { $0.id == id }?[keyPath: keyPath] ?? SelectionCustomAction()[keyPath: keyPath]
        }, set: { value in
            update(id) { $0[keyPath: keyPath] = value }
        })
    }

    private func update(_ id: UUID, _ change: (inout SelectionCustomAction) -> Void) {
        var list = custom
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        customRaw = SelectionCustomAction.encode(list)
    }

    private func addCustom(_ kind: SelectionCustomAction.Kind) {
        var action = SelectionCustomAction(kind: kind)
        switch kind {
        case .aiPrompt:
            action.name = "Summarize"
            action.value = "Summarize the following text in two sentences.\n\n{{text}}"
            action.replaces = false
        case .shortcut:
            action.name = "Shortcut"
        case .script:
            action.name = scriptLinks.first?.name ?? "Script"
            action.value = scriptLinks.first?.id.uuidString ?? ""
        }
        var list = custom
        list.append(action)
        customRaw = SelectionCustomAction.encode(list)
        expandedCustom = action.id
    }

    private func removeCustom(_ id: UUID) {
        var list = custom
        list.removeAll { $0.id == id }
        customRaw = SelectionCustomAction.encode(list)
        orderRaw = SelectionActionOrder.encode(SelectionActionOrder.resolve(orderRaw.isEmpty ? nil : orderRaw,
                                                                            custom: list))
    }

    private func loadShortcuts() {
        guard availableShortcuts.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, output) = Shell.run("/usr/bin/shortcuts", ["list"], timeout: 10, maxOutputBytes: 256 * 1024)
            let names = status == 0
                ? output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.sorted()
                : []
            DispatchQueue.main.async { availableShortcuts = names }
        }
    }

    // MARK: - Search and translation

    private var searchSection: some View {
        Section {
            Picker("Search with", selection: $engine) {
                ForEach(SelectionSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine.rawValue)
                }
            }
            if engine == SelectionSearchEngine.custom.rawValue {
                TextField("Search address", text: $customSearchURL, prompt: Text("https://example.com/search?q=%s"))
                if !customSearchURL.isEmpty, !SelectionSearchEngine.isUsableTemplate(customSearchURL) {
                    Text("Use a web address with %s where the text goes. Until then, Google is used.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Translate into", selection: $translateTarget) {
                Text("System language (\(SelectionTranslation.name(for: SelectionTranslation.targetCode(saved: nil))))").tag("")
                ForEach(SelectionTranslation.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
        } header: {
            Text("Search and Translate")
        } footer: {
            Text("Translation runs on this Mac with Apple's translation on macOS 15 and later; the first time a language is used macOS may ask to download it. When it can't, AI translates instead.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiSection: some View {
        Section {
            LabeledContent("Model") {
                Text(AIChatSupport.defaultModel().displayName).foregroundStyle(.secondary)
            }
            if aiConfigured {
                Label("Ready. AI actions use AI Chat's default model and key.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("No API key yet. AI actions open AI Chat's settings until one is added.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Button("Open AI Chat Settings") {
                SelectionAI.engine.openSettings()
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Rewrite, Fix Grammar, Make Shorter, Make Friendlier, Explain and your AI prompts send the selection to the model chosen in AI Chat. Nothing is sent until you click one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Excluded apps

    private var excludedSection: some View {
        Section {
            AppBundleList(title: "Apps without the bar",
                          caption: "The bar never appears while one of these apps is in front. Password managers and terminals are listed to begin with.",
                          addTitle: "Add App…",
                          removeLabel: "Remove",
                          bundleIDs: excluded,
                          reachesEveryApp: true,
                          onAdd: { id in
                              guard !excluded.contains(id) else { return }
                              excluded.append(id)
                              saveExcluded()
                          },
                          onRemove: { id in
                              excluded.removeAll { $0 == id }
                              saveExcluded()
                          })
            Button("Restore Default Apps") {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.selectionActionsExcludedApps)
                excluded = SelectionExcludedApps.current()
            }
        }
    }

    private func saveExcluded() {
        UserDefaults.standard.set(excluded, forKey: DefaultsKey.selectionActionsExcludedApps)
    }
}
