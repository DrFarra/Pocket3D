import ARKit
import ModelIO
import RealityKit
import SwiftUI

/// Reconstrucción LiDAR de ARKit (malla USDZ para ver al momento) + dataset de fotos con pose y profundidad
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
                Text("Recorre la estructura despacio · \(model.keyframes) fotos")
                    .font(.callout).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 70)
            }
            .scanChrome {
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

    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var frames: [[String: Any]] = []
    private var lastPose: simd_float4x4?
    private var capturing = false

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
        let pose = frame.camera.transform
        let tracking = frame.camera.trackingState
        MainActor.assumeIsolated { considerKeyframe(pose: pose, tracking: tracking) }
    }

    /// Nueva foto cada 10 cm o ~10° de giro, solo con tracking bueno y de una en una.
    private func considerKeyframe(pose: simd_float4x4, tracking: ARCamera.TrackingState) {
        guard case .normal = tracking, !capturing else { return }
        if let last = lastPose {
            let moved = simd_distance(last.columns.3, pose.columns.3)
            let forward = simd_dot(simd_normalize(last.columns.2), simd_normalize(pose.columns.2))
            guard moved > 0.10 || forward < cos(Float.pi / 18) else { return }
        }
        capturing = true
        lastPose = pose
        let index = frames.count
        let work = self.work
        arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            Task.detached {
                let entry = frame.flatMap { try? Dataset.write($0, index: index, to: work) }
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
        if !anchors.isEmpty {
            // USDZ se previsualiza en el iPhone; OBJ como respaldo si ModelIO no exporta USDZ.
            let ext = MDLAsset.canExportFileExtension("usdz") ? "usdz" : "obj"
            try Self.asset(from: anchors).export(to: Scans.newURL("Espacio", ext: ext))
        }
        if !frames.isEmpty {
            let json = try JSONSerialization.data(withJSONObject: ["camera_model": "OPENCV", "frames": frames], options: .prettyPrinted)
            try json.write(to: work.appending(path: "transforms.json"))
            let work = self.work
            let zipURL = Scans.newURL("Espacio dataset", ext: "zip")
            try await Task.detached { try Dataset.zip(work, to: zipURL) }.value
        }
    }

    /// Une las mallas de todos los anclajes en coordenadas del mundo.
    static func asset(from anchors: [ARMeshAnchor]) -> MDLAsset {
        let asset = MDLAsset()
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            let faces = anchor.geometry.faces
            precondition(vertices.format == .float3 && faces.bytesPerIndex == 4, "Formato de malla ARKit inesperado")

            var positions = [Float]()
            positions.reserveCapacity(vertices.count * 3)
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let v = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4(v[0], v[1], v[2], 1)
                positions += [world.x, world.y, world.z]
            }

            let indexCount = faces.count * faces.indexCountPerPrimitive
            let indices = Data(bytes: faces.buffer.contents(), count: indexCount * faces.bytesPerIndex)
            let submesh = MDLSubmesh(indexBuffer: MDLMeshBufferData(type: .index, data: indices), indexCount: indexCount,
                                     indexType: .uInt32, geometryType: .triangles, material: nil)

            let descriptor = MDLVertexDescriptor()
            descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
            descriptor.layouts[0] = MDLVertexBufferLayout(stride: 3 * MemoryLayout<Float>.size)
            let mesh = MDLMesh(vertexBuffers: [MDLMeshBufferData(type: .vertex, data: positions.withUnsafeBytes { Data($0) })],
                               vertexCount: vertices.count, descriptor: descriptor, submeshes: [submesh])
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            asset.add(mesh)
        }
        return asset
    }
}

private struct ARViewRepresentable: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
