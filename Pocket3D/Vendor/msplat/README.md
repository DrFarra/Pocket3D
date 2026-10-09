Copia del núcleo de [msplat](https://github.com/rayanht/msplat) (Apache 2.0, commit 6b81971) para entrenar
Gaussian splats en el propio iPhone con Metal. Solo `core/` (sin CLI ni Python).
Dependencias de solo cabecera: nlohmann/json 3.11.3 (MIT) y nanoflann 1.5.5 (BSD).

## Cambios respecto al original (marcados con «Pocket3D:» en el código)

- `src/msplat_api.mm`: las fotos se mueven en vez de copiarse y se libera la copia de `data.cameras`.
- `src/input_data.cpp`: tras subir una foto a la GPU se libera su copia en CPU (sin pirámide de resoluciones).
- `src/model.cpp`: sincronizar la GPU antes de ampliar los búferes de gaussianas.
- `metal/msplat_metal.mm`: error capturable si no se puede iniciar Metal (antes, puntero nulo).
- `src/loaders/save_gaussians.cpp`: error si el `.ply` no se escribe entero.
