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
    /// Promedio de las `blend` vistas más recientes que ven el punto sin nada delante (según la profundidad LiDAR).
    /// Una sola foto deja la malla moteada: ruido del sensor y exposición distinta entre fotos vecinas.
    static func color(of point: SIMD3<Float>, in views: [ColorView], blend: Int = 4) -> SIMD3<UInt8>? {
        var sum = SIMD3<UInt32>.zero, count = 0
        for view in views.reversed() {
            if count == blend { break }
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
            // El error del LiDAR y del suavizado de la malla crece con la distancia: ~3 % a 4 m.
            guard measured > 0, abs(measured - z) < max(0.05, 0.03 * z) else { continue }

            let i = (Int(v) * view.width + Int(u)) * 4
            sum &+= SIMD3(UInt32(view.rgba[i]), UInt32(view.rgba[i + 1]), UInt32(view.rgba[i + 2]))
            count += 1
        }
        return count > 0 ? SIMD3(truncatingIfNeeded: sum / UInt32(count)) : nil
    }

    static let unseen = SIMD3<UInt8>(160, 160, 160)

    /// Colorea todos los vértices repartiendo el trabajo entre los núcleos. Con `indices` (triángulos), los que
    /// ninguna foto vio limpio toman el color de sus vecinos; si no queda ninguno cerca, gris.
    static func colors(of positions: [SIMD3<Float>], in views: [ColorView], indices: [UInt32] = []) -> [SIMD3<UInt8>] {
        var colors = [SIMD3<UInt8>?](repeating: nil, count: positions.count)
        let chunk = 4096
        colors.withUnsafeMutableBufferPointer { buffer in
            let out = buffer  // copia del puntero: cada hilo escribe índices distintos
            DispatchQueue.concurrentPerform(iterations: (positions.count + chunk - 1) / chunk) { c in
                for i in c * chunk..<min(positions.count, (c + 1) * chunk) {
                    out[i] = color(of: positions[i], in: views)
                }
            }
        }
        fillGaps(&colors, indices: indices)
        return colors.map { $0 ?? unseen }
    }

    /// Bordes y ruido de profundidad dejan vértices sueltos sin color: sin esto la malla sale moteada de gris
    /// (~25 % en una habitación real). Cada pasada los tiñe con el promedio de sus vecinos ya coloreados.
    static func fillGaps(_ colors: inout [SIMD3<UInt8>?], indices: [UInt32], passes: Int = 12) {
        for _ in 0..<passes {
            var sum = [SIMD3<UInt32>](repeating: .zero, count: colors.count)
            var count = [UInt32](repeating: 0, count: colors.count)
            func spread(_ from: Int, _ to: Int) {
                if colors[to] == nil, let c = colors[from] { sum[to] &+= SIMD3(truncatingIfNeeded: c); count[to] += 1 }
            }
            for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
                let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
                spread(a, b); spread(b, a); spread(a, c); spread(c, a); spread(b, c); spread(c, b)
            }
            var changed = false
            for i in colors.indices where colors[i] == nil && count[i] > 0 {
                colors[i] = SIMD3(truncatingIfNeeded: sum[i] / count[i])
                changed = true
            }
            if !changed { return }
        }
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

    /// GLB (glTF binario) con color por vértice para Blender: entra derecho (Z arriba, en metros) y con el color ya
    /// conectado al material, sin necesitar luces. Probado con Blender 5.0: el PLY entra tumbado (asume Z arriba) y el
    /// OBJ sin material.
    static func glbData(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], indices: [UInt32]) throws -> Data {
        precondition(!positions.isEmpty && positions.count == colors.count && indices.count % 3 == 0)
        var bin = Data()
        bin.reserveCapacity(positions.count * 16 + indices.count * 4)
        for p in positions {
            for f in [p.x, p.y, p.z] { withUnsafeBytes(of: f.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
        }
        let colorOffset = bin.count
        for c in colors { bin.append(contentsOf: [c.x, c.y, c.z, 255]) }  // RGBA: glTF exige cada color alineado a 4 bytes
        let indexOffset = bin.count
        for i in indices { withUnsafeBytes(of: i.littleEndian) { bin.append(contentsOf: $0) } }
        let low = positions.reduce(positions[0]) { simd_min($0, $1) }, high = positions.reduce(positions[0]) { simd_max($0, $1) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Pocket3D"],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": "Pocket3D"]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0, "COLOR_0": 1], "indices": 2, "material": 0]]]],
            // Sin iluminar: el color ya trae la luz real de las fotos; con luces de Blender una habitación cerrada sale negra.
            "extensionsUsed": ["KHR_materials_unlit"],
            "materials": [["doubleSided": true, "extensions": ["KHR_materials_unlit": [String: Any]()],
                           "pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1]]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": colorOffset, "target": 34962],
                            ["buffer": 0, "byteOffset": colorOffset, "byteLength": indexOffset - colorOffset, "target": 34962],
                            ["buffer": 0, "byteOffset": indexOffset, "byteLength": bin.count - indexOffset, "target": 34963]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": positions.count, "type": "VEC3",
                           "min": [low.x, low.y, low.z], "max": [high.x, high.y, high.z]],
                          ["bufferView": 1, "componentType": 5121, "normalized": true, "count": colors.count, "type": "VEC4"],
                          ["bufferView": 2, "componentType": 5125, "count": indices.count, "type": "SCALAR"]],
        ]
        var header = try JSONSerialization.data(withJSONObject: json)
        header.append(contentsOf: repeatElement(0x20, count: (4 - header.count % 4) % 4))  // los bloques miden múltiplos de 4
        bin.append(contentsOf: repeatElement(0, count: (4 - bin.count % 4) % 4))

        var glb = Data()
        func word(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { glb.append(contentsOf: $0) } }
        word(0x4654_6C67); word(2); word(12 + 8 + header.count + 8 + bin.count)   // "glTF", versión, tamaño total
        word(header.count); word(0x4E4F_534A); glb.append(header)                 // bloque "JSON"
        word(bin.count); word(0x004E_4942); glb.append(bin)                       // bloque "BIN"
        return glb
    }

    /// Los PLY de Gaussian splats llevan coeficientes de color esférico (f_dc_*); los de malla no.
    static func isGaussianSplatPLY(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return header.contains("f_dc_0")
    }
}
