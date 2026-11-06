import AppKit
import Metal
import MetalKit
import simd

/// Timing for the one-shot crumple that clears a finished note.
struct CrumpleTimeline {
    static let duration: Double = 1.16

    struct State {
        var amount: Float
        var lighting: Float
        var scale: Float
        var rotationX: Float
        var rotationY: Float
        var rotationZ: Float
        var offsetY: Float
        var alpha: Float
    }

    static func state(at time: Double) -> State {
        let t = min(max(time, 0), duration)
        let fold = min(1, t / 0.64)
        let amount = Float(0.76 * pow(fold, 0.75))

        // A little settle after the sheet has finished folding.
        let settle = max(0, t - 0.64)
        let wobble = exp(-8 * settle) * sin(17 * settle)
        let scale = 1 + 0.045 * wobble

        // The final beat: the ball tips off the note line and the view clears.
        let drop = Float(smoothstep(CGFloat((t - 0.94) / 0.22)))
        let fade = Float(1 - smoothstep(CGFloat((t - 0.99) / 0.17)))

        return State(
            amount: amount,
            lighting: Float(smoothstep(CGFloat(amount / 0.12))),
            scale: Float(scale) * (1 - 0.06 * drop),
            rotationX: Float(-0.07 + 0.02 * sin(t * 6)) * Float(min(1, t / 0.55)),
            rotationY: Float(0.14) * Float(smoothstep(CGFloat(t / 0.72)))
                + Float(0.08) * Float(smoothstep(CGFloat((t - 0.64) / 0.34))),
            rotationZ: Float(-0.035 + 0.16 * smoothstep(CGFloat(fold))
                             + 0.03 * wobble),
            offsetY: -Float(t > 0.94 ? pow((t - 0.94) / 0.22, 1.6) : 0) * 0.20,
            alpha: fade
        )
    }
}

/// Renders a frozen note as a sheet that folds into a paper ball.
///
/// Geometry comes from `CrumpleSimulation`; Metal draws the deformed sheet with
/// matte paper shading, smooth normals and no blur, so creases stay crisp as
/// the sheet collapses.
final class CrumpleScene: NSObject, MTKViewDelegate {
    static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static var pipeline: MTLRenderPipelineState?
    private static var depthState: MTLDepthStencilState?
    private static var setupLock = NSLock()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let texture: MTLTexture
    private let imageSize: CGSize

    private var mesh: CrumpleMesh?
    private var vertexBuffer: MTLBuffer?
    private var quadVertexBuffer: MTLBuffer?
    private var quadIndexBuffer: MTLBuffer?
    private var startedAt: CFTimeInterval?
    private var reportedFinish = false

    /// Called once the crumple has fully played out, so the model can reveal the
    /// next note on the same frame instead of guessing a timer.
    var onFinish: (() -> Void)?

    /// Builds the shared Metal objects so the first crumple does not stall.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = sharedDeviceSetup()
        }
    }

    init?(image: NSImage, seed: UInt64 = 10) {
        guard let device = Self.metalDevice else { NSLog("crumple: no device"); return nil }
        guard let setup = Self.sharedDeviceSetup() else { NSLog("crumple: no pipeline"); return nil }
        guard let queue = device.makeCommandQueue() else { NSLog("crumple: no queue"); return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSLog("crumple: no cgimage"); return nil
        }

        guard let texture = Self.makeTexture(device: device, cgImage: cgImage) else {
            NSLog("crumple: no texture"); return nil
        }

        self.device = device
        self.queue = queue
        self.pipeline = setup.pipeline
        self.depthState = setup.depthState
        self.texture = texture
        imageSize = image.size
        quadVertexBuffer = Self.makeQuadVertices(
            device: device,
            aspect: max(0.2, Float(image.size.height / max(1, image.size.width))))
        quadIndexBuffer = Self.makeIndexBuffer(device: device, indices: [0, 1, 2, 0, 2, 3])
        super.init()

        let aspect = Float(image.size.height / max(1, image.size.width))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mesh = CrumpleSimulation.build(aspect: aspect, seed: seed, detail: 96)
            DispatchQueue.main.async {
                guard let self else { return }
                self.install(mesh: mesh)
            }
        }
    }

    private func install(mesh: CrumpleMesh) {
        self.mesh = mesh
        vertexBuffer = device.makeBuffer(length: MemoryLayout<CrumpleVertex>.stride * mesh.indices.count,
                                         options: .storageModeShared)
    }

    // MARK: - Drawing

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        // Wait for the simulation so the fold always starts from a flat sheet,
        // even if the background build takes a few frames.
        if startedAt == nil, mesh != nil { startedAt = CACurrentMediaTime() }
        let elapsed = startedAt.map { CACurrentMediaTime() - $0 } ?? 0
        let time = min(elapsed, CrumpleTimeline.duration)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encode(encoder, time: time, size: view.bounds.size)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if startedAt != nil, elapsed >= CrumpleTimeline.duration, !reportedFinish {
            reportedFinish = true
            view.isPaused = true
            onFinish?()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Encodes one animation frame into an existing render pass.
    func encode(_ encoder: MTLRenderCommandEncoder, time: Double, size: CGSize) {
        let size = size.width > 1 && size.height > 1 ? size : imageSize
        guard size.width > 1, size.height > 1 else { return }

        let state = CrumpleTimeline.state(at: time)
        var uniforms = makeUniforms(state: state, size: size)

        encoder.setCullMode(.none)
        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(Self.sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CrumpleUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CrumpleUniforms>.stride, index: 1)

        if let mesh, let vertexBuffer {
            let sample = sampleFrame(mesh, amount: state.amount)
            let faceNormals = faceNormals(mesh, positions: sample)
            let smoothNormals = smoothVertexNormals(mesh, faceNormals: faceNormals)
            let cavity = vertexCavity(mesh, positions: sample, normals: smoothNormals)
            // One vertex per triangle corner: each corner keeps its own normal
            // so folds stay sharp instead of being averaged into a blob.
            var vertices = [CrumpleVertex](repeating: CrumpleVertex(
                position: .zero, normal: SIMD3<Float>(0, 0, 1), uv: .zero, cavity: 0),
                count: mesh.indices.count)
            for index in 0..<mesh.indices.count {
                let vertex = Int(mesh.indices[index])
                let face = index / 3
                var sum = SIMD3<Float>.zero
                for incident in mesh.incidentFaces[vertex] {
                    let other = Int(incident)
                    let weight = Self.creaseWeight(dot: simd_dot(faceNormals[face],
                                                                 faceNormals[other]))
                    sum += faceNormals[other] * weight
                }
                let length = simd_length(sum)
                let normal = length > 0.000001 ? sum / length : SIMD3<Float>(0, 0, 1)
                let uv = mesh.uvs[vertex]
                vertices[index] = CrumpleVertex(
                    position: sample[vertex],
                    normal: normal,
                    uv: SIMD2<Float>(uv.x, 1 - uv.y),
                    cavity: cavity[vertex]
                )
            }
            vertices.withUnsafeBytes { raw in
                vertexBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: mesh.indices.count)
        } else {
            guard let quadVertexBuffer, let quadIndexBuffer else { return }
            uniforms.params.x = 0
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CrumpleUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CrumpleUniforms>.stride, index: 1)
            encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: 6,
                                          indexType: .uint32,
                                          indexBuffer: quadIndexBuffer,
                                          indexBufferOffset: 0)
        }
    }

    // MARK: - Animation state

    private func sampleFrame(_ mesh: CrumpleMesh, amount: Float) -> [SIMD3<Float>] {
        let clamped = min(1, max(0, amount))
        let exact = clamped * Float(mesh.frames.count - 1)
        let lower = Int(exact)
        let upper = min(lower + 1, mesh.frames.count - 1)
        let mix = exact - Float(lower)
        let from = mesh.frames[lower]
        let to = mesh.frames[upper]
        var result = from
        if mix > 0.0001 {
            for index in result.indices {
                result[index] = from[index] + (to[index] - from[index]) * mix
            }
        }
        return result
    }

    private func faceNormals(_ mesh: CrumpleMesh, positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: mesh.triangleCount)
        for face in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[face * 3])
            let b = Int(mesh.indices[face * 3 + 1])
            let c = Int(mesh.indices[face * 3 + 2])
            let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            let length = simd_length(normal)
            if length > 0.000001 { normals[face] = normal / length }
        }
        return normals
    }

    private func smoothVertexNormals(_ mesh: CrumpleMesh,
                                     faceNormals: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.vertexCount)
        for face in 0..<mesh.triangleCount {
            let normal = faceNormals[face]
            for corner in 0..<3 {
                normals[Int(mesh.indices[face * 3 + corner])] += normal
            }
        }
        for index in normals.indices {
            let length = simd_length(normals[index])
            normals[index] = length > 0.000001 ? normals[index] / length : SIMD3<Float>(0, 0, 1)
        }
        return normals
    }

    /// Concavity per vertex, normalised by the mesh spacing. Folds darker than
    /// ridges, which is what gives the ball its paper-ball crevices.
    private func vertexCavity(_ mesh: CrumpleMesh,
                              positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>]) -> [Float] {
        var cavity = [Float](repeating: 0, count: mesh.vertexCount)
        for vertex in 0..<mesh.vertexCount {
            var sum = SIMD3<Float>.zero
            var count = 0
            for incident in mesh.incidentFaces[vertex] {
                let face = Int(incident)
                for corner in 0..<3 {
                    let other = Int(mesh.indices[face * 3 + corner])
                    if other != vertex {
                        sum += positions[other]
                        count += 1
                    }
                }
            }
            guard count > 0 else { continue }
            let average = sum / Float(count)
            let value = simd_dot(average - positions[vertex], normals[vertex]) / mesh.spacing
            cavity[vertex] = min(2, max(0, value))
        }
        return cavity
    }

    private static func creaseWeight(dot value: Float) -> Float {
        let t = min(1, max(0, (value - 0.75) / 0.20))
        return t * t * (3 - 2 * t)
    }

    private func makeUniforms(state: CrumpleTimeline.State, size: CGSize) -> CrumpleUniforms {
        let width = Float(size.width)
        let height = Float(size.height)
        let aspect = width / max(1, height)
        let fovy: Float = 35 * .pi / 180
        let cameraZ = height / (2 * tan(fovy / 2))

        let scale = width * state.scale
        var model = simd_float4x4(translation: SIMD3<Float>(0, state.offsetY * width, 0))
        model *= simd_float4x4(rotationZ: state.rotationZ)
        model *= simd_float4x4(rotationY: state.rotationY)
        model *= simd_float4x4(rotationX: state.rotationX)
        model *= simd_float4x4(diagonal: SIMD4<Float>(scale, scale, scale, 1))

        let view = simd_float4x4(translation: SIMD3<Float>(0, 0, -cameraZ))
        let projection = simd_float4x4(perspectiveFov: fovy, aspect: aspect,
                                       near: max(20, cameraZ * 0.3), far: cameraZ * 3)
        let mvp = projection * view * model

        return CrumpleUniforms(
            mvp: mvp,
            model: model,
            light: SIMD4<Float>(simd_normalize(SIMD3<Float>(-0.48, 0.62, 0.56)), state.lighting),
            params: SIMD4<Float>(state.lighting, state.amount, state.alpha, 0)
        )
    }

    // MARK: - Shared setup

    private static let sampler: MTLSamplerState = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return metalDevice!.makeSamplerState(descriptor: descriptor)!
    }()

    private static func sharedDeviceSetup() -> (pipeline: MTLRenderPipelineState,
                                                depthState: MTLDepthStencilState)? {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard let device = metalDevice else { return nil }
        if let pipeline, let depthState { return (pipeline, depthState) }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) }
        catch { NSLog("crumple shader: \(error)"); return nil }
        let vertex = library.makeFunction(name: "crumpleVertex")
        let fragment = library.makeFunction(name: "crumpleFragment")
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = MemoryLayout<CrumpleVertex>.offset(of: \CrumpleVertex.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<CrumpleVertex>.offset(of: \CrumpleVertex.normal)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<CrumpleVertex>.offset(of: \CrumpleVertex.uv)!
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float
        vertexDescriptor.attributes[3].offset = MemoryLayout<CrumpleVertex>.offset(of: \CrumpleVertex.cavity)!
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<CrumpleVertex>.stride
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = 4
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline: MTLRenderPipelineState
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { NSLog("crumple pipeline: \(error)"); return nil }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.pipeline = pipeline
        self.depthState = depthState
        return (pipeline, depthState)
    }

    /// Normalises any snapshot into 8-bit BGRA so the texture loader never has
    /// to deal with 16-bit or indexed bitmaps, and uploads it top row first.
    private static func makeTexture(device: MTLDevice, cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        var drawn = false
        data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: info) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        #if arch(arm64)
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        #else
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return nil }
        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #endif
        return texture
    }

    private static func makeQuadVertices(device: MTLDevice, aspect: Float) -> MTLBuffer? {
        let halfWidth: Float = 0.5
        let halfHeight = aspect * 0.5
        let vertices = [
            CrumpleVertex(position: SIMD3(-halfWidth, -halfHeight, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1)),
            CrumpleVertex(position: SIMD3(halfWidth, -halfHeight, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 1)),
            CrumpleVertex(position: SIMD3(halfWidth, halfHeight, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            CrumpleVertex(position: SIMD3(-halfWidth, halfHeight, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0))
        ]
        let length = MemoryLayout<CrumpleVertex>.stride * vertices.count
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        vertices.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        return buffer
    }

    private static func makeIndexBuffer(device: MTLDevice, indices: [UInt32]) -> MTLBuffer? {
        device.makeBuffer(bytes: indices,
                          length: MemoryLayout<UInt32>.stride * indices.count,
                          options: .storageModeShared)
    }
}

struct CrumpleVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
    var cavity: Float = 0
}

struct CrumpleUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var light: SIMD4<Float>
    var params: SIMD4<Float>
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self.init(diagonal: SIMD4<Float>(1, 1, 1, 1))
        columns.3 = SIMD4<Float>(translation, 1)
    }

    init(rotationX angle: Float) {
        let c = cos(angle), s = sin(angle)
        self.init(columns: (SIMD4(1, 0, 0, 0),
                            SIMD4(0, c, s, 0),
                            SIMD4(0, -s, c, 0),
                            SIMD4(0, 0, 0, 1)))
    }

    init(rotationY angle: Float) {
        let c = cos(angle), s = sin(angle)
        self.init(columns: (SIMD4(c, 0, -s, 0),
                            SIMD4(0, 1, 0, 0),
                            SIMD4(s, 0, c, 0),
                            SIMD4(0, 0, 0, 1)))
    }

    init(rotationZ angle: Float) {
        let c = cos(angle), s = sin(angle)
        self.init(columns: (SIMD4(c, s, 0, 0),
                            SIMD4(-s, c, 0, 0),
                            SIMD4(0, 0, 1, 0),
                            SIMD4(0, 0, 0, 1)))
    }

    init(perspectiveFov fovy: Float, aspect: Float, near: Float, far: Float) {
        let ys = 1 / tan(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        self.init(columns: (SIMD4(xs, 0, 0, 0),
                            SIMD4(0, ys, 0, 0),
                            SIMD4(0, 0, zs, -1),
                            SIMD4(0, 0, zs * near, 0)))
    }
}

private func smoothstep(_ value: CGFloat) -> CGFloat {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 light;   // xyz: light direction in view space, w: lighting ramp
    float4 params;  // x: lighting, y: amount, z: alpha, w: unused
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
    float cavity [[attribute(3)]];
};

struct Varyings {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float cavity;
};

vertex Varyings crumpleVertex(VertexIn corner [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    Varyings out;
    out.position = uniforms.mvp * float4(corner.position, 1.0);
    out.normal = (uniforms.model * float4(corner.normal, 0.0)).xyz;
    out.uv = corner.uv;
    out.cavity = corner.cavity;
    return out;
}

static float paperNoise(float2 p) {
    float2 cell = fract(p * float2(127.1, 311.7));
    cell += dot(cell, cell + 41.7);
    return fract(cell.x * cell.y);
}

fragment float4 crumpleFragment(Varyings in [[stage_in]],
                                constant Uniforms &uniforms [[buffer(1)]],
                                texture2d<float> paperTexture [[texture(0)]],
                                sampler paperSampler [[sampler(0)]]) {
    float4 sampled = paperTexture.sample(paperSampler, in.uv);
    float alpha = sampled.a;
    if (alpha < 0.02) {
        discard_fragment();
    }

    float3 normal = normalize(in.normal);
    float3 view = float3(0.0, 0.0, 1.0);
    bool back = dot(normal, view) < 0.0;
    if (back) {
        normal = -normal;
    }

    const float3 stock = float3(0.906, 0.880, 0.820);
    float3 printed = sampled.rgb / max(alpha, 0.02);
    float3 albedo = back ? stock : printed;
    albedo *= 0.985 + paperNoise(in.uv * float2(900.0, 1100.0)) * 0.030;

    float3 light = normalize(uniforms.light.xyz);
    float diffuse = saturate(dot(normal, light));
    float sky = saturate(normal.y * 0.5 + 0.5);
    float3 ambient = mix(float3(0.52, 0.475, 0.40), float3(0.90, 0.875, 0.82), sky);
    float3 halfVector = normalize(light + view);
    float sheen = pow(saturate(dot(normal, halfVector)), 34.0) * 0.07;
    float occlusion = saturate(1.0 - in.cavity * 0.65);

    float3 lit = albedo * (ambient * mix(0.40, 0.62, occlusion)
                           + float3(1.0, 0.968, 0.918) * diffuse * 0.66);
    lit += float3(1.0, 0.97, 0.92) * sheen * occlusion;
    lit = max(lit, 0.0);

    float3 color = mix(printed, lit, uniforms.params.x);
    float outAlpha = alpha * uniforms.params.z;
    return float4(color * outAlpha, outAlpha);
}
"""
