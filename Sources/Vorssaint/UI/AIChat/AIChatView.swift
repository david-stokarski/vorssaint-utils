// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the AI Chat window. Saved chats on the left, the open chat on the
/// right, the model it talks to in its header.
struct AIChatView: View {
    @ObservedObject var service: AIChatService
    @State private var filter = ""
    @State private var renaming: AIChatConversation?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            AIChatDetailView(service: service)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 420)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $service.showsSettings) {
            AIChatSettingsView(service: service)
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let chat = renaming { service.rename(chat.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var filtered: [AIChatConversation] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return service.conversations }
        return service.conversations.filter { chat in
            chat.displayTitle.localizedCaseInsensitiveContains(query)
                || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    service.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (⌘N)")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            List(selection: $service.selectedID) {
                ForEach(filtered) { chat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayTitle)
                            .lineLimit(1)
                        Text(chat.updated, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(chat.id)
                    .contextMenu {
                        Button("Rename…") {
                            renameText = chat.title
                            renaming = chat
                        }
                        Button("Delete", role: .destructive) { service.delete(chat.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button {
                    service.showsSettings = true
                } label: {
                    Label("Models & Keys", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }
}

struct AIChatDetailView: View {
    @ObservedObject var service: AIChatService
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let chat = service.selected, !chat.messages.isEmpty {
                transcript(chat)
            } else {
                emptyState
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { composerFocused = true }
        .onChange(of: service.focusRequest) { _, _ in composerFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(service.selected?.displayTitle ?? "AI Chat")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let chat = service.selected {
                AIModelMenu(service: service, chat: chat)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: Transcript

    private func transcript(_ chat: AIChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { message in
                        AIChatMessageView(message: message,
                                          isStreaming: service.streamingID == chat.id
                                            && message.id == chat.messages.last?.id,
                                          isLast: message.id == chat.messages.last?.id,
                                          retry: service.retry)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.text.count ?? 0) { _, _ in
                guard service.streamingID == chat.id else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask anything")
                .font(.system(size: 18, weight: .semibold))
            if let model = service.selected?.model {
                Text(model.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if service.keyedProviders.isEmpty {
                Button("Add an API Key…") { service.showsSettings = true }
                    .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var canSend: Bool {
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(service.selected?.model.displayName ?? "")",
                          text: $service.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...10)
                    .focused($composerFocused)
                    .onSubmit { service.send(service.draft) }
                    .padding(.vertical, 4)
                if service.isStreaming {
                    Button(action: service.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                } else {
                    Button { service.send(service.draft) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1))))
            Text("Return to send · ⌥Return for a new line")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }
}

/// The model a chat talks to, grouped by provider.
struct AIModelMenu: View {
    @ObservedObject var service: AIChatService
    let chat: AIChatConversation

    var body: some View {
        let choices = service.choices(including: chat.model)
        Menu {
            ForEach(AIProvider.allCases.filter { choices[$0] != nil }) { provider in
                Section(provider.title) {
                    ForEach(choices[provider] ?? []) { choice in
                        Button {
                            service.setModel(choice, for: chat.id)
                        } label: {
                            if choice == chat.model {
                                Label(choice.displayName, systemImage: "checkmark")
                            } else {
                                Text(choice.displayName)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Use as Default") {
                UserDefaults.standard.set(chat.model.storageValue, forKey: DefaultsKey.aiChatDefaultModel)
            }
            .disabled(chat.model == AIChatSupport.defaultModel())
            Button("Models & Keys…") { service.showsSettings = true }
        } label: {
            HStack(spacing: 4) {
                Text(chat.model.displayName)
                Text(chat.model.provider.title).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct AIChatMessageView: View {
    let message: AIChatMessage
    let isStreaming: Bool
    let isLast: Bool
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16)))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty, isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    AIMarkdownView(text: message.text)
                }
                if let error = message.error {
                    HStack(spacing: 8) {
                        Label(error, systemImage: error == "Stopped." ? "stop.circle" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(error == "Stopped." ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                        if isLast { Button("Retry", action: retry).controlSize(.small) }
                    }
                }
                if !isStreaming, !message.text.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                        if let model = message.model {
                            Text(AIChatSupport.displayName(forModel: model))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Just enough Markdown for chat replies: headings, lists, inline styles and
/// fenced code with a copy button.
struct AIMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AIChatSupport.blocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(Self.inline(prose))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let heading):
                    Text(Self.inline(heading))
                        .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                case .code(let language, let code):
                    AICodeBlockView(language: language, code: code)
                }
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map(AIChatSupport.proseLine).joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: lines, options: options)) ?? AttributedString(lines)
    }
}

struct AICodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
