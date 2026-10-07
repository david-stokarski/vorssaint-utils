// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: draws App Icons' dark style. Every result sits on the current macOS
/// icon grid (an 824-point rounded square on a 1024 canvas, the way Apple's
/// template has it) with the system's soft shadow, so an old icon comes out
/// the same size and shape as a new one and macOS shows it as is instead of
/// boxing it in a gray tile.
enum AppIconRenderer {
    static let canvas = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4

    /// The icon macOS would draw for `image`, made dark.
    static func darkIcon(from image: NSImage) -> NSImage? {
        guard let source = bitmap(from: image, size: canvas),
              let bounds = AppIconStyler.opaqueBounds(of: source),
              let sourceImage = cgImage(from: source),
              let cropped = sourceImage.cropping(to: bounds)
        else { return nil }

        let kind = AppIconStyler.kind(of: source, bounds: bounds)
        guard let context = makeContext(width: canvas, height: canvas) else { return nil }
        let squircle = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous).cgPath

        // The system's own soft shadow under the tile.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
                          color: CGColor(gray: 0, alpha: 0.32))
        context.addPath(squircle)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(squircle)
        context.clip()
        switch kind {
        case .tile:
            // The tile, scaled to the grid, with its background made dark.
            guard var tile = bitmap(from: cropped, width: Int(body.width), height: Int(body.height)) else { return nil }
            AppIconStyler.darkenTile(&tile)
            guard let dark = cgImage(from: tile) else { return nil }
            // Drawn a hair larger so the old tile's own rim never shows.
            context.draw(dark, in: body.insetBy(dx: -3, dy: -3))
        case .shape:
            let accent = AppIconStyler.accent(of: source)
            let top = AppIconStyler.darkBase(for: accent, at: 0)
            let bottom = AppIconStyler.darkBase(for: accent, at: 1)
            let colors = [CGColor(red: top.r, green: top.g, blue: top.b, alpha: 1),
                          CGColor(red: bottom.r, green: bottom.g, blue: bottom.b, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                         locations: [0, 1]) {
                // CG's origin is at the bottom: the lighter color goes on top.
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY),
                                           end: CGPoint(x: 0, y: body.minY), options: [])
            }
            let fit = body.width * 0.76
            let scale = min(fit / bounds.width, fit / bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            context.draw(cropped, in: CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                                             width: size.width, height: size.height))
        }

        // A faint light along the top edge, as the system's icons have.
        context.addPath(squircle)
        context.setLineWidth(5)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.03)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: rim, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY),
                                       end: CGPoint(x: 0, y: body.midY), options: [])
        }
        context.restoreGState()

        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: canvas / 2, height: canvas / 2))
    }

    /// Any picture as an icon file wants it: 1024 pixels drawn as 512 points
    /// (an icon's largest size is 512 at 2x; 1024 at 1x is not one, and the
    /// system's encoder complains and drops it).
    static func iconImage(from image: NSImage) -> NSImage {
        guard let context = makeContext(width: canvas, height: canvas) else { return image }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: canvas / 2, height: canvas / 2)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Bitmaps

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func bitmap(from image: NSImage, size: Int) -> AppIconBitmap? {
        guard let context = makeContext(width: size, height: size) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap(from: context)
    }

    static func bitmap(from image: CGImage, width: Int, height: Int) -> AppIconBitmap? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap(from: context)
    }

    /// Straight alpha, top row first.
    private static func bitmap(from context: CGContext) -> AppIconBitmap? {
        guard let data = context.data else { return nil }
        let width = context.width, height = context.height, rowBytes = context.bytesPerRow
        let source = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * rowBytes + x * 4
                let d = (y * width + x) * 4
                let a = source[s + 3]
                pixels[d + 3] = a
                guard a > 0 else { continue }
                for c in 0..<3 {
                    pixels[d + c] = UInt8(min(255, (Int(source[s + c]) * 255 + Int(a) / 2) / Int(a)))
                }
            }
        }
        return AppIconBitmap(width: width, height: height, pixels: pixels)
    }

    static func cgImage(from bitmap: AppIconBitmap) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bitmap.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func pngData(_ image: NSImage, size: Int = canvas) -> Data? {
        guard let context = makeContext(width: size, height: size) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
