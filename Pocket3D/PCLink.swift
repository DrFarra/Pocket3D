import Foundation
import Network

/// Conexión en vivo con «Pocket3D PC» (pc/pocket3d_pc.py) por la WiFi de casa: mientras escaneas en modo Espacio, el
/// PC recibe cada foto, su pose y la malla, lo enseña en vivo y al terminar lo procesa con su GPU y devuelve el resultado.
/// Si no hay PC, nada cambia: el escaneo sigue igual en el iPhone.
@MainActor
final class PCLink: ObservableObject {
    static let shared = PCLink()
    static let port = 8765

    /// Nombre del PC conectado; nil si no hay ninguno.
    @Published private(set) var name: String?
    /// Envíos en cola (fotos y malla que aún no llegaron al PC).
    @Published private(set) var pending = 0
    /// Lo que el PC está haciendo con el último escaneo («procesando», «listo», «falló»).
    @Published private(set) var remoteState: String?
    /// Cambia cada vez que llega un resultado del PC (la lista de escaneos se recarga).
    @Published private(set) var resultsReceived = 0
    @Published var manualAddress = UserDefaults.standard.string(forKey: "pcAddress") ?? "" {
        didSet {
            UserDefaults.standard.set(manualAddress, forKey: "pcAddress")
            Task { await connectManual() }
        }
    }

    private var base: URL?
    private var browser: NWBrowser?
    private var resolving: NWConnection?
    private var tail: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var isConnected: Bool { name != nil }

    func start() {
        guard browser == nil else { return }
        Task { await connectManual() }
        // Búsqueda automática: el PC se anuncia por Bonjour si tiene `zeroconf` instalado.
        let browser = NWBrowser(for: .bonjour(type: "_pocket3d._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor in self?.resolve(endpoint) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// De servicio Bonjour a IP: se abre una conexión y se mira a qué dirección llegó (solo IPv4, más simple en una URL).
    private func resolve(_ endpoint: NWEndpoint) {
        guard !isConnected, resolving == nil else { return }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(.ipv4(let ip), let port) = connection.currentPath?.remoteEndpoint {
                        let address = ip.rawValue.map(String.init).joined(separator: ".")
                        await self.connect(URL(string: "http://\(address):\(port.rawValue)"))
                    }
                    connection.cancel()
                    self.resolving = nil
                case .failed, .cancelled:
                    self.resolving = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func connectManual() async {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        await connect(URL(string: address.contains(":") ? "http://\(address)" : "http://\(address):\(Self.port)"))
    }

    /// Comprueba que de verdad es Pocket3D PC antes de mandarle nada.
    private func connect(_ url: URL?) async {
        guard let url, let reply = try? await session.data(from: url.appending(path: "api/hello")),
              let hello = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any], hello["app"] as? String == "pocket3d"
        else { return }
        base = url
        name = hello["name"] as? String ?? url.host()
    }

    // MARK: Escaneo en vivo

    /// Abre un escaneo en el PC; nil si no hay PC.
    func beginScan() async -> String? {
        guard let base else { return nil }
        var request = URLRequest(url: base.appending(path: "api/scan"))
        request.httpMethod = "POST"
        guard let response = try? await session.data(for: request),
              let reply = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any] else {
            name = nil   // el PC se cerró o cambió de red
            return nil
        }
        remoteState = "recibiendo"
        return reply["id"] as? String
    }

    /// Manda un archivo del escaneo (foto, profundidad, malla). Se lee del disco al enviarlo: la cola no ocupa memoria.
    func send(file: URL, as path: String, scan: String) {
        enqueue(method: "PUT", path: "api/scan/\(scan)/file/\(path)", file: file)
    }

    func send(data: Data, as path: String, scan: String) {
        enqueue(method: "PUT", path: "api/scan/\(scan)/file/\(path)", body: data)
    }

    func addFrame(_ entry: [String: Any], scan: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: entry) else { return }
        enqueue(method: "POST", path: "api/scan/\(scan)/frame", body: body)
    }

    /// Espera a que llegue todo, avisa al PC de que terminó y, si lo procesa, trae el resultado cuando esté.
    /// Devuelve true si el PC va a procesarlo (entonces no hace falta entrenar también en el iPhone).
    func finish(scan: String) async -> Bool {
        await tail?.value
        guard let base else { return false }
        var request = URLRequest(url: base.appending(path: "api/scan/\(scan)/finish"))
        request.httpMethod = "POST"
        guard let response = try? await session.data(for: request),
              let reply = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let state = reply["state"] as? String else { return false }
        remoteState = state
        guard state == "procesando" else { return false }
        Task { await waitForResult(scan: scan, from: base) }
        return true
    }

    /// GET de un recurso del PC (nil si no hay PC o falla).
    func data(_ path: String) async -> Data? {
        guard let base, let reply = try? await session.data(from: base.appending(path: path)),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return reply.0
    }

    func json(_ path: String) async -> [String: Any]? {
        guard let data = await data(path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func waitForResult(scan: String, from base: URL) async {
        var gotMesh = false
        // Entrenar en el PC lleva minutos: se pregunta cada 5 s mientras la app esté abierta (hasta 3 horas).
        for _ in 0..<2160 {
            try? await Task.sleep(for: .seconds(5))
            guard let response = try? await session.data(from: base.appending(path: "api/scan/\(scan)/status")),
                  let status = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
                  let state = status["state"] as? String else { continue }   // sin red un momento: se reintenta
            remoteState = state
            // Modo PC: la malla final llega antes que el splat (si lo hay).
            if !gotMesh, status["final_mesh"] as? Bool == true,
               let download = try? await session.download(from: base.appending(path: "api/scan/\(scan)/malla.ply")),
               (download.1 as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.moveItem(at: download.0, to: Scans.newURL("Espacio PC malla", ext: "ply"))
                gotMesh = true
                resultsReceived += 1
            }
            if state == "falló" || (state == "listo" && status["result"] as? Bool != true) { return }
            if state == "listo", status["result"] as? Bool == true {
                guard let download = try? await session.download(from: base.appending(path: "api/scan/\(scan)/resultado.ply")),
                      (download.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
                // «Espacio … splat.ply»: el visor sabe que viene con Y hacia arriba (poses de ARKit).
                try? FileManager.default.moveItem(at: download.0, to: Scans.newURL("Espacio PC splat", ext: "ply"))
                resultsReceived += 1
                return
            }
        }
    }

    private func enqueue(method: String, path: String, body: Data? = nil, file: URL? = nil) {
        guard let base else { return }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        pending += 1
        let previous = tail
        // En orden: la foto llega antes que su fila de transforms.json.
        tail = Task {
            await previous?.value
            if let file {
                _ = try? await session.upload(for: request, fromFile: file)
            } else {
                _ = try? await session.upload(for: request, from: body ?? Data())
            }
            pending -= 1
        }
    }
}
