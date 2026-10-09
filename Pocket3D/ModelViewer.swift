import MetalKit
import MetalSplatter
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SplatIO
import SwiftUI

/// Visor 3D dentro de la app: Gaussian splats (.ply/.spz/.splat de Postshot o nerfstudio), mallas (.ply/.obj/.stl)
/// y habitaciones (.usdz de RoomPlan). Se ve por fuera (girando alrededor) o por dentro (parado en el centro).
struct ModelViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var mesh: MeshScene?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if Self.isSplat(url) {
                    SplatViewer(url: url, inside: Self.isRoom(url))
                } else if let mesh {
                    MeshViewer(mesh: mesh, inside: Self.isRoom(url))
                } else if loading {
                    ProgressView("Abriendo…").tint(.white).foregroundStyle(.white)
                } else {
                    ContentUnavailableView("No se puede abrir", systemImage: "questionmark.square.dashed",
                                           description: Text(url.lastPathComponent))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black)
            .task {
                // Una malla grande tarda en leerse: fuera del hilo principal para no congelar la pantalla.
                guard !Self.isSplat(url) else { return }
                let url = url
                mesh = await Task.detached { Self.meshScene(url) }.value
                loading = false
            }
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

    /// Habitaciones y espacios: se abren por dentro y los .usdz van a este visor en vez de Quick Look (solo por fuera).
    nonisolated static func isRoom(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.contains("Habitación") || name.contains("Plano") || name.contains("Espacio")
    }

    nonisolated static func isSplat(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "spz", "splat": true
        case "ply": MeshColor.isGaussianSplatPLY(url)
        default: false
        }
    }

    nonisolated static func meshScene(_ url: URL) -> MeshScene? {
        let scene: SCNScene
        if url.pathExtension.lowercased() == "usdz" {
            guard let loaded = try? SCNScene(url: url) else { return nil }
            scene = loaded
        } else {
            let asset = MDLAsset(url: url)
            guard asset.count > 0 else { return nil }
            scene = SCNScene(mdlAsset: asset)
        }
        // Los colores por vértice (malla de Espacio) se ven mejor sin sombreado fuerte; doble cara para verla por dentro.
        scene.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.lightingModel = .lambert; $0.isDoubleSided = true }
        }
        let (low, high) = scene.rootNode.boundingBox
        let center = (SIMD3<Float>(low) + SIMD3<Float>(high)) / 2
        let radius = max(simd_distance(SIMD3<Float>(low), SIMD3<Float>(high)) / 2, 0.01)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 60   // igual que el visor de splats
        camera.camera?.zNear = Double(radius) * 0.005
        camera.camera?.zFar = Double(radius) * 100
        scene.rootNode.addChildNode(camera)
        return MeshScene(scene: scene, camera: camera, center: center, radius: radius)
    }
}

/// Malla lista para ver, con su propia cámara: la de SceneKit solo gira alrededor y no deja entrar.
struct MeshScene {
    let scene: SCNScene
    let camera: SCNNode
    let center: SIMD3<Float>
    let radius: Float
}

private struct MeshViewer: View {
    let mesh: MeshScene
    @State private var camera: OrbitCamera

    init(mesh: MeshScene, inside: Bool) {
        self.mesh = mesh
        _camera = State(initialValue: OrbitCamera(orientation: 2, inside: inside))  // SceneKit y ARKit: Y arriba
    }

    var body: some View {
        SceneView(scene: mesh.scene, pointOfView: mesh.camera, options: [.autoenablesDefaultLighting, .rendersContinuously])
            .cameraControls($camera, radius: mesh.radius, canFlip: false)
            .onChange(of: camera, initial: true) {
                mesh.camera.simdTransform = camera.viewMatrix(center: mesh.center, radius: mesh.radius).inverse
            }
    }
}

/// Gaussian splat con MetalSplatter. Doble toque cambia qué eje es "arriba".
private struct SplatViewer: View {
    let url: URL
    @State private var camera: OrbitCamera
    @State private var radius: Float = 1
    @State private var error: String?

    init(url: URL, inside: Bool) {
        self.url = url
        // Los splats entrenados en la app conservan el "arriba" de ARKit (Y); los del PC suelen venir con Y hacia abajo.
        _camera = State(initialValue: OrbitCamera(orientation: OrbitCamera.trainedHere(url) ? 2 : 0, inside: inside))
    }

    var body: some View {
        SplatMetalView(url: url, camera: camera, radius: $radius, error: $error)
            .overlay {
                if let error {
                    ContentUnavailableView("No se pudo cargar el splat", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            }
            .cameraControls($camera, radius: radius, canFlip: true)
    }
}

/// Gestos de los dos visores. Por fuera: girar alrededor y acercar. Por dentro: mirar alrededor y caminar.
private struct CameraControls: ViewModifier {
    @Binding var camera: OrbitCamera
    let radius: Float
    let canFlip: Bool
    // Una base por gesto: si fuera compartida, al levantar un dedo del pellizco el arrastre se aplicaría dos veces.
    @State private var dragStart: OrbitCamera?
    @State private var pinchStart: OrbitCamera?

    func body(content: Content) -> some View {
        content
            .gesture(DragGesture()
                .onChanged { value in
                    let begin = dragStart ?? camera
                    dragStart = begin
                    // Por dentro se arrastra el mundo, como en una foto 360°: sentido contrario a girar alrededor.
                    let k: Float = camera.inside ? 0.005 : -0.01
                    camera.yaw = begin.yaw + k * Float(value.translation.width)
                    camera.pitch = min(1.5, max(-1.5, begin.pitch - k * Float(value.translation.height)))
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let begin = pinchStart ?? camera
                    pinchStart = begin
                    let scale = Float(value.magnification)
                    if camera.inside {
                        // Abrir los dedos = avanzar hacia donde miras, sin salir mucho del escaneo.
                        let walk = begin.walk + begin.forward * (scale - 1) * radius * 0.6
                        camera.walk = simd_length(walk) > radius * 1.5 ? simd_normalize(walk) * radius * 1.5 : walk
                    } else {
                        camera.zoom = min(20, max(0.05, begin.zoom / scale))
                    }
                }
                .onEnded { _ in pinchStart = nil })
            .onTapGesture(count: 2) {
                if canFlip { camera.orientation = (camera.orientation + 1) % OrbitCamera.orientations.count }
            }
            .overlay(alignment: .bottom) {
                GestureHint(text: (camera.inside ? "Arrastra para mirar alrededor · Pellizca para avanzar"
                                                 : "Arrastra para girar · Pellizca para acercar")
                                  + (canFlip ? " · Doble toque si sale torcido" : ""))
                    .id(camera.inside)  // vuelve a mostrarse al cambiar de modo
            }
            .overlay(alignment: .top) {
                Picker("Vista", selection: Binding(get: { camera.inside },
                                                   set: { camera = OrbitCamera(orientation: camera.orientation, inside: $0) })) {
                    Text("Por fuera").tag(false)
                    Text("Por dentro").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 260).padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                Button { withAnimation { camera = OrbitCamera(orientation: camera.orientation, inside: camera.inside) } } label: {
                    Image(systemName: "scope").font(.title2).padding(12).background(.ultraThinMaterial, in: Circle())
                }
                .padding().accessibilityLabel("Centrar vista")
            }
    }
}

extension View {
    fileprivate func cameraControls(_ camera: Binding<OrbitCamera>, radius: Float, canFlip: Bool) -> some View {
        modifier(CameraControls(camera: camera, radius: radius, canFlip: canFlip))
    }
}

/// Indicación de gestos que se desvanece sola a los pocos segundos.
private struct GestureHint: View {
    let text: String
    @State private var visible = true

    var body: some View {
        Text(text)
            .font(.footnote).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 30).padding(.horizontal)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 0.6)) { visible = false }
            }
    }
}

struct OrbitCamera: Equatable {
    var yaw: Float = 0, pitch: Float, zoom: Float = 1
    /// Cada herramienta deja el "arriba" en un eje distinto; doble toque prueba el siguiente.
    var orientation: Int
    /// Por dentro: el ojo está en el centro (+ lo caminado) y mira hacia fuera.
    var inside: Bool
    var walk = SIMD3<Float>.zero

    init(orientation: Int = 0, inside: Bool = false) {
        self.orientation = orientation
        self.inside = inside
        pitch = inside ? 0 : 0.2
    }

    /// Desde el centro hacia el ojo cuando se gira alrededor; por dentro se mira en sentido contrario.
    private var back: SIMD3<Float> { SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) }
    var forward: SIMD3<Float> { -back }

    /// Splats de Espacio (entrenados en el iPhone o en Pocket3D PC): conservan las poses de ARKit, con Y arriba.
    static func trainedHere(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.contains("Espacio") && name.hasSuffix("splat.ply")
    }
    static let orientations: [simd_quatf] = [
        simd_quatf(angle: .pi, axis: [0, 0, 1]),        // COLMAP / Postshot: Y hacia abajo
        simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),   // nerfstudio: Z hacia arriba
        simd_quatf(angle: 0, axis: [0, 1, 0]),          // ya con Y hacia arriba (ARKit)
    ]

    func viewMatrix(center: SIMD3<Float>, radius: Float) -> simd_float4x4 {
        let rotation = simd_float4x4(Self.orientations[orientation])
        let pivot = simd_float4x4(translation: center) * rotation * simd_float4x4(translation: -center)
        if inside {
            let eye = center + walk
            return .lookAt(eye: eye, target: eye + forward, up: [0, 1, 0]) * pivot
        }
        let eye = center + radius * 2.2 * zoom * back
        return .lookAt(eye: eye, target: center, up: [0, 1, 0]) * pivot
    }
}

private struct SplatMetalView: UIViewRepresentable {
    let url: URL
    let camera: OrbitCamera
    @Binding var radius: Float
    @Binding var error: String?

    func makeCoordinator() -> SplatRendererCoordinator { SplatRendererCoordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.load(url, into: view, onLoad: { radius = $0 }) { error = $0 }
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

    func load(_ url: URL, into view: MTKView, onLoad: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        guard let device = view.device else { return onError("Este dispositivo no tiene Metal.") }
        commandQueue = device.makeCommandQueue()
        Task {
            do {
                let renderer = try SplatRenderer(device: device, colorFormat: view.colorPixelFormat,
                                                 depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount,
                                                 maxViewCount: 1, maxSimultaneousRenders: 3)
                let (chunk, center, radius) = try await Task.detached {
                    let points = try await AutodetectSceneReader(url).readAll()
                    guard !points.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    let (center, radius) = Self.bounds(points.map(\.position))
                    return (try SplatChunk(device: device, from: points), center, radius)
                }.value
                (self.center, self.radius) = (center, radius)
                await renderer.addChunk(chunk)
                self.renderer = renderer
                onLoad(radius)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Centro = mediana y radio = percentil 90: ignora los "flotadores" lejanos típicos de los splats.
    nonisolated static func bounds(_ positions: [SIMD3<Float>]) -> (center: SIMD3<Float>, radius: Float) {
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
        guard let renderer, renderer.isReadyToRender else { return }
        inFlight.wait()  // antes de pedir el drawable, para no retenerlo esperando
        guard let drawable = view.currentDrawable, let commandBuffer = commandQueue?.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
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
