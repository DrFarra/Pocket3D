# Pocket3D

Escáner 3D para iPhone. Tres modos, todo se procesa en el propio teléfono:

| Modo | Para qué | Tecnología | Resultado |
|------|----------|------------|-----------|
| **Objeto** | Piezas, esculturas, zapatos, comida… | Object Capture + fotogrametría | USDZ con textura real |
| **Habitación** | Planos de interiores con medidas | RoomPlan | USDZ paramétrico (paredes, puertas, ventanas, muebles) |
| **Espacio / estructura** | Fachadas, escaleras, terreno, lo que sea | Reconstrucción LiDAR de ARKit | Malla USDZ (u OBJ) a escala real |

Los escaneos aparecen en «Mis escaneos» (vista 3D/AR con Quick Look, botón compartir) y en la app **Archivos → En mi iPhone → Pocket3D → Scans**, listos para Blender, CAD o impresión 3D.

## Requisitos

- iPhone con **LiDAR** (12 Pro / 13 Pro / 14 Pro / 15 Pro / 16 Pro o posterior) con iOS 17+.
- Mac con Xcode 16 o posterior.

## Instalar en tu iPhone

1. Abre `Pocket3D.xcodeproj` en Xcode.
2. Target *Pocket3D* → *Signing & Capabilities* → elige tu *Team* (sirve un Apple ID gratuito). Si el bundle id choca, cámbialo.
3. Conecta el iPhone, selecciónalo arriba y pulsa ▶︎.

## Consejos para buenos escaneos

- **Objeto**: buena luz difusa, objeto sobre una superficie lisa y despejada; da 2–3 vueltas a distintas alturas.
- **Espacio**: muévete despacio y vuelve a pasar por zonas sin malla; el LiDAR alcanza ~5 m.
