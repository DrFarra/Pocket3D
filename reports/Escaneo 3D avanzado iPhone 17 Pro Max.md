# Fusiona sensores, no elijas una sola app

En octubre de 2026, la forma más avanzada de escanear con un iPhone 17 Pro Max no es ninguna app ni un sensor concreto. Es un **flujo híbrido**. Primero se graba un dataset crudo y completo: fotos de 48 MP con exposición bloqueada, poses de ARKit por fotograma, profundidad LiDAR con su mapa de confianza y, si hace falta precisión absoluta, GNSS RTK. Luego se genera una vista previa en el propio teléfono, con un splat en 1–2 minutos o una malla LiDAR. Por último, el resultado se **refina en un Mac o en una GPU**: ajuste de poses, Gaussian Splatting para el aspecto visual y fotogrametría o malla extraída de splats (2DGS, PGSR, MILo) para lo que se va a medir o imprimir. La razón es que cada tecnología gana en un terreno distinto. La fotogrametría da la geometría más precisa, el Gaussian Splatting da el fotorrealismo y el LiDAR aporta escala métrica y rapidez. Un estudio de ISPRS de 2026 encontró además que, en edificios, **los métodos basados en imagen superan al LiDAR del teléfono tanto en calidad visual como en precisión espacial** ([ISPRS Annals 2026](https://isprs-annals.copernicus.org/articles/XI-M-1-2026/31/2026/)). El 17 Pro Max no trae un LiDAR mejor: sus ventajas son de cómputo (GPU con Neural Accelerators, unos 12 GB de RAM y cámara de vapor) y un teleobjetivo de 48 MP. Eso hace viable más trabajo en el dispositivo, pero no elimina el límite de Apple: en iOS, `PhotogrammetrySession` solo genera el nivel `.reduced`. En la práctica, puedes esperar milímetros en objetos fotografiados bien, 1–2 cm en piezas de 1–3 m con LiDAR, 2–8 cm en habitaciones y decímetros en edificios sin control externo. Un detalle de contexto: a esta fecha el iPhone 18 Pro y iOS 27 ya existen, y todo lo de aquí sigue siendo válido en iOS 27.

## El 17 Pro Max mejora el procesador, no el sensor de profundidad

Apple no da cifras del LiDAR del 17 Pro Max y lo lista sin especificaciones junto al barómetro, el giroscopio de alto rango dinámico y el acelerómetro de alta g ([Apple Support 125091](https://support.apple.com/en-us/125091)). Las resoluciones de profundidad que exponen las APIs tampoco han cambiado. ARKit entrega **256×192**. La LiDAR Depth Camera de AVFoundation fusiona el LiDAR con la cámara gran angular mediante un modelo de ML y llega a **320×240 en streaming y 768×576 en foto** ([WWDC22 110429](https://developer.apple.com/videos/play/wwdc2022/110429/)). El alcance útil citado ronda los **5 m** ([Sensors and Materials](https://sensors.myu-group.co.jp/sm_pdf/SM4222.pdf)). Todo apunta a que el módulo es funcionalmente el mismo que desde el iPhone 12 Pro, aunque ningún desmontaje lo confirma.

Lo que sí cambia está en el cómputo y en las cámaras. El A19 Pro incorpora un **Neural Accelerator en cada uno de sus 6 núcleos de GPU**. Apple anuncia **hasta 3× de pico de cómputo GPU** frente al A18 Pro ([BetaNews](https://betanews.com/2025/09/09/apple-unveils-iphone-17-pro-and-pro-max-with-a19-pro-chip-and-new-camera-system/)) y **hasta un 40 % más de rendimiento sostenido** gracias a la cámara de vapor ([OWC/MacSales](https://eshop.macsales.com/blog/97735-apples-new-iphone-17-pro-was-rebuilt-for-serious-speed/)). Una prueba de 30 minutos con carga de IA en GPU no llegó a calentar el equipo ([Notebookcheck](https://www.notebookcheck.net/New-iPhone-17-Pro-vapor-chamber-cooling-is-so-good-that-phone-reportedly-stays-cool-even-during-extreme-AI-loads.1122899.0.html)). La cifra de **12 GB de RAM** procede solo de fuentes secundarias ([Smartish](https://smartish.com/blogs/news/iphone-17-pro-max-review)). Las tres cámaras traseras son de 48 MP: principal de 24 mm, ultra gran angular de 13 mm y teleobjetivo tetraprisma de 100 mm. Se suman ProRAW, ProRes RAW y Genlock ([Apple Support 125091](https://support.apple.com/en-us/125091)). El sensor del teleobjetivo es **un 56 % más grande** que el del 16 Pro ([Notebookcheck](https://www.notebookcheck.net/Apple-iPhone-17-Pro-Max-First-sample-photos-reveal-camera-weaknesses-especially-at-40x-zoom.1111109.0.html)). Para escanear, todo esto se traduce en texturas mejores, entrenamientos más largos en el dispositivo sin estrangulamiento térmico y la posibilidad de fotografiar detalle a distancia con el 4x. No encontré ningún benchmark de reconstrucción 3D específico de este modelo, ni ninguna app que aproveche explícitamente el teleobjetivo o los aceleradores neuronales.

La pila nativa de Apple apenas ha cambiado desde 2024:

- **Object Capture** (`ObjectCaptureSession` + `PhotogrammetrySession`): captura guiada y reconstrucción. **En iOS solo admite el nivel `.reduced`**, con menos de 50.000 triángulos y texturas de 2048². Los niveles `.medium`, `.full` (250.000 triángulos, texturas de 8K con mapas de rugosidad y desplazamiento), `.raw` (hasta 30 millones de triángulos) y `custom` (texturas de hasta 16K) **solo funcionan en macOS** ([Apple: Request.Detail](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail)). La potencia extra del 17 Pro Max no desbloquea esos niveles: el límite es de política, no de hardware.
- **Novedades de WWDC24:** Area Mode, para terreno y superficies 2.5D, y **acceso de solo lectura a la pose, los intrínsecos y la calibración de cada foto**, que Apple presenta como útil "para tus propios pipelines de reconstrucción". En el Mac admite hasta 2.000 imágenes ([WWDC24 10107](https://developer.apple.com/videos/play/wwdc2024/10107/)).
- **RoomPlan:** no tiene cambios documentados desde la API MultiRoom de iOS 17 ([WWDC23 10192](https://developer.apple.com/videos/play/wwdc2023/10192/); [Foros de Apple](https://developer.apple.com/forums/thread/787628)).
- **WWDC26:** RealityKit añadió **renderizado** de Gaussian splats mediante buffers, sin ninguna API para crearlos ([WWDC26 279](https://developer.apple.com/videos/play/wwdc2026/279/)). Su disponibilidad en iOS no está clara: un desarrollador señaló que la documentación muestra iOS pero Xcode no expone los símbolos ([WWDC26 Group Lab 8004](https://developer.apple.com/videos/play/wwdc2026/8004/)). La misma edición trajo el **seguimiento de objetos de ARKit a iOS 27**, con poses en espacio métrico, que sirve para medir pero no para reconstruir ([WWDC26 283](https://developer.apple.com/videos/play/wwdc2026/283/)).

En resumen, Apple no ofrece ninguna API de primera parte que genere splats en el iPhone.

## Cada tecnología gana en un terreno distinto

La pregunta "¿cuál es la mejor técnica?" no tiene una respuesta única, porque cada una optimiza una cosa distinta. El estudio de ISPRS de 2026 sobre edificios es el dato más fuerte. Los splats entrenados sobre imágenes vencieron a los basados en LiDAR de teléfono en las dos métricas, visual y espacial. Limpiar la nube inicial de COLMAP **redujo claramente los "floaters"**, submuestrearla los aumentó, y dar **tres vueltas de captura** alrededor del edificio mejoró ambas métricas ([ISPRS Annals 2026](https://isprs-annals.copernicus.org/articles/XI-M-1-2026/31/2026/)). Aun así, un splat no es un entregable de medición. Las guías de profesionales recomiendan combinar el splat, que aporta el contexto visual, con una nube de puntos o una malla, que aporta la medida ([LiDAR News](https://lidarnews.com/gaussian-splatting-and-lidar-a-practitioners-field-guide/)). NeRF ha quedado como referencia académica: las apps y los estándares de 2026 se construyen alrededor de los splats.

| Técnica | Gana en | Pierde en | Dónde corre hoy |
|---|---|---|---|
| Fotogrametría (48 MP / ProRAW) | Precisión geométrica y textura de objetos; detalle submilimétrico con buena cámara ([AGILE 2023](https://agile-giss.copernicus.org/articles/4/49/2023/)) | Superficies lisas, brillantes o transparentes; es lenta | iPhone (`.reduced`), Mac (hasta `.raw`/16K), nube |
| LiDAR + ARKit | Escala métrica instantánea, interiores, rapidez | Detalle fino (profundidad de 256×192), alcance de ~5 m, deriva | 100 % en el dispositivo |
| Gaussian Splatting (3DGS) | Fotorrealismo: reflejos, vegetación, escenas completas | No es una malla medible por sí solo | iPhone en ~1–2 min (Scaniverse, Scantic); Mac o CUDA para calidad máxima |
| Malla desde splats (2DGS, PGSR, GOF, MILo) | Superficie limpia con apariencia de splat | Requiere GPU de escritorio | Mac (2DGS con MetalSplat), CUDA (MILo) |

La extracción de mallas desde splats ha madurado. 2DGS declara la mayor precisión entre los métodos con los que se compara y es **100× más rápido** que los métodos basados en SDF ([arXiv 2403.17888](https://arxiv.org/pdf/2403.17888)). PGSR baja el Chamfer medio en DTU a **0,47** usando solo RGB ([PyPI pgsr](https://pypi.org/project/pgsr/)). **MILo (2025)** extrae la malla dentro del propio bucle de entrenamiento mediante una triangulación de Delaunay diferenciable. Logra un F1 de 0,76 frente a 0,68 de GOF con **un orden de magnitud menos de vértices** ([arXiv 2506.24096](https://arxiv.org/html/2506.24096v2)). Todas estas cifras las dan los propios autores y no hay una tabla independiente que las compare. En un Mac sin NVIDIA, **MetalSplat v0.3.0 entrena 3DGS y 2DGS** sobre Apple Silicon ([Radiance Fields](https://radiancefields.com/metalsplat-v0.3.0-trains-3dgs-and-2dgs-on-apple-silicon)).

La otra frontera son los modelos feed-forward, que estiman cámaras, profundidad y nube de puntos en segundos y sin SfM clásico:

- **VGGT-Ω** fue oral en CVPR 2026, aunque sus autores advierten de una posible contaminación en los benchmarks de su versión de 1B parámetros ([LearnOpenCV](https://learnopencv.com/vggt-vs-vggt-%cf%89-vggt-omega-a-complete-guide-to-feed-forward-3d-reconstruction/)).
- **VGG-T³** reconstruye 1.000 imágenes en **54 s** ([CVPR 2026](https://cvpr.thecvf.com/virtual/2026/poster/36685)).
- **Depth Anything 3** declara un +35,7 % en pose sobre VGGT ([arXiv 2511.10647](https://arxiv.org/pdf/2511.10647)).
- **MapAnything** es el más relevante para el iPhone, porque **acepta como entrada poses, intrínsecos y profundidad**, es decir, ARKit y LiDAR ([arXiv 2509.13414](https://arxiv.org/pdf/2509.13414)).

Estos modelos tienen dos límites. Sufren de ambigüedad de escala, con errores de escala por encima de 0,46 en una evaluación independiente ([arXiv 2602.10101](https://arxiv.org/pdf/2602.10101)). Y ninguno corre en un teléfono. Lo único verificado en el dispositivo es **Apple SHARP**, que convierte una sola foto en un splat métrico en menos de 1 s en GPU ([UploadVR](https://www.uploadvr.com/apple-sharp-open-source-on-device-gaussian-splatting/)). Tiene un port comunitario a Core ML para iOS, con licencia de investigación de Apple que conviene revisar antes de un uso comercial ([HF Sharp-coreml](https://huggingface.co/descentbrine/Sharp-coreml/blob/main/README.md)). SHARP sirve para efectos de foto 3D, no para escanear. Para el iPhone, el uso correcto de esta familia de modelos es inicializar o refinar poses en un servidor, no sustituir la captura.

## La precisión depende de la escala y del software

Ningún estudio publicado mide el LiDAR del 17 Pro ni del 16 Pro. Las cifras siguientes vienen de iPhone 12–15 Pro y iPad Pro, que usan el mismo tipo de sensor dToF, así que son una aproximación razonable.

| Escenario | Precisión típica | Evidencia |
|---|---|---|
| Objetos de más de 10 cm con LiDAR | ±1 cm | iPhone 12 Pro ([Sci Rep 2021](https://www.nature.com/articles/s41598-021-01763-9)) |
| Piezas de 1–3 m con LiDAR | 1–2 cm; más de 25 cm en elementos de más de 4 m en escaneo dinámico | iPad Pro frente a TLS ([HBRC 2024](https://www.tandfonline.com/doi/full/10.1080/16874048.2024.2408839)) |
| Pasillo o interior frente a TLS | Desviación estándar de 6,0–6,4 cm (apps gratuitas) | [J. Geovis. 2026](https://link.springer.com/article/10.1007/s41651-026-00288-x) |
| Edificio frente a TLS | Media de 5 cm (Polycam) a 44 cm (Scaniverse, modo malla de 2023); 10–20 cm a 2σ | iPhone 13 Pro ([MDPI Geomatics 2023](https://www.mdpi.com/2673-7418/3/4/30)) |
| Patrimonio (cabañas de troncos) | Mejor RMSE de 49,8 mm; "nivel centimétrico" con gran variación entre apps | [ISPRS 2026](https://isprs-archives.copernicus.org/articles/XLIX-M-1-2026/1/2026/) |
| Acantilado de 130 m | ±10 cm | [Sci Rep 2021](https://www.nature.com/articles/s41598-021-01763-9) |
| Objeto pequeño con TrueDepth (Face ID) | 0,4–1,2 mm, unas 2–5× peor que un Artec Space Spider | [MDPI Technologies 2021](https://www.mdpi.com/2227-7080/9/2/25) |
| Con RTK continuo (Emlid + Pix4D) | RMSE de menos de 3 cm en X, Y y Z; ~12 cm si se pierde el fix | [ISPRS 2026](https://isprs-archives.copernicus.org/articles/XLIX-B1-2026/193/2026/) (con afiliación de proveedor) |

Dos conclusiones salen de esta tabla. La primera es que **el software importa tanto como el sensor**. Con el mismo hardware, el error medio en un edificio va de 5 a 44 cm según la app. Las apps con cierre de bucle (loop closure) rinden mejor en pasillos y calles ([ISPRS 2024](https://isprs-archives.copernicus.org/articles/XLVIII-2-W8-2024/431/2024/isprs-archives-XLVIII-2-W8-2024-431-2024.pdf)). Lo que separa a una app buena de una mediocre es la optimización de poses, el cierre de bucle y el filtrado por confianza.

La segunda es que **la deriva domina en las escalas grandes**. Sin control externo, un iPhone da calidad de "boceto" o as-built, de 5 a 20 cm en edificios, y no sustituye a un escáner láser terrestre (TLS) cuando el pliego exige 5 cm o menos. La única vía documentada a precisión topográfica es el **GNSS RTK externo continuo** (viDoc o Emlid) fusionado con las poses de ARKit. Los geo anchors de ARKit sirven para AR a escala de calle, y Apple no publica su precisión ([Apple: ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration.md)).

Un matiz contraintuitivo: en troncos de árboles, usar la confianza "low" del LiDAR dio un diámetro (DBH) **más preciso** que "high" ([ECNU](https://pure.ecnu.edu.cn/en/publications/evaluation-of-ipad-pro-2020-lidar-for-estimating-tree-diameters-i/)). Filtrar demasiado por confianza puede quitar puntos útiles, así que conviene ponderar en lugar de descartar.

## El método para cada sujeto

Apple fija unas reglas de captura que se aplican a todo lo fotogramétrico ([Apple: Capturing photographs for Object Capture](https://developer.apple.com/tutorials/data/documentation/realitykit/capturing-photographs-for-realitykit-object-capture.md)):

- **Solapamiento de al menos el 70 %** entre fotos. Por debajo del 50 %, la reconstrucción puede fallar.
- La máxima resolución disponible, y RAW si es posible.
- Zoom, apertura, obturación e ISO bloqueados durante toda la captura.
- Luz difusa: día nublado, sombra o caja de luz, nunca flash ni sol directo.
- Sujetos estáticos y no deformables.
- Fotografías con profundidad embebida, porque de ella sale la escala real. Sin profundidad, el modelo queda sin escala.

Para superficies brillantes, el estándar profesional es la **polarización cruzada**: se polariza la luz y se gira 90° el polarizador de la lente, a costa de perder unos 1,3 pasos de luz ([Paul Bourke](https://paulbourke.net/miscellaneous/crosspolarisation/)). Se combina con un **spray de escaneo aplicado de forma parcial**, rociando desde 50–70 cm. Cubrir el objeto entero lo vuelve otra vez una superficie de un solo color ([OpenScan](https://blog.openscan.eu/posts/tutorial-scanning-a-metal-key-with-the-right-amount-of-scanning-chalk-spray/)). En interiores con LiDAR, la deriva se controla limitando el alcance a menos de 5 m y moviéndose despacio ([EGU26-2752](https://meetingorganizer.copernicus.org/EGU26/EGU26-2752.html)).

| Sujeto | Mejor método en el 17 Pro Max | Apps de referencia | Expectativa |
|---|---|---|---|
| Objetos pequeños (impresión, CAD) | Fotogrametría con 48 MP: tres alturas de órbita, voltear el objeto, LiDAR solo para la escala; procesar en el Mac a `.full` o `.raw` | Object Capture en iOS y Mac, RealityScan Mobile seguido de RealityScan 2.x de escritorio, KIRI Photo Scan ([Swiftwand 2026](https://swiftwand.com/en/smartphone-3d-scanning-app-comparison-2026-en/)) | Milímetros |
| Objetos brillantes u oscuros | Lo mismo, más polarización cruzada y spray parcial | Las mismas | Depende de la preparación |
| Personas | Sujeto inmóvil, vuelta de 360° rápida, con splat (para el parecido visual) o fotogrametría; TrueDepth para cabeza y rostro | Heges (TrueDepth/LiDAR, cita el iPhone 17 entre los compatibles) ([App Store](https://apps.apple.com/app/id1382310112)); splats en Polycam o Scaniverse | Submilimétrico a 1 mm con TrueDepth de cerca |
| Personas en movimiento (4D) | No está listo con un solo teléfono: el 4DGS de calidad requiere rigs multicámara ([radiancefields.com](https://radiancefields.com/4d-gaussian-splatting)) | — | Investigación |
| Habitaciones | LiDAR con alcance de 5 m o menos y cierre de bucle; RoomPlan para el plano paramétrico; splat para lo visual | Polycam (mejor media frente a TLS), Magicplan, Twindo/Canvas para Scan-to-CAD ([MDPI 2023](https://www.mdpi.com/2673-7418/3/4/30)) | 2–8 cm |
| Fachadas y estructuras | Fotos o vídeo procesados en RealityScan 2.x de escritorio para el detalle; LiDAR (Polycam o SiteScape) para medir; tres vueltas si se entrena un splat | Polycam, SiteScape, RealityScan | 5–20 cm sin control |
| Exteriores grandes y terreno | Splats para visualizar; para medir, PIX4Dcatch con viDoc RTK, que ya aplica offsets SPC+ automáticos para el 17 Pro y el 17 Pro Max ([App Store](https://apps.apple.com/app/id1511483044)) | Scaniverse (gratuito, splats en el dispositivo, nuevos niveles en la nube con Niantic Spatial) ([GeekWire](https://www.geekwire.com/2026/from-pokemon-go-to-physical-ai-niantic-spatial-unveils-its-global-3d-mapping-platform/)) | Menos de 3 cm absolutos con RTK |

Luma AI ya no es una opción para trabajo nuevo. Pausó las subidas de capturas en 2024 y cerró Flythroughs el 1 de enero de 2026 ([Radiance Fields](https://radiancefields.com/radiance-field-uploads-suspended-on-luma-ai)).

El pipeline de máxima calidad que usan hoy los profesionales sigue una regla sencilla: **los fallos de un splat casi siempre vienen de cámaras mal alineadas**. Por eso primero se alinean las cámaras y después se entrena ([r/GaussianSplatting](https://nyc1.lr.ggtyler.dev/r/GaussianSplatting/comments/1go73il/what_app_should_i_use)). Los pasos son estos:

1. **Captura en el iPhone**, en foto o vídeo.
2. **Alineación de cámaras** en RealityScan 2.x de escritorio, que es gratuito por debajo de un millón de dólares de facturación ([Radiance Fields](https://radiancefields.com/realityscan-2-0-released)), o en COLMAP 4.0, que integra el SfM global GLOMAP ([Radiance Fields](https://radiancefields.com/colmap-4.0-introduces-major-performance-and-infrastructure-updates)).
3. **Entrenamiento del splat.** Con NVIDIA, en Postshot o gsplat. En un Mac, con msplat (~80 s por escena en un M4 Max, según su autor) ([PyPI msplat](https://pypi.org/project/msplat/)), MetalSplat u OpenSplat.

Hay un atajo: con LiDAR, las poses de ARKit y la profundidad permiten **saltarse COLMAP y obtener escala métrica**. Polycam exporta imágenes, poses optimizadas globalmente y profundidad en modo Developer, y nerfstudio tiene un importador para esos datos ([nerfstudio](https://docs.nerf.studio/quickstart/custom_dataset.html)). Además, la densificación guiada por LiDAR mejora la eficiencia y la calidad del entrenamiento ([arXiv 2511.19294](https://arxiv.org/pdf/2511.19294)).

## Qué implica para Pocket3D

Pocket3D cubre hoy los tres pilares nativos: Object Capture con reconstrucción `.reduced` en el iPhone, RoomPlan con una sola habitación exportada a USDZ, y la malla de ARKit (`ARMeshAnchor`) exportada sin textura por ModelIO. Es la base correcta, pero coincide con el techo de lo que Apple da gratis. Los hallazgos de este informe sugieren seis mejoras, ordenadas por impacto y coste.

**1. Guardar el dataset crudo en el modo Espacio.** Es la mejora de mayor impacto. El modo debería registrar `sceneDepth` con su `confidenceMap`, la pose y los intrínsecos de cada frame ([Apple: ARFrame.sceneDepth](https://developer.apple.com/documentation/arkit/arframe/scenedepth.md)), y una foto de alta resolución con `captureHighResolutionFrame` cada cierto desplazamiento, calibrado para un solapamiento del 70 %. Con eso, cada escaneo exportaría un `transforms.json` compatible con nerfstudio, gsplat y Brush, como hacen Stray Scanner y `apple_spatial_capture` ([pub.dev](https://pub.dev/documentation/apple_spatial_capture/latest/)). Un aviso práctico: un hilo de los foros reporta errores al pedir alta resolución con la profundidad activada ([Foros 805839](https://developer.apple.com/forums/thread/805839)), así que hay que probarlo en el 17 Pro Max real.

**2. Abrir una ruta de refinado en el Mac.** Las fotos de Object Capture ya llevan profundidad y gravedad, y Apple expone las poses y la calibración de cada toma ([WWDC24 10107](https://developer.apple.com/videos/play/wwdc2024/10107/)). Basta con compartir la carpeta de imágenes, por ejemplo con AirDrop, para que una herramienta de macOS la procese a `.full` o `.raw`. El cambio es casi gratuito y multiplica por 5 los triángulos, de menos de 50.000 a 250.000 en `.full`, y por 4 la resolución de textura, de 2048² a 8192².

**3. Aprender de lo que hacen las mejores apps.**

- Bloquear AE, AF y balance de blancos por código en lugar de confiar en el usuario.
- Mostrar en vivo la cobertura, el desenfoque y la velocidad angular.
- Ponderar la fusión por confianza en vez de descartar puntos (en árboles, la confianza "low" midió mejor).
- Adoptar `StructureBuilder` de RoomPlan para escanear varias habitaciones ([WWDC23 10192](https://developer.apple.com/videos/play/wwdc2023/10192/)).

**4. Añadir Gaussian splats.** Es el salto de calidad visual. El entrenamiento en el teléfono ya está demostrado:

- Scantic entrena en menos de un minuto ([CG Channel](https://www.cgchannel.com/2026/08/scantic-trains-gaussian-splats-entirely-on-your-phone/)).
- PocketGS alcanza un LPIPS de 0,108 en ~4 minutos en un iPhone 15, con menos de 3 GB de memoria ([arXiv 2601.17354](https://arxiv.org/html/2601.17354v3)).
- msplat ofrece bindings en Swift como punto de partida de código abierto.

Para mostrarlos, MetalSplatter renderiza PLY y SPZ en iOS sin depender de que RealityKit exponga sus splats en iOS ([Radiance Fields](https://radiancefields.com/tags/metalsplatter)). Conviene inicializar los Gaussianos con la nube LiDAR, porque la calidad de la nube inicial determina cuántos "floaters" aparecen ([ISPRS Annals 2026](https://isprs-annals.copernicus.org/articles/XI-M-1-2026/31/2026/)).

**5. Ampliar las exportaciones.**

- PLY como formato máster de los splats.
- SPZ, ~10× más pequeño y con licencia MIT ([Niantic SPZ](https://github.com/nianticlabs/spz)).
- glTF con `KHR_gaussian_splatting`, aún en release candidate pero ya implementado en Cesium, Babylon.js y PlayCanvas ([Khronos](https://www.khronos.org/news/permalink/khronos-announces-gltf-gaussian-splatting-extension)).
- Vigilar el esquema de splats de OpenUSD 26.03 ([AOUSD](https://aousd.org/blog/openusd-v26-03/)).

**6. Para uso profesional, integrar RTK y E57/LAS.** No es para la primera versión.

## Conclusión

El cambio de fondo es que la calidad del escaneo con iPhone ha dejado de depender del sensor y depende del pipeline. Con un LiDAR sin cambios desde 2020, la diferencia entre 5 y 44 cm de error, o entre una malla de 50.000 triángulos y un splat fotorrealista, la marcan la gestión de poses, la confianza de la profundidad, la calidad de la nube inicial y dónde se hace el procesado final. El 17 Pro Max aporta potencia y estabilidad térmica de sobra para capturar mejor y previsualizar en el dispositivo. El techo de calidad sigue en el Mac o en la GPU, en parte por decisiones de Apple como el límite `.reduced` y la ausencia de una API para crear splats.

Para un desarrollador independiente, esto es una oportunidad. Las apps comerciales no aprovechan todavía el hardware específico del 17 Pro, ningún modelo feed-forward corre aún en el teléfono y los estándares de splats (glTF, OpenUSD) se están cerrando ahora. Una app que guarde datasets crudos, completos y con escala métrica, y que se integre con los trainers abiertos, está mejor posicionada que una que compita en reconstrucción cerrada dentro del dispositivo. Quedan incógnitas que conviene verificar en el dispositivo real: la resolución exacta de profundidad y de foto de alta resolución en el 17 Pro Max, si iOS 27 expone el renderizado de splats de RealityKit y si el iPhone 18 Pro mantiene el LiDAR.
