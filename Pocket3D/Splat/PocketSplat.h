// Puente C entre Swift y el núcleo C++ de msplat: atrapa las excepciones de C++
// (cruzar a Swift con una excepción cerraría la app) y las devuelve como texto.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *PocketSplatTrainer;

/// Carga el dataset nerfstudio de `datasetPath` y prepara el entrenamiento. NULL si falla (motivo en `error`).
PocketSplatTrainer pocket_splat_create(const char *datasetPath, const char *metallibPath, int iterations,
                                       float downscale, char *error, int errorLength);
/// Da un paso de entrenamiento. Devuelve la iteración alcanzada o -1 si falla.
int pocket_splat_step(PocketSplatTrainer trainer, char *error, int errorLength);
int pocket_splat_count(PocketSplatTrainer trainer);
bool pocket_splat_export(PocketSplatTrainer trainer, const char *plyPath, char *error, int errorLength);
void pocket_splat_destroy(PocketSplatTrainer trainer);

#ifdef __cplusplus
}
#endif
