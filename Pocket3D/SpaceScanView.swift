import ARKit
import ModelIO
import RealityKit
import SwiftUI

/// Reconstrucción LiDAR de ARKit: sin límite de tamaño ni forma → malla USDZ (u OBJ).
struct SpaceScanView: View {
    @StateObject private var model = SpaceScanModel()
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        ARViewRepresentable(arView: model.arView)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text("Recorre la estructura despacio hasta cubrirla con la malla")
                    .font(.callout).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 70)
            }
            .scanChrome {
                Button("Guardar malla") {
                    do {
                        try model.save()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.arView.session.pause() }
            .alert("No se pudo guardar", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

@MainActor
final class SpaceScanModel: ObservableObject {
    let arView = ARView(frame: .zero)

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.run(config)
    }

    func save() throws {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        guard !anchors.isEmpty else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Aún no hay malla. Mueve el iPhone sobre la zona."]) }
        // USDZ se previsualiza en el iPhone; OBJ como respaldo si ModelIO no exporta USDZ.
        let ext = MDLAsset.canExportFileExtension("usdz") ? "usdz" : "obj"
        // shortcut: exporta en el hilo principal (pausa de ~1 s en escaneos grandes); mover a background si molesta.
        try Self.asset(from: anchors).export(to: Scans.newURL("Espacio", ext: ext))
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
