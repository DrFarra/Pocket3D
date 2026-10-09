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
            .scanChrome {
                if saving {
                    ProgressView("Uniendo habitaciones…").padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                } else if let room = controller.room {
                    HStack {
                        Button("Otra habitación") { controller.nextRoom() }
                        Button(controller.rooms.isEmpty ? "Guardar" : "Guardar (\(controller.rooms.count + 1))") { save(adding: room) }
                    }
                } else if controller.isScanning {
                    Button(controller.rooms.isEmpty ? "Terminar" : "Terminar habitación \(controller.rooms.count + 1)") { controller.stop() }
                }
            }
            .alert("No se pudo guardar", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func save(adding room: CapturedRoom) {
        let rooms = controller.rooms + [room]
        saving = true
        Task {
            do {
                if rooms.count == 1 {
                    try room.export(to: Scans.newURL("Habitación", ext: "usdz"))
                } else {
                    let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                    try structure.export(to: Scans.newURL("Plano \(rooms.count) habitaciones", ext: "usdz"))
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

    private func start() {
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func stop() {
        captureView.captureSession.stop(pauseARSession: false)
        isScanning = false
    }

    func nextRoom() {
        if let room { rooms.append(room) }
        room = nil
        start()
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in self.room = processedResult }
    }
}

private struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let controller: RoomCaptureController
    func makeUIViewController(context: Context) -> RoomCaptureController { controller }
    func updateUIViewController(_ controller: RoomCaptureController, context: Context) {}
}
