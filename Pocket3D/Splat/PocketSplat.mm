#include "PocketSplat.h"
#include "msplat_c_api.h"
#include <cstdio>
#include <exception>

namespace {
struct Session {
    MsplatDataset dataset;
    MsplatTrainer trainer;
};

void report(char *error, int length, const char *what) {
    if (error && length > 0) snprintf(error, (size_t)length, "%s", what);
}
}

PocketSplatTrainer pocket_splat_create(const char *datasetPath, const char *metallibPath, int iterations,
                                       float downscale, bool holdOutViews, char *error, int errorLength) {
    MsplatDataset dataset = nullptr;
    try {
        msplat_set_metallib_path(metallibPath);
        dataset = msplat_dataset_create(datasetPath, downscale, holdOutViews, 8);
        if (!dataset || msplat_dataset_num_train(dataset) == 0) {
            if (dataset) msplat_dataset_destroy(dataset);
            report(error, errorLength, "El escaneo no tiene fotos válidas para entrenar.");
            return nullptr;
        }
        MsplatConfig config = msplat_default_config();
        config.iterations = iterations;
        // El calendario por defecto está pensado para 30 000 pasos: se escala al número real.
        float scale = iterations / 30000.0f;
        config.resolutionSchedule = (int)(3000 * scale) > 0 ? (int)(3000 * scale) : 1;
        config.warmupLength = (int)(500 * scale) > 0 ? (int)(500 * scale) : 1;
        config.stopScreenSizeAt = (int)(4000 * scale);
        config.shDegreeInterval = (int)(1000 * scale) > 0 ? (int)(1000 * scale) : 1;
        config.bgColor[0] = config.bgColor[1] = config.bgColor[2] = 0.0f;
        // El entrenamiento progresivo a baja resolución de msplat da splats borrosos y desplazados
        // (12 dB frente a 16 dB en la prueba sintética): se entrena siempre a la resolución elegida.
        config.numDownscales = 0;
        // Exportar en metros reales y en las mismas coordenadas que la malla LiDAR (msplat normaliza al entrenar).
        config.keepCrs = true;
        MsplatTrainer trainer = msplat_trainer_create(dataset, config);
        return new Session{dataset, trainer};
    } catch (const std::exception &e) {
        if (dataset) msplat_dataset_destroy(dataset);
        report(error, errorLength, e.what());
    } catch (...) {
        if (dataset) msplat_dataset_destroy(dataset);
        report(error, errorLength, "Error desconocido al preparar el entrenamiento.");
    }
    return nullptr;
}

int pocket_splat_step(PocketSplatTrainer trainer, char *error, int errorLength) {
    try {
        return msplat_trainer_step(static_cast<Session *>(trainer)->trainer).iteration;
    } catch (const std::exception &e) {
        report(error, errorLength, e.what());
    } catch (...) {
        report(error, errorLength, "Error desconocido al entrenar.");
    }
    return -1;
}

int pocket_splat_count(PocketSplatTrainer trainer) {
    return msplat_trainer_splat_count(static_cast<Session *>(trainer)->trainer);
}

float pocket_splat_psnr(PocketSplatTrainer trainer) {
    try {
        return msplat_trainer_evaluate(static_cast<Session *>(trainer)->trainer).psnr;
    } catch (...) {
        return 0;
    }
}

bool pocket_splat_export(PocketSplatTrainer trainer, const char *plyPath, char *error, int errorLength) {
    try {
        msplat_trainer_export_ply(static_cast<Session *>(trainer)->trainer, plyPath);
        return true;
    } catch (const std::exception &e) {
        report(error, errorLength, e.what());
    } catch (...) {
        report(error, errorLength, "Error desconocido al guardar el splat.");
    }
    return false;
}

void pocket_splat_destroy(PocketSplatTrainer trainer) {
    auto *session = static_cast<Session *>(trainer);
    msplat_trainer_destroy(session->trainer);
    msplat_dataset_destroy(session->dataset);
    msplat_sync();
    delete session;
}
