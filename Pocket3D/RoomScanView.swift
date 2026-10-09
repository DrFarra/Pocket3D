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

    /// Extra para Blender (si falla, el USDZ ya está guardado): el mismo GLB que el modo Espacio, con cada elemento
    /// como una caja de color.
    private static func writeBlender(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface], windows: [CapturedRoom.Surface],
                                     openings: [CapturedRoom.Surface], floors: [CapturedRoom.Surface], objects: [CapturedRoom.Object],
                                     name: String) throws {
        // Las paredes y suelos son planos (grosor 0): 4 cm. Puertas y ventanas un poco más gruesas para que asomen.
        func boxes(_ surfaces: [CapturedRoom.Surface], depth: Float, color: SIMD3<UInt8>) -> [(transform: simd_float4x4, size: SIMD3<Float>, color: SIMD3<UInt8>)] {
            surfaces.map { ($0.transform, simd_max($0.dimensions, SIMD3(repeating: depth)), color) }
        }
        let items = boxes(walls, depth: 0.04, color: [225, 222, 215]) + boxes(floors, depth: 0.04, color: [170, 150, 125])
            + boxes(doors, depth: 0.08, color: [140, 95, 55]) + boxes(windows, depth: 0.08, color: [150, 200, 235])
            + boxes(openings, depth: 0.08, color: [70, 70, 70])
            + objects.map { ($0.transform, simd_max($0.dimensions, SIMD3(repeating: 0.02)), SIMD3<UInt8>(110, 135, 190)) }
        guard !items.isEmpty else { return }
        let mesh = MeshColor.boxes(items)
        try MeshColor.glbData(positions: mesh.positions, colors: mesh.colors, indices: mesh.indices, unlit: false)
            .write(to: Scans.newURL(name, ext: "glb"))
    }

    private func save(_ rooms: [CapturedRoom]) {
        saving = true
        Task {
            do {
                if rooms.count == 1 {
                    try rooms[0].export(to: Scans.newURL("Habitación", ext: "usdz"))
                    try? Self.writeBlender(walls: rooms[0].walls, doors: rooms[0].doors, windows: rooms[0].windows,
                                          openings: rooms[0].openings, floors: rooms[0].floors, objects: rooms[0].objects,
                                          name: "Habitación para Blender")
                } else {
                    do {
                        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                        try structure.export(to: Scans.newURL("Plano \(rooms.count) habitaciones", ext: "usdz"))
                        try? Self.writeBlender(walls: structure.walls, doors: structure.doors, windows: structure.windows,
                                              openings: structure.openings, floors: structure.floors, objects: structure.objects,
                                              name: "Plano para Blender")
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
