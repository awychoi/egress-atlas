import Foundation
import Metal
import MetalKit
import simd
import QuartzCore

struct RenderState {
    var camera: Camera
    var logicalSize: CGSize
    var drawList: DrawList
    var elapsed: Float
    var stageScale: Float
    var backdropYaw: Float
    var shake: Vec3
    var bloomStrength: Float
    var bloomRadius: Float
    var bloomEnabled: Bool
    var dofFocus: Float
    var dofAperture: Float
    var dofMaxBlur: Float
    var dofEnabled: Bool
    var exposure: Float = 0.98
}

private struct DynamicBuffer {
    var buffers: [MTLBuffer?] = [nil, nil, nil]
    var capacity = 0
    var stride: Int
    var label: String

    init(stride: Int, label: String) {
        self.stride = stride
        self.label = label
    }

    mutating func update<T>(_ array: [T], device: MTLDevice, frame: Int) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        let bytes = array.count * stride
        if capacity < array.count {
            capacity = max(array.count, capacity * 2, 256)
            let length = capacity * stride
            for i in 0..<buffers.count {
                buffers[i] = device.makeBuffer(length: length, options: .storageModeShared)
                buffers[i]?.label = label
            }
        }
        let index = frame % 3
        guard let buffer = buffers[index] else { return nil }
        array.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
        return buffer
    }
}

final class GlobeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let shapes: ShapeLibrary

    private var sceneColor: MTLTexture?
    private var sceneColorMSAA: MTLTexture?
    private var sceneDepthMSAA: MTLTexture?
    private var dofTexture: MTLTexture?
    private var bloomBright: MTLTexture?
    private var bloomH: [MTLTexture] = []
    private var bloomV: [MTLTexture] = []
    private var bloomComposite: MTLTexture?
    private var targetSize = CGSize.zero
    private var bloomSize = CGSize.zero
    private var blurKernels: [(offsets: [Float], weights: [Float], center: Float)] = []

    private var backgroundPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var spriteNoDepthPipeline: MTLRenderPipelineState!
    private var meshPipeline: MTLRenderPipelineState!
    private var rawPipeline: MTLRenderPipelineState!
    private var nodeRingPipeline: MTLRenderPipelineState!
    private var shockPipeline: MTLRenderPipelineState!
    private var atmospherePipeline: MTLRenderPipelineState!
    private var glassPipeline: MTLRenderPipelineState!
    private var planetPipeline: MTLRenderPipelineState!
    private var planetAtmoPipeline: MTLRenderPipelineState!
    private var shockShellPipeline: MTLRenderPipelineState!
    private var shieldPipeline: MTLRenderPipelineState!
    private var scanPipeline: MTLRenderPipelineState!
    private var discPipeline: MTLRenderPipelineState!
    private var jetPipeline: MTLRenderPipelineState!
    private var dofPipeline: MTLRenderPipelineState!
    private var brightPipeline: MTLRenderPipelineState!
    private var blurPipeline: MTLRenderPipelineState!
    private var bloomCompositePipeline: MTLRenderPipelineState!
    private var finalPipeline: MTLRenderPipelineState!
    private var finalPipelineRGBA: MTLRenderPipelineState!
    private var depthAlways: MTLDepthStencilState!
    private var depthNoWrite: MTLDepthStencilState!
    private var depthWrite: MTLDepthStencilState!

    private var lineBuffer = DynamicBuffer(stride: MemoryLayout<LineVertex>.stride, label: "lines")
    private var stageLineBuffer = DynamicBuffer(stride: MemoryLayout<LineVertex>.stride, label: "stage lines")
    private var pointBuffer = DynamicBuffer(stride: MemoryLayout<PointVertex>.stride, label: "points")
    private var stagePointBuffer = DynamicBuffer(stride: MemoryLayout<PointVertex>.stride, label: "stage points")
    private var spriteBuffer = DynamicBuffer(stride: MemoryLayout<SpriteInstance>.stride, label: "sprites")
    private var rawBuffer = DynamicBuffer(stride: MemoryLayout<TriangleVertex>.stride, label: "triangles")
    private var meshBuffers = (0..<ShapeID.allCases.count).map {
        DynamicBuffer(stride: MemoryLayout<MeshInstance>.stride, label: "mesh instances \($0)")
    }

    private var frameIndex = 0
    private var frameDiagnosticCounter = 0
    private let timingLock = NSLock()
    private var timingWallSum: Double = 0
    private var timingGPUSum: Double = 0
    private var timingCount = 0
    private var presentFirst: CFTimeInterval = 0
    private var presentLast: CFTimeInterval = 0
    private var presentIntervalSum: Double = 0
    private var presentIntervalMax: Double = 0
    private var presentCount = 0

    private var breakdownSamples = 0
    private var breakdownUpdate: Double = 0
    private var breakdownWait: Double = 0
    private var breakdownEncode: Double = 0

    private func recordFrameTiming(wall: Double, gpu: Double) {
        timingLock.lock()
        timingWallSum += wall
        timingGPUSum += gpu
        timingCount += 1
        if timingCount >= 120 {
            let w = timingWallSum / Double(timingCount) * 1000
            let g = timingGPUSum / Double(timingCount) * 1000
            AtlasDiagnostics.log(String(format: "frame timing wall=%.2fms gpu=%.2fms", w, g))
            timingWallSum = 0; timingGPUSum = 0; timingCount = 0
        }
        timingLock.unlock()
    }

    /// True delivered cadence: the timestamps the window server actually
    /// presented our drawables. This is the number the eye sees, independent
    /// of how often the clock fired or how long encoding took.
    private func recordPresent(_ presented: CFTimeInterval) {
        guard presented > 0 else { return }
        var logLine: String?
        timingLock.lock()
        if presentLast > 0 {
            let interval = max(0, presented - presentLast)
            presentIntervalSum += interval
            presentIntervalMax = max(presentIntervalMax, interval)
            presentCount += 1
        } else {
            presentFirst = presented
        }
        presentLast = presented
        if presentCount >= 120 {
            let seconds = max(0.0001, presented - presentFirst)
            let fps = Double(presentCount) / seconds
            let avg = presentIntervalSum / Double(presentCount) * 1000
            logLine = String(format: "present fps=%.1f interval=%.2fms max=%.2fms",
                             fps, avg, presentIntervalMax * 1000)
            presentFirst = 0
            presentLast = 0
            presentIntervalSum = 0
            presentIntervalMax = 0
            presentCount = 0
        }
        timingLock.unlock()
        if let logLine { AtlasDiagnostics.log(logLine) }
    }
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    weak var runtime: AtlasRuntime?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noQueue }
        self.queue = queue
        let source = try ShaderSource.load()
        do {
            self.library = try device.makeLibrary(source: source, options: nil)
        } catch {
            AtlasDiagnostics.log("shader compile failed: \(error)")
            throw RendererError.shaderCompile(String(describing: error))
        }
        self.shapes = ShapeLibrary(device: device)
        super.init()
        do {
            try makePipelines(pixelFormat: pixelFormat)
        } catch {
            AtlasDiagnostics.log("pipeline creation failed: \(error)")
            throw error
        }
        makeKernels()
        AtlasDiagnostics.log("renderer ready")
    }

    enum RendererError: Error, CustomStringConvertible {
        case noQueue
        case shaderCompile(String)
        case pipeline(String)

        var description: String {
            switch self {
            case .noQueue: return "no Metal command queue"
            case .shaderCompile(let s): return "shader compile failed: \(s)"
            case .pipeline(let s): return "pipeline failed: \(s)"
            }
        }
    }

    // ── pipelines ─────────────────────────────────────────────────────────

    private func makePipelines(pixelFormat: MTLPixelFormat) throws {
        let sceneFormat = MTLPixelFormat.rgba16Float
        let depthFormat = MTLPixelFormat.depth32Float

        func fn(_ name: String, _ stage: MTLFunctionType) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RendererError.pipeline("missing function \(name)")
            }
            return f
        }

        func additive(_ src: MTLBlendFactor = .sourceAlpha) -> MTLRenderPipelineColorAttachmentDescriptor {
            let a = MTLRenderPipelineColorAttachmentDescriptor()
            a.pixelFormat = sceneFormat
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = src
            a.destinationRGBBlendFactor = .one
            a.rgbBlendOperation = .add
            a.sourceAlphaBlendFactor = src
            a.destinationAlphaBlendFactor = .one
            a.alphaBlendOperation = .add
            return a
        }

        func normalBlend() -> MTLRenderPipelineColorAttachmentDescriptor {
            let a = MTLRenderPipelineColorAttachmentDescriptor()
            a.pixelFormat = sceneFormat
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.rgbBlendOperation = .add
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
            return a
        }

        func make(_ v: String, _ f: String,
                  attachment: MTLRenderPipelineColorAttachmentDescriptor,
                  depthFormat: MTLPixelFormat = .invalid) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(v, .vertex)
            d.fragmentFunction = try fn(f, .fragment)
            d.colorAttachments[0] = attachment
            if depthFormat != .invalid {
                d.depthAttachmentPixelFormat = depthFormat
                d.rasterSampleCount = 4
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        let alpha = additive()
        let alwaysDesc = MTLDepthStencilDescriptor()
        alwaysDesc.depthCompareFunction = .always
        alwaysDesc.isDepthWriteEnabled = false
        depthAlways = device.makeDepthStencilState(descriptor: alwaysDesc)
        let noWriteDesc = MTLDepthStencilDescriptor()
        noWriteDesc.depthCompareFunction = .lessEqual
        noWriteDesc.isDepthWriteEnabled = false
        depthNoWrite = device.makeDepthStencilState(descriptor: noWriteDesc)
        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .less
        writeDesc.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: writeDesc)

        backgroundPipeline = try make("background_vertex", "background_fragment", attachment: {
            let a = MTLRenderPipelineColorAttachmentDescriptor()
            a.pixelFormat = sceneFormat
            return a
        }(), depthFormat: depthFormat)

        linePipeline = try make("line_vertex", "line_fragment", attachment: alpha, depthFormat: depthFormat)
        pointPipeline = try make("point_vertex", "point_fragment", attachment: alpha, depthFormat: depthFormat)
        spritePipeline = try make("sprite_vertex", "sprite_fragment", attachment: alpha, depthFormat: depthFormat)
        spriteNoDepthPipeline = try make("sprite_vertex", "sprite_fragment", attachment: additive(), depthFormat: depthFormat)
        meshPipeline = try make("mesh_vertex", "mesh_fragment", attachment: alpha, depthFormat: depthFormat)
        rawPipeline = try make("line_vertex", "line_fragment", attachment: alpha, depthFormat: depthFormat)
        nodeRingPipeline = try make("node_ring_vertex", "node_ring_fragment", attachment: additive(), depthFormat: depthFormat)
        shockPipeline = try make("shock_vertex", "shock_fragment", attachment: additive(), depthFormat: depthFormat)
        atmospherePipeline = try make("atmosphere_vertex", "atmosphere_fragment", attachment: additive(), depthFormat: depthFormat)
        glassPipeline = try make("atmosphere_vertex", "glass_fragment", attachment: additive(), depthFormat: depthFormat)
        planetPipeline = try make("planet_vertex", "planet_fragment", attachment: normalBlend(), depthFormat: depthFormat)
        planetAtmoPipeline = try make("planet_atmo_vertex", "planet_atmo_fragment", attachment: additive(), depthFormat: depthFormat)
        shockShellPipeline = try make("shock_shell_vertex", "shock_shell_fragment", attachment: additive(), depthFormat: depthFormat)
        shieldPipeline = try make("shield_vertex", "shield_fragment", attachment: additive(), depthFormat: depthFormat)
        scanPipeline = try make("scan_vertex", "scan_fragment", attachment: additive(), depthFormat: depthFormat)
        discPipeline = try make("disc_vertex", "disc_fragment", attachment: additive(), depthFormat: depthFormat)
        jetPipeline = try make("jet_vertex", "jet_fragment", attachment: additive(), depthFormat: depthFormat)

        let postAttachment = { (format: MTLPixelFormat) -> MTLRenderPipelineColorAttachmentDescriptor in
            let a = MTLRenderPipelineColorAttachmentDescriptor()
            a.pixelFormat = format
            return a
        }

        dofPipeline = try make("post_vertex", "dof_fragment", attachment: postAttachment(sceneFormat), depthFormat: .invalid)
        brightPipeline = try make("post_vertex", "bright_fragment", attachment: postAttachment(sceneFormat), depthFormat: .invalid)
        blurPipeline = try make("post_vertex", "blur_fragment", attachment: postAttachment(sceneFormat), depthFormat: .invalid)
        bloomCompositePipeline = try make("post_vertex", "bloom_composite_fragment",
                                          attachment: postAttachment(sceneFormat), depthFormat: .invalid)
        finalPipeline = try make("post_vertex", "final_fragment", attachment: postAttachment(pixelFormat), depthFormat: .invalid)
        finalPipelineRGBA = try make("post_vertex", "final_fragment", attachment: postAttachment(.rgba8Unorm), depthFormat: .invalid)
    }

    private func makeKernels() {
        func kernel(_ radius: Int) -> (offsets: [Float], weights: [Float], center: Float) {
            let sigma = Float(radius) / 3
            var coef: [Float] = []
            for i in 0..<radius {
                coef.append(0.39894 * exp(-0.5 * Float(i * i) / (sigma * sigma)) / sigma)
            }
            var offsets: [Float] = []
            var weights: [Float] = []
            var i = 1
            while i < radius {
                let wa = coef[i]
                let wb = (i + 1 < radius) ? coef[i + 1] : 0
                let w = wa + wb
                offsets.append((Float(i) * wa + Float(i + 1) * wb) / w)
                weights.append(w)
                i += 2
            }
            return (offsets, weights, coef[0])
        }
        blurKernels = [6, 10, 14, 18, 22].map(kernel)
    }

    // ── targets ───────────────────────────────────────────────────────────

    private func ensureTargets(logical: CGSize, renderScale: CGFloat) {
        let width = max(2, Int((logical.width * renderScale).rounded()))
        let height = max(2, Int((logical.height * renderScale).rounded()))
        let size = CGSize(width: width, height: height)
        let cappedW = min(960, width)
        let cappedH = min(540, height)
        let bloomBase = CGSize(width: max(2, (cappedW + 1) / 2), height: max(2, (cappedH + 1) / 2))
        if targetSize == size && bloomSize == bloomBase && sceneColor != nil { return }
        targetSize = size
        bloomSize = bloomBase

        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage,
                     _ label: String, samples: Int = 1) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            let t = device.makeTexture(descriptor: d)!
            t.label = label
            return t
        }

        sceneColor = texture(width, height, .rgba16Float, [.renderTarget, .shaderRead], "scene color")
        sceneColorMSAA = texture(width, height, .rgba16Float, [.renderTarget], "scene color msaa", samples: 4)
        sceneDepthMSAA = texture(width, height, .depth32Float, [.renderTarget], "scene depth msaa", samples: 4)
        dofTexture = texture(width, height, .rgba16Float, [.renderTarget, .shaderRead], "dof")

        var mipsH: [MTLTexture] = []
        var mipsV: [MTLTexture] = []
        var w = Int(bloomBase.width)
        var h = Int(bloomBase.height)
        mipsH.append(texture(w, h, .rgba16Float, [.renderTarget, .shaderRead], "bloom h0"))
        mipsV.append(texture(w, h, .rgba16Float, [.renderTarget, .shaderRead], "bloom v0"))
        for i in 1..<5 {
            w = max(2, (w + 1) / 2)
            h = max(2, (h + 1) / 2)
            mipsH.append(texture(w, h, .rgba16Float, [.renderTarget, .shaderRead], "bloom h\(i)"))
            mipsV.append(texture(w, h, .rgba16Float, [.renderTarget, .shaderRead], "bloom v\(i)"))
        }
        bloomBright = texture(Int(bloomBase.width), Int(bloomBase.height), .rgba16Float,
                              [.renderTarget, .shaderRead], "bloom bright")
        bloomH = mipsH
        bloomV = mipsV
        bloomComposite = texture(Int(bloomBase.width), Int(bloomBase.height), .rgba16Float,
                                 [.renderTarget, .shaderRead], "bloom composite")
    }

    // ── frame ─────────────────────────────────────────────────────────────

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Targets follow the drawable size on the next frame.
        targetSize = .zero
    }

    func resetClock() {
        lastTime = CACurrentMediaTime()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, now - lastTime))
        lastTime = now
        guard let runtime else { return }
        let updateStart = CACurrentMediaTime()
        runtime.updateFrame(dt: Float(dt), viewSize: view.bounds.size)
        let updateSeconds = CACurrentMediaTime() - updateStart
        if frameDiagnosticCounter % 120 == 0 {
            AtlasDiagnostics.log("frame \(frameDiagnosticCounter) dt=\(String(format: "%.2f", dt * 1000))ms bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)) paused=\(view.isPaused)")
        }
        frameDiagnosticCounter += 1
        let waitStart = CACurrentMediaTime()
        guard let drawable = view.currentDrawable else { return }
        let waitSeconds = CACurrentMediaTime() - waitStart
        let state = runtime.makeRenderState(viewSize: view.bounds.size)
        let encodeStart = CACurrentMediaTime()
        do {
            try render(state: state, drawable: drawable.texture,
                        drawableSize: CGSize(width: drawable.texture.width, height: drawable.texture.height),
                        viewScale: view.drawableSize.width / max(1, view.bounds.size.width))
        } catch {
            NSLog("[atlas] render failed: \(error)")
        }
        let encodeSeconds = CACurrentMediaTime() - encodeStart
        if AtlasDiagnostics.enabled {
            breakdownSamples += 1
            breakdownUpdate += updateSeconds
            breakdownWait += waitSeconds
            breakdownEncode += encodeSeconds
            if breakdownSamples >= 120 {
                let n = Double(breakdownSamples)
                AtlasDiagnostics.log(String(
                    format: "frame breakdown update=%.2fms drawableWait=%.2fms encode=%.2fms",
                    breakdownUpdate / n * 1000, breakdownWait / n * 1000, breakdownEncode / n * 1000))
                breakdownSamples = 0
                breakdownUpdate = 0
                breakdownWait = 0
                breakdownEncode = 0
            }
        }
        guard let commandBuffer = currentCommandBuffer else { return }
        commandBuffer.present(drawable)
        if AtlasDiagnostics.enabled {
            let start = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { [weak self] cb in
                let wall = CACurrentMediaTime() - start
                let gpu = cb.gpuEndTime - cb.gpuStartTime
                self?.recordFrameTiming(wall: wall, gpu: gpu)
            }
            drawable.addPresentedHandler { [weak self] presented in
                self?.recordPresent(presented.presentedTime)
            }
        }
        commandBuffer.commit()
    }

    private var currentCommandBuffer: MTLCommandBuffer?

    // ── render ────────────────────────────────────────────────────────────

    private func frameUniforms(state: RenderState, renderSize: CGSize,
                               shake: Vec3) -> FrameUniforms {
        var camera = state.camera
        camera.position += shake
        camera.aspect = Float(renderSize.width / max(1, renderSize.height))
        let view = camera.viewMatrix
        let forward = camera.forward
        let right = forward.cross(.up).normalized
        let up = right.cross(forward).normalized
        let tanHalf = tan(camera.fov * .pi / 360)
        let pointScale = Float(renderSize.height) / (2 * tanHalf)
        return FrameUniforms(
            viewProj: camera.viewProjection,
            view: view,
            cameraPos: SIMD4(camera.position, 1),
            viewport: SIMD4(Float(renderSize.width), Float(renderSize.height),
                            1 / Float(renderSize.width), 1 / Float(renderSize.height)),
            cameraRight: SIMD4(right, 1),
            cameraUp: SIMD4(up, 1),
            cameraForward: SIMD4(forward, 1),
            misc: SIMD4(state.elapsed, pointScale, Float(camera.aspect), tanHalf),
            stage: SIMD4(state.stageScale, state.backdropYaw, camera.near, camera.far)
        )
    }

    private func encodeScene(state: RenderState, encoder: MTLRenderCommandEncoder,
                             frame: FrameUniforms, renderSize: CGSize) {
        let draw = state.drawList

        encoder.setCullMode(.none)
        // Star backdrop (opaque, no depth).
        encoder.setDepthStencilState(depthAlways)
        encoder.setRenderPipelineState(backgroundPipeline)
        var frameCopy = frame
        encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // The hollow instrument sphere: warm atmosphere, glass, and the limb.
        encoder.setDepthStencilState(depthNoWrite)
        encoder.setCullMode(.back)
        encoder.setRenderPipelineState(atmospherePipeline)
        for atmo in draw.atmospheres {
            var u = atmo
            encoder.setVertexBytes(&u, length: MemoryLayout<AtmoUniforms>.stride, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<AtmoUniforms>.stride, index: 0)
            encoder.setVertexBuffer(shapes.sphere.buffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.sphere.count)
        }
        if let glass = draw.glass {
            var u = glass
            encoder.setDepthStencilState(depthNoWrite)
            encoder.setCullMode(.back)
            encoder.setRenderPipelineState(glassPipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<AtmoUniforms>.stride, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<AtmoUniforms>.stride, index: 0)
            encoder.setVertexBuffer(shapes.sphere.buffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.sphere.count)
        }
        if let limb = draw.limbSprite {
            var inst = limb
            encoder.setDepthStencilState(depthAlways)
            encoder.setCullMode(.none)
            encoder.setRenderPipelineState(spriteNoDepthPipeline)
            encoder.setVertexBytes(&inst, length: MemoryLayout<SpriteInstance>.stride, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Dark planetary bodies write depth first.
        encoder.setDepthStencilState(depthWrite)
        encoder.setCullMode(.back)
        encoder.setRenderPipelineState(planetPipeline)
        for p in draw.planets {
            var u = p
            encoder.setVertexBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PlanetUniforms>.stride, index: 0)
            encoder.setVertexBuffer(shapes.planetSphere.buffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.planetSphere.count)
        }

        // Everything additive from here on.
        encoder.setDepthStencilState(depthNoWrite)
        encoder.setCullMode(.none)
        if !draw.sprites.isEmpty, let buffer = update(sprites: draw.sprites) {
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: draw.sprites.count)
        }

        if !draw.points.isEmpty, let buffer = update(points: draw.points) {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var transform = LineUniforms(transform: matrix_identity_float4x4)
            encoder.setVertexBytes(&transform, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: draw.points.count)
        }
        if !draw.stagePoints.isEmpty, let buffer = update(stagePoints: draw.stagePoints) {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var transform = LineUniforms(transform: Mat4.scale(Vec3(repeating: state.stageScale)))
            encoder.setVertexBytes(&transform, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: draw.stagePoints.count)
        }

        if !draw.lines.isEmpty, let buffer = update(lines: draw.lines) {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var transform = LineUniforms(transform: matrix_identity_float4x4)
            encoder.setVertexBytes(&transform, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: draw.lines.count)
        }
        if !draw.stageLines.isEmpty, let buffer = update(stageLines: draw.stageLines) {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var transform = LineUniforms(transform: Mat4.scale(Vec3(repeating: state.stageScale)))
            encoder.setVertexBytes(&transform, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: draw.stageLines.count)
        }

        if !draw.rawTriangles.isEmpty, let buffer = update(raw: draw.rawTriangles) {
            encoder.setRenderPipelineState(rawPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var transform = LineUniforms(transform: matrix_identity_float4x4)
            encoder.setVertexBytes(&transform, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.rawTriangles.count)
        }

        for shape in ShapeID.allCases {
            let instances = draw.meshBatches[shape.rawValue]
            guard !instances.isEmpty, let mesh = shapes.shapes[shape],
                  let buffer = update(mesh: instances, shape: shape) else { continue }
            encoder.setRenderPipelineState(meshPipeline)
            encoder.setCullMode(shape == .sphere || shape == .tetra || shape == .octa || shape == .box || shape == .cone ? .back : .none)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count,
                                   instanceCount: instances.count)
        }

        if !draw.nodeRings.isEmpty {
            encoder.setCullMode(.none)
            encoder.setRenderPipelineState(nodeRingPipeline)
            for u in draw.nodeRings {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<NodeRingUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<NodeRingUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        if !draw.shocks.isEmpty {
            encoder.setRenderPipelineState(shockPipeline)
            for u in draw.shocks {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<ShockUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<ShockUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        if !draw.shockShells.isEmpty {
            encoder.setCullMode(.back)
            encoder.setRenderPipelineState(shockShellPipeline)
            for u in draw.shockShells {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<ShockShellUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<ShockShellUniforms>.stride, index: 0)
                encoder.setVertexBuffer(shapes.shieldSphere.buffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.shieldSphere.count)
            }
        }

        if !draw.shields.isEmpty {
            encoder.setCullMode(.back)
            encoder.setRenderPipelineState(shieldPipeline)
            for u in draw.shields {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<ShieldUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<ShieldUniforms>.stride, index: 0)
                encoder.setVertexBuffer(shapes.shieldSphere.buffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.shieldSphere.count)
            }
        }

        if !draw.planetAtmospheres.isEmpty {
            encoder.setCullMode(.back)
            encoder.setRenderPipelineState(planetAtmoPipeline)
            for u in draw.planetAtmospheres {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<PlanetAtmoUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<PlanetAtmoUniforms>.stride, index: 0)
                encoder.setVertexBuffer(shapes.planetSphere.buffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.planetSphere.count)
            }
        }

        if !draw.scans.isEmpty {
            encoder.setRenderPipelineState(scanPipeline)
            for u in draw.scans {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<ScanUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<ScanUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        if !draw.discs.isEmpty {
            encoder.setRenderPipelineState(discPipeline)
            for u in draw.discs {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<DiscUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<DiscUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        if !draw.jets.isEmpty {
            encoder.setCullMode(.none)
            encoder.setRenderPipelineState(jetPipeline)
            for u in draw.jets {
                var uu = u
                encoder.setVertexBytes(&uu, length: MemoryLayout<JetUniforms>.stride, index: 0)
                encoder.setVertexBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uu, length: MemoryLayout<JetUniforms>.stride, index: 0)
                encoder.setVertexBuffer(shapes.jetCylinder.buffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shapes.jetCylinder.count)
            }
        }
    }

    // Dynamic buffers are queried through small wrappers so each draw list can
    // share the triple-buffered ring without dictionary lookups in the hot path.
    private func update(lines: [LineVertex]) -> MTLBuffer? {
        lineBuffer.update(lines, device: device, frame: frameIndex)
    }
    private func update(stageLines: [LineVertex]) -> MTLBuffer? {
        stageLineBuffer.update(stageLines, device: device, frame: frameIndex)
    }
    private func update(points: [PointVertex]) -> MTLBuffer? {
        pointBuffer.update(points, device: device, frame: frameIndex)
    }
    private func update(stagePoints: [PointVertex]) -> MTLBuffer? {
        stagePointBuffer.update(stagePoints, device: device, frame: frameIndex)
    }
    private func update(sprites: [SpriteInstance]) -> MTLBuffer? {
        spriteBuffer.update(sprites, device: device, frame: frameIndex)
    }
    private func update(raw: [TriangleVertex]) -> MTLBuffer? {
        rawBuffer.update(raw, device: device, frame: frameIndex)
    }
    private func update(mesh: [MeshInstance], shape: ShapeID) -> MTLBuffer? {
        meshBuffers[shape.rawValue].update(mesh, device: device, frame: frameIndex)
    }

    private func makeDofUniforms(state: RenderState, aspect: Float) -> DofUniforms {
        let cam = state.camera
        let forward = cam.forward
        let right = forward.cross(.up).normalized
        let up = right.cross(forward).normalized
        return DofUniforms(
            params: SIMD4(state.dofFocus, state.dofAperture, state.dofMaxBlur, aspect),
            cameraPos: SIMD4(cam.position, 1),
            cameraRight: SIMD4(right, 1),
            cameraUp: SIMD4(up, 1),
            cameraForward: SIMD4(forward, 1),
            depthParams: SIMD4(tan(cam.fov * .pi / 360),
                               runtime?.globeRadiusForRender ?? 6.34, cam.near, cam.far)
        )
    }

    private func postPass(_ commandBuffer: MTLCommandBuffer, target: MTLTexture,
                          configure: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        configure(encoder)
        encoder.endEncoding()
    }

    func render(state: RenderState, drawable: MTLTexture, drawableSize: CGSize, viewScale: CGFloat) throws {
        let renderScale = min(1.75, max(1, viewScale))
        ensureTargets(logical: state.logicalSize, renderScale: renderScale)
        guard let sceneColor, let sceneColorMSAA, let sceneDepthMSAA, let dofTexture,
              let bright = bloomBright, let bloomComposite, bloomH.count == 5, bloomV.count == 5,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        currentCommandBuffer = commandBuffer
        commandBuffer.label = "atlas frame \(frameIndex)"
        let renderSize = targetSize
        let frame = frameUniforms(state: state, renderSize: renderSize, shake: state.shake)

        // Scene pass.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneColorMSAA
        scenePass.colorAttachments[0].resolveTexture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        let clear = Palette.deep.linear
        scenePass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
        scenePass.depthAttachment.texture = sceneDepthMSAA
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1.0
        guard let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        encodeScene(state: state, encoder: sceneEncoder, frame: frame, renderSize: renderSize)
        sceneEncoder.endEncoding()

        // Depth of field.
        let aspect = Float(renderSize.width / max(1, renderSize.height))
        var dofEnabled = state.dofEnabled
        if dofEnabled {
            var dof = makeDofUniforms(state: state, aspect: aspect)
            postPass(commandBuffer, target: dofTexture) { enc in
                enc.setRenderPipelineState(dofPipeline)
                enc.setFragmentTexture(sceneColor, index: 0)
                enc.setFragmentBytes(&dof, length: MemoryLayout<DofUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else {
            dofEnabled = false
        }

        // Bloom: bright pass + 5 progressively blurred mips, then composite.
        let bloomOn = state.bloomEnabled && state.bloomStrength > 0.0001
        if bloomOn {
            var brightU = BrightUniforms(params: SIMD4(0.44, 0.25, state.exposure, 0))
            postPass(commandBuffer, target: bright) { enc in
                enc.setRenderPipelineState(brightPipeline)
                enc.setFragmentTexture(dofEnabled ? dofTexture : sceneColor, index: 0)
                enc.setFragmentBytes(&brightU, length: MemoryLayout<BrightUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            var source: MTLTexture = bright
            for i in 0..<5 {
                let kernel = blurKernels[i]
                var offsets = kernel.offsets
                var weights = kernel.weights
                while offsets.count < 12 { offsets.append(0) }
                while weights.count < 12 { weights.append(0) }
                var uH = BlurUniforms(
                    offsets: (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]),
                              SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]),
                              SIMD4(offsets[8], offsets[9], offsets[10], offsets[11])),
                    weights: (SIMD4(weights[0], weights[1], weights[2], weights[3]),
                              SIMD4(weights[4], weights[5], weights[6], weights[7]),
                              SIMD4(weights[8], weights[9], weights[10], weights[11])),
                    directionSize: SIMD4(1, 0, 1 / Float(bloomH[i].width), 1 / Float(bloomH[i].height)),
                    params: SIMD4(Float(kernel.weights.count), kernel.center, 0, 0)
                )
                postPass(commandBuffer, target: bloomH[i]) { enc in
                    enc.setRenderPipelineState(blurPipeline)
                    enc.setFragmentTexture(source, index: 0)
                    enc.setFragmentBytes(&uH, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                var uV = uH
                uV.directionSize = SIMD4(0, 1, 1 / Float(bloomV[i].width), 1 / Float(bloomV[i].height))
                postPass(commandBuffer, target: bloomV[i]) { enc in
                    enc.setRenderPipelineState(blurPipeline)
                    enc.setFragmentTexture(bloomH[i], index: 0)
                    enc.setFragmentBytes(&uV, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                source = bloomV[i]
            }
            var bloomU = BloomUniforms(params: SIMD4(state.bloomStrength, state.bloomRadius, 0, 0))
            postPass(commandBuffer, target: bloomComposite) { enc in
                enc.setRenderPipelineState(bloomCompositePipeline)
                for i in 0..<5 {
                    enc.setFragmentTexture(bloomV[i], index: i)
                }
                enc.setFragmentBytes(&bloomU, length: MemoryLayout<BloomUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        // Final composite into the drawable.
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = drawable
        finalPass.colorAttachments[0].loadAction = .clear
        finalPass.colorAttachments[0].storeAction = .store
        finalPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let finalEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) else { return }
        finalEncoder.setRenderPipelineState(finalPipeline)
        finalEncoder.setFragmentTexture(dofEnabled ? dofTexture : sceneColor, index: 0)
        finalEncoder.setFragmentTexture(bloomComposite, index: 1)
        var finalU = FinalUniforms(
            params: SIMD4(state.elapsed, bloomOn ? 1 : 0,
                          Float(state.logicalSize.width), Float(state.logicalSize.height)),
            renderSize: SIMD4(Float(renderSize.width), Float(renderSize.height),
                              1 / Float(renderSize.width), 1 / Float(renderSize.height))
        )
        finalEncoder.setFragmentBytes(&finalU, length: MemoryLayout<FinalUniforms>.stride, index: 0)
        finalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        finalEncoder.endEncoding()

        frameIndex += 1
    }

    /// Headless snapshot: render the final frame into an RGBA8 texture, read it
    /// back and write a PNG. Used by --snapshot and the visual checks.
    func snapshot(state: RenderState, size: CGSize, scale: CGFloat, path: URL) throws {
        ensureTargets(logical: size, renderScale: scale)
        guard let sceneColor, let sceneColorMSAA, let sceneDepthMSAA, let dofTexture,
              let bright = bloomBright, let bloomComposite, bloomH.count == 5, bloomV.count == 5,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let renderSize = targetSize
        let frame = frameUniforms(state: state, renderSize: renderSize, shake: state.shake)

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneColorMSAA
        scenePass.colorAttachments[0].resolveTexture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        let clear = Palette.deep.linear
        scenePass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
        scenePass.depthAttachment.texture = sceneDepthMSAA
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1
        guard let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        encodeScene(state: state, encoder: sceneEncoder, frame: frame, renderSize: renderSize)
        sceneEncoder.endEncoding()

        let aspect = Float(renderSize.width / max(1, renderSize.height))
        var dofEnabled = state.dofEnabled
        if dofEnabled {
            var dof = makeDofUniforms(state: state, aspect: aspect)
            postPass(commandBuffer, target: dofTexture) { enc in
                enc.setRenderPipelineState(dofPipeline)
                enc.setFragmentTexture(sceneColor, index: 0)
                enc.setFragmentBytes(&dof, length: MemoryLayout<DofUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else {
            dofEnabled = false
        }

        let bloomOn = state.bloomEnabled && state.bloomStrength > 0.0001
        if bloomOn {
            var brightU = BrightUniforms(params: SIMD4(0.44, 0.25, state.exposure, 0))
            postPass(commandBuffer, target: bright) { enc in
                enc.setRenderPipelineState(brightPipeline)
                enc.setFragmentTexture(dofEnabled ? dofTexture : sceneColor, index: 0)
                enc.setFragmentBytes(&brightU, length: MemoryLayout<BrightUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            var source = bright
            for i in 0..<5 {
                let kernel = blurKernels[i]
                var offsets = kernel.offsets
                var weights = kernel.weights
                while offsets.count < 12 { offsets.append(0) }
                while weights.count < 12 { weights.append(0) }
                var uH = BlurUniforms(
                    offsets: (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]),
                              SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]),
                              SIMD4(offsets[8], offsets[9], offsets[10], offsets[11])),
                    weights: (SIMD4(weights[0], weights[1], weights[2], weights[3]),
                              SIMD4(weights[4], weights[5], weights[6], weights[7]),
                              SIMD4(weights[8], weights[9], weights[10], weights[11])),
                    directionSize: SIMD4(1, 0, 1 / Float(bloomH[i].width), 1 / Float(bloomH[i].height)),
                    params: SIMD4(Float(kernel.weights.count), kernel.center, 0, 0)
                )
                postPass(commandBuffer, target: bloomH[i]) { enc in
                    enc.setRenderPipelineState(blurPipeline)
                    enc.setFragmentTexture(source, index: 0)
                    enc.setFragmentBytes(&uH, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                source = bloomH[i]
                var uV = uH
                uV.directionSize = SIMD4(0, 1, 1 / Float(bloomV[i].width), 1 / Float(bloomV[i].height))
                postPass(commandBuffer, target: bloomV[i]) { enc in
                    enc.setRenderPipelineState(blurPipeline)
                    enc.setFragmentTexture(bloomH[i], index: 0)
                    enc.setFragmentBytes(&uV, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                source = bloomV[i]
            }
            var bloomU = BloomUniforms(params: SIMD4(state.bloomStrength, state.bloomRadius, 0, 0))
            postPass(commandBuffer, target: bloomComposite) { enc in
                enc.setRenderPipelineState(bloomCompositePipeline)
                for i in 0..<5 { enc.setFragmentTexture(bloomV[i], index: i) }
                enc.setFragmentBytes(&bloomU, length: MemoryLayout<BloomUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        let width = Int(size.width)
        let height = Int(size.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                            height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let output = device.makeTexture(descriptor: desc) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(finalPipelineRGBA)
        encoder.setFragmentTexture(dofEnabled ? dofTexture : sceneColor, index: 0)
        encoder.setFragmentTexture(bloomComposite, index: 1)
        var finalU = FinalUniforms(
            params: SIMD4(state.elapsed, bloomOn ? 1 : 0,
                          Float(state.logicalSize.width), Float(state.logicalSize.height)),
            renderSize: SIMD4(Float(renderSize.width), Float(renderSize.height),
                              1 / Float(renderSize.width), 1 / Float(renderSize.height))
        )
        encoder.setFragmentBytes(&finalU, length: MemoryLayout<FinalUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let rowBytes = ((width * 4 + 255) / 256) * 256
        guard let readback = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else { return }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let base = readback.contents().bindMemory(to: UInt8.self, capacity: rowBytes * height) as UnsafeMutablePointer<UInt8>? else { return }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * rowBytes + x * 4
                let d = (y * width + x) * 4
                rgba[d] = base[s]
                rgba[d + 1] = base[s + 1]
                rgba[d + 2] = base[s + 2]
                rgba[d + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: path)
    }
}

enum ShaderSource {
    static func load() throws -> String {
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: nil) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Render") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        // Development fallback when running a bare SwiftPM binary.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Shaders.metal")
        return try String(contentsOf: path, encoding: .utf8)
    }
}
