// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fork: an attachment above the message field, with a way to take it off.
struct AIAttachmentChip: View {
    let attachment: AIChatAttachment
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            AIAttachmentIcon(attachment: attachment, size: 22)
            Text(attachment.title.isEmpty ? "Attachment" : attachment.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, remove == nil ? 8 : 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(AIAttachmentIcon.preview(attachment))
        .onTapGesture(count: 2) { AIAttachmentIcon.open(attachment) }
    }
}

/// The attachments a sent question carried, above its bubble.
struct AIAttachmentStrip: View {
    let attachments: [AIChatAttachment]

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 80)
            ForEach(attachments) { attachment in
                if attachment.kind == .image, let image = AIAttachmentIcon.thumbnail(attachment) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1)))
                        .help(attachment.title)
                        .onTapGesture { AIAttachmentIcon.open(attachment) }
                } else {
                    AIAttachmentChip(attachment: attachment)
                }
            }
        }
    }
}

struct AIAttachmentIcon: View {
    let attachment: AIChatAttachment
    let size: CGFloat

    var body: some View {
        if attachment.kind == .image, let image = Self.thumbnail(attachment) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: attachment.symbolName)
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(_ attachment: AIChatAttachment) -> NSImage? {
        guard let url = AIChatStore.fileURL(for: attachment) else { return nil }
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }

    static func preview(_ attachment: AIChatAttachment) -> String {
        guard attachment.kind == .text, let text = attachment.text else { return attachment.title }
        let head = text.prefix(400)
        return head.count < text.count ? head + "…" : String(head)
    }

    /// An image opens in the viewer the Mac uses for it.
    static func open(_ attachment: AIChatAttachment) {
        guard attachment.kind == .image, let url = AIChatStore.fileURL(for: attachment) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Files, images and text dropped on the chat, and images or files pasted
/// into it.
enum AIChatDrop {
    static let types: [UTType] = [.fileURL, .image, .plainText]

    static func load(_ providers: [NSItemProvider], into service: AIChatService) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { AIChatService.shared.attach(files: [url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    DispatchQueue.main.async { AIChatService.shared.attach(image: cgImage, title: "Dropped image") }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    DispatchQueue.main.async { AIChatService.shared.attach(text: text, title: "Dropped text") }
                }
            }
        }
    }

    /// Command-V: files or a lone image are attached; anything else is
    /// handed to the field with the caret as an ordinary paste. Read on the
    /// app's one pasteboard lane, never on the main thread.
    static func paste() {
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            // A rich copy from a web page carries text along with its image;
            // that is a text paste.
            let image = files.isEmpty && pasteboard.string(forType: .string) == nil
                ? NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
            DispatchQueue.main.async {
                if !files.isEmpty {
                    AIChatService.shared.attach(files: files)
                } else if let image {
                    AIChatService.shared.attach(image: image, title: "Pasted image")
                } else {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
        }
    }
}
