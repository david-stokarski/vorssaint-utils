// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreImage

// Fork: draws the recording overlays for the composer, so the editor preview,
// video, GIF, copy and share all get the same pixels. Clicks and the pointer
// effect go into the recording itself, under the pointer, so the zoom carries
// them; key captions and the camera bubble sit on the finished frame, above
// the background, the way a caption does.

extension RecorderTakeStore.Take {
    var clicksURL: URL { folder.appendingPathComponent(RecorderOverlaySupport.takeClicksName) }
    var keystrokesURL: URL { folder.appendingPathComponent(RecorderOverlaySupport.takeKeystrokesName) }
    var cameraURL: URL { folder.appendingPathComponent(RecorderOverlaySupport.takeCameraName) }
}

/// What a take recorded for the overlays. Empty for takes recorded before
/// overlays existed, imported movies, or with every overlay switched off.
struct RecorderOverlayInput {
    var clicks = RecorderClickTrack()
    var keystrokes = RecorderKeystrokeTrack()
    var camera: RecorderCameraFrameSource.Asset?

    var isEmpty: Bool { clicks.isEmpty && keystrokes.isEmpty && camera == nil }

    /// The two small tracks, read synchronously.
    static func tracks(in folder: URL) -> RecorderOverlayInput {
        RecorderOverlayInput(
            clicks: RecorderClickTrack.decoded(
                try? Data(contentsOf: folder.appendingPathComponent(RecorderOverlaySupport.takeClicksName))),
            keystrokes: RecorderKeystrokeTrack.decoded(
                try? Data(contentsOf: folder.appendingPathComponent(RecorderOverlaySupport.takeKeystrokesName))))
    }

    /// Everything, including the camera file, which needs an async open.
    static func load(from folder: URL) async -> RecorderOverlayInput {
        var input = tracks(in: folder)
        input.camera = await RecorderCameraFrameSource.Asset.load(
            folder.appendingPathComponent(RecorderOverlaySupport.takeCameraName))
        return input
    }
}

/// Everything about the overlays decided once per plan.
struct RecorderOverlayPlan {
    let settings: RecorderOverlaySettings
    /// The moment of the recording each finished frame shows.
    let sourceTimes: [Double]
    let presses: [RecorderClickEvent]
    let pressTimes: [Double]
    /// A highlight's full radius, in the recording's pixels.
    let clickRadius: CGFloat
    let pointerEffect: RecorderOverlaySettings.PointerEffect
    let pointerRadius: CGFloat
    let captions: [RecorderKeyCaption]
    let camera: RecorderCameraFrameSource.Asset?

    var drawsInRecording: Bool { !presses.isEmpty || pointerEffect != .none }

    static func make(settings rawSettings: RecorderOverlaySettings,
                     input: RecorderOverlayInput,
                     sourceTimes: [Double],
                     hasPointer: Bool) -> RecorderOverlayPlan? {
        let settings = rawSettings.sanitized()
        let presses = settings.clicks.enabled ? input.clicks.presses : []
        let effect = hasPointer ? settings.clicks.pointerEffect : .none
        let captions = settings.keystrokes.enabled
            ? RecorderKeyCaptions.captions(input.keystrokes.strokes, mode: settings.keystrokes.mode)
            : []
        let camera = settings.camera.enabled ? input.camera : nil
        guard !presses.isEmpty || effect != .none || !captions.isEmpty || camera != nil,
              !sourceTimes.isEmpty
        else { return nil }
        let scale = CGFloat(input.clicks.displayScale > 0 ? input.clicks.displayScale : 2)
        let size = CGFloat(settings.clicks.size)
        return RecorderOverlayPlan(settings: settings,
                                   sourceTimes: sourceTimes,
                                   presses: presses,
                                   pressTimes: presses.map(\.time),
                                   clickRadius: 24 * scale * size,
                                   pointerEffect: effect,
                                   pointerRadius: (effect == .spotlight ? 120 : 36) * scale * size,
                                   captions: captions,
                                   camera: camera)
    }
}

final class RecorderOverlayRenderer {
    private let plan: RecorderOverlayPlan
    private let canvasSize: CGSize
    private let camera: RecorderCameraFrameSource?
    private let bubbleRect: CGRect
    private let bubbleMask: CIImage?
    private let bubbleShadow: CIImage?
    private let bubbleBorder: CIImage?
    private let captionLock = NSLock()
    private var captionSprites: [Int: CGImage] = [:]

    init(plan: RecorderOverlayPlan, canvasSize: CGSize) {
        self.plan = plan
        self.canvasSize = canvasSize
        camera = plan.camera.map { RecorderCameraFrameSource(source: $0) }
        let camera = plan.settings.camera
        let rect = RecorderBubbleLayout.rect(canvas: canvasSize, shape: camera.shape,
                                             corner: camera.corner, size: camera.size)
        bubbleRect = rect
        let radius = RecorderBubbleLayout.cornerRadius(for: rect, shape: camera.shape)
        if plan.camera != nil, rect.width >= 2, rect.height >= 2 {
            bubbleMask = Self.shapeImage(size: rect.size, radius: radius)
                .map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: rect.minX,
                                                                              y: rect.minY)) }
            bubbleShadow = camera.shadow ? Self.shadowImage(rect: rect, radius: radius) : nil
            bubbleBorder = camera.border ? Self.borderImage(rect: rect, radius: radius) : nil
        } else {
            bubbleMask = nil
            bubbleShadow = nil
            bubbleBorder = nil
        }
    }

    private func sourceTime(_ index: Int) -> Double? {
        plan.sourceTimes.indices.contains(index) ? plan.sourceTimes[index] : plan.sourceTimes.last
    }

    // MARK: - In the recording

    /// Under the pointer and before the zoom, in the recording's own pixels.
    func drawInRecording(_ content: CIImage, index: Int, composer plan: RecorderComposer.Plan) -> CIImage {
        guard self.plan.drawsInRecording, let time = sourceTime(index) else { return content }
        let size = plan.sourceSize
        var result = content
        if self.plan.pointerEffect != .none,
           plan.positions.indices.contains(index),
           plan.pointerVisible.indices.contains(index) ? plan.pointerVisible[index] : true {
            let uv = plan.positions[index]
            let point = CGPoint(x: uv.x * size.width, y: (1 - uv.y) * size.height)
            result = drawPointerEffect(on: result, at: point, size: size)
        }
        let style = self.plan.settings.clicks.style
        for entry in RecorderClickAnimation.active(at: time, downTimes: self.plan.pressTimes,
                                                   duration: RecorderClickAnimation.duration(style)) {
            let press = self.plan.presses[entry.index]
            let progress = entry.progress
            guard press.x > -0.1, press.x < 1.1, press.y > -0.1, press.y < 1.1 else { continue }
            let isRight = press.button == .right && self.plan.settings.clicks.distinctRightClick
            let palette = isRight ? self.plan.settings.clicks.color.contrasting : self.plan.settings.clicks.color
            guard let sprite = Self.clickSprite(style: style, progress: progress,
                                                radius: self.plan.clickRadius,
                                                color: palette, dashed: isRight)
            else { continue }
            let x = CGFloat(press.x) * size.width
            let y = CGFloat(1 - press.y) * size.height
            result = CIImage(cgImage: sprite)
                .transformed(by: CGAffineTransform(translationX: x - CGFloat(sprite.width) / 2,
                                                   y: y - CGFloat(sprite.height) / 2))
                .composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func drawPointerEffect(on content: CIImage, at point: CGPoint, size: CGSize) -> CIImage {
        let radius = plan.pointerRadius
        let bounds = CGRect(origin: .zero, size: size)
        let center = CIVector(x: point.x, y: point.y)
        switch plan.pointerEffect {
        case .none:
            return content
        case .halo:
            let rgb = plan.settings.clicks.color.rgb
            let glow = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: center,
                "inputRadius0": radius * 0.15,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 0.38),
                "inputColor1": CIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 0),
            ])?.outputImage?.cropped(to: bounds)
            return glow?.composited(over: content) ?? content
        case .spotlight:
            let dim = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: center,
                "inputRadius0": radius,
                "inputRadius1": radius * 1.5,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.5),
            ])?.outputImage?.cropped(to: bounds)
            return dim?.composited(over: content) ?? content
        }
    }

    // MARK: - On the finished frame

    /// Above the background, the captions and the pictures.
    func drawOnCanvas(_ content: CIImage, index: Int) -> CIImage {
        guard let time = sourceTime(index) else { return content }
        var result = content
        if let camera, let mask = bubbleMask, let frame = camera.image(at: time) {
            result = drawBubble(frame, mask: mask, on: result)
        }
        if let active = RecorderKeyCaptions.active(plan.captions, at: time),
           let sprite = captionSprite(active.index) {
            result = drawCaption(sprite, opacity: active.opacity, on: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    private func drawBubble(_ frame: CIImage, mask: CIImage, on content: CIImage) -> CIImage {
        var image = frame
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return content }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if plan.settings.camera.mirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: extent.width, y: 0)))
        }
        let fill = RecorderBubbleLayout.aspectFill(image: extent.size, into: bubbleRect)
        image = image
            .transformed(by: CGAffineTransform(scaleX: fill.scale, y: fill.scale))
            .transformed(by: CGAffineTransform(translationX: fill.origin.x, y: fill.origin.y))
            .cropped(to: bubbleRect)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        var result = content
        if let bubbleShadow { result = bubbleShadow.composited(over: result) }
        result = image.composited(over: result)
        if let bubbleBorder { result = bubbleBorder.composited(over: result) }
        return result
    }

    private func drawCaption(_ sprite: CGImage, opacity: Double, on content: CIImage) -> CIImage {
        var width = CGFloat(sprite.width)
        var height = CGFloat(sprite.height)
        var image = CIImage(cgImage: sprite)
        let limit = canvasSize.width * 0.92
        if width > limit, width > 0 {
            let factor = limit / width
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            width *= factor
            height *= factor
        }
        let margin = (canvasSize.height * 0.06).rounded()
        let y = plan.settings.keystrokes.position == .bottom ? margin : canvasSize.height - margin - height
        let x = ((canvasSize.width - width) / 2).rounded()
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
            ])
        }
        return image.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: content)
    }

    private func captionSprite(_ index: Int) -> CGImage? {
        captionLock.lock()
        if let hit = captionSprites[index] {
            captionLock.unlock()
            return hit
        }
        captionLock.unlock()
        guard plan.captions.indices.contains(index) else { return nil }
        let height = max(18, (canvasSize.height * 0.062 * CGFloat(plan.settings.keystrokes.size)).rounded())
        guard let sprite = Self.captionImage(plan.captions[index].text, height: height,
                                             style: plan.settings.keystrokes.style)
        else { return nil }
        captionLock.lock()
        if captionSprites.count > 96 { captionSprites.removeAll() }
        captionSprites[index] = sprite
        captionLock.unlock()
        return sprite
    }

    // MARK: - Sprites

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func clickSprite(style: RecorderOverlaySettings.ClickStyle,
                            progress: Double,
                            radius: CGFloat,
                            color: RecorderOverlaySettings.Palette,
                            dashed: Bool) -> CGImage? {
        guard radius > 1, progress >= 0, progress <= 1 else { return nil }
        let line = max(1.5, radius * 0.11)
        let side = Int((radius * 2 + line * 2 + 4).rounded(.up))
        guard let context = context(width: side, height: side) else { return nil }
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let rgb = color.rgb
        func stroke(_ fraction: Double, alpha: Double, width: CGFloat) {
            guard alpha > 0.01, fraction > 0 else { return }
            let r = radius * CGFloat(fraction)
            context.setStrokeColor(CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha))
            context.setLineWidth(width)
            context.setLineDash(phase: 0, lengths: dashed ? [r * 0.42, r * 0.28] : [])
            context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        func fill(_ fraction: Double, alpha: Double) {
            guard alpha > 0.01, fraction > 0 else { return }
            let r = radius * CGFloat(fraction)
            context.setFillColor(CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha))
            context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        switch style {
        case .ring:
            let ring = RecorderClickAnimation.ring(progress: progress)
            fill(ring.radius, alpha: ring.alpha * 0.18)
            stroke(ring.radius, alpha: ring.alpha * 0.95, width: line * CGFloat(1 - progress * 0.5))
        case .pulse:
            let pulse = RecorderClickAnimation.pulse(progress: progress)
            fill(pulse.radius, alpha: pulse.alpha)
            if dashed { stroke(pulse.radius, alpha: pulse.alpha * 1.4, width: line * 0.7) }
        case .ripple:
            for delay in [0.0, 0.3] {
                let local = (progress - delay) / 0.7
                guard local >= 0, local <= 1 else { continue }
                let ring = RecorderClickAnimation.ring(progress: local)
                stroke(ring.radius, alpha: ring.alpha * 0.9, width: line * 0.8)
            }
            if progress < 0.25 { fill(0.22, alpha: 0.6 * (1 - progress / 0.25)) }
        }
        return context.makeImage()
    }

    static func captionImage(_ text: String, height: CGFloat,
                             style: RecorderOverlaySettings.CaptionStyle) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, height > 0 else { return nil }
        let pointSize = (height * 0.5).rounded()
        let foreground: NSColor = style == .dark ? .white : NSColor(white: 0.08, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize, weight: .semibold),
            .foregroundColor: foreground,
            .kern: pointSize * 0.04,
        ]
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)
        let bounds = attributed.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                          height: CGFloat.greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin])
        let padding = height * 0.48
        let shadowPad = (height * 0.25).rounded()
        let pillWidth = max(height, (bounds.width + padding * 2).rounded(.up))
        let width = Int(pillWidth + shadowPad * 2)
        let fullHeight = Int(height + shadowPad * 2)
        guard let context = context(width: width, height: fullHeight) else { return nil }
        let pill = CGRect(x: shadowPad, y: shadowPad, width: pillWidth, height: height)
        let path = CGPath(roundedRect: pill, cornerWidth: height * 0.3, cornerHeight: height * 0.3, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -height * 0.04), blur: height * 0.22,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(style == .dark ? CGColor(gray: 0.07, alpha: 0.82) : CGColor(gray: 1, alpha: 0.92))
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(style == .dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.1))
        context.setLineWidth(max(1, height * 0.02))
        context.addPath(path)
        context.strokePath()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        attributed.draw(with: CGRect(x: pill.midX - bounds.width / 2,
                                     y: pill.midY - bounds.height / 2,
                                     width: bounds.width, height: bounds.height),
                        options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func shapeImage(size: CGSize, radius: CGFloat) -> CGImage? {
        guard let context = context(width: Int(size.width), height: Int(size.height)) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return context.makeImage()
    }

    private static func shadowImage(rect: CGRect, radius: CGFloat) -> CIImage? {
        let blur = max(4, rect.width * 0.07)
        let pad = (blur * 2.5).rounded(.up)
        let size = CGSize(width: rect.width + pad * 2, height: rect.height + pad * 2)
        guard let context = context(width: Int(size.width), height: Int(size.height)) else { return nil }
        let shape = CGRect(x: pad, y: pad, width: rect.width, height: rect.height)
        context.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.02), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: rect.minX - pad, y: rect.minY - pad))
    }

    private static func borderImage(rect: CGRect, radius: CGFloat) -> CIImage? {
        let line = max(2, (rect.width * 0.022).rounded())
        guard let context = context(width: Int(rect.width), height: Int(rect.height)) else { return nil }
        let inset = CGRect(origin: .zero, size: rect.size).insetBy(dx: line / 2, dy: line / 2)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.setLineWidth(line)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - line / 2),
                               cornerHeight: max(0, radius - line / 2), transform: nil))
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
