import RealityKit
import SwiftUI

/// Object Capture: fotos guiadas alrededor del objeto → fotogrametría en el iPhone → USDZ texturizado.
@MainActor
final class ObjectScanModel: ObservableObject {
    @Published var session: ObjectCaptureSession?
    @Published var progress: Double?
    @Published var error: String?
    @Published var done = false

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
            if error == nil { Task { await self.reconstruct() } } else { cleanUp() }
        }
    }

    private func reconstruct() async {
        progress = 0
        do {
            // En iPhone la fotogrametría solo llega a calidad .reduced: las fotos van al PC para la versión buena.
            let images = self.images
            let zipURL = Scans.newURL("Objeto fotos", ext: "zip")
            try await Task.detached { try Dataset.exportPhotos(from: images, to: zipURL) }.value
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
            } else if let progress = model.progress {
                ProgressView("Generando modelo 3D… \(Int(progress * 100)) %", value: progress)
                    .tint(.white).foregroundStyle(.white).padding(40)
            }
        }
        .scanChrome {
            if model.done || model.error != nil { Button("Listo") { dismiss() } }
        }
        .task { model.start() }
        .onDisappear { model.cancel() }
    }
}

private struct CaptureControls: View {
    let session: ObjectCaptureSession // @Observable: SwiftUI la observa sola

    var body: some View {
        VStack {
            Spacer()
            Text(hint)
                .font(.callout).foregroundStyle(.white)
                .padding(10).background(.black.opacity(0.5), in: Capsule())
            HStack {
                switch session.state {
                case .ready:
                    Button("Continuar") { _ = session.startDetecting() }
                case .detecting:
                    Button("Empezar captura") { session.startCapturing() }
                case .capturing:
                    if session.userCompletedScanPass {
                        Button("Otra vuelta") { session.beginNewScanPass() }
                    }
                    Button("Terminar (\(session.numberOfShotsTaken) fotos)") { session.finish() }
                default:
                    ProgressView()
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding(.bottom, 40)
        }
    }

    private var hint: String {
        switch session.state {
        case .ready: "Apunta al objeto, sobre una superficie despejada"
        case .detecting: "Ajusta la caja para que envuelva el objeto"
        case .capturing where session.userCompletedScanPass: "¡Vuelta completa! Da otra más alta o más baja, o termina"
        case .capturing: "Camina despacio alrededor del objeto"
        default: "Preparando…"
        }
    }
}
