"""Fusión en tiempo real para el modo PC: cada foto con su profundidad LiDAR y su pose de ARKit se integra en un
volumen TSDF (el método de KinectFusion y de los escáneres de mano profesionales) y de ahí sale la malla.

- En vivo, con vóxeles de 3 cm: una malla ligera que el iPhone dibuja encima de la cámara (lo hecho y lo que falta).
- Al terminar, con vóxeles de 1 cm y todas las fotos: la malla final en color, que vuelve al iPhone.

Necesita numpy y open3d (pip install open3d). Sin ellos, Pocket3D PC funciona igual pero sin fusión.
"""
import queue
import struct
import threading
import time
from pathlib import Path

import numpy as np
import open3d as o3d

# ARKit (y nerfstudio) usan cámara OpenGL: x derecha, y arriba, z hacia atrás. Open3D usa OpenCV: y abajo, z adelante.
GL_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])


def load_rgbd(folder: Path, entry: dict):
    """Foto + profundidad de un fotograma al tamaño de la profundidad, con su intrínseca y extrínseca de Open3D."""
    # Se valida aquí: con una imagen rota (subida cortada por la WiFi) open3d aborta el proceso entero desde C++.
    depth = o3d.io.read_image(str(folder / entry["depth_file_path"]))
    if depth.is_empty():   # mirarla con numpy estando vacía también aborta
        raise ValueError("profundidad ilegible")
    d = np.asarray(depth)
    if d.ndim != 2 or d.dtype != np.uint16 or d.size == 0:
        raise ValueError("profundidad ilegible")
    h, w = d.shape
    color_path = folder / entry["file_path"]
    color = o3d.io.read_image(str(color_path)) if color_path.exists() else None
    c = np.asarray(color) if color is not None and not color.is_empty() else np.zeros(0)
    if c.size and c.dtype == np.uint8 and c.ndim in (2, 3):
        if c.ndim == 2:
            c = np.repeat(c[..., None], 3, axis=2)
        # Al tamaño de la profundidad (vecino más próximo): para fusionar no hace falta más.
        ys = (np.arange(h) * c.shape[0] / h).astype(int)
        xs = (np.arange(w) * c.shape[1] / w).astype(int)
        c = np.ascontiguousarray(c[ys][:, xs, :3])
    else:
        c = np.full((h, w, 3), 160, np.uint8)
    rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
        o3d.geometry.Image(c), depth, depth_scale=1000.0, depth_trunc=5.0, convert_rgb_to_intensity=False)
    s = w / float(entry["w"])
    intrinsic = o3d.camera.PinholeCameraIntrinsic(w, h, entry["fl_x"] * s, entry["fl_y"] * s, entry["cx"] * s, entry["cy"] * s)
    extrinsic = np.linalg.inv(np.array(entry["transform_matrix"], dtype=np.float64) @ GL_TO_CV)
    return rgbd, intrinsic, extrinsic


def volume(voxel: float):
    return o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=voxel, sdf_trunc=voxel * 4, color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8)


def mesh_arrays(mesh):
    positions = np.asarray(mesh.vertices, dtype=np.float32)
    indices = np.asarray(mesh.triangles, dtype=np.uint32)
    colors = (np.clip(np.asarray(mesh.vertex_colors), 0, 1) * 255).astype(np.uint8) if mesh.has_vertex_colors() \
        else np.full((len(positions), 3), 160, np.uint8)
    return positions, colors, indices


def preview_bin(positions: np.ndarray, indices: np.ndarray) -> bytes:
    """Lo que dibuja el iPhone: nº de vértices y de índices (uint32) + posiciones (float32) + índices (uint32)."""
    flat = indices.reshape(-1)
    return struct.pack("<II", len(positions), len(flat)) + positions.astype("<f4").tobytes() + flat.astype("<u4").tobytes()


def glb(positions: np.ndarray, colors: np.ndarray, indices: np.ndarray) -> bytes:
    """GLB con color por vértice para el visor web (mismo formato que la app)."""
    import json
    pos = positions.astype("<f4").tobytes()
    col = np.c_[colors, np.full(len(colors), 255, np.uint8)].astype(np.uint8).tobytes()
    idx = indices.astype("<u4").tobytes()
    binary = pos + col + idx
    doc = {"asset": {"version": "2.0", "generator": "Pocket3D PC"}, "scene": 0, "scenes": [{"nodes": [0]}],
           "nodes": [{"mesh": 0}],
           "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1}, "indices": 2, "material": 0}]}],
           "materials": [{"doubleSided": True, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1}}],
           "buffers": [{"byteLength": len(binary)}],
           "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos)},
                           {"buffer": 0, "byteOffset": len(pos), "byteLength": len(col)},
                           {"buffer": 0, "byteOffset": len(pos) + len(col), "byteLength": len(idx)}],
           "accessors": [{"bufferView": 0, "componentType": 5126, "count": len(positions), "type": "VEC3",
                          "min": positions.min(0).tolist(), "max": positions.max(0).tolist()},
                         {"bufferView": 1, "componentType": 5121, "normalized": True, "count": len(colors), "type": "VEC4"},
                         {"bufferView": 2, "componentType": 5125, "count": len(indices.reshape(-1)), "type": "SCALAR"}]}
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    binary += b"\0" * (-len(binary) % 4)
    return (struct.pack("<III", 0x46546C67, 2, 28 + len(js) + len(binary)) + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


class Fusion:
    """Integra en segundo plano los fotogramas que llegan y publica la malla en vivo cada `every` segundos."""

    def __init__(self, folder: Path, voxel: float = 0.03, every: float = 1.5):
        self.folder = folder
        self.live = volume(voxel)
        self.frames = []
        self.version = 0
        self.every = every
        self.pending = queue.Queue()
        self.lock = threading.Lock()
        self.failed = 0
        threading.Thread(target=self._run, daemon=True).start()

    def add(self, entry: dict):
        if "depth_file_path" in entry:   # sin LiDAR no hay nada que fusionar
            self.pending.put(entry)

    def _run(self):
        dirty, last = False, 0.0
        while True:
            try:
                entry = self.pending.get(timeout=0.3)
                try:
                    with self.lock:
                        self.live.integrate(*load_rgbd(self.folder, entry))
                        self.frames.append(entry)
                    dirty = True
                except Exception:   # un fotograma roto no para el escaneo
                    self.failed += 1
            except queue.Empty:
                pass
            if dirty and time.time() - last > self.every:
                self.publish()
                dirty, last = False, time.time()

    def publish(self):
        with self.lock:
            mesh = self.live.extract_triangle_mesh()
        positions, colors, indices = mesh_arrays(mesh)
        if len(indices) == 0:
            return
        for name, data in (("preview.bin", preview_bin(positions, indices)), ("fused.glb", glb(positions, colors, indices))):
            tmp = self.folder / (name + ".tmp")
            tmp.write_bytes(data)
            tmp.replace(self.folder / name)
        self.version += 1

    def wait(self, timeout: float = 60):
        """Espera a que se integre lo que está en cola."""
        end = time.time() + timeout
        while not self.pending.empty() and time.time() < end:
            time.sleep(0.1)
        time.sleep(0.4)

    def final(self) -> Path | None:
        """Malla final: todas las fotos otra vez, con vóxeles finos (1 cm en objetos, 2 cm en espacios grandes),
        sin los trocitos sueltos y como mucho 1,5 millones de triángulos (que el iPhone la abra con soltura)."""
        self.wait()
        with self.lock:
            frames = list(self.frames)
            extent = np.asarray(self.live.extract_point_cloud().get_axis_aligned_bounding_box().get_extent()) if frames else np.zeros(3)
        fine = volume(0.02 if extent.max() > 3 else 0.01)
        for entry in frames:
            try:
                fine.integrate(*load_rgbd(self.folder, entry))
            except Exception:
                pass
        mesh = fine.extract_triangle_mesh()
        if len(mesh.triangles) == 0:
            return None
        clusters, counts, _ = mesh.cluster_connected_triangles()
        counts = np.asarray(counts)
        mesh.remove_triangles_by_mask(counts[np.asarray(clusters)] < 50)
        mesh.remove_unreferenced_vertices()
        if len(mesh.triangles) > 1_500_000:
            mesh = mesh.simplify_quadric_decimation(1_500_000)
        mesh.compute_vertex_normals()
        # A un temporal y luego el nombre de verdad: el iPhone nunca descarga una malla a medio escribir.
        path, tmp = self.folder / "malla.ply", self.folder / "malla.tmp.ply"
        o3d.io.write_triangle_mesh(str(tmp), mesh, write_ascii=False)
        tmp.replace(path)
        return path
