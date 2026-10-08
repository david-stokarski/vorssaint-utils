// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Metal
import QuartzCore

/// Fork: the drift's own time, shared by every screen and the lock screen so
/// they all show the same moment. It only runs while something is drawn, so
/// a pause picks up where it stopped, and a change of speed bends the pace
/// instead of jumping the picture.
final class LiveWallpaperClock {
    private(set) var fieldTime: Double
    private var last: CFTimeInterval?
    private(set) var speed: Double

    init(speed: Double, start: Double = Double.random(in: 0..<1_000)) {
        self.speed = speed
        fieldTime = start
    }

    var isRunning: Bool { last != nil }

    /// The field time now; any number of views may ask in one frame.
    func time(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        if let last {
            // A long stall (sleep the notifications missed) resumes, not leaps.
            fieldTime += min(max(now - last, 0), 0.25) * speed
            self.last = now
        }
        return fieldTime
    }

    func run(at now: CFTimeInterval = CACurrentMediaTime()) {
        guard last == nil else { return }
        last = now
    }

    func pause(at now: CFTimeInterval = CACurrentMediaTime()) {
        _ = time(at: now)
        last = nil
    }

    func setSpeed(_ speed: Double, at now: CFTimeInterval = CACurrentMediaTime()) {
        _ = time(at: now)
        self.speed = speed
    }
}

/// One screen's worth of Live Wallpaper, drawn into a Metal layer by a
/// display link that only runs while animating. Soft scenes are drawn at
/// the screen's point size (Retina pixels would add nothing but memory);
/// lines and dots at its full resolution.
final class LiveWallpaperView: NSView {
    private let renderer: LiveWallpaperRenderer
    private let clock: LiveWallpaperClock
    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    /// The style faded from, and when the fade began.
    private var transition: (from: LiveWallpaperStyle, start: CFTimeInterval)?

    private(set) var style: LiveWallpaperStyle

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
        }
    }

    init?(frame: NSRect, style: LiveWallpaperStyle, clock: LiveWallpaperClock, opaque: Bool,
          seed: SIMD2<Float>) {
        guard let renderer = LiveWallpaperRenderer(opaque: opaque, seed: seed) else { return nil }
        self.renderer = renderer
        self.clock = clock
        self.style = style
        super.init(frame: frame)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = opaque
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 2
        metalLayer.contentsGravity = .resize
        metalLayer.backgroundColor = opaque ? Self.cgColor(style.base) : nil
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { metalLayer.isOpaque }

    // Never takes a click: a preview's tile button gets it instead.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        updateLink()
        drawFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        drawFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        drawFrame()
    }

    /// Full resolution while a sharp scene shows, or fades in or out.
    private func updateDrawableSize() {
        let sharp = style.scene.isSharp || transition?.from.scene.isSharp == true
        let scale = sharp ? (window?.backingScaleFactor ?? 1) : 1
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    /// Changes the look, fading across when asked to.
    func setStyle(_ next: LiveWallpaperStyle, animated: Bool) {
        guard next != style else { return }
        let now = CACurrentMediaTime()
        if animated, window != nil {
            // A fade cut short starts from wherever the old one stood; close
            // enough, since only the nearer style is still visible.
            let (from, progress) = frameStyles(at: now)
            transition = (progress.map { $0 < 0.5 ? from ?? style : style } ?? style, now)
        } else {
            transition = nil
        }
        style = next
        updateDrawableSize()
        if metalLayer.isOpaque { metalLayer.backgroundColor = Self.cgColor(next.base) }
        updateLink()
        drawFrame()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The style faded from and how far along, or nil when not fading.
    private func frameStyles(at now: CFTimeInterval) -> (from: LiveWallpaperStyle?, progress: Double?) {
        guard let transition else { return (nil, nil) }
        let progress = (now - transition.start) / LiveWallpaperSupport.transitionDuration
        if progress >= 1 {
            self.transition = nil
            updateDrawableSize()
            return (nil, nil)
        }
        // Ease in and out.
        return (transition.from, progress * progress * (3 - 2 * progress))
    }

    /// A paused wallpaper still finishes a fade it started.
    private func updateLink() {
        let wantsLink = window != nil && (isAnimating || transition != nil)
        if wantsLink, link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            let fps = Float(LiveWallpaperSupport.framesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wantsLink {
            stop()
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        drawFrame()
        if !isAnimating, transition == nil { stop() }
    }

    private func drawFrame() {
        guard window != nil, metalLayer.drawableSize.width > 1,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let (from, progress) = frameStyles(at: now)
        renderer.encode(style, from: from, progress: progress ?? 1, fieldTime: clock.time(at: now),
                        pixelScale: metalLayer.contentsScale, into: drawable.texture,
                        commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func cgColor(_ rgb: LiveWallpaperStyle.RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }
}
