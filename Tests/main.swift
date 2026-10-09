// Pruebas de MeshColor.swift en macOS (mismos ModelIO/SceneKit que iOS):
//   swiftc Pocket3D/MeshColor.swift Tests/main.swift -o meshcheck && ./meshcheck
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
check(MeshColor.color(of: [0, -0.5, -2], in: [split, blue]) == [127, 0, 127], "mezcla las vistas que ven el punto")
check(MeshColor.color(of: [0, -0.5, -2], in: [split, blue], blend: 1) == [0, 0, 255], "con blend 1 gana la vista más reciente")
check(MeshColor.color(of: [0, -0.5, -2], in: [split] + Array(repeating: blue, count: 4)) == [0, 0, 255], "solo mezcla las 4 más recientes")
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
