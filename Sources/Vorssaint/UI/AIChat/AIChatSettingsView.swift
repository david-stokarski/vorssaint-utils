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

private struct AIProviderKeyRow: View {
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
                SecureField(isSet ? "Replace key" : provider.keyPlaceholder, text: $key)
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
