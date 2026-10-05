// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: AI Chat inside the island. The same chat the window has open, read
/// back compactly, with a field to keep asking and a way out to the window.
struct NotchAIChatView: View {
    let size: CGSize
    @ObservedObject private var service = AIChatService.shared
    @FocusState private var focused: Bool

    private var chat: AIChatConversation? { service.selected }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            if service.keyedProviders.isEmpty {
                setupState
            } else if let chat, !chat.messages.isEmpty {
                transcript(chat)
            } else {
                emptyState
            }
            composer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear {
            service.loadIfNeeded()
            if service.selected == nil { service.newChat() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let chat {
                AIModelMenu(service: service, chat: chat)
                    .controlSize(.small)
                Text(chat.displayTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            iconButton("square.and.pencil", help: "New Chat") {
                service.newChat()
                focused = true
            }
            .disabled(service.isStreaming)
            iconButton("arrow.up.right.square", help: "Open in AI Chat") { service.show() }
        }
        .frame(height: 20)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Transcript

    private func transcript(_ chat: AIChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // The island is small; the latest exchanges are what matter.
                    ForEach(chat.messages.suffix(12)) { message in
                        row(message, streaming: service.streamingID == chat.id && message.id == chat.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.last?.text.count ?? 0) { _, _ in
                if service.streamingID == chat.id { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ message: AIChatMessage, streaming: Bool) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.opacity(0.28)))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty, streaming {
                    ProgressView().controlSize(.mini)
                } else {
                    AIMarkdownView(text: message.text, fontSize: 12)
                }
                if let error = message.error {
                    HStack(spacing: 6) {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(error == "Stopped." ? Color.secondary : Color.orange)
                        if message.id == chat?.messages.last?.id {
                            Button("Retry", action: service.retry)
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Empty and setup

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask \(chat?.model.displayName ?? "AI") anything")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setupState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)
            Text("Add an Anthropic or OpenAI API key to start chatting.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a Key…") {
                service.show()
                service.showsSettings = true
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var canSend: Bool {
        !service.islandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        if service.send(service.islandDraft) { service.islandDraft = "" }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Ask \(chat?.model.displayName ?? "AI")…", text: $service.islandDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit(send)
                .disabled(service.keyedProviders.isEmpty)
            if service.isStreaming {
                Button(action: service.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.08)))
    }
}
