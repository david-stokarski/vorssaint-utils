// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import PDFKit

/// Fork: what AI Chat can attach from outside itself: the text selected in
/// the app that was in front before the chat, that app's front window, or an
/// area picked with the screenshot tool's own surface. Each asks for its
/// permission at the moment it is used, and only then.
final class AIChatContext {
    static let shared = AIChatContext()

    enum Result {
        case attached(AIChatAttachment)
        /// Nothing to attach; the sentence says why.
        case nothing(String)
        case cancelled
    }

    /// The last app other than this one to be in front. The chat window is
    /// in front whenever its buttons are pressed, so "the frontmost app" is
    /// always the one that was there just before.
    private(set) var lastApp: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var selection: ScreenshotSelectionController?

    private init() {}

    /// Starts following which app is in front. Cheap, and only begun once AI
    /// Chat is first used.
    func start() {
        noteFrontmost()
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.note(app)
        }
    }

    func noteFrontmost() {
        if let front = NSWorkspace.shared.frontmostApplication { note(front) }
    }

    private func note(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != Bundle.main.bundleIdentifier, !app.isTerminated else { return }
        lastApp = app
    }

    private var appName: String { lastApp?.localizedName ?? "the app" }

    // MARK: Selection

    /// The selected text of the last app in front, through Accessibility.
    /// Read off the main thread: an app that hangs must not hang the chat.
    func attachSelection(completion: @escaping (Result) -> Void) {
        guard AXIsProcessTrusted() else {
            Permissions.shared.requestAccessibility()
            completion(.nothing("Allow Accessibility for Vorssaint to attach what's selected in other apps."))
            return
        }
        guard let app = lastApp, !app.isTerminated else {
            completion(.nothing("Select some text in another app first."))
            return
        }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "the app"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.selectedText(pid: pid)
            DispatchQueue.main.async {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion(.nothing("Nothing is selected in \(name), or it doesn't share its selection."))
                    return
                }
                completion(.attached(.text(text, title: "Selection from \(name)", origin: .selection)))
            }
        }
    }

    /// Blocking. The same reading as the Command Bar's, asked of a given app
    /// rather than the one in front.
    static func selectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // Set on the app element, never the system-wide one: that timeout
        // would become the default for every Accessibility call in the app.
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = copyValue(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard let raw = copyValue(element, kAXSelectedTextAttribute),
              CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: Window

    /// The front window of the last app in front, captured the way the
    /// screenshot tool captures a clicked window.
    @MainActor
    func attachFrontWindow() async -> Result {
        guard CGPreflightScreenCaptureAccess() else {
            Permissions.shared.requestScreenRecording()
            return .nothing("Allow Screen Recording for Vorssaint to attach a window.")
        }
        guard let app = lastApp, !app.isTerminated,
              let window = Self.frontWindow(of: app.processIdentifier) else {
            return .nothing("No window of \(appName) is on screen.")
        }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard let captured = await ScreenshotCaptureEngine.captureWindow(window.id, scale: scale),
              let image = AIChatAttachments.encode(captured.image) else {
            return .nothing("The window couldn't be captured.")
        }
        let title = window.title.map { "\(appName): \($0)" } ?? "\(appName) window"
        return save(image, title: title, origin: .window)
    }

    /// Front to back, the first ordinary window the app has on screen.
    private static func frontWindow(of pid: pid_t) -> (id: CGWindowID, title: String?)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 40, (bounds["Height"] ?? 0) >= 40 else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let name = (entry[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (id, name?.isEmpty == false ? name : nil)
        }
        return nil
    }

    // MARK: Area

    /// An area picked on the screenshot tool's surface, with this app's own
    /// windows kept out of the picture.
    func attachArea(completion: @escaping (Result) -> Void) {
        guard selection == nil, !ScreenshotSelectionController.isSessionOnScreen else {
            completion(.cancelled)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            Permissions.shared.requestScreenRecording()
            completion(.nothing("Allow Screen Recording for Vorssaint to attach a screenshot."))
            return
        }
        let controller = ScreenshotSelectionController(
            freeze: true, includePointer: false, showLastRegion: false, hideVorssaintWindows: true,
            purpose: "Attach to AI Chat", mode: .image)
        selection = controller
        controller.begin { [weak self] outcome in
            guard let self else { return }
            self.selection = nil
            switch outcome {
            case .captured(let capture):
                guard let image = AIChatAttachments.encode(capture.image) else {
                    completion(.nothing("The screenshot couldn't be read."))
                    return
                }
                completion(self.save(image, title: "Screenshot", origin: .area))
            case .failed:
                completion(.nothing("The screen couldn't be captured."))
            default:
                completion(.cancelled)
            }
        }
    }

    // MARK: Files and the pasteboard

    /// A dropped or pasted file: an image, a PDF's text or a text file.
    func attachFile(_ url: URL) -> Result {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .nothing("\(name) couldn't be read.")
        }
        if let cgImage = AIChatAttachments.image(fromData: data) {
            guard let image = AIChatAttachments.encode(cgImage) else { return .nothing("\(name) couldn't be read.") }
            return save(image, title: name, origin: .file)
        }
        if url.pathExtension.lowercased() == "pdf" {
            guard let text = AIChatPDFText.text(of: url), !text.isEmpty else {
                return .nothing("\(name) has no text to read.")
            }
            return .attached(.text(text, title: name, origin: .file))
        }
        guard let text = AIChatAttachments.text(fromFileData: data) else {
            return .nothing("\(name) isn't text or an image.")
        }
        return .attached(.text(text, title: name, origin: .file))
    }

    func attachImage(_ cgImage: CGImage, title: String, origin: AIChatAttachment.Origin) -> Result {
        guard let image = AIChatAttachments.encode(cgImage) else { return .nothing("The image couldn't be read.") }
        return save(image, title: title, origin: origin)
    }

    private func save(_ image: AIChatImage, title: String, origin: AIChatAttachment.Origin) -> Result {
        guard let attachment = AIChatStore.saveImage(image, title: title, origin: origin) else {
            return .nothing("The image couldn't be saved.")
        }
        return .attached(attachment)
    }
}

/// A PDF's text layer, for a dropped document. Scanned pages have none.
enum AIChatPDFText {
    static func text(of url: URL) -> String? {
        guard let text = PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return AIChatAttachments.clipped(text)
    }
}
