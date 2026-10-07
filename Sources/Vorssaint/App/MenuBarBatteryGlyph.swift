// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Fork: the icon-only menu bar battery. A battery outline whose fill is the
/// exact charge, yellow when low and red when critical, with a bolt cut into
/// it while the adapter is connected. Drawn at the same height as the
/// percentage block it replaces, so the baseline nudge still lines it up.
enum MenuBarBatteryGlyph {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(percent: Int, isCharging: Bool, externalConnected: Bool,
                      readable: Bool) -> NSImage {
        let clamped = max(0, min(100, percent))
        let onPower = isCharging || externalConnected
        let key = "\(clamped)|\(onPower)|\(readable)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let height: CGFloat = readable ? 22 : 20
        let bodyWidth: CGFloat = readable ? 25 : 23
        let bodyHeight: CGFloat = readable ? 12 : 11.5
        let nubWidth: CGFloat = 1.6
        let nubHeight: CGFloat = 4.5
        let size = NSSize(width: ceil(bodyWidth + nubWidth + 1.5), height: height)
        let level = MenuBarBatteryGlyphSupport.level(percent: clamped)

        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.6, y: (height - bodyHeight) / 2, width: bodyWidth, height: bodyHeight)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.4, yRadius: 3.4)
            outline.lineWidth = 1.1
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            outline.stroke()

            let nub = NSRect(x: body.maxX + 1, y: body.midY - nubHeight / 2, width: nubWidth, height: nubHeight)
            let nubPath = NSBezierPath()
            nubPath.appendRoundedRect(nub, xRadius: 0.8, yRadius: 0.8)
            NSColor.labelColor.withAlphaComponent(0.45).setFill()
            nubPath.fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            let width = MenuBarBatteryGlyphSupport.fillWidth(percent: clamped, innerWidth: Double(inner.width))
            if width > 0 {
                let fill = NSRect(x: inner.minX, y: inner.minY, width: CGFloat(width), height: inner.height)
                color(for: level).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.8, yRadius: 1.8).fill()
            }

            if onPower { drawBolt(in: body) }
            return true
        }
        image.isTemplate = false
        cache.setObject(image, forKey: key)
        return image
    }

    private static func color(for level: MenuBarBatteryGlyphSupport.Level) -> NSColor {
        switch level {
        case .normal: return .labelColor
        case .low: return .systemYellow
        case .critical: return .systemRed
        }
    }

    /// The bolt is knocked out of whatever lies under it first, then drawn
    /// in the label color, so it reads on a full fill and on an empty one.
    private static func drawBolt(in body: NSRect) {
        let boltHeight = body.height - 1.5
        let base = NSImage.SymbolConfiguration(pointSize: boltHeight, weight: .heavy)
        guard let context = NSGraphicsContext.current,
              let knockout = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(base),
              let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(base.applying(.init(paletteColors: [.labelColor]))) else { return }
        let scale = boltHeight / knockout.size.height
        let drawSize = NSSize(width: knockout.size.width * scale, height: boltHeight)
        let rect = NSRect(x: body.midX - drawSize.width / 2, y: body.midY - drawSize.height / 2,
                          width: drawSize.width, height: drawSize.height)
        context.saveGraphicsState()
        knockout.draw(in: rect.insetBy(dx: -1, dy: -1), from: .zero, operation: .destinationOut, fraction: 1)
        context.restoreGraphicsState()
        bolt.draw(in: rect)
    }
}
