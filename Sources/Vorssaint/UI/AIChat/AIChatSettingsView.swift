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
                    ForEach(AIProvider.allCases) { provider in
                        AIProviderKeyRow(service: service, provider: provider)
                    }
                }
                Section("Defaults") {
                    Picker("Default model", selection: $defaultModel) {
                        let choices = service.choices(including: AIChatSupport.defaultModel())
                        ForEach(AIProvider.allCases.filter { choices[$0] != nil }) { provider in
                            Section(provider.title) {
                                ForEach(choices[provider] ?? []) { choice in
                                    Text(choice.displayName).tag(choice.storageValue)
                                }
                            }
                        }
                    }
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
        .frame(width: 560, height: 560)
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
            } else if let error = service.modelErrors[provider], isSet {
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
                ForEach(AIProvider.allCases) { provider in
                    AIProviderKeyRow(service: service, provider: provider)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys are stored in your login keychain and only sent to their own provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chats") {
                Picker("Default model", selection: $defaultModel) {
                    let choices = service.choices(including: AIChatSupport.defaultModel())
                    ForEach(AIProvider.allCases.filter { choices[$0] != nil }) { provider in
                        Section(provider.title) {
                            ForEach(choices[provider] ?? []) { choice in
                                Text(choice.displayName).tag(choice.storageValue)
                            }
                        }
                    }
                }
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
        .onAppear { service.loadIfNeeded() }
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
