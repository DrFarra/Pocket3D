import Foundation

/// Entrena un Gaussian splat en el propio iPhone con el motor msplat (Metal), a partir del dataset de Espacio:
/// fotos con la pose de ARKit (sin COLMAP) y la malla LiDAR en color como nube de partida.
enum SplatTrainer {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let iterations = 5000
    /// Tope de tiempo entrenando (sin contar pausas): pasado esto se guarda lo aprendido. Nadie espera para siempre.
    static let timeBudget: TimeInterval = 6 * 60
    /// Por debajo de esto el splat aún es niebla: no merece la pena guardarlo.
    static let minimumUsefulIterations: Int32 = 500
    /// Más fotos no caben en memoria a la vez: se usa una muestra repartida por todo el recorrido.
    static let maximumPhotos = 150
    /// Ancho de entrenamiento: buen detalle sin agotar memoria ni tiempo.
    static let trainingWidth = 800

    /// Prepara `dataset/train/transforms.json` con una muestra de fotos y devuelve la carpeta y el factor de reducción.
    static func prepare(dataset: URL, frames: [[String: Any]], hasMesh: Bool) throws -> (folder: URL, downscale: Float) {
        let step = max(1, Int((Double(frames.count) / Double(maximumPhotos)).rounded(.up)))
        let sample = stride(from: 0, to: frames.count, by: step).map { index -> [String: Any] in
            var frame = frames[index]
            // Rutas absolutas: el cargador de msplat las resuelve tal cual.
            for key in ["file_path", "depth_file_path"] {
                if let relative = frame[key] as? String { frame[key] = dataset.appending(path: relative).path }
            }
            return frame
        }
        var meta: [String: Any] = ["camera_model": "OPENCV", "frames": sample]
        if hasMesh { meta["ply_file_path"] = dataset.appending(path: "mesh.ply").path }
        let folder = dataset.appending(path: "train")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appending(path: "transforms.json"))
        let width = (sample.first?["w"] as? Int) ?? trainingWidth
        return (folder, max(1, Float(width) / Float(trainingWidth)))
    }

    /// Entrena y guarda el splat en `output`. `finishNow` corta y guarda lo que haya.
    /// Devuelve false si se cortó demasiado pronto para guardar algo útil.
    static func train(folder: URL, downscale: Float, output: URL,
                      finishNow: () -> Bool, isPaused: () -> Bool, progress: (Double) -> Void) throws -> Bool {
        guard let metallib = Bundle.main.path(forResource: "default", ofType: "metallib") else {
            throw Failure(errorDescription: "Falta el motor Metal de splats en la app.")
        }
        var message = [CChar](repeating: 0, count: 512)
        func failure() -> Failure { Failure(errorDescription: String(cString: message)) }

        guard let trainer = pocket_splat_create(folder.path, metallib, Int32(iterations), downscale, false, &message, 512) else {
            throw failure()
        }
        defer { pocket_splat_destroy(trainer) }

        var iteration: Int32 = 0
        var trainingTime: TimeInterval = 0
        var last = Date()
        while iteration < iterations {
            if isPaused() { usleep(200_000); last = Date(); continue }
            if finishNow() || trainingTime > timeBudget { break }
            iteration = pocket_splat_step(trainer, &message, 512)
            if iteration < 0 { throw failure() }
            let now = Date()
            trainingTime += now.timeIntervalSince(last)
            last = now
            if iteration % 20 == 0 { progress(max(Double(iteration) / Double(iterations), trainingTime / timeBudget)) }
        }
        guard iteration >= minimumUsefulIterations else { return false }
        guard pocket_splat_export(trainer, output.path, &message, 512) else { throw failure() }
        return true
    }
}
