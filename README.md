# Pocket3D

Escáner 3D para iPhone con LiDAR (pensado para el 17 Pro Max) + procesado de máxima calidad en un PC con GPU NVIDIA. **No hace falta Mac.**

| Modo | En el iPhone (al instante) | Para el PC (calidad máxima) |
|------|----------------------------|-----------------------------|
| **Objeto** | Modelo USDZ texturizado (Object Capture) | `… Objeto fotos.zip`: las fotos JPEG a resolución completa → RealityScan / Postshot |
| **Habitación** | Plano 3D con medidas (RoomPlan, USDZ) | — |
| **Espacio / estructura** | Malla LiDAR a escala real (USDZ) | `… Espacio dataset.zip`: fotos de alta resolución + pose de ARKit + profundidad LiDAR (formato nerfstudio) → Gaussian splats |

Todo queda en «Mis escaneos» (vista 3D/AR y botón compartir) y en **Archivos → En mi iPhone → Pocket3D → Scans**.

## Instalar en el iPhone sin Mac (desde Windows)

1. En GitHub: pestaña **Actions** → último run verde de **Build** → descarga el artefacto **Pocket3D-ipa** (es un zip; dentro está `Pocket3D.ipa`).
2. Instala en el PC **iTunes** (versión de la web de Apple, no la de Microsoft Store) y **[Sideloadly](https://sideloadly.io)**.
3. Conecta el iPhone por cable, abre Sideloadly, arrastra `Pocket3D.ipa`, pon tu Apple ID y pulsa *Start*.
4. En el iPhone: *Ajustes → General → VPN y gestión de dispositivos* → confía en tu Apple ID; y *Ajustes → Privacidad y seguridad → Modo de desarrollador* → activar (reinicia).

Con un Apple ID gratuito la firma caduca a los 7 días: vuelve a pulsar *Start* en Sideloadly (no se pierden los escaneos). Con la cuenta de desarrollador de pago (99 $/año) dura un año.

## Pasar los escaneos al PC

- **Cable**: app *Dispositivos Apple* (o iTunes) → tu iPhone → *Archivos* → Pocket3D → arrastra la carpeta `Scans`.
- **Inalámbrico**: en «Mis escaneos» toca el zip → compartir → Google Drive / OneDrive / iCloud Drive.

## Procesar en el PC (RTX 5070)

Ver **[PC.md](PC.md)**.

## Consejos de captura

- **Objeto**: luz difusa, sin brillos directos, objeto sobre superficie lisa; 2–3 vueltas a distintas alturas.
- **Espacio**: camina despacio (la app guarda una foto cada ~10 cm o ~10°), vuelve a pasar por zonas sin malla y termina cerca de donde empezaste (cierra el bucle). El LiDAR alcanza ~5 m.

## Desarrollo

`Pocket3D.xcodeproj` (Xcode 16+, iOS 17+). Cada push compila en GitHub Actions (macOS) y publica la IPA.
