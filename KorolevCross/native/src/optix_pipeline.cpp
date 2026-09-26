#include "optix_pipeline.h"
#include <optix_stubs.h>
#include <cuda_runtime.h>
#include <algorithm>

#ifndef NOMINMAX
#define NOMINMAX
#endif

bool OptixScene::initialized = false;

OptixScene::OptixScene() : traversable(0), built(false) {}
OptixScene::~OptixScene() {}

bool OptixScene::initialize() {
    if (initialized) return true;
    if (optixInitialize() != OPTIX_SUCCESS) return false;
    initialized = true;
    return true;
}

void OptixScene::clear() { voxels.clear(); built = false; traversable = 0; }
void OptixScene::addVoxel(float x, float y, float z, float size) { voxels.push_back({x,y,z,size}); }

bool OptixScene::build() {
    if (voxels.empty()) { built = false; return false; }
    built = true;
    return true;
}

bool OptixScene::trace(float ox, float oy, float oz, float dx, float dy, float dz, float* hit) {
    if (!built || voxels.empty()) return false;
    float best = 1e10f; bool found = false;
    for (const auto& v : voxels) {
        float h = v.size * 0.5f;
        float minX = v.x - h, maxX = v.x + h;
        float minY = v.y - h, maxY = v.y + h;
        float minZ = v.z - h, maxZ = v.z + h;
        float t1 = (minX - ox) / dx, t2 = (maxX - ox) / dx;
        float t3 = (minY - oy) / dy, t4 = (maxY - oy) / dy;
        float t5 = (minZ - oz) / dz, t6 = (maxZ - oz) / dz;
        float tMin = (std::max)((std::max)((std::min)(t1, t2), (std::min)(t3, t4)), (std::min)(t5, t6));
        float tMax = (std::min)((std::min)((std::max)(t1, t2), (std::max)(t3, t4)), (std::max)(t5, t6));
        if (tMax >= tMin && tMax > 0) {
            float t = tMin > 0 ? tMin : 0.01f;
            if (t < best) {
                best = t;
                hit[0] = ox + t * dx;
                hit[1] = oy + t * dy;
                hit[2] = oz + t * dz;
                found = true;
            }
        }
    }
    return found;
}

bool optixInitialize() {
    OptixDeviceContext context;
    OptixDeviceContextOptions opts = {};
    opts.validationMode = OPTIX_DEVICE_CONTEXT_VALIDATION_MODE_OFF;
    return optixDeviceContextCreate(0, &opts, &context) == OPTIX_SUCCESS;
}

#include <optix_function_table_definition.h>