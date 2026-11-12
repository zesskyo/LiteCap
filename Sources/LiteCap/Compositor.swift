import CoreMedia
import CoreVideo
import Metal
import MetalKit
import SwiftUI

/// Draws the current scene's sources onto the canvas with the GPU, at the canvas
/// frame rate, and hands each finished frame to the encoders and the preview.
final class Compositor: @unchecked Sendable {
    struct Layer {
        let source: VideoSource
        let frame: CanvasRect
        let crop: Crop
    }

    struct Quad {
        var rect: SIMD4<Float>  // x0, y0, x1, y1 in clip space
        var uv: SIMD4<Float>    // u0, v0, u1, v1
        var opacity: Float = 1
        var tint = SIMD4<Float>(1, 1, 1, 1)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 uv; float opacity; float4 tint; };
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut litecap_vertex(uint vid [[vertex_id]], constant Quad& q [[buffer(0)]]) {
        float2 c = float2(float(vid & 1), float(vid >> 1));
        VOut o;
        o.pos = float4(mix(q.rect.xy, q.rect.zw, c), 0.0, 1.0);
        o.uv = mix(q.uv.xy, q.uv.zw, c);
        return o;
    }
    fragment float4 litecap_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                     sampler s [[sampler(0)]], constant Quad& q [[buffer(0)]]) {
        return tex.sample(s, in.uv) * q.tint * q.opacity;
    }
    """

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    /// 1×1 white texture, tinted to draw solid rectangles (selection box, guides).
    let whiteTexture: MTLTexture
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let renderQueue = DispatchQueue(label: "litecap.compositor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var layers: [Layer] = []
    private var pool: CVPixelBufferPool?
    private var latest: CVPixelBuffer?
    private var inFlight = 0
    private var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var framesThisSecond = 0
    private var secondStart = CFAbsoluteTimeGetCurrent()
    private(set) var fpsMeasured: Double = 0
    private(set) var skippedFrames = 0

    private(set) var width = 1920
    private(set) var height = 1080
    private(set) var fps = 60
    private(set) var isRunning = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "litecap_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "litecap_fragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("LiteCap: shader setup failed: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let white = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let whiteTexture = device.makeTexture(descriptor: white) else { return nil }
        var pixel: [UInt8] = [255, 255, 255, 255]
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        self.whiteTexture = whiteTexture
        configure(width: 1920, height: 1080, fps: 60)
    }

    // MARK: Control

    func configure(width: Int, height: Int, fps: Int) {
        let w = max(16, width & ~1), h = max(16, height & ~1)
        lock.withLock {
            self.width = w
            self.height = h
            self.fps = max(1, fps)
            pool = PixelBuffers.makePool(width: w, height: h, minimum: 8)
            latest = nil
        }
        if isRunning { restartTimer() }
    }

    func setLayers(_ newLayers: [Layer]) { lock.withLock { layers = newLayers } }

    func setFrameHandler(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) { lock.withLock { frameHandler = handler } }

    func latestOutput() -> CVPixelBuffer? { lock.withLock { latest } }

    /// What the preview draws on top of the picture: the selected item's box and snap guides.
    struct PreviewOverlay {
        var rect: CanvasRect?
        var locked = false
        var guides: [(vertical: Bool, position: Double)] = []
    }

    private var overlay = PreviewOverlay()
    func setOverlay(_ newOverlay: PreviewOverlay) { lock.withLock { overlay = newOverlay } }
    func currentOverlay() -> PreviewOverlay { lock.withLock { overlay } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        restartTimer()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        lock.withLock { latest = nil }
    }

    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        let interval = 1.0 / Double(fps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.render() }
        t.resume()
        timer = t
    }

    // MARK: Rendering (on renderQueue)

    func makeTexture(_ buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    private func render() {
        let (layers, pool, handler, w, h, busy) = lock.withLock { (self.layers, self.pool, frameHandler, width, height, inFlight) }
        guard busy < 3 else {
            lock.withLock { skippedFrames += 1 }
            return
        }
        var output: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) }
        guard let output, let (target, targetRef) = makeTexture(output),
              let commands = commandQueue.makeCommandBuffer() else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)

        var keepAlive: [AnyObject] = [targetRef]
        let W = Double(w), H = Double(h)
        for layer in layers {
            guard let frame = layer.source.latestFrame(), let (texture, ref) = makeTexture(frame) else { continue }
            keepAlive.append(ref)
            keepAlive.append(frame)
            let f = layer.frame
            let tw = Double(texture.width), th = Double(texture.height)
            let c = layer.crop
            var quad = Quad(
                rect: SIMD4(Float(f.x / W * 2 - 1), Float(1 - f.y / H * 2),
                            Float((f.x + f.w) / W * 2 - 1), Float(1 - (f.y + f.h) / H * 2)),
                uv: SIMD4(Float(c.left / tw), Float(c.top / th), Float(1 - c.right / tw), Float(1 - c.bottom / th))
            )
            encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        lock.withLock { inFlight += 1 }
        commands.addCompletedHandler { [weak self] _ in
            _ = keepAlive
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.lock.withLock {
                self.inFlight -= 1
                self.latest = output
                self.framesThisSecond += 1
                if now - self.secondStart >= 1 {
                    self.fpsMeasured = Double(self.framesThisSecond) / (now - self.secondStart)
                    self.framesThisSecond = 0
                    self.secondStart = now
                }
            }
            handler?(output, pts)
        }
        commands.commit()
    }
}

// MARK: - Preview

/// Shows the compositor's latest frame, aspect-fit.
struct PreviewSurface: NSViewRepresentable {
    let compositor: Compositor

    func makeCoordinator() -> Renderer { Renderer(compositor: compositor) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: compositor.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Renderer: NSObject, MTKViewDelegate {
        let compositor: Compositor
        private let queue: MTLCommandQueue?

        init(compositor: Compositor) {
            self.compositor = compositor
            queue = compositor.device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Selection box, handles and snap guides, drawn in the same pass as the picture so they
        /// move in lockstep with it.
        private func drawOverlay(_ encoder: MTLRenderCommandEncoder, view: MTKView, sx: Double, sy: Double) {
            let overlay = compositor.currentOverlay()
            guard overlay.rect != nil || !overlay.guides.isEmpty else { return }
            let W = Double(compositor.width), H = Double(compositor.height)
            let px = 2 / Double(max(1, view.drawableSize.width)), py = 2 / Double(max(1, view.drawableSize.height))
            func nx(_ x: Double) -> Double { -sx + x / W * 2 * sx }
            func ny(_ y: Double) -> Double { sy - y / H * 2 * sy }
            encoder.setFragmentTexture(compositor.whiteTexture, index: 0)
            func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ color: SIMD4<Float>) {
                var quad = Compositor.Quad(rect: SIMD4(Float(x0), Float(y0), Float(x1), Float(y1)),
                                           uv: SIMD4(0, 0, 1, 1), tint: color)
                encoder.setVertexBytes(&quad, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                encoder.setFragmentBytes(&quad, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            let cyan = SIMD4<Float>(0.2, 0.85, 1, 1)
            for guide in overlay.guides {
                if guide.vertical {
                    let x = nx(guide.position)
                    box(x - px, sy, x + px, -sy, cyan)
                } else {
                    let y = ny(guide.position)
                    box(-sx, y + py, sx, y - py, cyan)
                }
            }
            guard let r = overlay.rect else { return }
            let color: SIMD4<Float> = overlay.locked ? SIMD4(1, 0.6, 0.1, 1) : SIMD4(0.95, 0.2, 0.2, 1)
            let l = nx(r.x), rt = nx(r.x + r.w), t = ny(r.y), b = ny(r.y + r.h)
            let tx = 3 * px, ty = 3 * py
            box(l, t, rt, t - ty, color)
            box(l, b + ty, rt, b, color)
            box(l, t, l + tx, b, color)
            box(rt - tx, t, rt, b, color)
            guard !overlay.locked else { return }
            let hx = 6 * px, hy = 6 * py
            let midX = (l + rt) / 2, midY = (t + b) / 2
            for (x, y) in [(l, t), (midX, t), (rt, t), (rt, midY), (rt, b), (midX, b), (l, b), (l, midY)] {
                box(x - hx, y + hy, x + hx, y - hy, color)
            }
        }

        func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commands = queue?.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            var keep: [AnyObject] = []
            if let frame = compositor.latestOutput(), let (texture, ref) = compositor.makeTexture(frame) {
                keep = [ref, frame]
                let viewAspect = Double(view.drawableSize.width / max(1, view.drawableSize.height))
                let frameAspect = Double(texture.width) / Double(max(1, texture.height))
                var sx = 1.0, sy = 1.0
                if viewAspect > frameAspect { sx = frameAspect / viewAspect } else { sy = viewAspect / frameAspect }
                var quad = Compositor.Quad(rect: SIMD4(Float(-sx), Float(sy), Float(sx), Float(-sy)), uv: SIMD4(0, 0, 1, 1))
                encoder.setRenderPipelineState(compositor.pipeline)
                encoder.setFragmentSamplerState(compositor.sampler, index: 0)
                encoder.setVertexBytes(&quad, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                encoder.setFragmentBytes(&quad, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                drawOverlay(encoder, view: view, sx: sx, sy: sy)
            }
            encoder.endEncoding()
            commands.present(drawable)
            commands.addCompletedHandler { _ in _ = keep }
            commands.commit()
        }
    }
}
