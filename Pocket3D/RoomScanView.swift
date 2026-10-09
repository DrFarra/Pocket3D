import ARKit
import RoomPlan
import SwiftUI

/// RoomPlan: plano 3D paramétrico (paredes, huecos y muebles) → USDZ.
/// Varias habitaciones seguidas comparten la sesión AR y se unen en un solo plano con StructureBuilder.
struct RoomScanView: View {
    @StateObject private var controller = RoomCaptureController()
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        RoomCaptureRepresentable(controller: controller)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if controller.waitingForNextRoom {
                    Text("Ve a la siguiente habitación y pulsa «Empezar aquí»")
                        .font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 70).padding(.horizontal, 30)
                }
            }
            .scanChrome(confirmClose: controller.isScanning || controller.room != nil || !controller.rooms.isEmpty,
                        closeDisabled: saving) {
                if saving {
                    ProgressView("Uniendo habitaciones…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                } else if controller.processingFailed {
                    Button("No se pudo procesar · Repetir", systemImage: "arrow.counterclockwise") { controller.start() }
                } else if controller.waitingForNextRoom {
                    HStack {
                        Button("Guardar (\(controller.rooms.count))") { save(controller.rooms) }.buttonStyle(.bordered)
                        Button("Empezar aquí") { controller.start() }
                    }
                } else if let room = controller.room {
                    HStack {
                        Button("Otra habitación", systemImage: "plus") { controller.nextRoom() }.buttonStyle(.bordered)
                        Button(controller.rooms.isEmpty ? "Guardar" : "Guardar (\(controller.rooms.count + 1))") { save(controller.rooms + [room]) }
                    }
                } else if controller.isScanning {
                    Button(controller.rooms.isEmpty ? "Terminar" : "Terminar habitación \(controller.rooms.count + 1)") { controller.stop() }
                } else {
                    ProgressView("Procesando la habitación…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Aviso", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil; if savedSeparately { dismiss() } }
            } message: { Text(error ?? "") }
    }

    @State private var savedSeparately = false

    private func save(_ rooms: [CapturedRoom]) {
        saving = true
        Task {
            do {
                if rooms.count == 1 {
                    try rooms[0].export(to: Scans.newURL("Habitación", ext: "usdz"))
                } else {
                    do {
                        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                        try structure.export(to: Scans.newURL("Plano \(rooms.count) habitaciones", ext: "usdz"))
                    } catch {
                        // No se pudieron unir (p. ej. el tracking se perdió entre habitaciones): que no se pierda ninguna.
                        for (i, room) in rooms.enumerated() { try room.export(to: Scans.newURL("Habitación \(i + 1)", ext: "usdz")) }
                        savedSeparately = true
                        self.error = "No se pudieron unir en un solo plano, así que cada habitación se ha guardado por separado."
                        saving = false
                        return
                    }
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// UIViewController porque RoomCaptureViewDelegate exige NSCoding.
final class RoomCaptureController: UIViewController, ObservableObject, RoomCaptureViewDelegate {
    @Published var room: CapturedRoom?
    @Published var rooms: [CapturedRoom] = []
    @Published var isScanning = false
    @Published var waitingForNextRoom = false
    @Published var processingFailed = false
    // Una sola sesión AR para todas las habitaciones: así comparten coordenadas y StructureBuilder puede unirlas.
    private let arSession = ARSession()
    private lazy var captureView = RoomCaptureView(frame: .zero, arSession: arSession)

    override func loadView() {
        captureView.delegate = self
        view = captureView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureView.captureSession.stop()
        arSession.pause()
        isScanning = false
    }

    func start() {
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
        waitingForNextRoom = false
        processingFailed = false
        room = nil
    }

    func stop() {
        captureView.captureSession.stop(pauseARSession: false)
        isScanning = false
    }

    /// Guarda la habitación y espera a que el usuario esté en la siguiente (si no, escanearía la misma otra vez).
    func nextRoom() {
        if let room { rooms.append(room) }
        room = nil
        waitingForNextRoom = true
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if error != nil { Task { @MainActor in self.processingFailed = true } }
        return error == nil
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in self.room = processedResult }
    }
}

private struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let controller: RoomCaptureController
    func makeUIViewController(context: Context) -> RoomCaptureController { controller }
    func updateUIViewController(_ controller: RoomCaptureController, context: Context) {}
}
