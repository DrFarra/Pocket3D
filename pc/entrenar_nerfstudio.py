#!/usr/bin/env python3
"""Entrena un Gaussian splat con nerfstudio y deja el .ply donde lo pide Pocket3D PC.

    python pocket3d_pc.py --al-terminar "python entrenar_nerfstudio.py {datos} {salida}"

Usa las poses de ARKit tal cual (sin reorientar, centrar ni escalar), así el splat sale en metros y con
Y hacia arriba, igual que lo que ve la app. Requiere nerfstudio con PyTorch para CUDA 12.8+ (RTX 50); ver PC.md.
"""
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    data, out = Path(sys.argv[1]), Path(sys.argv[2])
    steps = sys.argv[3] if len(sys.argv) > 3 else "15000"
    runs = data / "nerfstudio"
    subprocess.run(["ns-train", "splatfacto", "--data", str(data), "--output-dir", str(runs),
                    "--max-num-iterations", steps, "--viewer.quit-on-train-completion", "True",
                    "nerfstudio-data", "--load-3D-points", "True", "--orientation-method", "none",
                    "--center-method", "none", "--auto-scale-poses", "False"], check=True)
    configs = sorted(runs.glob("**/config.yml"), key=lambda p: p.stat().st_mtime)
    if not configs:
        sys.exit("nerfstudio no dejó config.yml")
    export = data / "export"
    subprocess.run(["ns-export", "gaussian-splat", "--load-config", str(configs[-1]), "--output-dir", str(export)], check=True)
    shutil.copy(export / "splat.ply", out)
    print(f"Splat listo: {out}")


if __name__ == "__main__":
    main()
