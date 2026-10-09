import MetalKit
import MetalSplatter
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SplatIO
import SwiftUI

/// Visor 3D dentro de la app: Gaussian splats (.ply/.spz/.splat de Postshot o nerfstudio) y mallas (.ply/.obj/.stl).
struct ModelViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if Self.isSplat(url) {
                    SplatViewer(url: url)
                } else if let scene = Self.meshScene(url) {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                } else {
                    ContentUnavailableView("No se puede abrir", systemImage: "questionmark.square.dashed",
                                           description: Text(url.lastPathComponent))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
            }
        }
        .preferredColorScheme(.dark)
    }

    static let extensions: Set<String> = ["ply", "spz", "splat", "obj", "stl"]

    static func isSplat(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "spz", "splat": true
        case "ply": MeshColor.isGaussianSplatPLY(url)
        default: false
        }
    }

    static func meshScene(_ url: URL) -> SCNScene? {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        let scene = SCNScene(mdlAsset: asset)
        // Los colores por vértice (malla de Espacio) se ven mejor sin sombreado fuerte.
        scene.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.lightingModel = .lambert; $0.isDoubleSided = true }
        }
        return scene
    }
}

/// Gaussian splat con MetalSplatter. Arrastra para girar, pellizca para acercar, doble toque para cambiar qué eje es "arriba".
private struct SplatViewer: View {
    let url: URL
    @State private var camera = OrbitCamera()
    @State private var startCamera: OrbitCamera?
    @State private var error: String?

    var body: some View {
        SplatMetalView(url: url, camera: camera, error: $error)
            .overlay {
                if let error {
                    ContentUnavailableView("No se pudo cargar el splat", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            }
            .gesture(DragGesture()
                .onChanged { value in
                    let start = startCamera ?? camera
                    startCamera = start
                    camera.yaw = start.yaw - Float(value.translation.width) * 0.01
                    camera.pitch = min(1.5, max(-1.5, start.pitch + Float(value.translation.height) * 0.01))
                }
                .onEnded { _ in startCamera = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = startCamera ?? camera
                    startCamera = start
                    camera.zoom = min(20, max(0.05, start.zoom / Float(value.magnification)))
                }
                .onEnded { _ in startCamera = nil })
            .onTapGesture(count: 2) { camera.orientation = (camera.orientation + 1) % OrbitCamera.orientations.count }
    }
}

struct OrbitCamera {
    var yaw: Float = 0, pitch: Float = 0.2, zoom: Float = 1
    /// Cada herramienta deja el "arriba" en un eje distinto; doble toque prueba el siguiente.
    var orientation = 0
    static let orientations: [simd_quatf] = [
        simd_quatf(angle: .pi, axis: [0, 0, 1]),        // COLMAP / Postshot: Y hacia abajo
        simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),   // nerfstudio: Z hacia arriba
        simd_quatf(angle: 0, axis: [0, 1, 0]),          // ya con Y hacia arriba (ARKit)
    ]

    func viewMatrix(center: SIMD3<Float>, radius: Float) -> simd_float4x4 {
        let distance = radius * 2.2 * zoom
        let eye = center + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        let rotation = simd_float4x4(Self.orientations[orientation])
        let pivot = simd_float4x4(translation: center) * rotation * simd_float4x4(translation: -center)
        return .lookAt(eye: eye, target: center, up: [0, 1, 0]) * pivot
    }
}

private struct SplatMetalView: UIViewRepresentable {
    let url: URL
    let camera: OrbitCamera
    @Binding var error: String?

    func makeCoordinator() -> SplatRendererCoordinator { SplatRendererCoordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.load(url, into: view) { error = $0 }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.camera = camera
    }
}

@MainActor
final class SplatRendererCoordinator: NSObject, MTKViewDelegate {
    var camera = OrbitCamera()
    private var renderer: SplatRenderer?
    private var commandQueue: MTLCommandQueue?
    private var center = SIMD3<Float>(repeating: 0)
    private var radius: Float = 1
    private var drawableSize = CGSize(width: 1, height: 1)
    private let inFlight = DispatchSemaphore(value: 3)

    func load(_ url: URL, into view: MTKView, onError: @escaping (String) -> Void) {
        guard let device = view.device else { return onError("Este dispositivo no tiene Metal.") }
        commandQueue = device.makeCommandQueue()
        Task {
            do {
                let renderer = try SplatRenderer(device: device, colorFormat: view.colorPixelFormat,
                                                 depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount,
                                                 maxViewCount: 1, maxSimultaneousRenders: 3)
                let points = try await AutodetectSceneReader(url).readAll()
                guard !points.isEmpty else { return onError("El archivo no tiene puntos.") }
                (center, radius) = Self.bounds(points.map(\.position))
                await renderer.addChunk(try SplatChunk(device: device, from: points))
                self.renderer = renderer
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Centro = mediana y radio = percentil 90: ignora los "flotadores" lejanos típicos de los splats.
    static func bounds(_ positions: [SIMD3<Float>]) -> (center: SIMD3<Float>, radius: Float) {
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        let center = SIMD3(median(positions.map(\.x)), median(positions.map(\.y)), median(positions.map(\.z)))
        let distances = positions.map { simd_distance($0, center) }.sorted()
        return (center, max(distances[Int(Float(distances.count - 1) * 0.9)], 0.01))
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { drawableSize = size }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let renderer, renderer.isReadyToRender, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        inFlight.wait()
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1),
            projectionMatrix: .perspective(fovY: .pi / 3, aspect: aspect, near: radius * 0.01, far: radius * 100),
            viewMatrix: camera.viewMatrix(center: center, radius: radius),
            screenSize: SIMD2(Int(drawableSize.width), Int(drawableSize.height)))
        let rendered = (try? renderer.render(viewports: [viewport], colorTexture: drawable.texture, colorStoreAction: .store,
                                             depthTexture: view.depthStencilTexture, rasterizationRateMap: nil,
                                             renderTargetArrayLength: 0, to: commandBuffer)) ?? false
        if rendered { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }

    /// Cámara mirando a `target` (mano derecha, mira a -Z como Metal/ARKit).
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
                                       SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }

    /// Proyección con profundidad 0…1 (Metal), igual que el ejemplo de MetalSplatter.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }
}
