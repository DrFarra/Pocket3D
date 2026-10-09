import RoomPlan
import SwiftUI

/// RoomPlan: plano 3D paramétrico de la habitación (paredes, huecos y muebles) → USDZ.
struct RoomScanView: View {
    @StateObject private var controller = RoomCaptureController()
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        RoomCaptureRepresentable(controller: controller)
            .ignoresSafeArea()
            .scanChrome {
                if let room = controller.room {
                    Button("Guardar") {
                        do {
                            try room.export(to: Scans.newURL("Habitación", ext: "usdz"))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } else if controller.isScanning {
                    Button("Terminar") { controller.stop() }
                }
            }
            .alert("No se pudo guardar", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

// UIViewController porque RoomCaptureViewDelegate exige NSCoding.
final class RoomCaptureController: UIViewController, ObservableObject, RoomCaptureViewDelegate {
    @Published var room: CapturedRoom?
    @Published var isScanning = false
    private let captureView = RoomCaptureView(frame: .zero)

    override func loadView() {
        captureView.delegate = self
        view = captureView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        captureView.captureSession.stop()
        isScanning = false
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
