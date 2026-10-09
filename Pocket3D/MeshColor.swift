import Foundation
import simd

/// Una foto reducida con su pose y profundidad, usada para colorear la malla LiDAR.
/// Sin dependencias de ARKit para poder probarlo en macOS (ver Tests/main.swift).
struct ColorView {
    var worldToCamera: simd_float4x4
    /// Intrínsecos ya escalados al tamaño de `rgba`.
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Int, height: Int
    var rgba: [UInt8]
    var depthMM: [UInt16]
    var depthWidth: Int, depthHeight: Int
}

enum MeshColor {
    /// Color de la vista más reciente que ve el punto sin nada delante (según la profundidad LiDAR).
    static func color(of point: SIMD3<Float>, in views: [ColorView], tolerance: Float = 0.05) -> SIMD3<UInt8>? {
        for view in views.reversed() {
            // Convención ARKit/OpenGL: la cámara mira a -Z, Y hacia arriba; la imagen tiene Y hacia abajo.
            let c = view.worldToCamera * SIMD4(point, 1)
            let z = -c.z
            guard z > 0.05 else { continue }
            let u = view.fx * c.x / z + view.cx
            let v = -view.fy * c.y / z + view.cy
            guard u >= 0, v >= 0, u < Float(view.width), v < Float(view.height) else { continue }

            let du = Int(u * Float(view.depthWidth) / Float(view.width))
            let dv = Int(v * Float(view.depthHeight) / Float(view.height))
            let measured = Float(view.depthMM[dv * view.depthWidth + du]) / 1000
            guard measured > 0, abs(measured - z) < tolerance else { continue }

            let i = (Int(v) * view.width + Int(u)) * 4
            return SIMD3(view.rgba[i], view.rgba[i + 1], view.rgba[i + 2])
        }
        return nil
    }

    /// Colorea todos los vértices repartiendo el trabajo entre los núcleos; gris si ninguna foto los ve.
    static func colors(of positions: [SIMD3<Float>], in views: [ColorView]) -> [SIMD3<UInt8>] {
        var colors = [SIMD3<UInt8>](repeating: SIMD3(160, 160, 160), count: positions.count)
        let chunk = 4096
        colors.withUnsafeMutableBufferPointer { buffer in
            let out = buffer  // copia del puntero: cada hilo escribe índices distintos
            DispatchQueue.concurrentPerform(iterations: (positions.count + chunk - 1) / chunk) { c in
                for i in c * chunk..<min(positions.count, (c + 1) * chunk) {
                    if let color = color(of: positions[i], in: views) { out[i] = color }
                }
            }
        }
        return colors
    }

    /// PLY binario con color por vértice: lo abren Blender, MeshLab, CloudCompare, nerfstudio y el visor de la app.
    static func plyData(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], indices: [UInt32]) -> Data {
        precondition(positions.count == colors.count && indices.count % 3 == 0)
        var data = Data("""
        ply
        format binary_little_endian 1.0
        element vertex \(positions.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(indices.count / 3)
        property list uchar int vertex_indices
        end_header

        """.utf8)
        data.reserveCapacity(data.count + positions.count * 15 + indices.count / 3 * 13)
        for (p, c) in zip(positions, colors) {
            for f in [p.x, p.y, p.z] { withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: [c.x, c.y, c.z])
        }
        for t in stride(from: 0, to: indices.count, by: 3) {
            data.append(3)
            for i in indices[t..<t + 3] { withUnsafeBytes(of: Int32(i).littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    /// Los PLY de Gaussian splats llevan coeficientes de color esférico (f_dc_*); los de malla no.
    static func isGaussianSplatPLY(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return header.contains("f_dc_0")
    }
}
