# Pocket3D

Escáner 3D para iPhone con LiDAR (pensado para el 17 Pro Max) + procesado de máxima calidad en un PC con GPU NVIDIA. **No hace falta Mac.**

| Modo | En el iPhone (al instante) | Para el PC (calidad máxima) |
|------|----------------------------|-----------------------------|
| **Objeto** | Modelo USDZ texturizado (Object Capture) | `… Objeto fotos.zip`: las fotos JPEG a resolución completa → RealityScan / Postshot |
| **Habitación** | Plano 3D con medidas (RoomPlan, USDZ). Pulsa *Otra habitación* para seguir y unirlas todas en un solo plano de la casa | — |
| **Espacio / estructura** | Malla LiDAR a escala real **en color** (PLY) + **Gaussian splat fotorrealista entrenado en el propio iPhone** (unos minutos; se puede saltar) | `… Espacio dataset.zip`: fotos de alta resolución + pose de ARKit + profundidad LiDAR + nube de color inicial (formato nerfstudio) → Gaussian splats |

## Ver tus escaneos en el iPhone

En «Mis escaneos» toca cualquier escaneo:

- **Objeto (USDZ)**: vista 3D y botón de **realidad aumentada** para ponerlo en tu mesa.
- **Habitación (USDZ) y Espacio (PLY en color)**: visor propio que se abre **por dentro**: estás parado en el centro, arrastra para mirar alrededor y pellizca para avanzar. Arriba eliges *Por fuera* para girarlo como maqueta.
- **Espacio splat**: la versión fotorrealista hecha en el iPhone (motor [msplat](https://github.com/rayanht/msplat) sobre Metal, con las poses de ARKit y la malla LiDAR como punto de partida).
- **Gaussian splats hechos en el PC** (`.ply` / `.spz` / `.splat` de Postshot o nerfstudio): botón **Importar del PC** (arriba a la derecha) y tócalo para verlo fotorrealista en el iPhone. Arrastra para girar, pellizca para zoom y **doble toque** si sale torcido (cambia qué eje es "arriba").
- **Mallas del PC** (`.obj` / `.ply` / `.stl` de RealityScan): igual, con *Importar del PC*.

Todo está también en **Archivos → En mi iPhone → Pocket3D → Scans** (puedes copiar ahí archivos desde Windows con la app *Dispositivos Apple*).

## Instalar en el iPhone sin Mac (desde Windows)

1. En GitHub: pestaña **Actions** → último run verde de **Build** → descarga el artefacto **Pocket3D-ipa** (es un zip; dentro está `Pocket3D.ipa`).
2. Instala en el PC **iTunes** (versión de la web de Apple, no la de Microsoft Store) y **[Sideloadly](https://sideloadly.io)**.
3. Conecta el iPhone por cable, abre Sideloadly, arrastra `Pocket3D.ipa`, pon tu Apple ID y pulsa *Start*.
4. En el iPhone: *Ajustes → General → VPN y gestión de dispositivos* → confía en tu Apple ID; y *Ajustes → Privacidad y seguridad → Modo de desarrollador* → activar (reinicia).

Con un Apple ID gratuito la firma caduca a los 7 días: vuelve a pulsar *Start* en Sideloadly (no se pierden los escaneos). Con la cuenta de desarrollador de pago (99 $/año) dura un año.

## Abrir en Blender

Todos los modos dan un modelo que Blender (probado con 5.0) abre a escala real y derecho, sin tocar opciones:

| Modo | Archivo | En Blender |
|------|---------|------------|
| Objeto | `… Objeto.usdz` | *Archivo → Importar → Universal Scene Description*: malla con textura |
| Habitación | `… Habitación para Blender.glb` / `… Plano para Blender.glb` (o el `.usdz`) | *Archivo → Importar → glTF 2.0*: paredes, suelo, puertas, ventanas y muebles como cajas de color |
| Espacio | `… Espacio para Blender.glb` | *Archivo → Importar → glTF 2.0*: malla con el color ya puesto en el material |

El *Espacio splat* es un Gaussian splat: Blender no lo dibuja solo (hace falta un complemento de 3DGS). Para un objeto con más detalle que el USDZ del iPhone, procesa `… Objeto fotos.zip` en RealityScan ([PC.md](PC.md)) y exporta FBX/OBJ.

## Pasar los escaneos al PC

- **Cable**: app *Dispositivos Apple* (o iTunes) → tu iPhone → *Archivos* → Pocket3D → arrastra la carpeta `Scans`.
- **Inalámbrico**: en «Mis escaneos» toca el zip → compartir → Google Drive / OneDrive / iCloud Drive.

## Procesar en el PC (RTX 5070)

Ver **[PC.md](PC.md)**.

## Consejos de captura

- **Objeto**: luz difusa, sin brillos directos, objeto sobre superficie lisa; 2–3 vueltas a distintas alturas.
- **Espacio**: camina despacio (la app guarda una foto cada ~10 cm o ~10° y avisa en rojo si vas demasiado rápido), vuelve a pasar por zonas sin malla y termina cerca de donde empezaste (cierra el bucle). El LiDAR alcanza ~5 m.

## Desarrollo

`Pocket3D.xcodeproj` (Xcode 16.3+, iOS 18+). Splats: [MetalSplatter](https://github.com/scier/MetalSplatter) para verlos y el núcleo de [msplat](https://github.com/rayanht/msplat) (Apache 2.0, en `Pocket3D/Vendor`) para entrenarlos. Cada push compila en GitHub Actions (macOS), ejecuta `Tests/main.swift`, entrena un splat de prueba y exige ≥ 25 dB de PSNR en vistas no vistas, arranca la app en un simulador y publica la IPA.
