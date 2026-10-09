// Pruebas de MeshColor.swift en macOS (mismos ModelIO/SceneKit que iOS):
//   swiftc Pocket3D/MeshColor.swift Pocket3D/Reflections.swift Tests/main.swift -o meshcheck && ./meshcheck
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FALLO: \(message)"); exit(1) }
    print("ok: \(message)")
}

// Vista 100×100 en el origen mirando a -Z; mitad superior verde, inferior roja; pared a 2 m.
func view(color: (Int) -> SIMD3<UInt8>, transform: simd_float4x4 = matrix_identity_float4x4) -> ColorView {
    var rgba = [UInt8]()
    for y in 0..<100 { for _ in 0..<100 { let c = color(y); rgba += [c.x, c.y, c.z, 255] } }
    return ColorView(worldToCamera: transform.inverse, fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100,
                     rgba: rgba, depthMM: [UInt16](repeating: 2000, count: 64 * 48), depthWidth: 64, depthHeight: 48)
}
let split = view { $0 < 50 ? [0, 255, 0] : [255, 0, 0] }

check(MeshColor.color(of: [0, -0.5, -2], in: [split]) == [255, 0, 0], "punto bajo en la pared toma rojo (imagen con Y hacia abajo)")
check(MeshColor.color(of: [0, 0.5, -2], in: [split]) == [0, 255, 0], "punto alto en la pared toma verde")
check(MeshColor.color(of: [0, 0, -3], in: [split]) == nil, "punto tapado por la pared (3 m tras pared a 2 m) no se colorea")
check(MeshColor.color(of: [0, 0, 2], in: [split]) == nil, "punto detrás de la cámara no se colorea")
check(MeshColor.color(of: [5, 0, -2], in: [split]) == nil, "punto fuera de la imagen no se colorea")
let blue = view { _ in [0, 0, 255] }
let gray100 = view { _ in [100, 100, 100] }, gray110 = view { _ in [110, 110, 110] }
check(MeshColor.color(of: [0, -0.5, -2], in: [gray100, gray110]) == [105, 105, 105], "mezcla las vistas que ven el punto")
check(MeshColor.color(of: [0, -0.5, -2], normal: [0, 0, 1], in: [split]) == [255, 0, 0], "superficie de frente se colorea")
check(MeshColor.color(of: [0, -0.5, -2], normal: [1, 0, 0], in: [split]) == nil, "superficie vista de canto no se colorea")
check(MeshColor.color(of: [0.97, 0, -2], in: [split]) == nil, "el borde de la foto no se usa")
check(MeshColor.color(of: [0, -0.5, -2], in: [split, blue], blend: 1) == [0, 0, 255], "con blend 1 gana la vista más reciente")
check(MeshColor.color(of: [0, -0.5, -2], in: [split] + Array(repeating: blue, count: 4)) == [0, 0, 255],
      "un color que solo da una foto, mucho más claro que el resto, se descarta")
// Brillo de una lámpara en una foto: más claro que la mediana del punto → fuera.
let gray104 = view { _ in [104, 104, 104] }, highlight = view { _ in [240, 240, 235] }
check(MeshColor.color(of: [0, -0.5, -2], in: [gray100, gray104, highlight]) == [102, 102, 102], "un brillo especular no tiñe el color")
// Píxel quemado (255): no dice nada del color real.
let burnt = view { _ in [255, 255, 255] }, gray90 = view { _ in [90, 90, 90] }
check(MeshColor.color(of: [0, -0.5, -2], in: [burnt, gray90]) == [90, 90, 90], "un píxel quemado se ignora")
// Exposición: la misma pared vista por una foto clara (100) y otra oscura (50) queda uniforme al corregir cada foto.
let bright = view { _ in [100, 100, 100] }, dark = view { _ in [50, 50, 50] }
let wall = (0..<2_500).map { i in SIMD3<Float>(Float(i % 50) / 50 - 0.5, Float(i / 50) / 50 - 0.5, -2) }
let corrected = MeshColor.colors(of: wall, in: [bright, dark])
check(corrected.allSatisfy { abs(Int($0.x) - 75) <= 2 }, "exposición distinta entre fotos se compensa (\(corrected[0]))")
var moved = matrix_identity_float4x4
moved.columns.3 = [0, 0, 1, 1]   // cámara 1 m más atrás: la pared queda a 3 m, la profundidad dice 2 m
check(MeshColor.color(of: [0, -0.5, -2], in: [split, view(color: { _ in [0, 0, 255] }, transform: moved)]) == [255, 0, 0],
      "una vista cuya profundidad no cuadra se descarta y se usa la anterior")

// El coloreado en paralelo da lo mismo que punto a punto (10 000 puntos → varios bloques e hilos).
let many = (0..<10_000).map { i in SIMD3<Float>(Float(i % 100) / 100 - 0.5, Float(i / 100) / 100 - 0.5, -2) }
let parallel = MeshColor.colors(of: many, in: [split])
check(parallel == many.map { MeshColor.color(of: $0, in: [split]) ?? MeshColor.unseen }, "colorear en paralelo = colorear uno a uno")

// Vértices sin foto limpia toman el color de sus vecinos por los triángulos; los aislados quedan grises.
var gaps: [SIMD3<UInt8>?] = [[200, 0, 0], nil, nil, [0, 0, 100], nil]
MeshColor.fillGaps(&gaps, indices: [0, 1, 3, 1, 2, 3])
check(gaps[1] == [66, 0, 66] && gaps[2] == [0, 0, 100] && gaps[4] == nil, "rellenar huecos con el promedio de los vecinos")

// GLB para Blender: cabecera, bloques alineados a 4 y vistas que cubren el binario (el formato lo verificó Blender 5.0).
let glb = try! MeshColor.glbData(positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], colors: [[255, 0, 0], [0, 255, 0], [0, 0, 255]], indices: [0, 1, 2])
func word(_ at: Int) -> Int { Int(glb[at]) | Int(glb[at + 1]) << 8 | Int(glb[at + 2]) << 16 | Int(glb[at + 3]) << 24 }
let jsonLength = word(12)
let gltf = try! JSONSerialization.jsonObject(with: glb[20..<20 + jsonLength]) as! [String: Any]
let views = gltf["bufferViews"] as! [[String: Int]]
check(word(0) == 0x4654_6C67 && word(8) == glb.count && jsonLength % 4 == 0 && word(20 + jsonLength) % 4 == 0, "GLB: cabecera y bloques válidos")
check(views.map { $0["byteLength"]! } == [36, 12, 12] && word(20 + jsonLength) == 60, "GLB: posiciones, colores RGBA e índices en el binario")

var shifted = matrix_identity_float4x4
shifted.columns.3 = [10, 0, 0, 1]
let box = MeshColor.boxes([(shifted, [2, 4, 6], [1, 2, 3])])
check(box.positions.count == 8 && box.indices.count == 36 && box.positions.contains([11, 2, 3]) && box.positions.contains([9, -2, -3])
      && Set(box.indices).count == 8, "caja de RoomPlan: 8 esquinas en su sitio y 12 triángulos")

// Limpieza: dos bloques con el borde duplicado se sueldan en uno; un triángulo suelto (ruido) se va.
let blockA: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0]], blockB: [SIMD3<Float>] = [[1, 0, 0], [1, 1, 0], [0, 1, 0]]
let speck: [SIMD3<Float>] = [[5, 5, 5], [5.1, 5, 5], [5, 5.1, 5]]
let cleaned = MeshColor.clean(positions: blockA + blockB + speck, indices: [0, 1, 2, 3, 4, 5, 6, 7, 8], minimumTriangles: 2)
check(cleaned.positions.count == 4 && cleaned.indices.count == 6, "soldar bloques de ARKit y quitar fragmentos sueltos")
check(MeshColor.clean(positions: speck, indices: [0, 1, 2]).indices.count == 3, "nunca se borra la pieza más grande")
let normals = MeshColor.normals(of: blockA, indices: [0, 1, 2])
check(normals[0].map { abs($0.z) > 0.99 } == true, "normal del triángulo en el plano XY = eje Z")

// Splat: se quitan las gaussianas lejos de la superficie, pero nunca más de la mitad.
func splatPLY(_ points: [SIMD3<Float>]) -> URL {
    var data = Data("ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty float opacity\nend_header\n".utf8)
    for p in points { for f in [p.x, p.y, p.z, 1] { withUnsafeBytes(of: f) { data.append(contentsOf: $0) } } }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ply")
    try! data.write(to: url)
    return url
}
let surface = MeshColor.occupiedCells([[0, 0, 0], [1, 0, 0]], cell: 0.15)
let splat = splatPLY([[0.05, 0, 0], [1.1, 0.1, 0], [0.5, 3, 0]])
check((try? MeshColor.pruneSplat(at: splat, near: surface, cell: 0.15)) == 1, "quita la gaussiana flotante")
let pruned = try! Data(contentsOf: splat)
check(String(decoding: pruned.prefix(80), as: UTF8.self).contains("element vertex 2\n") && pruned.count == 138 + 2 * 16, "PLY reescrito con 2 gaussianas")
let lost = splatPLY([[9, 9, 9], [8, 8, 8], [0, 0, 0]])
check((try? MeshColor.pruneSplat(at: lost, near: surface, cell: 0.15)) == 0, "si quitaría más de la mitad, no toca nada")

// Nitidez: un tablero de ajedrez nítido supera al mismo tablero desenfocado.
func board(blur: Bool) -> [UInt8] {
    var out = [UInt8]()
    for y in 0..<64 { for x in 0..<64 {
        let v: UInt8 = blur ? UInt8(128 + 60 * sin(Float(x) * .pi / 8)) : ((x / 8 + y / 8) % 2 == 0 ? 255 : 0)
        out += [v, v, v, 255]
    } }
    return out
}
check(MeshColor.sharpness(rgba: board(blur: false), width: 64, height: 64) > 10 * MeshColor.sharpness(rgba: board(blur: true), width: 64, height: 64),
      "una foto nítida mide más nitidez que una movida")

// Reflejos: habitación de 4×4 m con suelo, cuatro paredes y techo; un espejo en la pared del fondo crea una caja fantasma
// 1 m detrás de ella y un suelo brillante, patas fantasma bajo el suelo. Un armario (frente de 2 m²) tiene cosas reales detrás.
func grid(_ origin: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ n: Int = 20) -> (p: [SIMD3<Float>], i: [UInt32]) {
    var p = [SIMD3<Float>](), i = [UInt32]()
    for a in 0...n { for b in 0...n { p.append(origin + u * Float(a) / Float(n) + v * Float(b) / Float(n)) } }
    for a in 0..<n { for b in 0..<n {
        let k = UInt32(a * (n + 1) + b)
        i += [k, k + UInt32(n + 1), k + 1, k + 1, k + UInt32(n + 1), k + UInt32(n + 2)]
    } }
    return (p, i)
}
func cube(_ low: SIMD3<Float>, _ size: SIMD3<Float>) -> [(p: [SIMD3<Float>], i: [UInt32])] {
    let (x, y, z) = (SIMD3<Float>(size.x, 0, 0), SIMD3<Float>(0, size.y, 0), SIMD3<Float>(0, 0, size.z))
    return [grid(low, x, y, 4), grid(low + z, x, y, 4), grid(low, z, y, 4), grid(low + x, z, y, 4), grid(low + y, x, z, 4)]
}
var room: (p: [SIMD3<Float>], i: [UInt32]) = ([], [])
func add(_ parts: [(p: [SIMD3<Float>], i: [UInt32])]) {
    for part in parts { let base = UInt32(room.p.count); room.p += part.p; room.i += part.i.map { $0 + base } }
}
add([grid([-2, 0, -2], [4, 0, 0], [0, 0, 4]),                 // suelo
     grid([-2, 2.5, -2], [4, 0, 0], [0, 0, 4]),               // techo
     grid([-2, 0, -2], [4, 0, 0], [0, 2.5, 0]),               // pared del fondo (z = -2), con el espejo
     grid([-2, 0, 2], [4, 0, 0], [0, 2.5, 0]),
     grid([-2, 0, -2], [0, 0, 4], [0, 2.5, 0]),
     grid([2, 0, -2], [0, 0, 4], [0, 2.5, 0]),
     grid([1, 0, -1.2], [0.9, 0, 0], [0, 2.2, 0])])           // frente del armario (z = -1.2)
add(cube([1.2, 0, -1.9], [0.5, 0.6, 0.4]))                     // caja real detrás del armario
add(cube([-0.5, 0.2, -3.4], [0.8, 0.8, 0.8]))                  // fantasma del espejo: 1,4 m tras la pared
add(cube([-1, -0.9, 0], [0.3, 0.6, 0.3]))                      // fantasma del suelo brillante
let cameras = (0..<12).map { k in SIMD3<Float>(cos(Float(k) * .pi / 6), 1.5, 0.5 + sin(Float(k) * .pi / 6)) }
let cleanRoom = Reflections.removePhantoms(positions: room.p, indices: room.i, cameras: cameras)
check(!cleanRoom.positions.contains { $0.z < -2.5 }, "espejo: la habitación fantasma tras la pared se quita")
check(!cleanRoom.positions.contains { $0.y < -0.5 }, "suelo brillante: los reflejos bajo el suelo se quitan")
check(cleanRoom.positions.contains { $0.z < -1.5 && $0.z > -1.95 && $0.x > 1.1 && $0.y > 0.1 }, "lo real detrás del armario se queda")
check(cleanRoom.positions.contains { $0.z <= -1.99 } && cleanRoom.positions.contains { abs($0.y) < 0.01 }, "paredes y suelo se quedan")
let lookingOut = (0..<12).map { k in SIMD3<Float>(Float(k), 1.5, 5) }   // fachada vista desde fuera: no hay «habitación»
check(Reflections.removePhantoms(positions: room.p, indices: room.i, cameras: lookingOut).removed <= cleanRoom.removed,
      "con el iPhone fuera, no quita más que con él dentro")
check(Reflections.convexHull([[0, 0], [1, 0], [1, 1], [0, 1], [0.5, 0.5]]).count == 4, "envolvente convexa")

// PLY coloreado → ModelIO → SceneKit (lo que hace el visor de la app).
let positions: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0]]
let colors: [SIMD3<UInt8>] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocket3d-check.ply")
try MeshColor.plyData(positions: positions, colors: colors, indices: [0, 1, 2, 2, 1, 3]).write(to: url)

let asset = MDLAsset(url: url)
check(asset.count == 1, "ModelIO lee el PLY")
let mesh = asset.object(at: 0) as! MDLMesh
check(mesh.vertexCount == 4, "4 vértices")
let colorAttribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor)
check(colorAttribute != nil, "ModelIO conserva el color por vértice")

let scene = SCNScene(mdlAsset: asset)
var geometries = [SCNGeometry]()
scene.rootNode.enumerateHierarchy { node, _ in if let g = node.geometry { geometries.append(g) } }
check(geometries.count == 1, "SceneKit crea la geometría")
check(!geometries[0].sources(for: .color).isEmpty, "SceneKit recibe los colores por vértice")
check(geometries[0].elements.first?.primitiveCount == 2, "2 triángulos")

check(!MeshColor.isGaussianSplatPLY(url), "un PLY de malla no se confunde con un splat")
let splatURL = FileManager.default.temporaryDirectory.appendingPathComponent("pocket3d-splat.ply")
try Data("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float f_dc_0\nend_header\n".utf8).write(to: splatURL)
check(MeshColor.isGaussianSplatPLY(splatURL), "un PLY de Gaussian splat se detecta")
print("TODO OK")
