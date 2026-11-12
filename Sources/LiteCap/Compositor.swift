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
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 uv; float opacity; };
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
        return tex.sample(s, in.uv) * q.opacity;
    }
    """

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
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
        view.preferredFramesPerSecond = 30
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
            }
            encoder.endEncoding()
            commands.present(drawable)
            commands.addCompletedHandler { _ in _ = keep }
            commands.commit()
        }
    }
}
