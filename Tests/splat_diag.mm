// Diagnóstico temporal: PSNR con varias configuraciones y render de la vista de prueba 0 (PPM).
#include "msplat_c_api.h"
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
    MsplatConfig base = msplat_default_config();
    base.iterations = 1500;
    run("default", argv[1], base);

    MsplatConfig scaled = base;
    float s = 1500 / 30000.0f;
    scaled.resolutionSchedule = (int)(3000 * s); scaled.warmupLength = (int)(500 * s);
    scaled.stopScreenSizeAt = (int)(4000 * s); scaled.shDegreeInterval = (int)(1000 * s);
    scaled.bgColor[0] = scaled.bgColor[1] = scaled.bgColor[2] = 0;
    run("scaled", argv[1], scaled);

    MsplatConfig sh0 = scaled; sh0.shDegree = 0;
    run("scaled_sh0", argv[1], sh0);

    MsplatConfig longer = base; longer.iterations = 4000;
    run("default4000", argv[1], longer);
    return 0;
}
