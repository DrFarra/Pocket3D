# Procesar escaneos en el PC (Windows + RTX 5070)

En el iPhone, Apple solo permite fotogrametría en calidad reducida y no tiene API para Gaussian splats. Tu RTX 5070 hace la versión de calidad máxima.

## 1. Objeto → malla texturizada de alta calidad: RealityScan (gratis)

1. Descarga **RealityScan** (antes RealityCapture) desde el Epic Games Launcher. Gratis para particulares y empresas con menos de 1 M$ de ingresos.
2. Descomprime `… Objeto fotos.zip`.
3. *Inputs* → la carpeta de fotos → **Align Images** → **Calculate Model** (High) → **Simplify** si es muy pesado → **Texture** → **Export** (OBJ/FBX/GLB).
4. Escala: el modelo sale en unidades arbitrarias; coloca un *distance constraint* entre dos puntos de medida conocida (o usa el USDZ del iPhone, que ya está a escala, como referencia).

Resultado: millones de polígonos y texturas 8K/16K, apto para impresión 3D o CAD.

## 2. Cualquier cosa → Gaussian splat fotorrealista: Postshot (fácil)

1. Instala **[Jawset Postshot](https://www.jawset.com)** (Windows + NVIDIA).
2. Descomprime el zip (`Objeto fotos` o `Espacio dataset`) y arrastra la carpeta `images` (o las fotos) a Postshot.
3. Perfil *Splat3*, entrena hasta ~30k pasos (minutos en una RTX 5070).
4. Exporta `.ply` (o `.spz` para web). Para verlo/compartirlo: [SuperSplat](https://superspl.at/editor) en el navegador.

Postshot calcula sus propias poses, así que funciona con cualquiera de los dos zips.

## 3. Espacio → splat usando las poses de ARKit y la profundidad LiDAR: nerfstudio (avanzado)

El zip `… Espacio dataset.zip` trae `transforms.json` en formato **nerfstudio**: no hace falta COLMAP, ya lleva la pose de cada foto (ARKit), sus intrínsecos y un mapa de profundidad LiDAR en mm (`depth/*.png`, 0 = sin dato fiable).

Recomendado en **WSL2 (Ubuntu)** con el driver NVIDIA de Windows actualizado. Las RTX 50 (Blackwell) necesitan PyTorch compilado para **CUDA 12.8 o superior**:

```bash
conda create -n ns python=3.10 -y && conda activate ns
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install nerfstudio
# descomprime el dataset en ~/scan
ns-train splatfacto --data ~/scan            # splat con las poses de ARKit
ns-train depth-nerfacto --data ~/scan        # alternativa NeRF que usa también la profundidad LiDAR
ns-export gaussian-splat --load-config outputs/*/splatfacto/*/config.yml --output-dir export/
```

Si las poses de ARKit han derivado (escaneos muy grandes), Postshot (opción 2) recalcula las poses y suele dar mejor resultado.

## ¿Qué uso?

| Quiero… | Herramienta |
|---------|-------------|
| Imprimir en 3D / CAD / medir un objeto | RealityScan con `Objeto fotos.zip` |
| Que se vea como una foto, desde cualquier ángulo | Postshot con cualquiera de los zips |
| Medidas de una estancia | El USDZ de Habitación (RoomPlan) |
| Malla a escala de una fachada o terreno | El USDZ/OBJ de Espacio (directo del iPhone) |
