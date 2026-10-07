// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: the pixel work behind App Icons' dark style. An icon is read as a
/// bitmap; a tile (the familiar rounded square) has the smooth area that
/// touches its edge taken for its background and turned dark, and a dark
/// glyph that stood on a light background turned light so it still reads. A
/// free-standing shape gets a dark tile of its own instead, made in
/// AppIconRenderer. Pure and on plain bytes so the tests can feed it
/// pictures they draw themselves.
struct AppIconBitmap: Equatable {
    let width: Int
    let height: Int
    /// RGBA, 8 bits each, straight (not premultiplied) alpha, top row first.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (0, 0, 0, 0)) {
        self.init(width: width, height: height,
                  pixels: [UInt8](repeating: 0, count: width * height * 4).enumerated().map { index, _ in
                      switch index % 4 {
                      case 0: return fill.r
                      case 1: return fill.g
                      case 2: return fill.b
                      default: return fill.a
                      }
                  })
    }

    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}

enum AppIconStyler {
    enum Kind: Equatable {
        /// A rounded square filled edge to edge.
        case tile
        /// A shape standing on its own (older icons, or a glyph with a shadow).
        case shape
    }

    /// How the tile's background was handled.
    enum Treatment: Equatable {
        /// The smooth area along the edge was found and darkened.
        case background
        /// No calm background to find (a photo, a busy pattern): dimmed whole.
        case dimmed
        /// Already dark: only its shape is brought to the grid.
        case kept
    }

    /// Opaque bounds, ignoring a soft shadow around the icon.
    static func opaqueBounds(of bitmap: AppIconBitmap, alphaThreshold: UInt8 = 200) -> CGRect? {
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            let row = y * bitmap.width * 4
            for x in 0..<bitmap.width where bitmap.pixels[row + x * 4 + 3] >= alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A tile is near square, large on its canvas, and solid inside a
    /// rounded square of its own bounds.
    static func kind(of bitmap: AppIconBitmap, bounds: CGRect) -> Kind {
        let aspect = bounds.width / max(bounds.height, 1)
        guard (0.92...1.08).contains(aspect),
              bounds.width >= CGFloat(bitmap.width) * 0.55 else { return .shape }
        // Sample a grid inside the rounded square, staying clear of its rim.
        let inset = bounds.insetBy(dx: bounds.width * 0.03, dy: bounds.height * 0.03)
        let radius = inset.width * 0.24
        var inside = 0, solid = 0
        let step = max(1, Int(inset.width / 64))
        var y = Int(inset.minY)
        while y < Int(inset.maxY) {
            var x = Int(inset.minX)
            while x < Int(inset.maxX) {
                if isInsideRoundedRect(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), rect: inset, radius: radius) {
                    inside += 1
                    if bitmap.pixel(x, y).a >= 230 { solid += 1 }
                }
                x += step
            }
            y += step
        }
        guard inside > 0 else { return .shape }
        return Double(solid) / Double(inside) >= 0.97 ? .tile : .shape
    }

    static func isInsideRoundedRect(_ point: CGPoint, rect: CGRect, radius: CGFloat) -> Bool {
        guard rect.contains(point) else { return false }
        let cx = min(max(point.x, rect.minX + radius), rect.maxX - radius)
        let cy = min(max(point.y, rect.minY + radius), rect.maxY - radius)
        let dx = point.x - cx, dy = point.y - cy
        return dx * dx + dy * dy <= radius * radius
    }

    // MARK: - Color helpers

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    static func rgb(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        let i = Int(floor(h * 6)) % 6
        let f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The dark tile color for a background of this color, at height `t`
    /// (0 top, 1 bottom). Keeps a hint of the original hue so the icon is
    /// still recognizably itself.
    static func darkBase(for background: (r: Double, g: Double, b: Double), at t: Double) -> (r: Double, g: Double, b: Double) {
        let (h, s, _) = hsv(background.r, background.g, background.b)
        let saturation = s < 0.12 ? 0 : min(s * 0.55, 0.42)
        let value = 0.24 - 0.13 * t
        return rgb(h: h, s: saturation, v: value)
    }

    /// The average hue an icon wears, saturated pixels counting most, for the
    /// tile under a free-standing shape.
    static func accent(of bitmap: AppIconBitmap) -> (r: Double, g: Double, b: Double) {
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        var i = 0
        while i < bitmap.pixels.count {
            let a = Double(bitmap.pixels[i + 3]) / 255
            if a > 0.8 {
                let pr = Double(bitmap.pixels[i]) / 255, pg = Double(bitmap.pixels[i + 1]) / 255
                let pb = Double(bitmap.pixels[i + 2]) / 255
                let s = hsv(pr, pg, pb).s
                let w = s * s
                r += pr * w; g += pg * w; b += pb * w; weight += w
            }
            i += 16  // every fourth pixel is plenty for an average
        }
        guard weight > 0 else { return (0.5, 0.5, 0.5) }
        return (r / weight, g / weight, b / weight)
    }

    // MARK: - Tiles

    /// Darkens a tile in place: `bitmap` is just the tile, its rounded square
    /// filling the frame (corners may be transparent).
    @discardableResult
    static func darkenTile(_ bitmap: inout AppIconBitmap) -> Treatment {
        let w = bitmap.width, h = bitmap.height, count = w * h
        var px = bitmap.pixels
        func isInside(_ i: Int) -> Bool { px[i * 4 + 3] > 128 }

        // Seeds: a band just inside the edge on every row and column.
        let band = max(2, w / 60)
        var seeds: [Int] = []
        for y in stride(from: h / 10, to: h * 9 / 10, by: 2) {
            if let first = (0..<w).first(where: { isInside(y * w + $0) }), first + band < w {
                seeds.append(y * w + first + band)
            }
            if let last = (0..<w).last(where: { isInside(y * w + $0) }), last - band >= 0 {
                seeds.append(y * w + last - band)
            }
        }
        for x in stride(from: w / 10, to: w * 9 / 10, by: 2) {
            if let first = (0..<h).first(where: { isInside($0 * w + x) }), first + band < h {
                seeds.append((first + band) * w + x)
            }
            if let last = (0..<h).last(where: { isInside($0 * w + x) }), last - band >= 0 {
                seeds.append((last - band) * w + x)
            }
        }
        guard !seeds.isEmpty else { return .dimmed }

        // The background is the smooth area most of the edge belongs to.
        // Flooding across small steps crosses a gradient but not the sharp
        // edge of a glyph, so a glyph that runs off the edge (an outline, a
        // body cut off at the bottom) is left out. A few starting points
        // are tried, the most typical first, and the widest area wins.
        func channel(_ c: Int) -> Int {
            var values = seeds.map { Int(px[$0 * 4 + c]) }
            values.sort()
            return values[values.count / 2]
        }
        let median = (channel(0), channel(1), channel(2))
        let medianValue = Double(max(median.0, median.1, median.2)) / 255
        // An edge that is already dark is left alone: flooding it could
        // seep into a glow and take the glyph with it.
        if medianValue < 0.25 { return .kept }
        let ordered = seeds.sorted { a, b in
            func distance(_ i: Int) -> Int {
                max(abs(Int(px[i * 4]) - median.0), abs(Int(px[i * 4 + 1]) - median.1),
                    abs(Int(px[i * 4 + 2]) - median.2))
            }
            return distance(a) < distance(b)
        }
        var label = [Int32](repeating: 0, count: count)
        var queue = [Int32]()
        func difference(_ a: Int, _ b: Int) -> Int {
            max(abs(Int(px[a * 4]) - Int(px[b * 4])), abs(Int(px[a * 4 + 1]) - Int(px[b * 4 + 1])),
                abs(Int(px[a * 4 + 2]) - Int(px[b * 4 + 2])))
        }
        /// Floods `labelValue` out from `seed`. A step must be small, and so
        /// must two steps together: a gradient changes a little at a time,
        /// while a glyph's soft edge changes a lot over two or three pixels.
        func flood(from seed: Int, as labelValue: Int32) {
            label[seed] = labelValue
            queue.removeAll(keepingCapacity: true)
            queue.append(Int32(seed))
            var head = 0
            while head < queue.count {
                let p = Int(queue[head]); head += 1
                let x = p % w, y = p / w
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    guard label[q] == 0, isInside(q), difference(p, q) <= 12 else { continue }
                    let bx = x - dx, by = y - dy
                    if bx >= 0, by >= 0, bx < w, by < h, isInside(by * w + bx),
                       difference(by * w + bx, q) > 18 { continue }
                    label[q] = labelValue
                    queue.append(Int32(q))
                }
            }
        }
        var bestLabel: Int32 = 0, bestCovered = 0
        var nextLabel: Int32 = 1
        var start = 0
        while nextLabel <= 4, start < ordered.count {
            let seed = ordered[start]
            start += 1
            guard label[seed] == 0 else { continue }
            let current = nextLabel
            nextLabel += 1
            flood(from: seed, as: current)
            let covered = seeds.reduce(0) { $0 + (label[$1] == current ? 1 : 0) }
            if covered > bestCovered { bestCovered = covered; bestLabel = current }
            if Double(covered) / Double(seeds.count) >= 0.6 { break }
        }
        // Other areas of the background's color that reach the edge (a
        // body cut off at the bottom, the same white as around it) go dark
        // with it, so line art keeps its two tones.
        if bestLabel != 0, let reference = seeds.first(where: { label[$0] == bestLabel }) {
            for seed in seeds where label[seed] != bestLabel && difference(seed, reference) <= 20 {
                if label[seed] != 0 {
                    let other = label[seed]
                    for p in 0..<count where label[p] == other { label[p] = bestLabel }
                } else {
                    flood(from: seed, as: bestLabel)
                }
            }
            bestCovered = seeds.reduce(0) { $0 + (label[$1] == bestLabel ? 1 : 0) }
        }
        var mask = [UInt8](repeating: 0, count: count)
        var region = [Int32]()
        for p in 0..<count where label[p] == bestLabel && bestLabel != 0 {
            mask[p] = 1
            region.append(Int32(p))
        }
        let insideCount = (0..<count).reduce(0) { $0 + (isInside($1) ? 1 : 0) }
        let filled = region.count
        // Too little of the edge or of the tile is calm: a photo or a busy
        // pattern. Dark ones stay as they are; others are dimmed whole.
        guard Double(bestCovered) / Double(seeds.count) >= 0.5, insideCount > 0,
              Double(filled) / Double(insideCount) >= 0.18 else {
            if medianValue < 0.25 { return .kept }
            dim(&px)
            bitmap.pixels = px
            return .dimmed
        }
        // A background that takes nearly the whole tile yet runs from dark
        // to bright has swallowed a glyph that fades into it on purpose.
        // Dimming the whole tile keeps that glyph light.
        if Double(filled) / Double(insideCount) > 0.93 {
            var lums = stride(from: 0, to: region.count, by: 7).map { k -> Double in
                let i = Int(region[k]) * 4
                return luminance(Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
            }
            lums.sort()
            if lums[lums.count * 98 / 100] - lums[lums.count * 2 / 100] > 0.35 {
                dim(&px)
                bitmap.pixels = px
                return .dimmed
            }
        }
        let queueForStats = region

        // Soft edges: the mask averaged over a 3×3 neighbourhood.
        var weight = [Float](repeating: 0, count: count)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < w else { continue }
                        sum += Int(mask[yy * w + xx]); n += 1
                    }
                }
                weight[y * w + x] = Float(sum) / Float(n)
            }
        }

        // The background's own color and brightness, to keep its shading.
        var br = 0.0, bg = 0.0, bb = 0.0, bl = 0.0
        for q in queueForStats {
            let i = Int(q) * 4
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            br += r; bg += g; bb += b; bl += luminance(r, g, b)
        }
        let n = Double(filled)
        let background = (r: br / n, g: bg / n, b: bb / n)
        let backgroundLum = bl / n
        let wasLight = backgroundLum > 0.55
        // Already dark (judged by brightness, so a deep but vivid purple is
        // not mistaken for dark): only its shape changes.
        if max(background.r, background.g, background.b) < 0.25 { return .kept }

        for y in 0..<h {
            let t = Double(y) / Double(max(h - 1, 1))
            let base = darkBase(for: background, at: t)
            for x in 0..<w {
                let p = y * w + x
                let i = p * 4
                guard px[i + 3] > 0 else { continue }
                var r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                let wb = Double(weight[p])
                let lum = luminance(r, g, b)
                if wb > 0 {
                    // Dark, with the background's own shading kept faintly.
                    let shade = (lum - backgroundLum) * 0.3
                    let dr = min(max(base.r + shade, 0), 1)
                    let dg = min(max(base.g + shade, 0), 1)
                    let db = min(max(base.b + shade, 0), 1)
                    r = r + (dr - r) * wb; g = g + (dg - g) * wb; b = b + (db - b) * wb
                }
                if wasLight, wb < 1 {
                    // A dark, colorless glyph on what was a light background
                    // turns light, or it would vanish into the new dark.
                    let (hue, sat, value) = hsv(r, g, b)
                    let amount = (1 - wb) * smoothstep(0.5, 0.25, lum) * smoothstep(0.32, 0.12, sat)
                    if amount > 0 {
                        let light = rgb(h: hue, s: sat, v: min(1, 0.94 - value * 0.45))
                        r += (light.r - r) * amount; g += (light.g - g) * amount; b += (light.b - b) * amount
                    }
                }
                px[i] = UInt8((r * 255).rounded())
                px[i + 1] = UInt8((g * 255).rounded())
                px[i + 2] = UInt8((b * 255).rounded())
            }
        }
        bitmap.pixels = px
        return .background
    }

    /// For a tile with no calm background: darker and a little richer.
    private static func dim(_ px: inout [UInt8]) {
        var i = 0
        while i < px.count {
            if px[i + 3] > 0 {
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                let (h, s, v) = hsv(r, g, b)
                let out = rgb(h: h, s: min(1, s * 1.08), v: pow(v, 1.3) * 0.72)
                px[i] = UInt8((out.r * 255).rounded())
                px[i + 1] = UInt8((out.g * 255).rounded())
                px[i + 2] = UInt8((out.b * 255).rounded())
            }
            i += 4
        }
    }
}
