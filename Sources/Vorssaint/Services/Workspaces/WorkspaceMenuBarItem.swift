// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import SwiftUI

/// Fork: the workspaces in the menu bar. One rounded square per workspace
/// that has windows, in workspace order: filled for the one in view, outlined
/// for the rest. Clicking a square goes there. A template image, so the bar
/// colors it for light and dark and for a focused or inactive display.
final class WorkspaceMenuBarItem: NSObject {
    static let shared = WorkspaceMenuBarItem()

    private static let side: CGFloat = 15
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 2

    private var item: NSStatusItem?
    private var sinks = Set<AnyCancellable>()
    private var timer: Timer?
    private var squares: [WorkspaceMenuBarSquare] = []

    func sync() {
        let wanted = AppFeature.workspaces.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.menuBarWorkspaces)
            && WorkspaceService.shared.isRunning
        if wanted { install() } else { remove() }
    }

    private func install() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "VorssaintWorkspaces"
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp])
            item.button?.imagePosition = .imageOnly
            self.item = item
            let service = WorkspaceService.shared
            service.$activeWorkspaceID.combineLatest(service.$occupiedWorkspaceIDs)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.render() }
                .store(in: &sinks)
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.render() }
                .store(in: &sinks)
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                WorkspaceService.shared.refreshOccupancy()
            }
        }
        render()
    }

    private func remove() {
        timer?.invalidate()
        timer = nil
        sinks.removeAll()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        squares = []
    }

    private func render() {
        guard let item else { return }
        let service = WorkspaceService.shared
        let next = WorkspaceSupport.menuBarSquares(WorkspaceSupport.definitions(),
                                                   active: service.activeWorkspaceID,
                                                   occupied: service.occupiedWorkspaceIDs)
        guard next != squares || item.button?.image == nil else { return }
        squares = next
        item.button?.image = Self.image(for: next)
        item.button?.setAccessibilityLabel("Workspaces: " + next.map { $0.isActive ? "\($0.label), current" : $0.label }
            .joined(separator: ", "))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, !squares.isEmpty else { return }
        let point = sender.convert(event.locationInWindow, from: nil)
        let imageWidth = Self.width(for: squares.count)
        let originX = (sender.bounds.width - imageWidth) / 2
        let x = point.x - originX - Self.inset
        let slot = Int((x + Self.spacing / 2) / (Self.side + Self.spacing))
        guard squares.indices.contains(slot) else { return }
        WorkspaceService.shared.switchTo(squares[slot].id)
    }

    private static func width(for count: Int) -> CGFloat {
        CGFloat(count) * side + CGFloat(max(0, count - 1)) * spacing + inset * 2
    }

    static func image(for squares: [WorkspaceMenuBarSquare]) -> NSImage {
        let height: CGFloat = 18
        let size = NSSize(width: width(for: max(1, squares.count)), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            for (index, square) in squares.enumerated() {
                let rect = NSRect(x: inset + CGFloat(index) * (side + spacing),
                                  y: (height - side) / 2, width: side, height: side)
                let label = NSAttributedString(string: square.label, attributes: [
                    .font: font, .foregroundColor: NSColor.black,
                ])
                let labelSize = label.size()
                let labelOrigin = NSPoint(x: rect.midX - labelSize.width / 2,
                                          y: rect.midY - labelSize.height / 2 + 0.5)
                if square.isActive {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                    // The number is cut out of the filled square.
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    label.draw(at: labelOrigin)
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                } else {
                    NSColor.black.setStroke()
                    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
                    border.lineWidth = 1.5
                    border.stroke()
                    label.draw(at: labelOrigin)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Fork: the workspaces item as the Monitor page's menu bar preview shows
/// it, drawn from the same image the real item uses.
struct WorkspaceMenuBarPreview: View {
    @ObservedObject private var service = WorkspaceService.shared

    var body: some View {
        let squares = WorkspaceSupport.menuBarSquares(WorkspaceSupport.definitions(),
                                                      active: service.activeWorkspaceID,
                                                      occupied: service.occupiedWorkspaceIDs)
        if service.isRunning, !squares.isEmpty {
            Image(nsImage: WorkspaceMenuBarItem.image(for: squares))
                .renderingMode(.template)
                .foregroundStyle(.white)
                .accessibilityLabel("Workspaces")
        }
    }
}
