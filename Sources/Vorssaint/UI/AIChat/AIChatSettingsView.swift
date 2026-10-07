// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: API keys, the default model and the system prompt for AI Chat.
struct AIChatSettingsView: View {
    @ObservedObject var service: AIChatService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.aiChatDefaultModel) private var defaultModel = AIModelChoice.fallbackDefault.storageValue
    @AppStorage(DefaultsKey.aiChatSystemPrompt) private var systemPrompt = ""
    @AppStorage(DefaultsKey.commandBarAskAI) private var askAI = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Providers") {
                    ForEach(AIProvider.builtIn) { provider in
                        AIProviderKeyRow(service: service, provider: provider)
                    }
                }
                AIEndpointsSection(service: service)
                Section("Defaults") {
                    AIDefaultModelPicker(service: service, selection: $defaultModel)
                    Toggle("Offer “Ask AI” in the Command Bar when nothing matches", isOn: $askAI)
                }
                Section {
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12.5))
                        .frame(height: 80)
                } header: {
                    Text("System prompt")
                } footer: {
                    Text("Sent with every chat. Leave empty for none.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Keys are stored in your login keychain. Chats are saved on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 640)
        .onAppear { service.reloadEndpoints() }
    }
}

struct AIProviderKeyRow: View {
    @ObservedObject var service: AIChatService
    let provider: AIProvider
    @State private var key = ""
    @State private var failed = false

    private var isSet: Bool { service.keyedProviders.contains(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.title).font(.headline)
                if isSet {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Link("Get a key", destination: provider.consoleURL)
                    .font(.caption)
            }
            HStack {
                SecureField("\(provider.title) API key", text: $key,
                            prompt: Text(isSet ? "Paste a new key to replace it" : provider.keyPlaceholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if isSet {
                    Button("Remove", role: .destructive) { service.setKey(nil, for: provider) }
                }
            }
            if failed {
                Text("The keychain refused the key.").font(.caption).foregroundStyle(.orange)
            } else if let error = service.modelErrors[provider.rawValue], isSet {
                Text("Couldn't list models: \(error)").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        failed = !service.setKey(key, for: provider)
        if !failed { key = "" }
    }
}

/// Fork: the Command Bar page's way into AI Chat.
struct CommandBarAskAISection: View {
    @AppStorage(DefaultsKey.commandBarAskAI) private var askAI = true
    @AppStorage(DefaultsKey.aiChatDefaultModel) private var defaultModel = AIModelChoice.fallbackDefault.storageValue

    var body: some View {
        Section {
            Toggle("Ask AI when nothing matches", isOn: $askAI)
            LabeledContent("Default model") {
                Text(AIModelChoice(storageValue: defaultModel)?.displayName ?? defaultModel)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open AI Chat") { AIChatService.shared.show() }
                Button("Models & Keys…") {
                    AIChatService.shared.show()
                    AIChatService.shared.showsSettings = true
                }
            }
        } header: {
            Text("AI Chat")
        } footer: {
            Text("Press Return on a search with no results to ask your default model. Chats are kept in the AI Chat window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Fork: Settings › AI Chat.
struct AIChatSettingsPage: View {
    @ObservedObject private var service = AIChatService.shared
    @AppStorage(DefaultsKey.aiChatDefaultModel) private var defaultModel = AIModelChoice.fallbackDefault.storageValue
    @AppStorage(DefaultsKey.aiChatSystemPrompt) private var systemPrompt = ""
    @AppStorage(DefaultsKey.commandBarAskAI) private var askAI = true
    @AppStorage(DefaultsKey.notchTabs) private var tabsRaw: String?
    @AppStorage(DefaultsKey.notchHiddenModules) private var hiddenModules = ""
    @State private var confirmsDeleteAll = false

    private let tab = NotchTabItem.action(.module(.aiChat))

    private var isTab: Bool {
        _ = tabsRaw  // Read so a change redraws the toggle.
        return NotchTabbedLayout.storedTabs().contains(tab)
    }

    private var tabsFull: Bool {
        _ = tabsRaw
        return NotchTabbedLayout.storedTabs().count >= NotchTabbedLayout.maximumTabs
    }

    private var hiddenInIsland: Bool {
        hiddenModules.split(separator: ",").contains { $0 == NotchModule.aiChat.rawValue }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(AIChatSupport.hubDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open AI Chat") { service.show() }
                }
            } header: {
                Text(AIChatSupport.title)
            }

            Section {
                ForEach(AIProvider.builtIn) { provider in
                    AIProviderKeyRow(service: service, provider: provider)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys are stored in your login keychain and only sent to their own provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            AIEndpointsSection(service: service)

            Section("Chats") {
                AIDefaultModelPicker(service: service, selection: $defaultModel)
                VStack(alignment: .leading, spacing: 6) {
                    Text("System prompt")
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12.5))
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    Text("Sent with every chat. Leave empty for none.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Command Bar") {
                Toggle("Ask AI when a search finds nothing", isOn: $askAI)
                Text("Press Return on a search with no results to start a chat with your default model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            AIAskSelectionSection()

            Section("Dynamic Island") {
                Toggle("Show AI Chat in the island", isOn: Binding(get: { !hiddenInIsland }, set: setShownInIsland))
                Toggle("Pin as a tab at the top left", isOn: Binding(get: { isTab }, set: setTab))
                    .disabled(hiddenInIsland || (!isTab && tabsFull))
                if !isTab, tabsFull {
                    Text("The island already has \(NotchTabbedLayout.maximumTabs) tabs. Remove one in Dynamic Island settings first.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Ask from the island and keep chatting there; the same chats open in the AI Chat window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Saved chats", value: "\(service.conversations.filter { !$0.messages.isEmpty }.count)")
                HStack {
                    Button("Show in Finder") {
                        guard let directory = AIChatStore.directory else { return }
                        PrivateFileStore.createDirectory(at: directory)
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                    Button("Delete All Chats…", role: .destructive) { confirmsDeleteAll = true }
                        .disabled(service.conversations.allSatisfy { $0.messages.isEmpty })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            service.loadIfNeeded()
            service.reloadEndpoints()
        }
        .confirmationDialog("Delete all chats?", isPresented: $confirmsDeleteAll) {
            Button("Delete All Chats", role: .destructive) { service.deleteAll() }
        } message: {
            Text("Every saved chat is removed from this Mac. This can't be undone.")
        }
    }

    private func setTab(_ on: Bool) {
        var tabs = NotchTabbedLayout.storedTabs()
        if on {
            guard !tabs.contains(tab), tabs.count < NotchTabbedLayout.maximumTabs else { return }
            tabs.append(tab)
        } else {
            tabs.removeAll { $0 == tab }
        }
        tabsRaw = NotchTabbedLayout.encode(tabs)
        NotchService.shared.syncWithPreferences()
        NotchService.shared.refreshPresentation(animated: false)
    }

    private func setShownInIsland(_ shown: Bool) {
        var hidden = hiddenModules.split(separator: ",").map(String.init).filter { $0 != NotchModule.aiChat.rawValue }
        if !shown { hidden.append(NotchModule.aiChat.rawValue) }
        hiddenModules = hidden.joined(separator: ",")
        NotchService.shared.syncWithPreferences()
        NotchService.shared.refreshPresentation(animated: false)
    }
}

/// Fork: the default model, grouped like the chat's own picker.
struct AIDefaultModelPicker: View {
    @ObservedObject var service: AIChatService
    @Binding var selection: String

    var body: some View {
        Picker("Default model", selection: $selection) {
            ForEach(service.groups(including: AIChatSupport.defaultModel())) { group in
                Section(group.title) {
                    ForEach(group.choices) { choice in
                        Text(choice.displayName).tag(choice.storageValue)
                    }
                }
            }
        }
    }
}

/// Fork: "Ask AI About Selection", the global shortcut.
struct AIAskSelectionSection: View {
    @AppStorage(DefaultsKey.aiChatSelectionShortcutEnabled) private var enabled = false
    @ObservedObject private var hotkey = AIChatSelectionHotkey.shared

    var body: some View {
        Section {
            Toggle("Ask about the selection with a shortcut", isOn: $enabled)
                .onChange(of: enabled) { _, _ in AIChatSelectionHotkey.shared.syncWithPreferences() }
            ShortcutPreferenceRow(role: .aiChatSelection, isEnabled: enabled,
                                  label: AIChatSupport.askSelectionTitle, symbolName: "text.cursor",
                                  includeInactiveConflicts: true) {
                AIChatSelectionHotkey.shared.syncWithPreferences()
            }
            if enabled, hotkey.registrationFailed {
                Text("Another app already uses this shortcut. Pick a different one.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Ask About Selection")
        } footer: {
            Text("Select text in any app and press the shortcut: AI Chat opens with the selection attached. Reading the selection needs Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Fork: the OpenAI-compatible endpoints: local servers, OpenRouter, any
/// self-hosted proxy.
struct AIEndpointsSection: View {
    @ObservedObject var service: AIChatService

    var body: some View {
        Section {
            ForEach(service.endpoints) { endpoint in
                AIEndpointRow(service: service, endpoint: endpoint)
            }
            Menu {
                ForEach(AIEndpointPreset.allCases) { preset in
                    Button(preset.title) { service.addEndpoint(preset) }
                }
            } label: {
                Label("Add Endpoint", systemImage: "plus")
            }
            .fixedSize()
        } header: {
            Text("Your Models")
        } footer: {
            Text("Ollama, LM Studio, OpenRouter, Gemini or any server that speaks OpenAI's chat completions. Models are listed from the server; type them in when it lists none.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AIEndpointRow: View {
    @ObservedObject var service: AIChatService
    let endpoint: AIEndpoint
    @State private var name = ""
    @State private var url = ""
    @State private var modelsText = ""
    @State private var key = ""
    @State private var keyFailed = false
    @State private var confirmsRemove = false
    @FocusState private var focused: Field?

    private enum Field { case name, url, models }

    private var isKeySet: Bool { service.keyedEndpoints.contains(endpoint.id) }
    private var source: String { endpoint.sourceID }
    private var models: [String] { service.models(of: endpoint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($focused, equals: .name)
                    .onSubmit(commit)
                Spacer()
                Text(endpoint.preset.title).font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    confirmsRemove = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(endpoint.displayName)")
            }
            TextField("Base URL", text: $url, prompt: Text("http://localhost:11434/v1"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused, equals: .url)
                .onSubmit(commit)
            if let base = AIEndpointURL.normalized(url) {
                if base.absoluteString != url.trimmingCharacters(in: .whitespaces) {
                    Text("Requests go to \(base.absoluteString)/chat/completions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if AIEndpointURL.isInsecureRemote(base) {
                    Text("macOS only allows plain http on this Mac and your local network. Use https for a server on the internet.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if !url.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("That isn't a web address.").font(.caption).foregroundStyle(.orange)
            }

            if endpoint.preset.offersKey {
                HStack {
                    SecureField("API key", text: $key,
                                prompt: Text(isKeySet ? "Paste a new key to replace it" : endpoint.preset.keyPlaceholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isKeySet {
                        Button("Remove Key", role: .destructive) { service.setKey(nil, for: endpoint) }
                    }
                    if let link = endpoint.preset.keyURL {
                        Link("Get a key", destination: link).font(.caption)
                    }
                }
                if keyFailed {
                    Text("The keychain refused the key.").font(.caption).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                if service.refreshingSources.contains(source) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                } else if let error = service.modelErrors[source], endpoint.manualModels.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !models.isEmpty {
                    Label("\(models.count) model\(models.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("Refresh Models") {
                    commit()
                    service.refreshModels(for: endpoint)
                }
                .controlSize(.small)
            }

            if !models.isEmpty {
                Picker("Default model", selection: Binding(
                    get: { endpoint.defaultModel },
                    set: { value in
                        var changed = endpoint
                        changed.defaultModel = value
                        service.updateEndpoint(changed)
                    })) {
                    Text("First listed").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                    if !endpoint.defaultModel.isEmpty, !models.contains(endpoint.defaultModel) {
                        Text(endpoint.defaultModel).tag(endpoint.defaultModel)
                    }
                }
                Button("Use \(models.first ?? "") as the Default for New Chats") {
                    guard let first = models.first else { return }
                    UserDefaults.standard.set(AIModelChoice(endpoint: endpoint.id, model: first).storageValue,
                                              forKey: DefaultsKey.aiChatDefaultModel)
                }
                .controlSize(.small)
                .disabled(AIChatSupport.defaultModel() == AIModelChoice(endpoint: endpoint.id, model: models.first ?? ""))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Models (optional, one per line; replaces the server's list)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("", text: $modelsText, prompt: Text("llama3.2:latest"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...5)
                    .focused($focused, equals: .models)
            }
            Text(endpoint.preset.hint).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
        .onChange(of: endpoint) { _, _ in if focused == nil { load() } }
        .onChange(of: focused) { previous, _ in if previous != nil { commit() } }
        .onDisappear(perform: commit)
        .confirmationDialog("Remove \(endpoint.displayName)?", isPresented: $confirmsRemove) {
            Button("Remove", role: .destructive) { service.removeEndpoint(endpoint.id) }
        } message: {
            Text("Its key is removed from the keychain. Chats that used it stay, but can't continue on it.")
        }
    }

    private func load() {
        name = endpoint.name
        url = endpoint.baseURL
        modelsText = endpoint.models.joined(separator: "\n")
    }

    private func commit() {
        guard service.endpoints.contains(where: { $0.id == endpoint.id }) else { return }
        var changed = endpoint
        changed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        changed.baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        changed.models = AIEndpointURL.modelList(modelsText)
        service.updateEndpoint(changed)
    }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commit()
        keyFailed = !service.setKey(key, for: endpoint)
        if !keyFailed { key = "" }
    }
}
