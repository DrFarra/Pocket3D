import ARKit
import QuickLook
import RealityKit
import RoomPlan
import SwiftUI
import UniformTypeIdentifiers

@main
struct Pocket3DApp: App {
    init() {
        #if DEBUG
        Dataset.selfCheck()
        #endif
        // Restos de escaneos interrumpidos (la app cerrada a medias): pueden ser gigas.
        let tmp = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

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
            Tip(icon: "lightbulb.fill", text: "Mesa lisa y despejada, luz suave. Evita sol directo y focos que hagan brillos."),
            Tip(icon: "scope", text: "Pon el punto blanco sobre el objeto y, cuando la caja lo rodee entero, toca «Fijar caja»."),
            Tip(icon: "arrow.2.circlepath", text: "Rodéalo despacio dos veces, una más alta y otra más baja. «Ver» enseña los huecos; «Dándole la vuelta» fotografía la base."),
            Tip(icon: "sparkles", text: "Vidrio, espejos o metal muy brillante confunden a cualquier escáner: cúbrelos con spray mate o talco, o usa Postshot en el PC."),
        ]
        case .room: [
            Tip(icon: "lightbulb.fill", text: "Enciende las luces y abre las puertas que quieras incluir."),
            Tip(icon: "figure.walk", text: "Recorre el perímetro despacio apuntando a paredes, ventanas y muebles."),
            Tip(icon: "house.and.flag.fill", text: "Al terminar, pulsa «Otra habitación» para seguir con la casa entera, o «Guardar»."),
        ]
        case .space: [
            Tip(icon: "tortoise.fill", text: "Camina despacio: la app guarda una foto cada 10 cm y vibra suavemente con cada una."),
            Tip(icon: "car.fill", text: "¿Un objeto grande, como un auto? Rodéalo despacio: la app te dice cuándo dar otra vuelta más alta y guarda también «Espacio objeto», solo con él, sin suelo ni lo de alrededor."),
            Tip(icon: "exclamationmark.triangle.fill", text: "Si el aviso se pone rojo, ve más despacio: así las fotos no salen movidas."),
            Tip(icon: "arrow.triangle.capsulepath", text: "Cubre todo con la malla (hasta ~5 m) y termina cerca de donde empezaste."),
            Tip(icon: "sparkles", text: "Espejos, ventanas y suelos brillantes: la app quita sola lo que aparece reflejado tras las paredes o bajo el suelo, y los brillos de las lámparas no manchan el color."),
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

    /// Lo que se puede abrir; las texturas y .mtl que acompañan a un .obj importado no se listan.
    static let listed: Set<String> = ["usdz", "reality", "ply", "spz", "splat", "obj", "stl", "glb", "zip"]

    static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { listed.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

struct HomeView: View {
    @State private var scans = Scans.all()
    @State private var mode: ScanMode?
    @State private var preview: URL?
    @State private var viewing: URL?
    @State private var importing = false
    @State private var importError: String?
    @State private var showingPC = false
    @ObservedObject private var pc = PCLink.shared

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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingPC = true } label: {
                        Label(pc.isConnected ? "PC conectado" : "PC", systemImage: pc.isConnected ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(pc.isConnected ? .green : .indigo)
                }
                ToolbarItem { Button("Importar del PC", systemImage: "square.and.arrow.down") { importing = true } }
            }
            .sheet(isPresented: $showingPC) { PCSheet() }
            .task { pc.start() }
            // Llegó un splat procesado en el PC: a la lista.
            .onChange(of: pc.resultsReceived) { scans = Scans.all() }
        }
        .tint(.indigo)
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { ModelViewer(url: viewing) }
        }
        // Splats de Postshot/nerfstudio o mallas de RealityScan: se copian a Scans para verlos aquí.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let before = Set(scans)
            let urls = (try? result.get()) ?? []
            var failed = [String]()
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                // Varios archivos a la vez (p. ej. .obj + .mtl + texturas): nombres originales para que se sigan encontrando.
                var destination = urls.count > 1 ? Scans.folder.appending(path: url.lastPathComponent)
                    : Scans.newURL(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = Scans.newURL(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                }
                do { try FileManager.default.copyItem(at: url, to: destination) } catch { failed.append(url.lastPathComponent) }
            }
            if !failed.isEmpty { importError = "No se pudo importar: " + failed.joined(separator: ", ") }
            openNewest(since: before)
        }
        .alert("Importar", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .fullScreenCover(item: $mode, onDismiss: { openNewest(since: Set(scans)) }) { ScanContainer(mode: $0) }
    }

    /// Tras escanear o importar, abre directamente el resultado (no los zips para el PC).
    private func openNewest(since before: Set<URL>) {
        scans = Scans.all()
        if let new = scans.first(where: { !before.contains($0) && !["zip", "glb"].contains($0.pathExtension.lowercased()) }) { open(new) }
    }

    private func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // Las habitaciones .usdz también: Quick Look solo deja verlas por fuera.
        if ModelViewer.extensions.contains(ext) || (ext == "usdz" && ModelViewer.isRoom(url)) { viewing = url } else { preview = url }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        scans = Scans.all()
    }
}

/// Conectar con Pocket3D PC: el escaneo de Espacio se ve en vivo en el ordenador y su GPU hace la versión fotorrealista.
private struct PCSheet: View {
    @ObservedObject private var pc = PCLink.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = pc.name {
                        Label("Conectado a \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Buscando el PC en tu WiFi…", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    if let state = pc.remoteState, pc.isConnected {
                        LabeledContent("Último escaneo", value: state.capitalized)
                    }
                } footer: {
                    Text("Con el PC conectado, el modo Espacio le manda cada foto y la malla mientras escaneas: lo ves crecer en la pantalla del ordenador y, al guardar, su GPU crea la versión fotorrealista y la devuelve aquí.")
                }
                Section {
                    TextField("Ej. 192.168.1.20", text: $pc.manualAddress)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Dirección del PC (si no aparece solo)")
                } footer: {
                    Text("La muestra la ventana de Pocket3D PC al abrirse. El iPhone y el PC tienen que estar en la misma WiFi.")
                }
                Section("En el PC (una vez)") {
                    Label("Instala Python desde python.org", systemImage: "1.circle")
                    Label("Descarga la carpeta «pc» de Pocket3D (GitHub)", systemImage: "2.circle")
                    Label("Doble clic en «Pocket3D PC.bat» y permite el acceso en redes privadas", systemImage: "3.circle")
                }
            }
            .navigationTitle("Tu PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Listo") { dismiss() } }
        }
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
    /// Fotos para procesar en el PC y mallas para Blender: no se abren aquí, se envían.
    private var isForPC: Bool { ext == "zip" || ext == "glb" }
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
        case "glb": "Para Blender"
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
        case "glb": "cube.transparent.fill"
        case "usdz", "reality": parts.name.hasPrefix("Habitación") || parts.name.hasPrefix("Plano") ? "house.fill" : "cube.fill"
        default: isSplat ? "sparkles" : "square.stack.3d.up.fill"
        }
    }

    private var color: Color {
        switch ext {
        case "zip": .indigo
        case "glb": .orange
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
        .environment(\.scanPaused, showTips)  // nada se fija ni empieza mientras se leen los consejos
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

extension EnvironmentValues {
    /// true mientras hay algo tapando la pantalla de escaneo (p. ej. los consejos).
    @Entry var scanPaused = false
}

/// Botones de cierre y acción comunes a las tres pantallas de escaneo.
struct ScanChrome<Action: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    /// Si hay algo escaneado sin guardar, pregunta antes de cerrar.
    let confirmClose: Bool
    /// Mientras se guarda no se puede cerrar: se perdería o quedaría a medias.
    let closeDisabled: Bool
    let action: Action
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button { if confirmClose { confirming = true } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle)
                }
                .tint(.white).padding().accessibilityLabel("Cerrar")
                .disabled(closeDisabled).opacity(closeDisabled ? 0.3 : 1)
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
    func scanChrome<A: View>(confirmClose: Bool = false, closeDisabled: Bool = false, @ViewBuilder action: () -> A) -> some View {
        modifier(ScanChrome(confirmClose: confirmClose, closeDisabled: closeDisabled, action: action()))
    }
}
