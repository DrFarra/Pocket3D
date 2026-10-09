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
    @State private var dismissAfterAlert = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // Mientras se entrena el splat, fuera la vista AR: RealityKit seguiría dibujando y quitándole GPU.
            if model.splatProgress == nil { ARViewRepresentable(arView: model.arView) } else { Color.black }
        }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Group {
                    if let warning = model.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.black)
                            .background(.yellow, in: RoundedRectangle(cornerRadius: 16).inset(by: -10))
                    } else {
                        Text(model.keyframes >= SpaceScanModel.maximumKeyframes
                             ? "Ya hay fotos de sobra: puedes guardar"
                             : "Recorre todo despacio. La malla marca lo ya escaneado · \(model.keyframes) fotos")
                            .font(.callout).foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16).inset(by: -10))
                    }
                }
                .multilineTextAlignment(.center).padding(.horizontal, 30)
                .animation(.spring, value: model.warning)
                    .padding(.top, 70)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: model.keyframes)
            .sensoryFeedback(.warning, trigger: model.warning) { _, new in new != nil }
            .scanChrome(confirmClose: model.keyframes > 0, closeDisabled: saving) {
                if saving {
                    ProgressView("Guardando…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Button(model.keyframes < SpaceScanModel.minimumKeyframes ? "Faltan \(SpaceScanModel.minimumKeyframes - model.keyframes) fotos" : "Guardar") {
                        saving = true
                        Task {
                            do {
                                try await model.save()
                            } catch {
                                self.error = error.localizedDescription
                                saving = false
                                return
                            }
                            // La malla y el zip ya están guardados: si el splat falla, no se pierde nada.
                            do {
                                try await model.trainSplat()
                                dismiss()
                            } catch {
                                dismissAfterAlert = true
                                self.error = "La malla y las fotos se guardaron, pero no se pudo crear la versión fotorrealista: \(error.localizedDescription)"
                            }
                            saving = false
                        }
                    }
                    .disabled(model.keyframes < SpaceScanModel.minimumKeyframes)
                }
            }
            .onChange(of: scenePhase) { _, phase in model.pauseSplat(phase != .active) }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .overlay {
                if let progress = model.splatProgress {
                    SplatProgressView(progress: progress) { model.cancelSplat() }
                }
            }
            .alert("Aviso", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil; if dismissAfterAlert { dismiss() } }
            } message: { Text(error ?? "") }
    }
}

/// Pantalla mientras se entrena el splat en el iPhone.
private struct SplatProgressView: View {
    let progress: Double
    let skip: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.pink)
                Text("Creando la versión fotorrealista").font(.title3.bold())
                ProgressView(value: progress).tint(.pink).frame(maxWidth: 260)
                Text("\(Int(progress * 100)) % · Como mucho 6 minutos. Deja la app abierta; si sales, se pausa.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Terminar ya (con menos detalle)", action: skip).buttonStyle(.bordered).padding(.top, 8)
            }
            .foregroundStyle(.white).padding(32)
        }
    }
}

/// Bandera compartida con el hilo de entrenamiento.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    var value: Bool { lock.withLock { cancelled } }
    var isPaused: Bool { lock.withLock { paused } }
    func cancel() { lock.withLock { cancelled = true } }
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
}

@MainActor
final class SpaceScanModel: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero)
    @Published var keyframes = 0
    @Published var tooFast = false
    /// Lo que impide un buen escaneo ahora mismo (velocidad, luz, tracking), en lenguaje claro.
    @Published var warning: String?
    /// Avance del entrenamiento del splat (nil = no se está entrenando).
    @Published var splatProgress: Double?
    private let splatCancel = CancelFlag()
    static let minimumKeyframes = 8
    /// Tope de fotos: más no mejora el resultado y llenaría memoria y disco (~5 MB por foto).
    static let maximumKeyframes = 400

    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var frames: [[String: Any]] = []
    private var lastPose: simd_float4x4?
    private var capturing = false
    private var colorViews: [ColorView] = []
    /// Dónde hay superficie real (celdas de 15 cm): lo que el splat ponga lejos de ahí es basura flotante.
    private var surfaceCells = Set<SIMD3<Int32>>()
    nonisolated static let surfaceCell: Float = 0.15
    private var previous: (pose: simd_float4x4, time: TimeInterval)?
    private var speed: Float = 0, turnRate: Float = 0
    private let config = ARWorldTrackingConfiguration()

    func start() {
        try? FileManager.default.createDirectory(at: work.appending(path: "images"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work.appending(path: "depth"), withIntermediateDirectories: true)
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
        let warning = Self.warning(for: frame, tooFast: tooFast)
        if warning != self.warning { self.warning = warning }
        previous = (pose, frame.timestamp)
        considerKeyframe(frame)
    }

    private static func warning(for frame: ARFrame, tooFast: Bool) -> String? {
        switch frame.camera.trackingState {
        case .limited(.excessiveMotion): return "Más despacio"
        case .limited(.insufficientFeatures): return "Apunta a zonas con más detalle"
        case .limited(.initializing), .limited(.relocalizing): return "Mueve el iPhone despacio para empezar"
        case .notAvailable: return "Esperando a la cámara…"
        default: break
        }
        if tooFast { return "Más despacio: las fotos salen movidas" }
        if let light = frame.lightEstimate?.ambientIntensity, light < 250 { return "Poca luz: enciende las luces" }
        return nil
    }

    /// Nueva foto cada 10 cm o ~10° de giro, solo con tracking bueno, sin ir rápido y de una en una.
    private func considerKeyframe(_ frame: ARFrame) {
        let pose = frame.camera.transform
        guard case .normal = frame.camera.trackingState, !capturing, !tooFast, frames.count < Self.maximumKeyframes else { return }
        if let last = lastPose {
            let moved = simd_distance(last.columns.3, pose.columns.3)
            let forward = simd_dot(simd_normalize(last.columns.2), simd_normalize(pose.columns.2))
            guard moved > 0.10 || forward < cos(Float.pi / 18) else { return }
        }
        capturing = true
        lastPose = pose
        if let view = Dataset.colorView(from: frame, width: 192) { colorViews.append(view) }
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
        // Que termine la foto que se esté guardando, para no meter una a medias en el zip.
        for _ in 0..<20 where capturing { try? await Task.sleep(for: .milliseconds(100)) }
        arView.session.pause()
        do { try await export() } catch {
            arView.session.run(config)  // si falla, la cámara sigue viva para reintentar
            throw error
        }
    }

    private func export() async throws {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        guard !anchors.isEmpty || !frames.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Aún no hay nada escaneado. Mueve el iPhone sobre la zona."])
        }
        let (rawPositions, rawIndices) = Self.mesh(from: anchors)
        let views = colorViews
        let work = self.work
        var meta: [String: Any] = ["camera_model": "OPENCV", "frames": frames]
        if !rawPositions.isEmpty { meta["ply_file_path"] = "mesh.ply" }  // nube inicial con color para splatfacto
        let json = try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
        let hasFrames = !frames.isEmpty

        // shortcut: colorear recorre vértices × vistas en CPU (en paralelo); pasar a Metal si se queda corto.
        surfaceCells = try await Task.detached {
            let (positions, indices) = MeshColor.clean(positions: rawPositions, indices: rawIndices)
            let colors = MeshColor.colors(of: positions, in: views, indices: indices)
            if !positions.isEmpty {
                let ply = MeshColor.plyData(positions: positions, colors: colors, indices: indices)
                try ply.write(to: Scans.newURL("Espacio", ext: "ply"))
                // Extra: si falla, que no se pierdan el PLY ni las fotos de abajo.
                try? MeshColor.glbData(positions: positions, colors: colors, indices: indices)
                    .write(to: Scans.newURL("Espacio para Blender", ext: "glb"))
                if hasFrames { try ply.write(to: work.appending(path: "mesh.ply")) }
            }
            if hasFrames {
                try json.write(to: work.appending(path: "transforms.json"))
                try Dataset.zip(work, to: Scans.newURL("Espacio dataset", ext: "zip"))
            }
            if hasFrames && !positions.isEmpty {
                // Nube de partida del splat: una muestra de la malla. Con todos los vértices (157 000 en una
                // habitación) las gaussianas se multiplican y la app se queda sin memoria.
                let picks = Array(stride(from: 0, to: positions.count, by: (positions.count + SplatTrainer.maximumInitialPoints - 1) / SplatTrainer.maximumInitialPoints))
                try MeshColor.plyData(positions: picks.map { positions[$0] }, colors: picks.map { colors[$0] }, indices: [])
                    .write(to: work.appending(path: SplatTrainer.initialCloud))
            }
            return MeshColor.occupiedCells(positions, cell: Self.surfaceCell)
        }.value
    }

    /// Gaussian splat fotorrealista entrenado en el iPhone con las fotos, las poses de ARKit y la malla en color.
    func trainSplat() async throws {
        // msplat no tiene arranque aleatorio: sin nube de partida entrenaría 0 gaussianas durante minutos.
        guard FileManager.default.fileExists(atPath: work.appending(path: SplatTrainer.initialCloud).path) else {
            throw SplatTrainer.Failure(errorDescription: "No hay malla de la que partir para el splat. Escanea despacio hasta ver la malla.")
        }
        let (folder, downscale) = try SplatTrainer.prepare(dataset: work, frames: frames, hasCloud: true)
        let output = Scans.newURL("Espacio splat", ext: "ply")
        let cancel = splatCancel
        splatProgress = 0
        defer { splatProgress = nil }
        let saved = try await Task.detached(priority: .userInitiated) {
            try SplatTrainer.train(folder: folder, downscale: downscale, output: output,
                                   finishNow: { cancel.value }, isPaused: { cancel.isPaused }) { progress in
                // Tras terminar (splatProgress = nil) se ignoran avisos rezagados.
                Task { @MainActor in if self.splatProgress != nil { self.splatProgress = progress } }
            }
        }.value
        if !saved {
            throw SplatTrainer.Failure(errorDescription: "Se terminó demasiado pronto para guardar el splat.")
        }
        let cells = surfaceCells
        if !cells.isEmpty {
            try? await Task.detached { try MeshColor.pruneSplat(at: output, near: cells, cell: Self.surfaceCell) }.value
        }
    }

    func cancelSplat() { splatCancel.cancel() }
    /// iOS no deja usar la GPU en segundo plano: si sales de la app, el entrenamiento espera a que vuelvas.
    func pauseSplat(_ paused: Bool) { splatCancel.setPaused(paused) }

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
