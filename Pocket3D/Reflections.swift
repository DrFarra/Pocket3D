import simd

/// Espejos, vidrios y suelos brillantes. El LiDAR mide el reflejo (o lo que hay al otro lado del vidrio) como si fuera
/// real: aparecen habitaciones fantasma detrás de las paredes y muebles colgando bajo el suelo. Pero el iPhone nunca
/// estuvo al otro lado de una pared: lo que queda claramente detrás de un límite de la habitación, visto desde donde se
/// escaneó, solo puede ser un reflejo o lo que se ve por una ventana. Se quita.
///
/// Calibrado con una habitación real: con 30 cm de margen quita solo lo de fuera (hasta 2 m tras una pared, el 2,4 %);
/// con 5 cm se comía trozos de pared, porque las paredes reales no son planas.
enum Reflections {
    struct Plane {
        var normal: SIMD3<Float>
        var offset: Float
        var inliers: [Int]
    }

    /// Planos grandes (paredes, suelo, techo, frentes de armario) por RANSAC sobre vértices con normal.
    static func planes(positions: [SIMD3<Float>], indices: [UInt32], minimumArea: Float = 1.5, maximumPlanes: Int = 12) -> [Plane] {
        let normals = MeshColor.normals(of: positions, indices: indices)
        var area = [Float](repeating: 0, count: positions.count)
        for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let third = simd_length(simd_cross(positions[b] - positions[a], positions[c] - positions[a])) / 6
            area[a] += third; area[b] += third; area[c] += third
        }
        let tolerance: Float = 0.03, alignment = cos(Float.pi / 9)   // 3 cm y 20°
        func fits(_ i: Int, _ n: SIMD3<Float>, _ d: Float) -> Bool {
            guard let ni = normals[i] else { return false }
            return abs(simd_dot(n, positions[i]) - d) < tolerance && abs(simd_dot(n, ni)) > alignment
        }

        var random = SplitMix64(seed: 0x5EED)   // fijo: el mismo escaneo da siempre el mismo resultado
        var remaining = positions.indices.filter { normals[$0] != nil }
        var found = [Plane]()
        while found.count < maximumPlanes, remaining.count > 100 {
            // Hipótesis con una muestra (rápido); la mejor se cuenta con todos los vértices.
            remaining.shuffle(using: &random)
            let sample = remaining.prefix(20_000)
            let scale = Float(remaining.count) / Float(sample.count)
            var best: (score: Float, normal: SIMD3<Float>, offset: Float)?
            for _ in 0..<300 {
                let i = sample[sample.startIndex + Int(random.next() % UInt64(sample.count))]
                let n = normals[i]!, d = simd_dot(n, positions[i])
                let score = sample.reduce(Float(0)) { fits($1, n, d) ? $0 + area[$1] : $0 } * scale
                if score > best?.score ?? 0 { best = (score, n, d) }
            }
            guard let best else { break }
            let inliers = remaining.filter { fits($0, best.normal, best.offset) }
            guard inliers.reduce(Float(0), { $0 + area[$1] }) >= minimumArea else { break }
            // Reajuste: normal media (con el signo alineado) y distancia media.
            let normal = simd_normalize(inliers.reduce(SIMD3<Float>.zero) {
                let n = normals[$1]!
                return $0 + (simd_dot(n, best.normal) < 0 ? -n : n)
            })
            let offset = inliers.reduce(Float(0)) { $0 + simd_dot(normal, positions[$1]) } / Float(inliers.count)
            found.append(Plane(normal: normal, offset: offset, inliers: inliers))
            let taken = Set(inliers)
            remaining.removeAll { taken.contains($0) }
        }
        return found
    }

    /// Quita la geometría que está más de `depth` metros al otro lado de un límite de la habitación (la pared más
    /// exterior en cada dirección, el suelo o el techo) desde donde estuvo el iPhone, y dentro del contorno de ese límite.
    static func removePhantoms(positions: [SIMD3<Float>], indices: [UInt32], cameras: [SIMD3<Float>], depth: Float = 0.3)
        -> (positions: [SIMD3<Float>], indices: [UInt32], removed: Int) {
        guard cameras.count >= 3, !indices.isEmpty else { return (positions, indices, 0) }
        struct Boundary { var outward: SIMD3<Float>; var offset: Float; var inliers: [Int] }

        var candidates = [Boundary]()
        for plane in planes(positions: positions, indices: indices) {
            let vertical = abs(plane.normal.y) < sin(Float.pi / 12)      // < 15° de inclinación
            let horizontal = abs(plane.normal.y) > cos(Float.pi * 5 / 36) // < 25°: suelo, techo
            guard vertical || horizontal else { continue }
            // Límite = el iPhone siempre estuvo del mismo lado (≥ 96 % de las fotos).
            let sides = cameras.map { simd_dot(plane.normal, $0) - plane.offset }
            let front = sides.filter { $0 > 0 }.count
            guard max(front, cameras.count - front) * 100 >= cameras.count * 96 else { continue }
            let sign: Float = front * 2 >= cameras.count ? 1 : -1
            candidates.append(Boundary(outward: -sign * plane.normal, offset: -sign * plane.offset, inliers: plane.inliers))
        }
        // Solo el más exterior en cada dirección: el frente de un armario no es una pared, lo de detrás es real.
        let boundaries = candidates.filter { c in
            !candidates.contains { o in simd_dot(o.outward, c.outward) > cos(Float.pi / 9) && o.offset > c.offset + 0.05 }
        }

        var phantom = [Bool](repeating: false, count: positions.count)
        for boundary in boundaries {
            let n = boundary.outward
            let u = simd_normalize(simd_cross(n, abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0))), w = simd_cross(n, u)
            let hull = convexHull(boundary.inliers.map { SIMD2(simd_dot(positions[$0], u), simd_dot(positions[$0], w)) })
            guard hull.count >= 3 else { continue }
            for (i, p) in positions.enumerated() where !phantom[i] && simd_dot(n, p) - boundary.offset > depth {
                phantom[i] = contains(hull, SIMD2(simd_dot(p, u), simd_dot(p, w)))
            }
        }
        let removed = phantom.filter { $0 }.count
        // Más del 15 % no son reflejos: algo no cuadra (p. ej. poses raras). Mejor no tocar nada.
        guard removed > 0, removed * 100 <= positions.count * 15 else { return (positions, indices, 0) }

        var newIndex = [Int](repeating: -1, count: positions.count)
        var outPositions = [SIMD3<Float>](), outIndices = [UInt32]()
        for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let triangle = indices[t..<t + 3].map(Int.init)
            guard !triangle.contains(where: { phantom[$0] }) else { continue }
            for v in triangle {
                if newIndex[v] < 0 { newIndex[v] = outPositions.count; outPositions.append(positions[v]) }
                outIndices.append(UInt32(newIndex[v]))
            }
        }
        return (outPositions, outIndices, removed)
    }

    /// Envolvente convexa (cadena monótona de Andrew), en sentido antihorario.
    static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower = [SIMD2<Float>](), upper = [SIMD2<Float>]()
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func contains(_ hull: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) < 0 { return false }
        }
        return true
    }
}

/// Generador pseudoaleatorio con semilla: RANSAC reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
