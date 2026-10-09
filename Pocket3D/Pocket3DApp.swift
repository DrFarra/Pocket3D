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

enum ScanMode: String, Identifiable, CaseIterable {
    case object, room, space
    var id: Self { self }

    var title: String {
        switch self {
        case .object: "Objeto"
        case .room: "Habitación"
        case .space: "Espacio o estructura"
        }
    }

    var subtitle: String {
        switch self {
        case .object: "Piezas, figuras, zapatos… Modelo 3D con su textura real."
        case .room: "Plano con medidas: paredes, puertas, ventanas y muebles. Una o varias habitaciones."
        case .space: "Fachadas, escaleras, terreno, lo que sea. Malla 3D en color a escala real."
        }
    }

    var icon: String {
        switch self {
        case .object: "cube.fill"
        case .room: "house.fill"
        case .space: "building.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .object: .orange
        case .room: .blue
        case .space: .purple
        }
    }

    @MainActor var isSupported: Bool {
        switch self {
        case .object: ObjectCaptureSession.isSupported
        case .room: RoomCaptureSession.isSupported
        case .space: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }

    struct Tip { let icon: String, text: String }

    var tips: [Tip] {
        switch self {
        case .object: [
            Tip(icon: "lightbulb.fill", text: "Pon el objeto sobre una mesa despejada, con luz suave y sin sombras duras."),
            Tip(icon: "cube.transparent", text: "Ajusta la caja para que envuelva el objeto y pulsa «Empezar captura»."),
            Tip(icon: "arrow.2.circlepath", text: "Rodéalo despacio. Al completar la vuelta, da otra más alta o más baja, o pulsa «Terminar»."),
        ]
        case .room: [
            Tip(icon: "lightbulb.fill", text: "Enciende las luces y abre las puertas que quieras incluir."),
            Tip(icon: "figure.walk", text: "Recorre el perímetro despacio apuntando a paredes, ventanas y muebles."),
            Tip(icon: "house.and.flag.fill", text: "Al terminar, pulsa «Otra habitación» para seguir con la casa entera, o «Guardar»."),
        ]
        case .space: [
            Tip(icon: "tortoise.fill", text: "Camina despacio: la app guarda una foto cada 10 cm y vibra suavemente con cada una."),
            Tip(icon: "exclamationmark.triangle.fill", text: "Si el aviso se pone rojo, ve más despacio: así las fotos no salen movidas."),
            Tip(icon: "arrow.triangle.capsulepath", text: "Cubre todo con la malla (hasta ~5 m) y termina cerca de donde empezaste."),
        ]
        }
    }
}

/// Escaneos guardados en Documents/Scans (visibles también en la app Archivos).
enum Scans {
    static let folder: URL = {
        let url = URL.documentsDirectory.appending(path: "Scans")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// La fecha va primero para que ordenar por nombre sea ordenar por fecha.
    static func newURL(_ kind: String, ext: String) -> URL {
        folder.appending(path: "\(stamp.string(from: .now)) \(kind).\(ext)")
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
                Section("Nuevo escaneo") {
                    ForEach(ScanMode.allCases) { item in ModeCard(mode: item) { mode = $0 } }
                }
                Section {
                    if scans.isEmpty {
                        ContentUnavailableView("Aún no hay escaneos", systemImage: "cube.transparent",
                                               description: Text("Elige un modo arriba. Lo que escanees aparecerá aquí."))
                    }
                    ForEach(scans, id: \.self) { url in
                        ScanRow(url: url) { open(url) }
                            .contextMenu {
                                ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { delete(url) } label: { Label("Borrar", systemImage: "trash") }
                            }
                    }
                    .onDelete { offsets in offsets.map { scans[$0] }.forEach(delete) }
                } header: {
                    Text("Mis escaneos")
                } footer: {
                    if !scans.isEmpty {
                        Text("«Enviar al PC» manda las fotos para procesarlas en RealityScan o Postshot. Con el botón Importar (arriba) traes aquí el resultado para verlo.")
                    }
                }
            }
            .navigationTitle("Pocket3D")
            .refreshable { scans = Scans.all() }
            .toolbar {
                Button("Importar del PC", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .tint(.indigo)
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { ModelViewer(url: viewing) }
        }
        // Splats de Postshot/nerfstudio o mallas de RealityScan: se copian a Scans para verlos aquí.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let before = Set(scans)
            for url in (try? result.get()) ?? [] {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.copyItem(at: url, to: Scans.newURL(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
            }
            openNewest(since: before)
        }
        .fullScreenCover(item: $mode, onDismiss: { openNewest(since: Set(scans)) }) { ScanContainer(mode: $0) }
    }

    /// Tras escanear o importar, abre directamente el resultado (no los zips para el PC).
    private func openNewest(since before: Set<URL>) {
        scans = Scans.all()
        if let new = scans.first(where: { !before.contains($0) && $0.pathExtension.lowercased() != "zip" }) { open(new) }
    }

    private func open(_ url: URL) {
        if ModelViewer.extensions.contains(url.pathExtension.lowercased()) { viewing = url } else { preview = url }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        scans = Scans.all()
    }
}

private struct ModeCard: View {
    let mode: ScanMode
    let start: (ScanMode) -> Void

    var body: some View {
        let supported = mode.isSupported
        Button { start(mode) } label: {
            HStack(spacing: 14) {
                Image(systemName: mode.icon)
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(mode.color.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline).foregroundStyle(.primary)
                    Text(supported ? mode.subtitle : "Necesita un iPhone con LiDAR (modelos Pro).")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .disabled(!supported)
        .opacity(supported ? 1 : 0.5)
    }
}

/// Fila de la biblioteca: nombre legible, tipo, fecha relativa y tamaño. Los zips se envían al tocarlos.
private struct ScanRow: View {
    let url: URL
    let open: () -> Void

    var body: some View {
        // .plain: sin esto el texto de la fila hereda el color de acento.
        if isForPC {
            ShareLink(item: url) { label }.buttonStyle(.plain)
        } else {
            Button(action: open) { label }.buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isForPC {
                Label("Enviar al PC", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.semibold)).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.indigo.opacity(0.15), in: Capsule()).foregroundStyle(.indigo)
                    .fixedSize()
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())  // toda la fila es tocable, también el hueco del Spacer
    }

    private var ext: String { url.pathExtension.lowercased() }
    private var isForPC: Bool { ext == "zip" }
    private var isSplat: Bool { ModelViewer.isSplat(url) }

    /// "2026-10-09 12.30.05 Espacio dataset" → fecha + "Espacio".
    private var parts: (date: Date?, name: String) {
        let base = url.deletingPathExtension().lastPathComponent
        guard base.count > 20, let date = Scans.stamp.date(from: String(base.prefix(19))) else { return (nil, base) }
        return (date, String(base.dropFirst(20)))
    }

    private var title: String {
        isForPC ? parts.name.replacingOccurrences(of: " dataset", with: "").replacingOccurrences(of: " fotos", with: "") : parts.name
    }

    private var kind: String {
        switch ext {
        case "zip": "Fotos y datos"
        case "usdz", "reality": "Modelo 3D · AR"
        case "ply", "spz", "splat": isSplat ? "Gaussian splat" : "Malla en color"
        default: "Malla 3D"
        }
    }

    private var details: String {
        var items = [kind]
        if let date = parts.date { items.append(date.formatted(.relative(presentation: .named))) }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            items.append(Int64(size).formatted(.byteCount(style: .file)))
        }
        return items.joined(separator: " · ")
    }

    private var icon: String {
        switch ext {
        case "zip": "shippingbox.fill"
        case "usdz", "reality": parts.name.hasPrefix("Habitación") || parts.name.hasPrefix("Plano") ? "house.fill" : "cube.fill"
        default: isSplat ? "sparkles" : "square.stack.3d.up.fill"
        }
    }

    private var color: Color {
        switch ext {
        case "zip": .indigo
        case "usdz", "reality": parts.name.hasPrefix("Habitación") || parts.name.hasPrefix("Plano") ? .blue : .orange
        default: isSplat ? .pink : .purple
        }
    }
}

/// Pantalla de escaneo con sus consejos (la primera vez y con el botón «?»).
private struct ScanContainer: View {
    let mode: ScanMode
    @AppStorage private var tipsSeen: Bool
    @State private var showTips = false

    init(mode: ScanMode) {
        self.mode = mode
        _tipsSeen = AppStorage(wrappedValue: false, "tipsSeen.\(mode.rawValue)")
    }

    var body: some View {
        Group {
            switch mode {
            case .object: ObjectScanView()
            case .room: RoomScanView()
            case .space: SpaceScanView()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { showTips = true } label: { Image(systemName: "questionmark.circle.fill").font(.largeTitle) }
                .tint(.white).padding().accessibilityLabel("Cómo escanear")
        }
        .sheet(isPresented: $showTips) { TipsSheet(mode: mode).presentationDetents([.medium, .large]) }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if !tipsSeen { showTips = true; tipsSeen = true }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct TipsSheet: View {
    let mode: ScanMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(mode.title, systemImage: mode.icon).font(.title2.bold()).foregroundStyle(mode.color)
            ForEach(Array(mode.tips.enumerated()), id: \.offset) { _, tip in
                Label { Text(tip.text) } icon: { Image(systemName: tip.icon).foregroundStyle(mode.color) }
                    .font(.body)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Text("Entendido").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(mode.color)
        }
        .padding(24)
    }
}

/// Botones de cierre y acción comunes a las tres pantallas de escaneo.
struct ScanChrome<Action: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    /// Si hay algo escaneado sin guardar, pregunta antes de cerrar.
    let confirmClose: Bool
    let action: Action
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button { if confirmClose { confirming = true } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle)
                }
                .tint(.white).padding().accessibilityLabel("Cerrar")
            }
            .overlay(alignment: .bottom) {
                action.buttonStyle(.borderedProminent).controlSize(.large).padding(.bottom, 40)
            }
            .confirmationDialog("¿Salir sin guardar?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Descartar escaneo", role: .destructive) { dismiss() }
            } message: {
                Text("Lo escaneado hasta ahora se perderá.")
            }
    }
}

extension View {
    func scanChrome<A: View>(confirmClose: Bool = false, @ViewBuilder action: () -> A) -> some View {
        modifier(ScanChrome(confirmClose: confirmClose, action: action()))
    }
}
