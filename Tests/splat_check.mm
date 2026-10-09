// Entrena con el núcleo msplat de la app y el puente PocketSplat, como hace el iPhone, y mide la calidad
// en vistas que el entrenamiento no ve (si la convención de poses estuviera mal, el PSNR se hundiría):
//   splatcheck <dataset> <default.metallib> <salida.ply>
#include "PocketSplat.h"
#include <cstdio>

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    char error[512] = {0};
    const int iterations = 1500;
    const float minimumPSNR = 22;  // un splat inútil (poses mal, colores al azar) se queda en ~10 dB
    PocketSplatTrainer trainer = pocket_splat_create(argv[1], argv[2], iterations, 1.0f, true, error, sizeof error);
    if (!trainer) { printf("FALLO al crear: %s\n", error); return 1; }
    int iteration = 0;
    while (iteration < iterations) {
        iteration = pocket_splat_step(trainer, error, sizeof error);
        if (iteration < 0) { printf("FALLO al entrenar: %s\n", error); return 1; }
    }
    int count = pocket_splat_count(trainer);
    float psnr = pocket_splat_psnr(trainer);
    if (!pocket_splat_export(trainer, argv[3], error, sizeof error)) { printf("FALLO al exportar: %s\n", error); return 1; }
    pocket_splat_destroy(trainer);
    printf("%d iteraciones, %d gaussianas, PSNR en vistas no vistas: %.2f dB (mínimo %.0f)\n", iteration, count, psnr, minimumPSNR);
    return psnr >= minimumPSNR ? 0 : 1;
}
