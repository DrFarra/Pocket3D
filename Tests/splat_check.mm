// Entrena con el núcleo msplat de la app y el puente PocketSplat, como hace el iPhone:
//   splatcheck <dataset> <default.metallib> <salida.ply>
#include "PocketSplat.h"
#include <cstdio>

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    char error[512] = {0};
    const int iterations = 300;
    PocketSplatTrainer trainer = pocket_splat_create(argv[1], argv[2], iterations, 1.0f, error, sizeof error);
    if (!trainer) { printf("FALLO al crear: %s\n", error); return 1; }
    int iteration = 0;
    while (iteration < iterations) {
        iteration = pocket_splat_step(trainer, error, sizeof error);
        if (iteration < 0) { printf("FALLO al entrenar: %s\n", error); return 1; }
    }
    int count = pocket_splat_count(trainer);
    if (!pocket_splat_export(trainer, argv[3], error, sizeof error)) { printf("FALLO al exportar: %s\n", error); return 1; }
    pocket_splat_destroy(trainer);
    printf("ok: %d iteraciones, %d gaussianas\n", iteration, count);
    return count > 0 ? 0 : 1;
}
