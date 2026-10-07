// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Fork: what a question to AI Chat can carry besides its words: the text
// selected in another app, a window or an area of the screen, and files or
// images dropped or pasted in. Text is sent as a fenced block ahead of the
// question; images as each provider's image content. The encoding lives here,
// where the tests compile it; reading the screen and the selection is in
// Services/AIChat.

/// One thing attached to a question. Images are saved next to the chats (see
/// `AIChatStore`) and referred to by file name, never kept as base64 in the
/// chat file or in preferences.
struct AIChatAttachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image }
    enum Origin: String, Codable { case selection, window, area, file, paste }

    var id: UUID
    var kind: Kind
    var origin: Origin
    /// Shown on the chip and, for text, named above its block.
    var title: String
    var text: String?
    /// The image's file name in the attachments folder.
    var file: String?
    var mediaType: String?

    init(id: UUID = UUID(), kind: Kind, origin: Origin, title: String,
         text: String? = nil, file: String? = nil, mediaType: String? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.title = title
        self.text = text
        self.file = file
        self.mediaType = mediaType
    }

    static func text(_ text: String, title: String, origin: Origin) -> AIChatAttachment {
        AIChatAttachment(kind: .text, origin: origin, title: title,
                         text: AIChatAttachments.clipped(text))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .text
        origin = (try? container.decode(Origin.self, forKey: .origin)) ?? .file
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        text = try? container.decode(String.self, forKey: .text)
        file = try? container.decode(String.self, forKey: .file)
        mediaType = try? container.decode(String.self, forKey: .mediaType)
    }

    var symbolName: String {
        switch origin {
        case .selection: return "text.cursor"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        case .file, .paste: return kind == .image ? "photo" : "doc.text"
        }
    }
}

/// An image ready to send: already scaled and encoded.
struct AIChatImage: Equatable {
    var mediaType: String
    var data: Data

    var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }
}

/// One turn as a request sees it: the words, with text attachments already
/// folded in, and the images that go with them.
struct AIChatTurn: Equatable {
    var role: AIChatMessage.Role
    var text: String
    var images: [AIChatImage] = []
}

enum AIChatAttachments {
    /// The long edge Anthropic recommends; larger images are scaled down on
    /// their side anyway, and only cost more to upload.
    static let maximumImageEdge = 1568
    static let jpegQuality = 0.85
    /// A selection or file longer than this is cut, with a note saying so.
    static let maximumTextLength = 100_000
    /// Files larger than this are not read as text at all.
    static let maximumTextFileBytes = 2_000_000

    static func clipped(_ text: String) -> String {
        guard text.count > maximumTextLength else { return text }
        return String(text.prefix(maximumTextLength)) + "\n… (cut at \(maximumTextLength) characters)"
    }

    // MARK: Text

    /// A fence longer than any run of backticks inside the text, so code in
    /// a selection cannot close the block early.
    static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func block(_ attachment: AIChatAttachment) -> String? {
        guard attachment.kind == .text, let text = attachment.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fence = fence(for: text)
        let title = attachment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "" : "\(title):\n") + "\(fence)\n\(text)\n\(fence)"
    }

    /// What the model reads for one question: every text attachment as a
    /// fenced block, then the question itself.
    static func composedText(_ question: String, attachments: [AIChatAttachment]) -> String {
        let blocks = attachments.compactMap(block)
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return (blocks + (question.isEmpty ? [] : [question])).joined(separator: "\n\n")
    }

    /// The turns a request sends. Replies that failed before saying anything
    /// are left out, so a retry does not send an empty assistant turn. Images
    /// whose file is gone are skipped rather than failing the whole turn.
    static func turns(from messages: [AIChatMessage],
                      imageData: (AIChatAttachment) -> AIChatImage?) -> [AIChatTurn] {
        messages.compactMap { message in
            let attachments = message.attachments ?? []
            guard message.role == .user else {
                return message.text.isEmpty ? nil : AIChatTurn(role: message.role, text: message.text)
            }
            let images = attachments.filter { $0.kind == .image }.compactMap(imageData)
            let text = composedText(message.text, attachments: attachments)
            guard !text.isEmpty || !images.isEmpty else { return nil }
            return AIChatTurn(role: .user, text: text, images: images)
        }
    }

    // MARK: Images

    /// The size an image is sent at: never larger than it is, the long edge
    /// at most `maximum`.
    static func scaledSize(width: Int, height: Int, maximum: Int = maximumImageEdge) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longest = max(width, height)
        guard longest > maximum else { return (width, height) }
        let factor = Double(maximum) / Double(longest)
        return (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
    }

    /// Scaled to fit and encoded: JPEG for what is opaque (screens, photos),
    /// PNG when transparency would otherwise turn black.
    static func encode(_ image: CGImage, maximum: Int = maximumImageEdge) -> AIChatImage? {
        let size = scaledSize(width: image.width, height: image.height, maximum: maximum)
        guard size.width > 0 else { return nil }
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                                                         : CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { return nil }
        let type = opaque ? UTType.jpeg : UTType.png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return AIChatImage(mediaType: opaque ? "image/jpeg" : "image/png", data: data as Data)
    }

    /// Any image format the system reads (PNG, JPEG, HEIC, TIFF, GIF, WebP…),
    /// first frame only.
    static func image(fromData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// A file's contents as text, when it is text: valid UTF-8 (or Latin-1
    /// for older files) with no NUL bytes, which binary formats always have.
    static func text(fromFileData data: Data) -> String? {
        guard data.count <= maximumTextFileBytes, !data.contains(0) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return clipped(text)
    }
}
