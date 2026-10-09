import ARKit
import RealityKit
import SwiftUI

/// Reconstrucción LiDAR de ARKit (malla PLY coloreada con las fotos) + dataset de fotos con pose y profundidad
/// para entrenar Gaussian splats o hacer fotogrametría en el PC.
struct SpaceScanView: View {
    @StateObject private var model = SpaceScanModel()
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        ARViewRepresentable(arView: model.arView)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text(model.tooFast ? "Más despacio: las fotos salen movidas" : "Recorre la estructura despacio · \(model.keyframes) fotos")
                    .font(.callout).foregroundStyle(.white)
                    .padding(10).background(model.tooFast ? .red.opacity(0.7) : .black.opacity(0.5), in: Capsule())
                    .padding(.top, 70)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: model.keyframes)
            .sensoryFeedback(trigger: model.tooFast) { _, fast in fast ? .warning : nil }
            .scanChrome(confirmClose: model.keyframes > 0) {
                if saving {
                    ProgressView("Guardando…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Button("Guardar") {
                        saving = true
                        Task {
                            do {
                                try await model.save()
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            saving = false
                        }
                    }
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .alert("No se pudo guardar", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

@MainActor
final class SpaceScanModel: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero)
    @Published var keyframes = 0
    @Published var tooFast = false

    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var frames: [[String: Any]] = []
    private var lastPose: simd_float4x4?
    private var capturing = false
    private var colorViews: [ColorView] = []
    private var previous: (pose: simd_float4x4, time: TimeInterval)?
    private var speed: Float = 0, turnRate: Float = 0

    func start() {
        try? FileManager.default.createDirectory(at: work.appending(path: "images"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work.appending(path: "depth"), withIntermediateDirectories: true)
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.delegate = self
        arView.session.run(config)
    }

    func stop() {
        arView.session.pause()
        try? FileManager.default.removeItem(at: work)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { update(with: frame) }
    }

    private func update(with frame: ARFrame) {
        let pose = frame.camera.transform
        if let previous, frame.timestamp > previous.time {
            let dt = Float(frame.timestamp - previous.time)
            // Media móvil: a 60 Hz el temblor del tracking daría picos falsos.
            speed = 0.9 * speed + 0.1 * simd_distance(previous.pose.columns.3, pose.columns.3) / dt
            let turn = acos(min(1, simd_dot(simd_normalize(previous.pose.columns.2), simd_normalize(pose.columns.2)))) / dt
            turnRate = 0.9 * turnRate + 0.1 * turn
            let fast = speed > 0.6 || turnRate > .pi / 2   // > 0,6 m/s o > 90°/s
            if fast != tooFast { tooFast = fast }
        }
        previous = (pose, frame.timestamp)
        considerKeyframe(frame)
    }

    /// Nueva foto cada 10 cm o ~10° de giro, solo con tracking bueno, sin ir rápido y de una en una.
    private func considerKeyframe(_ frame: ARFrame) {
        let pose = frame.camera.transform
        guard case .normal = frame.camera.trackingState, !capturing, !tooFast else { return }
        if let last = lastPose {
            let moved = simd_distance(last.columns.3, pose.columns.3)
            let forward = simd_dot(simd_normalize(last.columns.2), simd_normalize(pose.columns.2))
            guard moved > 0.10 || forward < cos(Float.pi / 18) else { return }
        }
        capturing = true
        lastPose = pose
        if let view = Dataset.colorView(from: frame, width: 192) { colorViews.append(view) }
        let depth = frame.sceneDepth
        let index = frames.count
        let work = self.work
        arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            Task.detached {
                let entry = frame.flatMap { try? Dataset.write($0, depth: depth, index: index, to: work) }
                await MainActor.run {
                    if let entry {
                        self?.frames.append(entry)
                        self?.keyframes += 1
                    }
                    self?.capturing = false
                }
            }
        }
    }

    func save() async throws {
        arView.session.pause()
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        guard !anchors.isEmpty || !frames.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Aún no hay nada escaneado. Mueve el iPhone sobre la zona."])
        }
        let (positions, indices) = Self.mesh(from: anchors)
        let views = colorViews
        let work = self.work
        var meta: [String: Any] = ["camera_model": "OPENCV", "frames": frames]
        if !positions.isEmpty { meta["ply_file_path"] = "mesh.ply" }  // nube inicial con color para splatfacto
        let json = try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
        let hasFrames = !frames.isEmpty

        // shortcut: colorear recorre vértices × vistas en CPU (segundos en escaneos grandes); pasar a Metal si se queda corto.
        try await Task.detached {
            if !positions.isEmpty {
                let colors = positions.map { MeshColor.color(of: $0, in: views) ?? SIMD3(160, 160, 160) }
                let ply = MeshColor.plyData(positions: positions, colors: colors, indices: indices)
                try ply.write(to: Scans.newURL("Espacio", ext: "ply"))
                if hasFrames { try ply.write(to: work.appending(path: "mesh.ply")) }
            }
            if hasFrames {
                try json.write(to: work.appending(path: "transforms.json"))
                try Dataset.zip(work, to: Scans.newURL("Espacio dataset", ext: "zip"))
            }
        }.value
    }

    /// Une las mallas de todos los anclajes en coordenadas del mundo.
    static func mesh(from anchors: [ARMeshAnchor]) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var positions = [SIMD3<Float>]()
        var indices = [UInt32]()
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            let faces = anchor.geometry.faces
            precondition(vertices.format == .float3 && faces.bytesPerIndex == 4, "Formato de malla ARKit inesperado")

            let offset = UInt32(positions.count)
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let v = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4(v[0], v[1], v[2], 1)
                positions.append(SIMD3(world.x, world.y, world.z))
            }
            let faceIndices = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<faces.count * faces.indexCountPerPrimitive { indices.append(faceIndices[i] + offset) }
        }
        return (positions, indices)
    }
}

private struct ARViewRepresentable: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
