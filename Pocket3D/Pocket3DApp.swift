import ARKit
import QuickLook
import RealityKit
import RoomPlan
import SwiftUI

@main
struct Pocket3DApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

enum ScanMode: String, Identifiable {
    case object, room, space
    var id: Self { self }
}

/// Escaneos guardados en Documents/Scans (visibles también en la app Archivos).
enum Scans {
    static let folder: URL = {
        let url = URL.documentsDirectory.appending(path: "Scans")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// La fecha va primero para que ordenar por nombre sea ordenar por fecha.
    static func newURL(_ kind: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appending(path: "\(formatter.string(from: .now)) \(kind).\(ext)")
    }

    static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

struct HomeView: View {
    @State private var scans = Scans.all()
    @State private var mode: ScanMode?
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Escanear") {
                    modeRow(.object, "Objeto", "cube", "Modelo 3D con textura real. Rodea el objeto con el iPhone.",
                            supported: ObjectCaptureSession.isSupported)
                    modeRow(.room, "Habitación", "house", "Paredes, puertas, ventanas y muebles con medidas reales.",
                            supported: RoomCaptureSession.isSupported)
                    modeRow(.space, "Espacio / estructura", "building.2", "Malla LiDAR de cualquier cosa: fachadas, escaleras, terreno…",
                            supported: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
                }
                Section("Mis escaneos") {
                    if scans.isEmpty {
                        Text("Aún no hay escaneos").foregroundStyle(.secondary)
                    }
                    ForEach(scans, id: \.self) { url in
                        Button { preview = url } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "cube.transparent")
                        }
                    }
                    .onDelete { offsets in
                        offsets.forEach { try? FileManager.default.removeItem(at: scans[$0]) }
                        scans = Scans.all()
                    }
                }
            }
            .navigationTitle("Pocket3D")
            .refreshable { scans = Scans.all() }
        }
        .quickLookPreview($preview, in: scans)
        .fullScreenCover(item: $mode, onDismiss: { scans = Scans.all() }) { mode in
            Group {
                switch mode {
                case .object: ObjectScanView()
                case .room: RoomScanView()
                case .space: SpaceScanView()
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func modeRow(_ mode: ScanMode, _ title: String, _ icon: String, _ detail: String, supported: Bool) -> some View {
        Button { self.mode = mode } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(supported ? detail : "Este iPhone no lo soporta (requiere LiDAR).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: icon) }
        }
        .disabled(!supported)
    }
}

/// Botones de cierre y acción comunes a las tres pantallas de escaneo.
struct ScanChrome<Action: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let action: Action

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle) }
                    .tint(.white).padding().accessibilityLabel("Cerrar")
            }
            .overlay(alignment: .bottom) {
                action.buttonStyle(.borderedProminent).controlSize(.large).padding(.bottom, 40)
            }
    }
}

extension View {
    func scanChrome<A: View>(@ViewBuilder action: () -> A) -> some View {
        modifier(ScanChrome(action: action()))
    }
}
