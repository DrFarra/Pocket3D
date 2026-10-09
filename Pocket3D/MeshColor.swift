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
    /// Promedio ponderado de las `blend` mejores vistas que ven el punto sin nada delante (según la profundidad LiDAR).
    /// Mejor = más de frente y más cerca: las fotos de canto o lejanas estiran y emborronan el color. Con una sola foto
    /// la malla salía moteada (ruido del sensor y exposición distinta entre fotos).
    static func color(of point: SIMD3<Float>, normal: SIMD3<Float>? = nil, in views: [ColorView], blend: Int = 4) -> SIMD3<UInt8>? {
        var best: [(score: Float, color: SIMD3<Float>)] = []
        best.reserveCapacity(blend + 1)
        for view in views.reversed() {
            // Convención ARKit/OpenGL: la cámara mira a -Z, Y hacia arriba; la imagen tiene Y hacia abajo.
            let c = view.worldToCamera * SIMD4(point, 1)
            let z = -c.z
            guard z > 0.05 else { continue }
            let u = view.fx * c.x / z + view.cx
            let v = -view.fy * c.y / z + view.cy
            // Sin el 3 % del borde: ahí la lente distorsiona y la pose cuadra peor.
            let mu = Float(view.width) * 0.03, mv = Float(view.height) * 0.03
            guard u >= mu, v >= mv, u < Float(view.width) - mu, v < Float(view.height) - mv else { continue }

            let du = Int(u * Float(view.depthWidth) / Float(view.width))
            let dv = Int(v * Float(view.depthHeight) / Float(view.height))
            let measured = Float(view.depthMM[dv * view.depthWidth + du]) / 1000
            // El error del LiDAR y del suavizado de la malla crece con la distancia: ~3 % a 4 m.
            guard measured > 0, abs(measured - z) < max(0.05, 0.03 * z) else { continue }

            var facing: Float = 1
            if let normal {
                // Coseno entre la normal y el rayo a la cámara, en coordenadas de cámara (el signo de la normal da igual).
                let n4 = view.worldToCamera * SIMD4(normal, 0), n = SIMD3(n4.x, n4.y, n4.z)
                facing = abs(simd_dot(simd_normalize(n), simd_normalize(-SIMD3(c.x, c.y, c.z))))
                guard facing > 0.3 else { continue }   // más de ~72° de canto: no aporta, solo emborrona
            }
            let score = facing / z
            // Ante empate gana la más reciente (se recorren de la última a la primera).
            guard best.count < blend || score > best[blend - 1].score else { continue }
            let i = (Int(v) * view.width + Int(u)) * 4
            best.append((score, SIMD3(Float(view.rgba[i]), Float(view.rgba[i + 1]), Float(view.rgba[i + 2]))))
            best.sort { $0.score > $1.score }
            if best.count > blend { best.removeLast() }
        }
        guard !best.isEmpty else { return nil }
        let total = best.reduce(0) { $0 + $1.score }
        let mean = best.reduce(SIMD3<Float>.zero) { $0 + $1.color * $1.score } / total
        return SIMD3(UInt8(min(255, mean.x.rounded())), UInt8(min(255, mean.y.rounded())), UInt8(min(255, mean.z.rounded())))
    }

    static let unseen = SIMD3<UInt8>(160, 160, 160)

    /// Colorea todos los vértices repartiendo el trabajo entre los núcleos. Con `indices` (triángulos), los que
    /// ninguna foto vio limpio toman el color de sus vecinos; si no queda ninguno cerca, gris.
    static func colors(of positions: [SIMD3<Float>], in views: [ColorView], indices: [UInt32] = []) -> [SIMD3<UInt8>] {
        var colors = [SIMD3<UInt8>?](repeating: nil, count: positions.count)
        let normals = indices.isEmpty ? nil : normals(of: positions, indices: indices)
        let chunk = 4096
        colors.withUnsafeMutableBufferPointer { buffer in
            let out = buffer  // copia del puntero: cada hilo escribe índices distintos
            DispatchQueue.concurrentPerform(iterations: (positions.count + chunk - 1) / chunk) { c in
                for i in c * chunk..<min(positions.count, (c + 1) * chunk) {
                    out[i] = color(of: positions[i], normal: normals?[i], in: views)
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

    /// Normal de cada vértice: media de las caras que lo tocan, pesada por área. Nil en vértices sin caras.
    static func normals(of positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>?] {
        var sum = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])  // largo = 2 × área
            sum[a] += n; sum[b] += n; sum[c] += n
        }
        return sum.map { simd_length($0) > 1e-12 ? simd_normalize($0) : nil }
    }

    /// Une la malla de ARKit en una pieza y quita la basura suelta. ARKit la da en bloques con los bordes duplicados
    /// (grietas: ni el color ni el relleno de huecos cruzan de un bloque a otro) y con fragmentos de ruido: en una
    /// habitación real, 918 piezas, 10 % de vértices repetidos y ~650 fragmentos de menos de 50 triángulos.
    static func clean(positions: [SIMD3<Float>], indices: [UInt32], weld: Float = 0.002, minimumTriangles: Int = 50)
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        // Soldar: vértices en la misma celda de 2 mm pasan a ser uno.
        var cellIndex = [SIMD3<Int32>: UInt32](minimumCapacity: positions.count)
        var welded = [SIMD3<Float>](), remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(p / weld, rounding: .down)
            if let existing = cellIndex[key] { remap[i] = existing } else {
                remap[i] = UInt32(welded.count)
                cellIndex[key] = remap[i]
                welded.append(p)
            }
        }
        var triangles = [UInt32]()
        triangles.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let a = remap[Int(indices[t])], b = remap[Int(indices[t + 1])], c = remap[Int(indices[t + 2])]
            if a != b, b != c, a != c { triangles += [a, b, c] }   // los que se aplastan al soldar sobran
        }

        // Piezas conexas (unión-búsqueda) y cuántos triángulos tiene cada una.
        var parent = Array(0..<UInt32(welded.count))
        func root(_ x: UInt32) -> UInt32 {
            var x = x
            while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
            return x
        }
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let a = root(triangles[t])
            for v in [triangles[t + 1], triangles[t + 2]] { let r = root(v); if r != a { parent[Int(r)] = a } }
        }
        var size = [UInt32: Int]()
        for t in stride(from: 0, to: triangles.count, by: 3) { size[root(triangles[t]), default: 0] += 1 }
        // Nunca se borra la pieza más grande (un objeto pequeño puede tener pocos triángulos).
        let keepFrom = min(minimumTriangles, size.values.max() ?? 0)

        var outIndex = [UInt32: UInt32](), outPositions = [SIMD3<Float>](), outTriangles = [UInt32]()
        for t in stride(from: 0, to: triangles.count, by: 3) where size[root(triangles[t]), default: 0] >= keepFrom {
            for v in triangles[t..<t + 3] {
                if let existing = outIndex[v] { outTriangles.append(existing) } else {
                    let new = UInt32(outPositions.count)
                    outIndex[v] = new
                    outPositions.append(welded[Int(v)])
                    outTriangles.append(new)
                }
            }
        }
        return (outPositions, outTriangles)
    }

    /// Celdas ocupadas por la superficie escaneada, para saber qué está cerca de algo real.
    static func occupiedCells(_ positions: [SIMD3<Float>], cell: Float) -> Set<SIMD3<Int32>> {
        Set(positions.map { SIMD3<Int32>($0 / cell, rounding: .down) })
    }

    /// Quita del splat las gaussianas que flotan lejos de toda superficie que vio el LiDAR (nubes en el aire, típicas
    /// de los splats). Lee el PLY de msplat (todo float, x y z primero) y lo reescribe. No toca nada si quitaría más
    /// de la mitad: eso indicaría coordenadas que no cuadran, no basura.
    @discardableResult
    static func pruneSplat(at url: URL, near cells: Set<SIMD3<Int32>>, cell: Float) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let end = data.range(of: Data("end_header\n".utf8)) else { return 0 }
        let header = String(decoding: data[..<end.upperBound], as: UTF8.self)
        let lines = header.split(separator: "\n")
        guard header.contains("binary_little_endian"),
              let countLine = lines.first(where: { $0.hasPrefix("element vertex ") }),
              let count = Int(countLine.dropFirst("element vertex ".count)),
              lines.filter({ $0.hasPrefix("property") }).allSatisfy({ $0.hasPrefix("property float ") }) else { return 0 }
        let stride = lines.filter { $0.hasPrefix("property") }.count * 4
        let body = data[end.upperBound...]
        guard stride >= 12, body.count >= count * stride else { return 0 }

        var kept = Data()
        kept.reserveCapacity(count * stride)
        var keptCount = 0
        body.withUnsafeBytes { raw in
            for i in 0..<count {
                let row = raw.baseAddress!.advanced(by: i * stride)
                let p = SIMD3(row.loadUnaligned(as: Float.self), row.loadUnaligned(fromByteOffset: 4, as: Float.self),
                              row.loadUnaligned(fromByteOffset: 8, as: Float.self))
                let c = SIMD3<Int32>(p / cell, rounding: .down)
                var near = false
                // La celda y sus 26 vecinas: hasta ~2 celdas de la superficie.
                search: for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 where cells.contains(c &+ SIMD3(dx, dy, dz)) {
                    near = true
                    break search
                } } }
                if near {
                    kept.append(row.assumingMemoryBound(to: UInt8.self), count: stride)
                    keptCount += 1
                }
            }
        }
        let removed = count - keptCount
        guard removed > 0, removed * 2 <= count else { return 0 }
        var out = Data(header.replacingOccurrences(of: String(countLine), with: "element vertex \(keptCount)").utf8)
        out.append(kept)
        try out.write(to: url, options: .atomic)
        return removed
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
    /// `unlit`: el color ya trae la luz real (escaneo con fotos); sin él, Blender lo sombrea (cajas de un plano).
    static func glbData(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], indices: [UInt32], unlit: Bool = true) throws -> Data {
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

        var material: [String: Any] = ["doubleSided": true,
                                       "pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1]]
        if unlit { material["extensions"] = ["KHR_materials_unlit": [String: Any]()] }
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Pocket3D"],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": "Pocket3D"]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0, "COLOR_0": 1], "indices": 2, "material": 0]]]],
            "materials": [material],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": colorOffset, "target": 34962],
                            ["buffer": 0, "byteOffset": colorOffset, "byteLength": indexOffset - colorOffset, "target": 34962],
                            ["buffer": 0, "byteOffset": indexOffset, "byteLength": bin.count - indexOffset, "target": 34963]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": positions.count, "type": "VEC3",
                           "min": [low.x, low.y, low.z], "max": [high.x, high.y, high.z]],
                          ["bufferView": 1, "componentType": 5121, "normalized": true, "count": colors.count, "type": "VEC4"],
                          ["bufferView": 2, "componentType": 5125, "count": indices.count, "type": "SCALAR"]],
        ]
        // Sin iluminar: el color ya trae la luz real de las fotos; con luces de Blender una habitación cerrada sale negra.
        if unlit { json["extensionsUsed"] = ["KHR_materials_unlit"] }
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

    /// Cajas de color (paredes, puertas, muebles de RoomPlan) como una sola malla, centradas en `transform`.
    static func boxes(_ items: [(transform: simd_float4x4, size: SIMD3<Float>, color: SIMD3<UInt8>)])
        -> (positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], indices: [UInt32]) {
        // Esquina i: bit 0 = +x, bit 1 = +y, bit 2 = +z. Seis caras de dos triángulos.
        let faces: [UInt32] = [0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3, 0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6, 0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5]
        var positions = [SIMD3<Float>](), colors = [SIMD3<UInt8>](), indices = [UInt32]()
        for item in items {
            let base = UInt32(positions.count)
            for i in 0..<8 {
                let sign = SIMD3<Float>(i & 1 == 0 ? -0.5 : 0.5, i & 2 == 0 ? -0.5 : 0.5, i & 4 == 0 ? -0.5 : 0.5)
                let p = item.transform * SIMD4(sign * item.size, 1)
                positions.append(SIMD3(p.x, p.y, p.z))
                colors.append(item.color)
            }
            indices += faces.map { $0 + base }
        }
        return (positions, colors, indices)
    }

    /// Los PLY de Gaussian splats llevan coeficientes de color esférico (f_dc_*); los de malla no.
    static func isGaussianSplatPLY(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return header.contains("f_dc_0")
    }
}
