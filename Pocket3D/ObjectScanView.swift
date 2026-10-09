import RealityKit
import SwiftUI

/// Object Capture: fotos guiadas alrededor del objeto → fotogrametría en el iPhone → USDZ texturizado.
@MainActor
final class ObjectScanModel: ObservableObject {
    @Published var session: ObjectCaptureSession?
    @Published var progress: Double?
    @Published var error: String?
    @Published var done = false
    @Published var preparingPhotos = false

    private var cancelled = false
    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var images: URL { work.appending(path: "Images/") }
    private var checkpoint: URL { work.appending(path: "Checkpoint/") }
    private var photogrammetry: PhotogrammetrySession?

    func start() {
        guard session == nil, !done else { return }
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        config.isOverCaptureEnabled = true  // fotos extra de zonas difíciles: mejor resultado en el PC
        session.start(imagesDirectory: images, configuration: config)
        self.session = session

        Task {
            for await state in session.stateUpdates {
                if case .completed = state { break }
                if case .failed(let error) = state {
                    self.error = error.localizedDescription
                    break
                }
            }
            // La sesión de captura debe liberarse antes de reconstruir: ambas no caben en memoria.
            self.session = nil
            if error == nil {
                Task { await self.reconstruct() }
            } else {
                // Si falló a medias, que no se pierdan las fotos: van al zip para el PC.
                if !cancelled { await exportPhotos() }
                cleanUp()
            }
        }
    }

    private func exportPhotos() async {
        preparingPhotos = true
        let images = self.images
        let zipURL = Scans.newURL("Objeto fotos", ext: "zip")
        try? await Task.detached { try Dataset.exportPhotos(from: images, to: zipURL) }.value
        preparingPhotos = false
    }

    private func reconstruct() async {
        // En iPhone la fotogrametría solo llega a calidad .reduced: las fotos van al PC para la versión buena.
        await exportPhotos()
        guard !cancelled else { return cleanUp() }
        progress = 0
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = checkpoint
            let photogrammetry = try PhotogrammetrySession(input: images, configuration: config)
            self.photogrammetry = photogrammetry
            let output = Scans.newURL("Objeto", ext: "usdz")
            try photogrammetry.process(requests: [.modelFile(url: output)])
            for try await event in photogrammetry.outputs {
                switch event {
                case .requestProgress(_, let fraction): progress = fraction
                case .requestError(_, let error): throw error
                case .processingComplete: done = true
                default: break
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        cleanUp()
    }

    func cancel() {
        cancelled = true
        session?.cancel()
        photogrammetry?.cancel()
    }

    private func cleanUp() {
        photogrammetry = nil
        try? FileManager.default.removeItem(at: work)
    }
}

struct ObjectScanView: View {
    @StateObject private var model = ObjectScanModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = model.session {
                ObjectCaptureView(session: session).ignoresSafeArea()
                CaptureControls(session: session)
            } else if let error = model.error {
                ContentUnavailableView("No se pudo crear el modelo", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if model.done {
                ContentUnavailableView("Modelo guardado", systemImage: "checkmark.circle",
                                       description: Text("Está en «Mis escaneos»."))
            } else if model.preparingPhotos {
                ProgressView("Guardando las fotos…").tint(.white).foregroundStyle(.white)
            } else if let progress = model.progress {
                VStack(spacing: 16) {
                    ProgressView("Generando modelo 3D… \(Int(progress * 100)) %", value: progress)
                    Text("Suele tardar 1–3 minutos. Deja la app abierta; al terminar se abrirá el modelo.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .tint(.white).foregroundStyle(.white).padding(40)
            }
        }
        .scanChrome(confirmClose: model.session != nil || model.preparingPhotos || (model.progress != nil && !model.done && model.error == nil)) {
            if model.error != nil { Button("Cerrar") { dismiss() } }
        }
        .task { model.start() }
        // Al terminar, cierra y la pantalla de inicio abre el modelo recién creado.
        .onChange(of: model.done) { _, done in if done { dismiss() } }
        .onDisappear { model.cancel() }
    }
}

/// Flujo guiado: detecta el objeto sola, fija la caja en cuanto lo ve estable, avisa de cada problema
/// (luz, distancia, velocidad) y no deja terminar con pocas fotos.
private struct CaptureControls: View {
    let session: ObjectCaptureSession // @Observable: SwiftUI la observa sola
    @Environment(\.scanPaused) private var paused
    @State private var lockCountdown: Int?
    @State private var reviewing = false
    /// Se queda en true tras la primera vuelta completa (beginNewScanPass reinicia userCompletedScanPass).
    @State private var passDone = false

    private static let minimumShots = 25

    var body: some View {
        ZStack {
            if reviewing {
                // Nube de puntos de lo capturado hasta ahora: así ves qué zonas faltan.
                ObjectCapturePointCloudView(session: session).ignoresSafeArea().background(Color.black)
            }
            VStack(spacing: 12) {
                Spacer()
                if let warning, !reviewing {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.yellow, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
                Text(hint)
                    .font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.horizontal)
                buttons
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.bottom, 40)
            }
            .animation(.spring, value: warning)
        }
        .sensoryFeedback(.warning, trigger: warning) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: session.userCompletedScanPass) { _, done in done }
        .task(id: "\(stateKey)-\(paused)") { if !paused { await automate() } }
        .onChange(of: session.userCompletedScanPass) { _, done in if done { passDone = true } }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch session.state {
            case .ready:
                Button("Buscar objeto") { _ = session.startDetecting() }
            case .detecting:
                Button("Otro objeto", systemImage: "arrow.counterclockwise") { _ = session.resetDetection() }
                    .buttonStyle(.bordered)
                Button("Fijar caja") { session.startCapturing() }
            case .capturing:
                if reviewing {
                    Button("Seguir escaneando") { session.resume(); reviewing = false }
                } else {
                    if session.userCompletedScanPass {
                        Button("Ver cómo va", systemImage: "eye") { session.pause(); reviewing = true }
                            .buttonStyle(.bordered)
                        Button("Otra vuelta") { session.beginNewScanPass() }.buttonStyle(.bordered)
                    }
                    let missing = Self.minimumShots - session.numberOfShotsTaken
                    Button(missing > 0 ? "Faltan \(missing) fotos" : passDone ? "Terminar (\(session.numberOfShotsTaken))" : "Completa la vuelta") {
                        session.finish()
                    }
                    .disabled(missing > 0 || !passDone)
                }
            default:
                ProgressView().tint(.white)
            }
        }
    }

    private var stateKey: String { "\(session.state)" }

    /// Sin toques: en «listo» empieza a buscar el objeto y en «detectando» fija la caja tras ~2 s viéndolo estable,
    /// así la caja deja de moverse con la cámara.
    private func automate() async {
        lockCountdown = nil
        switch session.state {
        case .ready:
            while !Task.isCancelled, case .ready = session.state {
                if session.startDetecting() { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        case .detecting:
            var stableTicks = 0
            while !Task.isCancelled, case .detecting = session.state {
                // Estable = ningún aviso salvo la luz (que no cambia el encuadre).
                stableTicks = session.feedback.subtracting([.environmentLowLight]).isEmpty ? stableTicks + 1 : 0
                lockCountdown = stableTicks > 0 ? 3 - stableTicks * 3 / 8 : nil
                if stableTicks >= 8 {   // 8 × 0,25 s
                    session.startCapturing()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        default:
            break
        }
    }

    /// Problemas detectados por Object Capture, en frases que se entienden.
    private var warning: String? {
        let feedback = session.feedback
        if feedback.contains(.environmentTooDark) { return "Demasiado oscuro: enciende una luz" }
        if feedback.contains(.environmentLowLight) { return "Poca luz: acerca una lámpara" }
        if feedback.contains(.movingTooFast) { return "Más despacio" }
        if feedback.contains(.objectTooClose) { return "Aléjate un poco" }
        if feedback.contains(.objectTooFar) { return "Acércate un poco" }
        if feedback.contains(.outOfFieldOfView) { return "Apunta al objeto" }
        if case .detecting = session.state, feedback.contains(.objectNotDetected) { return "No veo el objeto: céntralo en pantalla" }
        return nil
    }

    private var hint: String {
        switch session.state {
        case .ready: "Apunta al objeto. Mejor sobre una mesa lisa y despejada"
        case .detecting:
            if let lockCountdown { "Fijando la caja en \(lockCountdown)… no muevas el iPhone" } else { "Centra el objeto en la pantalla" }
        case .capturing where reviewing: "Puntos = zonas ya capturadas. Los huecos son lo que falta"
        case .capturing where session.userCompletedScanPass: "¡Vuelta completa! Mira cómo va, da otra más alta o más baja, o termina"
        case .capturing: "Camina despacio alrededor hasta completar el anillo"
        default: "Preparando…"
        }
    }
}
