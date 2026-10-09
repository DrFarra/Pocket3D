# Escena sintética con el formato exacto que guarda Pocket3D (Dataset.swift + MeshColor.plyData):
# un cubo con textura de cuadros fotografiado desde 24 posiciones, poses en convención ARKit/OpenGL.
import json, struct, sys
from pathlib import Path
import numpy as np
from PIL import Image

root = Path(sys.argv[1]); (root / "images").mkdir(parents=True, exist_ok=True)
W, H, f = 160, 120, 140.0
faces_col = np.array([[230, 60, 60], [60, 200, 90], [60, 90, 230], [240, 200, 40], [200, 60, 220], [40, 210, 220]], float)

def render(c2w):
    u, v = np.meshgrid(np.arange(W) + 0.5, np.arange(H) + 0.5)
    d = np.stack([(u - W / 2) / f, -(v - H / 2) / f, -np.ones_like(u)], -1) @ c2w[:3, :3].T
    o = c2w[:3, 3]
    with np.errstate(divide="ignore", invalid="ignore"):
        t1, t2 = (-0.5 - o) / d, (0.5 - o) / d
    tmin, tmax = np.minimum(t1, t2).max(-1), np.maximum(t1, t2).min(-1)
    hit = (tmax >= tmin) & (tmax > 0)
    p = o + d * tmin[..., None]
    axis = np.abs(p).argmax(-1); sign = np.take_along_axis(p, axis[..., None], -1)[..., 0] > 0
    col = faces_col[axis * 2 + sign]
    checker = ((np.floor(p[..., 0] * 8) + np.floor(p[..., 1] * 8) + np.floor(p[..., 2] * 8)) % 2)[..., None]
    img = np.where(hit[..., None], col * (0.55 + 0.45 * checker), 25)
    return img.clip(0, 255).astype(np.uint8)

frames = []
for i in range(24):
    a, el = 2 * np.pi * i / 24, 0.35 if i % 2 else -0.15
    eye = 2.2 * np.array([np.cos(el) * np.sin(a), np.sin(el), np.cos(el) * np.cos(a)])
    z = eye / np.linalg.norm(eye); x = np.cross([0, 1, 0], z); x /= np.linalg.norm(x); y = np.cross(z, x)
    m = np.eye(4); m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = x, y, z, eye
    Image.fromarray(render(m)).save(root / f"images/{i:05d}.jpg", quality=92)
    frames.append({"file_path": f"images/{i:05d}.jpg", "transform_matrix": m.tolist(),
                   "fl_x": f, "fl_y": f, "cx": W / 2, "cy": H / 2, "w": W, "h": H})

# Nube inicial: puntos de la superficie del cubo con su color, como la malla LiDAR en color.
rng = np.random.default_rng(0); pts = rng.uniform(-0.5, 0.5, (3000, 3))
ax = rng.integers(0, 3, 3000); pts[np.arange(3000), ax] = np.sign(rng.uniform(-1, 1, 3000)) * 0.5
cols = faces_col[ax * 2 + (pts[np.arange(3000), ax] > 0)].astype(np.uint8)
header = ("ply\nformat binary_little_endian 1.0\nelement vertex %d\nproperty float x\nproperty float y\nproperty float z\n"
          "property uchar red\nproperty uchar green\nproperty uchar blue\nelement face 0\n"
          "property list uchar int vertex_indices\nend_header\n") % len(pts)
body = b"".join(struct.pack("<fffBBB", *p, *c) for p, c in zip(pts.astype(np.float32), cols))
(root / "mesh.ply").write_bytes(header.encode() + body)
json.dump({"camera_model": "OPENCV", "frames": frames, "ply_file_path": "mesh.ply"}, open(root / "transforms.json", "w"))
print("dataset listo:", root)
