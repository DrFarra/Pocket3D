import ARKit
import RealityKit
import SwiftUI

/// Reconstrucción LiDAR de ARKit (malla PLY coloreada con las fotos) + dataset de fotos con pose y profundidad
/// para entrenar Gaussian splats o hacer fotogrametría en el PC.
struct SpaceScanView: View {
    @StateObject private var model: SpaceScanModel
    @State private var showingPC = false
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false
    @State private var dismissAfterAlert = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var pc = PCLink.shared

    /// `pcMode`: el iPhone solo captura (cámara, LiDAR, posición) y la malla la calcula tu PC en vivo.
    init(pcMode: Bool = false) {
        _model = StateObject(wrappedValue: SpaceScanModel(pcMode: pcMode))
    }

    var body: some View {
        if model.pcMode && !pc.isConnected {
            ContentUnavailableView {
                Label("Conecta tu PC", systemImage: "desktopcomputer")
            } description: {
                Text("En el modo PC tu ordenador hace los cálculos. Abre Pocket3D PC en él y conéctalo (misma WiFi).")
            } actions: {
                Button("Conectar mi PC") { showingPC = true }.buttonStyle(.borderedProminent)
            }
            .scanChrome {}
            .sheet(isPresented: $showingPC) { PCSheet() }
        } else {
            scanner
        }
    }

    private var scanner: some View {
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
                        Text((model.keyframes >= SpaceScanModel.maximumKeyframes
                             ? "Ya hay fotos de sobra: puedes guardar"
                             : model.guidance ?? (model.pcMode ? "Lo celeste ya lo calculó tu PC: apunta a lo que falta"
                                                               : "Recorre todo despacio. La malla marca lo ya escaneado"))
                             + (model.pcScan != nil ? "\nEn vivo en \(pc.name ?? "el PC")" : ""))
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
                    ProgressView(pc.pending > 0 && model.pcScan != nil ? "Enviando al PC… \(pc.pending)" : "Guardando…")
                        .padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
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
                            // Con el PC procesándolo, no hace falta esperar al iPhone: su GPU lo hace mejor y más rápido.
                            if await model.finishOnPC() {
                                dismissAfterAlert = true
                                self.error = model.pcMode
                                    ? "Guardado. Tu PC está terminando la malla final: aparecerá en «Mis escaneos» (deja la app abierta)."
                                    : "Guardado. Tu PC está creando la versión fotorrealista: aparecerá en «Mis escaneos» al terminar (deja la app abierta)."
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
    let pcMode: Bool
    /// Modo PC: la malla que va calculando tu PC, dibujada en el mismo mundo de ARKit (por eso se queda quieta
    /// sobre lo escaneado aunque muevas el iPhone: las poses que recibe el PC son las de esta sesión).
    private let pcMeshAnchor = AnchorEntity(world: .zero)
    private let pcMesh = ModelEntity()
    private var pcMeshTask: Task<Void, Never>?

    init(pcMode: Bool = false) {
        self.pcMode = pcMode
        super.init()
    }
    @Published var keyframes = 0
    @Published var tooFast = false
    /// Lo que impide un buen escaneo ahora mismo (velocidad, luz, tracking), en lenguaje claro.
    @Published var warning: String?
    /// Avance del entrenamiento del splat (nil = no se está entrenando).
    @Published var splatProgress: Double?
    private let splatCancel = CancelFlag()
    static let minimumKeyframes = 8
    /// Tope de fotos: más no mejora el resultado y llenaría memoria y disco (~5 MB por foto).
    static let maximumKeyframes = 800

    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var frames: [[String: Any]] = []
    /// Poses de las fotos ya guardadas: una foto nueva tiene que mostrar algo que ninguna otra muestre.
    private var keyPoses: [simd_float4x4] = []
    private var capturing = false
    private var colorViews: [ColorView] = []
    private var recentSharpness: [Float] = []
    /// Escaneo abierto en Pocket3D PC (nil = sin PC): recibe cada foto y la malla mientras escaneas.
    @Published private(set) var pcScan: String?
    /// Qué hacer ahora cuando rodeas un objeto (nil = escaneo de un espacio, sin vueltas que guiar).
    @Published private(set) var guidance: String?
    private var lastMeshSent: TimeInterval = 0
    private var blurryRejected = 0
    /// Dónde hay superficie real (celdas de 15 cm): lo que el splat ponga lejos de ahí es basura flotante.
    private var surfaceCells = Set<SIMD3<Int32>>()
    nonisolated static let surfaceCell: Float = 0.15
    /// Si diste la vuelta a un objeto (un auto): su superficie (celdas de 10 cm) y la altura del suelo, para guardar
    /// también el splat solo con él.
    private var object: (cells: Set<SIMD3<Int32>>, ground: Float)?
    nonisolated static let objectCell: Float = 0.10
    private var previous: (pose: simd_float4x4, time: TimeInterval)?
    private var speed: Float = 0, turnRate: Float = 0
    private let config = ARWorldTrackingConfiguration()

    func start() {
        try? FileManager.default.createDirectory(at: work.appending(path: "images"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work.appending(path: "depth"), withIntermediateDirectories: true)
        config.sceneReconstruction = pcMode ? [] : .mesh   // en modo PC la malla la calcula el ordenador
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        if pcMode {
            pcMeshAnchor.addChild(pcMesh)
            arView.scene.addAnchor(pcMeshAnchor)
        } else {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }
        arView.session.delegate = self
        arView.session.run(config)
        Task {
            pcScan = await PCLink.shared.beginScan()
            if pcMode { followPCMesh() }
        }
    }

    /// Cada segundo: si el PC tiene malla nueva, se descarga y sustituye a la anterior.
    private func followPCMesh() {
        pcMeshTask = Task { [weak self] in
            var shown = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let scan = self?.pcScan,
                      let status = await PCLink.shared.json("api/scan/\(scan)/status"),
                      let version = status["preview"] as? Int, version != shown,
                      let data = await PCLink.shared.data("api/scan/\(scan)/preview.bin"),
                      let descriptor = await Task.detached(operation: { Self.meshDescriptor(fromPreview: data) }).value,
                      let resource = try? MeshResource.generate(from: [descriptor]) else { continue }
                shown = version
                var material = UnlitMaterial(color: UIColor.systemTeal.withAlphaComponent(0.45))
                material.blending = .transparent(opacity: 0.45)
                self?.pcMesh.model = ModelComponent(mesh: resource, materials: [material])
            }
        }
    }

    /// preview.bin de Pocket3D PC: nº de vértices y de índices (uint32), posiciones (float32 ×3) e índices (uint32).
    /// Viene de la red: se valida el tamaño y que ningún índice se salga.
    nonisolated static func meshDescriptor(fromPreview data: Data) -> MeshDescriptor? {
        guard data.count >= 8 else { return nil }
        let (vertexCount, indexCount) = data.withUnsafeBytes {
            (Int($0.loadUnaligned(as: UInt32.self)), Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        }
        guard vertexCount > 0, indexCount > 0, indexCount % 3 == 0, data.count == 8 + vertexCount * 12 + indexCount * 4 else { return nil }
        var positions = [SIMD3<Float>](), indices = [UInt32]()
        positions.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)
        data.withUnsafeBytes { raw in
            for i in 0..<vertexCount {
                let o = 8 + i * 12
                positions.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                       raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
            }
            let start = 8 + vertexCount * 12
            for i in 0..<indexCount { indices.append(raw.loadUnaligned(fromByteOffset: start + i * 4, as: UInt32.self)) }
        }
        guard indices.allSatisfy({ Int($0) < vertexCount }) else { return nil }
        var descriptor = MeshDescriptor(name: "pc")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    func stop() {
        pcMeshTask?.cancel()
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
        sendMeshToPC(frame)
    }

    /// Cada 3 s, la malla actual al PC para verla crecer allí. Si la WiFi va atrasada, se salta: las fotos importan más.
    private func sendMeshToPC(_ frame: ARFrame) {
        guard let scan = pcScan, frame.timestamp - lastMeshSent > 3, PCLink.shared.pending < 8 else { return }
        lastMeshSent = frame.timestamp
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { return }
        let (rawPositions, rawIndices) = Self.mesh(from: anchors)   // copia ya: ARKit reescribe sus buffers
        Task {
            let glb = await Task.detached {
                let (positions, indices) = MeshColor.clean(positions: rawPositions, indices: rawIndices)
                guard !positions.isEmpty else { return nil as Data? }
                return try? MeshColor.glbData(positions: positions, colors: Array(repeating: MeshColor.unseen, count: positions.count),
                                              indices: indices, unlit: false)
            }.value
            if let glb { PCLink.shared.send(data: glb, as: "mesh.glb", scan: scan) }
        }
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

    /// Nueva foto si ninguna de las ya guardadas está a menos de 10 cm y ~10° de esta: así una segunda vuelta a otra
    /// altura suma fotos y repetir el mismo camino no llena la memoria. Solo con tracking bueno, sin ir rápido.
    private func considerKeyframe(_ frame: ARFrame) {
        let pose = frame.camera.transform
        guard case .normal = frame.camera.trackingState, !capturing, !tooFast, frames.count < Self.maximumKeyframes,
              Self.isNovel(pose, among: keyPoses) else { return }
        let view = Dataset.colorView(from: frame, width: 192)
        if let view {
            // Temblor de mano: la foto sale corrida aunque el iPhone no vaya rápido. Se compara con las últimas
            // aceptadas (la nitidez depende de la escena) y se espera al siguiente fotograma.
            let sharpness = MeshColor.sharpness(rgba: view.rgba, width: view.width, height: view.height)
            let recent = recentSharpness.sorted()
            if recent.count >= 5, sharpness < 0.5 * recent[recent.count / 2] {
                blurryRejected += 1
                if blurryRejected < 30 { return }   // si la escena es lisa de verdad, no bloquear el escaneo
            }
            blurryRejected = 0
            recentSharpness = Array((recentSharpness + [sharpness]).suffix(15))
        }
        capturing = true
        keyPoses.append(pose)
        updateGuidance()
        if let view { colorViews.append(view) }
        let index = frames.count
        let work = self.work
        arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            Task.detached {
                let entry = frame.flatMap { try? Dataset.write($0, index: index, to: work) }
                await MainActor.run {
                    if let entry {
                        self?.frames.append(entry)
                        self?.keyframes += 1
                        self?.sendFrameToPC(entry, work: work)
                    }
                    self?.capturing = false
                }
            }
        }
    }

    private func sendFrameToPC(_ entry: [String: Any], work: URL) {
        guard let scan = pcScan else { return }
        for key in ["file_path", "depth_file_path"] {
            if let path = entry[key] as? String { PCLink.shared.send(file: work.appending(path: path), as: path, scan: scan) }
        }
        PCLink.shared.addFrame(entry, scan: scan)
    }

    /// Tras guardar: la malla en color al PC (nube de partida del splat) y aviso de fin. True si el PC lo va a procesar.
    func finishOnPC() async -> Bool {
        guard let scan = pcScan else { return false }
        let mesh = work.appending(path: "mesh.ply")
        if FileManager.default.fileExists(atPath: mesh.path) { PCLink.shared.send(file: mesh, as: "mesh.ply", scan: scan) }
        return await PCLink.shared.finish(scan: scan)
    }

    /// En vez de contar fotos (que no dice nada), qué falta: la vuelta completa, otra desde arriba, o nada.
    private func updateGuidance() {
        let cameras = keyPoses.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        let forwards = keyPoses.map { -SIMD3($0.columns.2.x, $0.columns.2.y, $0.columns.2.z) }
        guard let progress = Reflections.orbitProgress(cameras: cameras, forwards: forwards) else { guidance = nil; return }
        let new: String
        if progress.sides < 11 {
            new = "Sigue rodeándolo despacio: llevas \(progress.sides * 100 / 12) % de la vuelta"
        } else if progress.highSides < 9 {
            new = "¡Vuelta completa! Ahora otra con el iPhone más alto, mirando hacia abajo · \(progress.highSides * 100 / 12) %"
        } else {
            new = "¡Listo! Ya puedes guardar (otra vuelta más baja mejora aún más el detalle)"
        }
        if new != guidance { guidance = new }
    }

    static func isNovel(_ pose: simd_float4x4, among poses: [simd_float4x4]) -> Bool {
        let forward = simd_normalize(pose.columns.2)
        return !poses.contains { other in
            simd_distance(other.columns.3, pose.columns.3) < 0.10 && simd_dot(simd_normalize(other.columns.2), forward) > cos(Float.pi / 18)
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
        (surfaceCells, object) = try await Task.detached {
            let welded = MeshColor.clean(positions: rawPositions, indices: rawIndices)
            // Reflejos de espejos, vidrios y suelos brillantes: fuera lo que quede tras las paredes o bajo el suelo.
            let cameras = views.map { view in let c = view.worldToCamera.inverse.columns.3; return SIMD3(c.x, c.y, c.z) }
            let (positions, indices, _) = Reflections.removePhantoms(positions: welded.positions, indices: welded.indices, cameras: cameras)
            let colors = MeshColor.colors(of: positions, in: views, indices: indices)
            // ¿Diste la vuelta a algo? Entonces, además, el objeto solo: sin suelo ni lo de alrededor.
            let forwards = views.map { view in let f = view.worldToCamera.inverse.columns.2; return -SIMD3(f.x, f.y, f.z) }
            var object: (cells: Set<SIMD3<Int32>>, ground: Float)?
            if let isolated = Reflections.isolateObject(positions: positions, indices: indices, cameras: cameras, forwards: forwards),
               !isolated.indices.isEmpty {
                let objectPositions = isolated.vertices.map { positions[$0] }, objectColors = isolated.vertices.map { colors[$0] }
                try MeshColor.plyData(positions: objectPositions, colors: objectColors, indices: isolated.indices)
                    .write(to: Scans.newURL("Espacio objeto", ext: "ply"))
                try? MeshColor.glbData(positions: objectPositions, colors: objectColors, indices: isolated.indices)
                    .write(to: Scans.newURL("Espacio objeto para Blender", ext: "glb"))
                object = (MeshColor.occupiedCells(objectPositions, cell: Self.objectCell), isolated.ground)
            }
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
            return (MeshColor.occupiedCells(positions, cell: Self.surfaceCell), object)
        }.value
        colorViews = []   // ya coloreado: con hasta 800 fotos ocupan ~150 MB que el entrenamiento necesita
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
        let cells = surfaceCells, object = self.object
        if !cells.isEmpty {
            try? await Task.detached { try MeshColor.pruneSplat(at: output, near: cells, cell: Self.surfaceCell) }.value
        }
        if let object {
            _ = try? await Task.detached {
                try MeshColor.isolateSplat(from: output, to: Scans.newURL("Espacio objeto splat", ext: "ply"),
                                           cells: object.cells, cell: Self.objectCell, ground: object.ground)
            }.value
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
