"""Fusión del modo PC con una escena sintética de pose y profundidad exactas: python pc/test_fusion.py
(necesita numpy, open3d y pillow). Comprueba sobre todo el cambio de convención ARKit → Open3D: si estuviera mal,
la caja saldría espejada, girada o no se fusionaría."""
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import fusion

W, H, DW, DH, F = 1920, 1440, 256, 192, 1400.0   # foto, profundidad y focal como las del iPhone


def look_at(eye, target):
    """Pose cámara→mundo con el convenio de ARKit (columnas: derecha, arriba, atrás, posición)."""
    back = eye - target
    back /= np.linalg.norm(back)
    right = np.cross([0, 1, 0], back)
    right /= np.linalg.norm(right)
    up = np.cross(back, right)
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = right, up, back, eye
    return m


def render_depth(pose):
    """Profundidad (a lo largo del eje óptico) de un suelo y = 0 y una caja de 1 m centrada en (0.3, 0.5, -0.2)."""
    s = DW / W
    fx, cx, cy = F * s, DW / 2, DH / 2
    u, v = np.meshgrid(np.arange(DW) + 0.5, np.arange(DH) + 0.5)
    # Rayo en cámara OpenGL: x derecha, y arriba, mira a -z.
    d_cam = np.stack([(u - cx) / fx, -(v - cy) / fx, -np.ones_like(u)], -1)
    d = d_cam @ pose[:3, :3].T
    o = pose[:3, 3]
    t = np.full(u.shape, np.inf)
    floor = -o[1] / np.where(np.abs(d[..., 1]) < 1e-9, 1e-9, d[..., 1])
    t = np.where(floor > 0, floor, t)
    lo, hi = np.array([-0.2, 0.0, -0.7]), np.array([0.8, 1.0, 0.3])
    inv = 1 / np.where(np.abs(d) < 1e-9, 1e-9, d)
    t0, t1 = (lo - o) * inv, (hi - o) * inv
    near, far = np.minimum(t0, t1).max(-1), np.maximum(t0, t1).min(-1)
    box = (near < far) & (near > 0)
    t = np.where(box & (near < t), near, t)
    z = t * 1.0   # |d_cam.z| = 1: t ya es la profundidad sobre el eje
    mm = np.where(np.isfinite(z) & (z < 5), z * 1000, 0)
    return mm.astype(np.uint16)


class FusionTest(unittest.TestCase):
    def test_box_on_floor(self):
        folder = Path(tempfile.mkdtemp())
        (folder / "images").mkdir()
        (folder / "depth").mkdir()
        live = fusion.Fusion(folder, every=0.2)
        for k in range(24):
            a = 2 * np.pi * k / 24
            pose = look_at(np.array([0.3 + 2.5 * np.cos(a), 1.4, -0.2 + 2.5 * np.sin(a)]), np.array([0.3, 0.5, -0.2]))
            name = f"{k:05d}"
            Image.fromarray(render_depth(pose)).save(folder / "depth" / f"{name}.png")
            Image.new("RGB", (640, 480), (200, 40, 40)).save(folder / "images" / f"{name}.jpg")
            live.add({"file_path": f"images/{name}.jpg", "depth_file_path": f"depth/{name}.png",
                      "transform_matrix": pose.tolist(), "fl_x": F, "fl_y": F, "cx": W / 2, "cy": H / 2, "w": W, "h": H})
        # Una subida cortada por la WiFi: se descarta sin tumbar el programa (open3d abortaría desde C++).
        (folder / "depth" / "99999.png").write_bytes(b"png a medias")
        live.add({"file_path": "images/99999.jpg", "depth_file_path": "depth/99999.png",
                  "transform_matrix": np.eye(4).tolist(), "fl_x": F, "fl_y": F, "cx": W / 2, "cy": H / 2, "w": W, "h": H})
        live.wait()
        live.publish()
        self.assertGreater(live.version, 0)
        self.assertEqual(live.failed, 1)

        # Malla en vivo, en el formato que lee el iPhone.
        data = (folder / "preview.bin").read_bytes()
        nv, ni = struct.unpack("<II", data[:8])
        p = np.frombuffer(data[8:8 + nv * 12], "<f4").reshape(-1, 3)
        self.assertEqual(len(data), 8 + nv * 12 + ni * 4)
        top = p[(p[:, 1] > 0.9) & (p[:, 1] < 1.1)]
        self.assertGreater(len(top), 20, "no aparece la tapa de la caja a 1 m")
        # La tapa está donde está la caja (no espejada): x en [-0.2, 0.8], z en [-0.7, 0.3].
        self.assertTrue(np.all((top[:, 0] > -0.3) & (top[:, 0] < 0.9) & (top[:, 2] > -0.8) & (top[:, 2] < 0.4)), top[:5])
        self.assertAlmostEqual(float(np.median(top[:, 0])), 0.3, delta=0.15)
        self.assertAlmostEqual(float(np.median(top[:, 2])), -0.2, delta=0.15)

        # Malla final: más fina, con color y a escala.
        final = live.final()
        import open3d as o3d
        mesh = o3d.io.read_triangle_mesh(str(final))
        v = np.asarray(mesh.vertices)
        side = v[(np.abs(v[:, 0] - 0.8) < 0.03) & (v[:, 1] > 0.2) & (v[:, 1] < 0.8)]
        self.assertGreater(len(side), 50, "falta la cara de la caja en x = 0,8")
        self.assertTrue(mesh.has_vertex_colors())
        red = np.asarray(mesh.vertex_colors)[(v[:, 1] > 0.95)]
        self.assertGreater(red[:, 0].mean(), 0.6, "el color de las fotos no llegó a la malla")
        # GLB del visor web válido.
        glb = (folder / "fused.glb").read_bytes()
        self.assertEqual(struct.unpack("<I", glb[:4])[0], 0x46546C67)
        self.assertEqual(struct.unpack("<I", glb[8:12])[0], len(glb))


if __name__ == "__main__":
    unittest.main()
