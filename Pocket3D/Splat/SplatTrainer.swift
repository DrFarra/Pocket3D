import Foundation
import os

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
    /// msplat guarda cada foto dos veces en float32 (CPU y GPU): 100 × 720×540 ≈ 0,9 GB. Más no cabe con holgura.
    static let maximumPhotos = 100
    /// Ancho de entrenamiento: buen detalle sin agotar memoria ni tiempo.
    static let trainingWidth = 720
    /// Gaussianas de partida (~1,5 KB cada una con el estado del optimizador, y se multiplican al densificar).
    static let maximumInitialPoints = 60_000
    static let initialCloud = "init.ply"
    /// Si queda menos memoria libre que esto, se guarda lo aprendido antes de que iOS cierre la app.
    /// Crece con las gaussianas: una ronda de densificación puede reservar ~3 KB por gaussiana de golpe.
    static func memoryFloor(gaussians: Int) -> Int { max(1_000_000_000, gaussians * 3_000) }

    /// Prepara `dataset/train/transforms.json` con una muestra de fotos y devuelve la carpeta y el factor de reducción.
    static func prepare(dataset: URL, frames: [[String: Any]], hasCloud: Bool) throws -> (folder: URL, downscale: Float) {
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
        if hasCloud { meta["ply_file_path"] = dataset.appending(path: initialCloud).path }
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
        guard os_proc_available_memory() > 2 * memoryFloor(gaussians: 0) else {
            throw Failure(errorDescription: "No hay memoria libre suficiente. Cierra otras apps y vuelve a intentarlo.")
        }
        var message = [CChar](repeating: 0, count: 512)
        func failure() -> Failure { Failure(errorDescription: String(cString: message)) }

        guard let trainer = pocket_splat_create(folder.path, metallib, Int32(iterations), downscale, false, &message, 512) else {
            throw failure()
        }
        defer { pocket_splat_destroy(trainer) }

        var iteration: Int32 = 0
        var outOfMemory = false
        var trainingTime: TimeInterval = 0
        var last = Date()
        var wasPaused = false
        while iteration < iterations {
            if isPaused() {
                // Vaciar la cola de la GPU antes de quedar en segundo plano, donde iOS no deja usarla.
                if !wasPaused { pocket_splat_sync(); wasPaused = true }
                usleep(200_000)
                last = Date()
                continue
            }
            wasPaused = false
            if finishNow() || trainingTime > timeBudget { break }
            // Las gaussianas crecen al densificar: antes de que iOS mate la app por memoria, se guarda lo que haya.
            if os_proc_available_memory() < memoryFloor(gaussians: Int(pocket_splat_count(trainer))) { outOfMemory = true; break }
            iteration = pocket_splat_step(trainer, &message, 512)
            if iteration < 0 { throw failure() }
            let now = Date()
            trainingTime += now.timeIntervalSince(last)
            last = now
            if iteration % 20 == 0 { progress(max(Double(iteration) / Double(iterations), trainingTime / timeBudget)) }
        }
        guard iteration >= minimumUsefulIterations else {
            if outOfMemory {
                throw Failure(errorDescription: "Esta escena es demasiado grande para el splat en el iPhone. Usa el zip «Enviar al PC» con Postshot.")
            }
            return false
        }
        // A un temporal y luego a su sitio: un splat a medias nunca aparece en la biblioteca.
        let partial = output.deletingLastPathComponent().appending(path: ".\(output.lastPathComponent).tmp")
        guard pocket_splat_export(trainer, partial.path, &message, 512) else {
            try? FileManager.default.removeItem(at: partial)
            throw failure()
        }
        try FileManager.default.moveItem(at: partial, to: output)
        return true
    }
}
