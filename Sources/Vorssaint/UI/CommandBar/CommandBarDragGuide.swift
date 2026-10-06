// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: moving the Command Bar by hand. The drag runs its own tracking loop
/// so every step can snap; meanwhile the display the pointer is on shows its
/// thirds and middle, the guides the bar landed on lit, and a label naming
/// the spot. Holding Option places the bar freely.
final class CommandBarDragController {
    static let shared = CommandBarDragController()

    private var overlay: NSPanel?
    private let model = CommandBarGuideModel()
    private var landed: [CommandBarPlacement.Guide] = []

    /// Follows the pointer from `event` until the button comes up. Returns
    /// whether the bar actually moved, as opposed to a plain click.
    @discardableResult
    func track(from event: NSEvent, window: NSWindow) -> Bool {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var dragging = false
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged],
                                         until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            if !dragging {
                guard hypot(dx, dy) > 3 else { continue }
                dragging = true
                NSCursor.closedHand.push()
            }
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen
            else { continue }
            let free = NSEvent.modifierFlags.contains(.option)
            let size = window.frame.size
            let snapped = CommandBarPlacement.snap(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy),
                                                   size: size, in: screen.visibleFrame, enabled: !free)
            window.setFrameOrigin(snapped.origin)
            if snapped.guides != landed, !snapped.guides.isEmpty {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            landed = snapped.guides
            show(on: screen, below: window, bar: CGRect(origin: snapped.origin, size: size), free: free)
        }
        if dragging {
            NSCursor.pop()
            hide()
        }
        landed = []
        return dragging
    }

    #if VORSSAINT_DEVELOPMENT
    func previewShow(on screen: NSScreen, below window: NSWindow, bar: CGRect, guides: [CommandBarPlacement.Guide]) {
        landed = guides
        show(on: screen, below: window, bar: bar, free: false)
    }

    func endPreview() {
        landed = []
        hide()
    }
    #endif

    private func show(on screen: NSScreen, below window: NSWindow, bar: CGRect, free: Bool) {
        let panel = overlay ?? makeOverlay()
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        model.update(screen: screen, bar: bar, landed: landed, free: free)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.order(.below, relativeTo: window.windowNumber)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel = overlay, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makeOverlay() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = NSHostingView(rootView: CommandBarGuideOverlay(model: model))
        overlay = panel
        return panel
    }
}

/// What the overlay draws, in its own top-left coordinates.
final class CommandBarGuideModel: ObservableObject {
    @Published private(set) var area: CGRect = .zero
    @Published private(set) var bar: CGRect = .zero
    @Published private(set) var lines: [(guide: CommandBarPlacement.Guide, rect: CGRect, lit: Bool)] = []
    @Published private(set) var label: String?

    func update(screen: NSScreen, bar barFrame: CGRect, landed: [CommandBarPlacement.Guide], free: Bool) {
        let frame = screen.frame
        let visible = screen.visibleFrame
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        area = local(visible)
        bar = local(barFrame)
        lines = (CommandBarPlacement.verticalGuides + CommandBarPlacement.horizontalGuides).map { guide in
            let at = CommandBarPlacement.position(of: guide, in: visible)
            let rect = guide.axis == .vertical
                ? CGRect(x: at, y: visible.minY, width: 0, height: visible.height)
                : CGRect(x: visible.minX, y: at, width: visible.width, height: 0)
            return (guide, local(rect), landed.contains(guide))
        }
        label = free ? "Free placement · release ⌥ to snap" : CommandBarPlacement.label(for: landed)
    }
}

struct CommandBarGuideOverlay: View {
    @ObservedObject var model: CommandBarGuideModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.16)
            Canvas { context, _ in
                let area = model.area.insetBy(dx: 8, dy: 8)
                context.stroke(Path(roundedRect: area, cornerRadius: 16),
                               with: .color(.white.opacity(0.28)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                for line in model.lines {
                    var path = Path()
                    path.move(to: CGPoint(x: line.rect.minX, y: line.rect.minY))
                    path.addLine(to: CGPoint(x: line.rect.maxX, y: line.rect.maxY))
                    if line.lit {
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    } else {
                        context.stroke(path, with: .color(.white.opacity(line.guide.isMarker ? 0.18 : 0.26)),
                                       style: StrokeStyle(lineWidth: 1, dash: line.guide.isMarker ? [4, 6] : []))
                    }
                }
                // The bar's own outline, so where it will open reads at a glance.
                context.stroke(Path(roundedRect: model.bar.insetBy(dx: -3, dy: -3), cornerRadius: 25),
                               with: .color(.accentColor.opacity(0.55)), lineWidth: 1.5)
            }
            if let label = model.label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                    .fixedSize()
                    .position(x: model.bar.midX, y: max(model.area.minY + 20, model.bar.minY - 24))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.label)
        .ignoresSafeArea()
    }
}

#if VORSSAINT_DEVELOPMENT
extension CommandBarDragController {
    /// Developer builds: drops the bar a few points off the display's middle
    /// and shows the guides as a drag would, for checking the overlay.
    func previewSnap(window: NSWindow) {
        guard let screen = window.screen else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        let proposal = CGPoint(x: visible.midX - size.width / 2 + 8, y: visible.midY - size.height - 5)
        let snapped = CommandBarPlacement.snap(proposal, size: size, in: visible)
        window.setFrameOrigin(snapped.origin)
        previewShow(on: screen, below: window, bar: CGRect(origin: snapped.origin, size: size), guides: snapped.guides)
    }
}
#endif
