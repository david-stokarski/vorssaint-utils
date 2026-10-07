// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit

// Fork: the live camera bubble shown while recording, so the person can see
// and frame themselves. It is left out of the screen capture by the recorder
// session, so the camera is recorded once, as its own track, and the editor
// decides where the bubble finally goes.

final class RecorderCameraBubbleWindow {
    private final class Panel: OverlayPanel {
        override var canBecomeKey: Bool { false }
    }

    private final class BubbleView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession, side: CGFloat) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.cornerRadius = side / 2
            previewLayer.masksToBounds = true
            previewLayer.borderWidth = 3
            previewLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer = previewLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Dragging anywhere on the bubble moves it out of the way.
        override var mouseDownCanMoveWindow: Bool { true }

        /// A mirror, the way a person expects to see themselves; the editor
        /// keeps its own choice for the recording.
        func applyMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    private let panel: Panel
    private let view: BubbleView
    static let side: CGFloat = 168

    init(session: AVCaptureSession, region: RecorderSupport.Region) {
        let side = Self.side
        view = BubbleView(session: session, side: side)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered,
                      defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = view
        panel.setFrameOrigin(Self.origin(for: region, side: side))
    }

    /// Bottom right of the recorded area, inside the screen it is on.
    private static func origin(for region: RecorderSupport.Region, side: CGFloat) -> NSPoint {
        let area = region.anchorRect
        let screen = NSScreen.screens.first { $0.displayID == region.displayID }?.visibleFrame ?? area
        let inset: CGFloat = 24
        let x = min(area.maxX, screen.maxX) - side - inset
        let y = max(area.minY, screen.minY) + inset
        return NSPoint(x: max(screen.minX + inset, x), y: min(screen.maxY - side - inset, y))
    }

    var windowNumber: Int? {
        panel.windowNumber > 0 ? panel.windowNumber : nil
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func cameraDidStart() {
        view.applyMirroring()
    }

    func hide() {
        panel.orderOut(nil)
        view.previewLayer.session = nil
    }
}
