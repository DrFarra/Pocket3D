# El splat exportado (keepCrs) debe estar en las coordenadas reales de la escena: el cubo ocupa [-0.5, 0.5]³.
import sys
import numpy as np

data = open(sys.argv[1], "rb").read()
end = data.index(b"end_header\n") + len(b"end_header\n")
header = data[:end].decode()
count = int(next(l.split()[2] for l in header.splitlines() if l.startswith("element vertex")))
floats = sum(1 for l in header.splitlines() if l.startswith("property float"))
xyz = np.frombuffer(data[end:end + count * floats * 4], dtype="<f4").reshape(count, floats)[:, :3]
inside = (np.abs(xyz) < 0.75).all(axis=1).mean()
print(f"{count} gaussianas, {inside:.1%} dentro del cubo (margen 0,25)")
assert inside > 0.9, "el splat no está en las coordenadas de la escena"
