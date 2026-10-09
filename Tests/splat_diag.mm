// Diagnóstico temporal: PSNR con varias configuraciones y render de la vista de prueba 0 (PPM).
#include "msplat_c_api.h"
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <string>

static void savePPM(MsplatPixelBuffer b, const std::string &path) {
    FILE *f = fopen(path.c_str(), "wb");
    fprintf(f, "P6\n%d %d\n255\n", b.width, b.height);
    for (int i = 0; i < b.width * b.height * 3; i++) {
        float v = b.data[i] < 0 ? 0 : (b.data[i] > 1 ? 1 : b.data[i]);
        fputc((int)(v * 255 + 0.5f), f);
    }
    fclose(f);
    free(b.data);
}

static void run(const char *name, const char *dataset, MsplatConfig c) {
    MsplatDataset ds = msplat_dataset_create(dataset, 1.0f, true, 8);
    MsplatTrainer t = msplat_trainer_create(ds, c);
    for (int i = 0; i < c.iterations; i++) msplat_trainer_step(t);
    MsplatEvalMetrics m = msplat_trainer_evaluate(t);
    printf("[%s] test PSNR %.2f dB, %d gaussianas, %d vistas de prueba, %d de entrenamiento\n",
           name, m.psnr, m.numGaussians, m.numTest, msplat_dataset_num_train(ds));
    savePPM(msplat_trainer_render(t, 0, true), std::string("diag/") + name + "_test0.ppm");
    savePPM(msplat_trainer_render(t, 0, false), std::string("diag/") + name + "_train0.ppm");
    msplat_trainer_destroy(t);
    msplat_dataset_destroy(ds);
}

int main(int argc, char **argv) {
    msplat_set_metallib_path(argv[2]);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    printf("GPU: %s · Apple7 %d · Apple9 %d · Metal3 %d\n", device.name.UTF8String,
           [device supportsFamily:MTLGPUFamilyApple7], [device supportsFamily:MTLGPUFamilyApple9],
           [device supportsFamily:MTLGPUFamilyMetal3]);
    {
        // Sin entrenar: la nube inicial (puntos del cubo) ya debe verse en su sitio si la geometría cuadra.
        MsplatConfig c = msplat_default_config();
        c.bgColor[0] = c.bgColor[1] = c.bgColor[2] = 0;
        c.numDownscales = 0;
        MsplatDataset ds = msplat_dataset_create(argv[1], 1.0f, true, 8);
        MsplatTrainer t = msplat_trainer_create(ds, c);
        savePPM(msplat_trainer_render(t, 0, false), "diag/init_train0.ppm");
        msplat_trainer_step(t);
        savePPM(msplat_trainer_render(t, 0, false), "diag/step1_train0.ppm");
        for (int i = 0; i < 200; i++) msplat_trainer_step(t);
        savePPM(msplat_trainer_render(t, 0, false), "diag/step200_train0.ppm");
        msplat_trainer_destroy(t);
        msplat_dataset_destroy(ds);
    }
    MsplatConfig base = msplat_default_config();
    base.iterations = 1500;
    base.bgColor[0] = base.bgColor[1] = base.bgColor[2] = 0;
    base.numDownscales = 0;
    run("nd0", argv[1], base);

    MsplatConfig noDensify = base;
    noDensify.densifyGradThresh = 1e9f;   // nunca dividir ni duplicar
    run("nd0_nodensify", argv[1], noDensify);

    MsplatConfig noReset = base;
    noReset.resetAlphaEvery = 1000;       // sin reinicio de opacidad
    run("nd0_noreset", argv[1], noReset);

    MsplatConfig neither = noDensify;
    neither.resetAlphaEvery = 1000;
    run("nd0_neither", argv[1], neither);

    MsplatConfig downscaled = base;
    downscaled.numDownscales = 2; downscaled.resolutionSchedule = 250;
    run("nd2", argv[1], downscaled);
    return 0;
}
