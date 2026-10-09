import ARKit
import QuickLook
import RealityKit
import RoomPlan
import SwiftUI
import UniformTypeIdentifiers

@main
struct Pocket3DApp: App {
    #if DEBUG
    init() { Dataset.selfCheck() }
    #endif

    var body: some SwiftUI.Scene {
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
    @State private var viewing: URL?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Escanear") {
                    modeRow(.object, "Objeto", "cube", "Modelo 3D al instante + fotos para calidad máxima en el PC.",
                            supported: ObjectCaptureSession.isSupported)
                    modeRow(.room, "Habitación", "house", "Paredes, puertas, ventanas y muebles con medidas reales.",
                            supported: RoomCaptureSession.isSupported)
                    modeRow(.space, "Espacio / estructura", "building.2", "Malla LiDAR en color + fotos con pose y profundidad para splats en el PC.",
                            supported: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
                }
                Section("Mis escaneos") {
                    if scans.isEmpty {
                        Text("Aún no hay escaneos").foregroundStyle(.secondary)
                    }
                    ForEach(scans, id: \.self) { url in
                        Button {
                            if ModelViewer.extensions.contains(url.pathExtension.lowercased()) { viewing = url } else { preview = url }
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: Self.icon(for: url))
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
            .toolbar {
                Button { importing = true } label: { Label("Importar del PC", systemImage: "square.and.arrow.down") }
            }
        }
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { ModelViewer(url: viewing) }
        }
        // Splats de Postshot/nerfstudio o mallas de RealityScan: se copian a Scans para verlos aquí.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.copyItem(at: url, to: Scans.newURL(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
            }
            scans = Scans.all()
        }
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

    private static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "zip": "doc.zipper"
        case "spz", "splat": "sparkles"
        case "ply": MeshColor.isGaussianSplatPLY(url) ? "sparkles" : "square.stack.3d.up.fill"
        case "obj", "stl": "square.stack.3d.up"
        default: "cube.transparent"
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
