# Procesar escaneos en el PC (Windows + RTX 5070)

En el iPhone, Apple solo permite fotogrametría en calidad reducida y no tiene API para Gaussian splats. Tu RTX 5070 hace la versión de calidad máxima.

## 0. En vivo: el iPhone le manda el escaneo al PC mientras escaneas

1. Instala **Python** desde [python.org](https://www.python.org/downloads/) (marca *Add python.exe to PATH*).
2. Copia la carpeta [`pc`](pc) de este repositorio a tu PC y haz **doble clic en `Pocket3D PC.bat`**. Si Windows pregunta por el firewall, permite el acceso en **redes privadas**.
3. En la app, arriba a la izquierda, **PC**: aparece solo (o escribe la IP que muestra la ventana). iPhone y PC en la misma WiFi.
4. Escanea en modo **Espacio**: en `http://localhost:8765` ves la malla crecer y el recorrido de la cámara en tiempo real. Cada foto con su pose y profundidad LiDAR se guarda en `Documentos\..\Pocket3D\<fecha>` ya en formato nerfstudio (`transforms.json` siempre al día).
5. Al pulsar *Guardar* en el iPhone, el PC puede procesarlo solo y devolver el resultado a la app («Espacio PC splat»). Para eso arranca el servidor con un comando:

```bat
"Pocket3D PC.bat" --al-terminar "python entrenar_nerfstudio.py {datos} {salida}"
```

`entrenar_nerfstudio.py` entrena con nerfstudio (sección 3) usando las poses de ARKit tal cual, así el splat sale a escala y derecho. Sirve cualquier otro programa: `{datos}` es la carpeta del escaneo y `{salida}` el `.ply` que vuelve al iPhone. Sin `--al-terminar`, el dataset queda listo en la carpeta para Postshot o RealityScan.

### Modo PC: tu PC calcula, el iPhone captura

En la app, el modo **Modo PC** usa el iPhone solo como sensor (cámara, LiDAR y posición). Tu PC fusiona cada foto con su profundidad en una malla 3D (TSDF, como los escáneres profesionales) y se la devuelve en vivo: la ves **en celeste sobre la cámara**, quieta sobre lo escaneado aunque te muevas. Lo pintado ya está; donde no hay malla, falta. Al guardar, el PC calcula la malla final (1 cm en objetos, 2 cm en espacios grandes) y vuelve a «Mis escaneos» como «Espacio PC malla».

Necesita **Python 3.12** (el motor 3D, open3d 0.19, no existe aún para 3.13) — `Pocket3D PC.bat` lo instala solo. La versión 0.20 de open3d tiene un fallo que deja la malla vacía: por eso va fijada la 0.19.

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

El zip `… Espacio dataset.zip` trae `transforms.json` en formato **nerfstudio**: no hace falta COLMAP, ya lleva la pose de cada foto (ARKit), sus intrínsecos, un mapa de profundidad LiDAR en mm (`depth/*.png`, 0 = sin dato fiable) y `mesh.ply`, la malla LiDAR en color que `splatfacto` usa como nube inicial (converge antes y con menos "flotadores" que con inicio aleatorio).

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

## 4. Verlo en el iPhone

Pasa el resultado al iPhone (`.ply`/`.spz` del splat, u `.obj` de RealityScan) por Drive/OneDrive o con *Dispositivos Apple* a la carpeta Pocket3D, y en la app pulsa **Importar del PC**. Los splats se ven fotorrealistas en el propio iPhone; si salen torcidos, doble toque.

## ¿Qué uso?

| Quiero… | Herramienta |
|---------|-------------|
| Imprimir en 3D / CAD / medir un objeto | RealityScan con `Objeto fotos.zip` |
| Que se vea como una foto, desde cualquier ángulo | Postshot con cualquiera de los zips |
| Medidas de una estancia | El USDZ de Habitación (RoomPlan) |
| Malla en color a escala de una fachada o terreno | El `Espacio para Blender.glb` (directo del iPhone) o el PLY de Espacio en MeshLab / CloudCompare |
