#pragma once
#include <string>
#include <cuda.h>

class DensityRuntime {
public:
    DensityRuntime();
    ~DensityRuntime();

    bool compile(const std::string& cudaCode,
                 const std::string& entryFinal,
                 const std::string& entryInitial);
    bool executeFinal(int chunkX, int chunkZ, int minY, int maxY, int seaLevel,
                      short* d_out, cudaStream_t stream);
    bool executeInitial(int chunkX, int chunkZ, int minY, int maxY,
                        float* d_out, cudaStream_t stream);
    bool isLoaded() const { return m_loaded; }

private:
    CUmodule m_module;
    CUfunction m_finalKernel;
    CUfunction m_initialKernel;
    bool m_loaded;
};