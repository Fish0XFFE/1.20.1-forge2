#ifndef OPTIX_PIPELINE_H
#define OPTIX_PIPELINE_H
#include <optix.h>
#include <vector>

class OptixScene {
public:
    OptixScene();
    ~OptixScene();
    void clear();
    void addVoxel(float x, float y, float z, float size);
    bool build();
    bool trace(float ox, float oy, float oz, float dx, float dy, float dz, float* hit);
    static bool initialize();
private:
    struct Voxel { float x, y, z, size; };
    std::vector<Voxel> voxels;
    OptixTraversableHandle traversable;
    bool built;
    static bool initialized;
};
bool optixInitialize();
#endif