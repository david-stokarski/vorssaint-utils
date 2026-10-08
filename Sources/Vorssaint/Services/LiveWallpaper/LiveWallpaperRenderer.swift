// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Metal
import QuartzCore

// Fork: draws a Live Wallpaper. Two passes: each scene's slow field is worked
// out on a small float texture (it is smooth, so a few hundred pixels across
// is plenty), then the screen-sized pass turns it into fog, lines or dots and
// adds a fixed dither, so the faint gradients near black do not band. While
// one scene fades into another both are drawn, one per half of the texture.
// With Blur on, the scene is drawn smaller instead, blurred both ways and
// stretched back over the screen, so the blur reaches every scene alike and
// costs less the stronger it is. The shader is compiled from source at run
// time, so the build needs no Metal step.
final class LiveWallpaperRenderer {
    /// One scene's look; the layout matches `Layer` in the shader.
    private struct Layer {
        var inkA: SIMD4<Float>
        var inkB: SIMD4<Float>
        var strength: Float
        var scale: Float
        var pace: Float
        var scene: UInt32

        init(_ style: LiveWallpaperStyle) {
            inkA = style.inkA.vector
            inkB = style.inkB.vector
            strength = style.strength
            scale = style.scale
            pace = style.scene.pace
            scene = style.scene.shaderIndex
        }
    }

    /// The layout matches `Uniforms` in the shader.
    private struct Uniforms {
        var base: SIMD4<Float>
        var from: Layer
        var to: Layer
        var seed: SIMD2<Float>
        var aspect: Float
        var time: Float
        var mix: Float
        var pixelScale: Float
        /// 0 over the lock screen, 1 over the base color, 2 bare ink to blur.
        var opaque: UInt32
        var padding: UInt32 = 0
    }

    /// The layout matches `BlurParams` in the shader.
    private struct BlurParams {
        var step: SIMD2<Float>
        var sigma: Float
        var padding: Float = 0
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let fieldPipeline: MTLRenderPipelineState
    private let composePipeline: MTLRenderPipelineState
    /// Bare premultiplied ink into a float texture, for the blur.
    private let inkPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let finishPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var field: MTLTexture?
    /// The small ink texture and the blur's other half; only while blurring.
    private var blurTextures: (MTLTexture, MTLTexture)?
    /// Full floats where they can be filtered: half floats step visibly
    /// along a contour line on a gentle slope.
    private let fieldFormat: MTLPixelFormat
    /// Where this run sits in the endless noise, so no two runs look alike.
    private let seed: SIMD2<Float>

    /// Opaque on the desktop; on the lock screen only the drift is drawn,
    /// over the plain picture macOS shows there.
    let opaque: Bool

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), opaque: Bool,
          seed: SIMD2<Float> = SIMD2(Float.random(in: 0..<500), Float.random(in: 0..<500))) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "lw_vertex"),
              let fieldFragment = library.makeFunction(name: "lw_field"),
              let composeFragment = library.makeFunction(name: "lw_compose"),
              let blurFragment = library.makeFunction(name: "lw_blur"),
              let finishFragment = library.makeFunction(name: "lw_finish")
        else { return nil }
        func pipeline(_ fragment: MTLFunction, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let fieldFormat: MTLPixelFormat = device.supports32BitFloatFiltering ? .rgba32Float : .rgba16Float
        let fieldDescriptor = MTLRenderPipelineDescriptor()
        fieldDescriptor.vertexFunction = vertex
        fieldDescriptor.fragmentFunction = fieldFragment
        fieldDescriptor.colorAttachments[0].pixelFormat = fieldFormat
        let composeDescriptor = MTLRenderPipelineDescriptor()
        composeDescriptor.vertexFunction = vertex
        composeDescriptor.fragmentFunction = composeFragment
        composeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let fieldPipeline = try? device.makeRenderPipelineState(descriptor: fieldDescriptor),
              let composePipeline = try? device.makeRenderPipelineState(descriptor: composeDescriptor),
              let inkPipeline = pipeline(composeFragment, .rgba16Float),
              let blurPipeline = pipeline(blurFragment, .rgba16Float),
              let finishPipeline = pipeline(finishFragment, .bgra8Unorm),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }
        self.inkPipeline = inkPipeline
        self.blurPipeline = blurPipeline
        self.finishPipeline = finishPipeline
        self.device = device
        self.queue = queue
        self.fieldPipeline = fieldPipeline
        self.composePipeline = composePipeline
        self.sampler = sampler
        self.opaque = opaque
        self.seed = seed
        self.fieldFormat = fieldFormat
    }

    /// Draws one frame into `target` (bgra8Unorm) at `fieldTime`, the
    /// drift's own clock (see `LiveWallpaperClock`). With `from`, the frame
    /// is `progress` of the way from that style to `style`. `pixelScale` is
    /// target pixels per point, so lines and dots keep their size.
    func encode(_ style: LiveWallpaperStyle, from: LiveWallpaperStyle? = nil, progress: Double = 1,
                fieldTime: Double, pixelScale: Double, into target: MTLTexture,
                commandBuffer: MTLCommandBuffer) {
        let width = target.width, height = target.height
        guard width > 0, height > 0 else { return }
        let fieldSize = LiveWallpaperStyle.fieldSize(forWidth: width, height: height)
        if field?.width != fieldSize.width || field?.height != fieldSize.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fieldFormat, width: fieldSize.width, height: fieldSize.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            field = device.makeTexture(descriptor: descriptor)
        }
        guard let field else { return }
        let start = from ?? style
        let amount = from == nil ? Float(0) : Float(max(0, min(1, progress)))
        // Wrapped well inside Float precision; the seam comes once in many
        // hours, as a single step.
        let wrapped = Float(fieldTime.truncatingRemainder(dividingBy: 20_000))
        var uniforms = Uniforms(base: start.mixedBase(with: style, progress: Double(amount)).vector,
                                from: Layer(start), to: Layer(style), seed: seed,
                                aspect: Float(width) / Float(height), time: wrapped, mix: amount,
                                pixelScale: Float(max(1, pixelScale)), opaque: opaque ? 1 : 0)
        let blur = LiveWallpaperStyle.blurPlan(sigma: LiveWallpaperSupport.blurPixels(style.blur, height: height),
                                               width: width, height: height)

        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = field
        fieldPass.colorAttachments[0].loadAction = .dontCare
        fieldPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: fieldPass) {
            encoder.setRenderPipelineState(fieldPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        guard let blur, let textures = blurTextures(width: blur.width, height: blur.height) else {
            blurTextures = nil
            draw(composePipeline, into: target, commandBuffer: commandBuffer) { encoder in
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(field, index: 0)
            }
            return
        }

        let (ink, spare) = textures
        // Bare ink at the small size, lines and dots kept to their size in points.
        var inkUniforms = uniforms
        inkUniforms.opaque = 2
        inkUniforms.pixelScale = uniforms.pixelScale * Float(blur.height) / Float(height)
        draw(inkPipeline, into: ink, commandBuffer: commandBuffer) { encoder in
            encoder.setFragmentBytes(&inkUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(field, index: 0)
        }
        var across = BlurParams(step: SIMD2(1 / Float(blur.width), 0), sigma: Float(blur.sigma))
        draw(blurPipeline, into: spare, commandBuffer: commandBuffer) { encoder in
            encoder.setFragmentBytes(&across, length: MemoryLayout<BlurParams>.stride, index: 0)
            encoder.setFragmentTexture(ink, index: 0)
        }
        var down = BlurParams(step: SIMD2(0, 1 / Float(blur.height)), sigma: Float(blur.sigma))
        draw(blurPipeline, into: ink, commandBuffer: commandBuffer) { encoder in
            encoder.setFragmentBytes(&down, length: MemoryLayout<BlurParams>.stride, index: 0)
            encoder.setFragmentTexture(spare, index: 0)
        }
        draw(finishPipeline, into: target, commandBuffer: commandBuffer) { encoder in
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(ink, index: 0)
        }
    }

    private func draw(_ pipeline: MTLRenderPipelineState, into texture: MTLTexture,
                      commandBuffer: MTLCommandBuffer, bind: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        bind(encoder)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func blurTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let blurTextures, blurTextures.0.width == width, blurTextures.0.height == height { return blurTextures }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let ink = device.makeTexture(descriptor: descriptor),
              let spare = device.makeTexture(descriptor: descriptor) else { return nil }
        blurTextures = (ink, spare)
        return blurTextures
    }

    // Positions are in screen heights from the center, so every screen
    // shape shows the same composition, only wider or narrower. Scene
    // numbers match `LiveWallpaperScene.shaderIndex`.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Layer {
        float4 inkA;
        float4 inkB;
        float strength;
        float scale;
        float pace;
        uint scene;
    };

    struct Uniforms {
        float4 base;
        Layer from;
        Layer to;
        float2 seed;
        float aspect;
        float time;
        float mix;
        float pixelScale;
        uint opaque;
        uint padding;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings lw_vertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        Varyings out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    static float lw_hash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    static float lw_noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = lw_hash(i);
        float b = lw_hash(i + float2(1.0, 0.0));
        float c = lw_hash(i + float2(0.0, 1.0));
        float d = lw_hash(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    static float lw_fbm(float2 p, int octaves) {
        const float2x2 turn = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
        float sum = 0.0;
        float total = 0.0;
        float amplitude = 0.5;
        for (int octave = 0; octave < octaves; octave++) {
            sum += amplitude * lw_noise(p);
            total += amplitude;
            p = turn * p * 2.02 + float2(17.1, 3.7);
            amplitude *= 0.42;
        }
        return sum / total;
    }

    // MARK: Fields, at low resolution. Each returns two smooth values.

    // Mist: domain-warped noise (after Inigo Quilez), noise pushed around by
    // noise, reads as smoke or ink in water. A slow mask lets whole regions
    // come and go.
    static float2 lw_mist(float2 q, float t) {
        float2 a = float2(lw_fbm(q + float2(0.0, 0.13 * t), 4),
                          lw_fbm(q + float2(5.2, 1.3) + float2(-0.11 * t, 0.07 * t), 4));
        float2 r = float2(lw_fbm(q + 1.3 * a + float2(1.7, 9.2) + float2(0.09 * t, -0.03 * t), 4),
                          lw_fbm(q + 1.3 * a + float2(8.3, 2.8) + float2(-0.08 * t, 0.05 * t), 4));
        float f = lw_fbm(q + 1.5 * r, 4);
        float wisps = smoothstep(0.38, 0.86, f);
        wisps *= wisps;
        float mask = smoothstep(0.30, 0.75, lw_noise(q * 0.35 + float2(-0.021 * t, 0.017 * t) + 41.0));
        return float2(clamp(wisps * (0.35 + 0.65 * mask), 0.0, 1.0), smoothstep(0.2, 0.8, r.x));
    }

    // Contours: a gently warped height map; its level lines are drawn later.
    static float2 lw_contours(float2 q, float t) {
        float2 w = float2(lw_fbm(q * 0.6 + float2(0.0, 0.05 * t), 3),
                          lw_fbm(q * 0.6 + float2(4.1, 7.3) + float2(-0.04 * t, 0.0), 3));
        float h = lw_fbm(q + 0.9 * w + float2(0.02 * t, -0.015 * t), 3);
        float mask = smoothstep(0.2, 0.7, lw_noise(q * 0.3 + float2(0.012 * t, 0.0) + 23.0));
        return float2(h, mask);
    }

    // Waves: a ribbon of threads, its center line and half its width along
    // the screen. Where the width narrows the ribbon seems to turn over.
    static float2 lw_waves(float2 p, float2 seed, float t) {
        float x = p.x;
        float center = 0.10 * sin(x * 1.3 + 0.30 * t + seed.x)
                     + 0.05 * sin(x * 2.9 - 0.23 * t + seed.y)
                     + 0.16 * (lw_noise(float2(x * 0.6 - 0.05 * t, 0.5) + seed) - 0.5);
        float twist = 0.5 + 0.5 * sin(x * 1.1 + 0.27 * t + seed.y * 0.7
                                      + 1.5 * lw_noise(float2(x * 0.5 + 0.03 * t, 7.0) + seed));
        return float2(center, 0.06 + 0.20 * twist);
    }

    // Halo: a few large soft glows wandering on their own slow paths.
    static float2 lw_halo(float2 p, float aspect, float2 seed, float t) {
        float cover = 0.0;
        float warm = 0.0;
        for (int i = 0; i < 4; i++) {
            float k = float(i);
            float2 c = float2((lw_noise(float2(0.045 * t + k * 13.7, seed.x)) - 0.5) * aspect * 1.2,
                              (lw_noise(float2(seed.y + k * 5.3, 0.04 * t + k * 2.1)) - 0.5) * 1.3);
            float r = 0.30 + 0.10 * sin(0.07 * t + k * 1.9);
            float g = exp(-dot(p - c, p - c) / (r * r));
            cover += g * (i == 3 ? 0.6 : 1.0);
            warm += g * float(i & 1);
        }
        return float2(clamp(cover, 0.0, 1.0), warm / (cover + 0.001));
    }

    // Dots: a slow swell crossing the grid, roughened by noise.
    static float2 lw_dots(float2 q, float t) {
        float f = lw_fbm(q * 0.8 + float2(0.05 * t, -0.03 * t), 3);
        float swell = 0.5 + 0.5 * sin(q.x * 1.2 + q.y * 0.7 - 0.4 * t);
        return float2(smoothstep(0.35, 0.85, f * 0.75 + swell * 0.35), f);
    }

    // Ripple: a little unevenness for the rings, and where they show.
    static float2 lw_ripple(float2 q, float t) {
        return float2(lw_noise(q * 1.2 + float2(0.03 * t, -0.02 * t)) - 0.5,
                      lw_noise(q * 0.4 + float2(-0.01 * t, 0.015 * t) + 11.0));
    }

    static float2 lw_layer_field(constant Layer &l, float2 p, constant Uniforms &u) {
        float t = u.time * l.pace;
        float2 q = p * l.scale + u.seed;
        switch (l.scene) {
            case 1: return lw_contours(q, t);
            case 2: return lw_waves(p, u.seed, t);
            case 3: return lw_halo(p, u.aspect, u.seed, t);
            case 4: return lw_dots(q, t);
            case 5: return lw_ripple(q, t);
            default: return lw_mist(q, t);
        }
    }

    fragment float4 lw_field(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = (in.uv - 0.5) * float2(u.aspect, 1.0);
        float2 from = u.mix < 1.0 ? lw_layer_field(u.from, p, u) : float2(0.0);
        float2 to = u.mix > 0.0 ? lw_layer_field(u.to, p, u) : float2(0.0);
        return float4(from, to);
    }

    // MARK: Compose, at full resolution.

    // A line of `width` pixels on every whole number of `v`, smooth at the
    // edges, evening out where the lines would crowd into a moire.
    static float lw_line(float v, float width) {
        float step = max(fwidth(v), 1e-4);
        float d = abs(fract(v + 0.5) - 0.5) / step;
        float line = 1.0 - smoothstep(width * 0.5 - 0.5, width * 0.5 + 0.5, d);
        // Where lines crowd, their average: a sheen, not a moire.
        return mix(line, min(1.0, width * step), smoothstep(0.2, 0.45, step));
    }

    // One scene's ink, premultiplied.
    static float4 lw_layer(constant Layer &l, float2 f, float2 p, float2 pixel, float vignette,
                           constant Uniforms &u) {
        float t = u.time * l.pace;
        // Drawn at least a pixel wide, and fainter by as much, so a line in
        // the small texture behind Blur holds its weight.
        float trueWidth = 1.15 * u.pixelScale;
        float width = max(trueWidth, 1.0);
        float thin = trueWidth / width;
        float alpha = 0.0;
        float tint = f.y;
        switch (l.scene) {
            case 1: {
                float v = f.x * 15.0;
                float minor = lw_line(v, width);
                float major = lw_line(v * 0.2, width * 1.4);
                alpha = max(minor * 0.5, major) * thin * (0.3 + 0.7 * f.y) * (0.5 + 0.5 * vignette);
                tint = smoothstep(0.3, 0.7, f.x);
                break;
            }
            case 2: {
                float across = (p.y - f.x) / f.y;
                float edge = 1.0 - smoothstep(0.75, 1.08, abs(across));
                alpha = lw_line(across * 12.0, width) * thin * edge * (0.45 + 0.55 * vignette);
                tint = 0.5 + 0.5 * across;
                break;
            }
            case 3:
                alpha = f.x * (0.6 + 0.4 * vignette);
                break;
            case 4: {
                float spacing = 26.0;
                float2 points = pixel / u.pixelScale;
                float2 cell = (fract(points / spacing + 0.5) - 0.5) * spacing;
                float radius = mix(0.9, 2.8, f.x);
                // At least a pixel across, and fainter by its lost area.
                float pixels = radius * u.pixelScale;
                float shown = max(pixels, 1.0);
                float edge = 0.6 / u.pixelScale;
                float drawn = shown / u.pixelScale;
                float disc = 1.0 - smoothstep(drawn - edge, drawn + edge, length(cell));
                float kept = pixels / shown;
                alpha = disc * kept * kept * (0.22 + 0.78 * f.x) * (0.55 + 0.45 * vignette);
                tint = smoothstep(0.3, 0.7, f.y);
                break;
            }
            case 5: {
                float2 center = float2(sin(0.031 * t) * 0.25 * min(u.aspect, 1.8), cos(0.023 * t) * 0.12);
                float d = length(p - center) + f.x * 0.05;
                float v = d * 10.0 - 0.22 * t;
                float fade = smoothstep(0.0, 0.12, d) * (1.0 - smoothstep(0.4, 1.6, d));
                alpha = lw_line(v, width) * thin * fade * (0.55 + 0.45 * f.y);
                tint = smoothstep(0.2, 1.2, d);
                break;
            }
            default:
                alpha = f.x * (0.55 + 0.45 * vignette);
                break;
        }
        alpha = clamp(alpha * l.strength, 0.0, 1.0);
        float3 ink = mix(l.inkA.rgb, l.inkB.rgb, clamp(tint, 0.0, 1.0));
        return float4(ink * alpha, alpha);
    }

    // Cubic B-spline filtering from four bilinear taps: the stretched field
    // stays smooth in its slope too, so lines drawn from it do not kink at
    // the edges of its texels.
    static float4 lw_sample(texture2d<float> field, sampler smooth, float2 uv) {
        float2 size = float2(field.get_width(), field.get_height());
        float2 st = uv * size - 0.5;
        float2 i = floor(st);
        float2 f = st - i;
        float2 f2 = f * f;
        float2 f3 = f2 * f;
        float2 w0 = (-f3 + 3.0 * f2 - 3.0 * f + 1.0) / 6.0;
        float2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
        float2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
        float2 w3 = f3 / 6.0;
        float2 g0 = w0 + w1;
        float2 g1 = w2 + w3;
        float2 a = (i - 1.0 + w1 / g0 + 0.5) / size;
        float2 b = (i + 1.0 + w3 / g1 + 0.5) / size;
        return g0.y * (g0.x * field.sample(smooth, float2(a.x, a.y)) + g1.x * field.sample(smooth, float2(b.x, a.y)))
             + g1.y * (g0.x * field.sample(smooth, float2(a.x, b.y)) + g1.x * field.sample(smooth, float2(b.x, b.y)));
    }

    // Interleaved gradient noise: a fixed, even dither of one code value.
    static float lw_dither(float2 pixel) {
        return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5;
    }

    // Ink over the base color, over the lock screen, or bare for the blur.
    static float4 lw_output(float4 ink, float2 pixel, constant Uniforms &u) {
        if (u.opaque == 2) return ink;
        float noise = lw_dither(pixel) / 255.0;
        if (u.opaque == 1) {
            float3 color = u.base.rgb * (1.0 - ink.a) + ink.rgb + noise;
            return float4(clamp(color, 0.0, 1.0), 1.0);
        }
        // Premultiplied: the dither scales the ink it lands on.
        float a = clamp(ink.a + noise, 0.0, 1.0);
        return float4(ink.rgb * (a / max(ink.a, 1e-4)), a);
    }

    fragment float4 lw_compose(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                               texture2d<float> field [[texture(0)]], sampler smooth [[sampler(0)]]) {
        float4 sample = lw_sample(field, smooth, in.uv);
        float2 p = (in.uv - 0.5) * float2(u.aspect, 1.0);
        // Calmer toward the edges and corners, where the eye rests least.
        float vignette = 1.0 - smoothstep(0.35, 1.05, length(p * float2(0.75, 1.0)));
        float4 from = u.mix < 1.0 ? lw_layer(u.from, sample.xy, p, in.position.xy, vignette, u) : float4(0.0);
        float4 to = u.mix > 0.0 ? lw_layer(u.to, sample.zw, p, in.position.xy, vignette, u) : float4(0.0);
        return lw_output(mix(from, to, u.mix), in.position.xy, u);
    }

    // Separable Gaussian, one direction per pass, over thirteen taps.
    struct BlurParams {
        float2 step;
        float sigma;
        float padding;
    };

    fragment float4 lw_blur(Varyings in [[stage_in]], constant BlurParams &b [[buffer(0)]],
                            texture2d<float> source [[texture(0)]], sampler smooth [[sampler(0)]]) {
        float4 sum = float4(0.0);
        float total = 0.0;
        float spread = 2.0 * max(b.sigma * b.sigma, 0.01);
        for (int k = -6; k <= 6; k++) {
            float w = exp(-float(k * k) / spread);
            sum += w * source.sample(smooth, in.uv + b.step * float(k));
            total += w;
        }
        return sum / total;
    }

    // The blurred ink stretched back over the screen.
    fragment float4 lw_finish(Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                              texture2d<float> ink [[texture(0)]], sampler smooth [[sampler(0)]]) {
        return lw_output(lw_sample(ink, smooth, in.uv), in.position.xy, u);
    }
    """
}
