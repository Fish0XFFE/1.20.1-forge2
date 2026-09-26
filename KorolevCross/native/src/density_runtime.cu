#include "density_runtime.h"
#include <nvrtc.h>
#include <cuda_runtime.h>
#include <vector>
#include <cstdio>
#include <string>
#include <cstdlib>

static const char* KERNEL_WRAPPER = R"(
extern "C" __global__ void kernel_final(int cx,int cz,int minY,int maxY,int seaLevel,short* out){
    int x=blockIdx.x*blockDim.x+threadIdx.x;
    int z=blockIdx.y*blockDim.y+threadIdx.y;
    if(x>=16||z>=16)return;
    int wx=cx*16+x;
    int wz=cz*16+z;
    int sizeY=maxY-minY+1;
    for(int ly=0;ly<sizeY;ly++){
        int wy=minY+ly;
        if(wy==minY){out[(x*16+z)*sizeY+ly]=12;continue;}
        double d=evaluate((double)wx,(double)wy,(double)wz);
        if(d>0.0){
            int depth=0;
            for(int k=1;k<=4&&(ly+k)<sizeY;k++){
                double dk=evaluate((double)wx,(double)(wy+k),(double)wz);
                if(dk<=0.0){depth=k;break;}
            }
            if(depth==1)out[(x*16+z)*sizeY+ly]=2;
            else if(depth>=2&&depth<=4)out[(x*16+z)*sizeY+ly]=3;
            else out[(x*16+z)*sizeY+ly]=1;
        } else {
            if(wy<=seaLevel&&wy>0)out[(x*16+z)*sizeY+ly]=8;
            else out[(x*16+z)*sizeY+ly]=0;
        }
    }
}

extern "C" __global__ void kernel_initial(int cx,int cz,int minY,int maxY,float* out){
    int x=blockIdx.x*blockDim.x+threadIdx.x;
    int z=blockIdx.y*blockDim.y+threadIdx.y;
    if(x>=16||z>=16)return;
    int wx=cx*16+x;
    int wz=cz*16+z;
    int sizeY=maxY-minY+1;
    for(int ly=0;ly<sizeY;ly++){
        int wy=minY+ly;
        double d=evaluate_initial((double)wx,(double)wy,(double)wz);
        out[(x*16+z)*sizeY+ly]=(float)d;
    }
}
)";

DensityRuntime::DensityRuntime()
    : m_module(nullptr), m_finalKernel(nullptr), m_initialKernel(nullptr), m_loaded(false) {}

DensityRuntime::~DensityRuntime() {
    if (m_module) cuModuleUnload(m_module);
}

bool DensityRuntime::compile(const std::string& cudaCode,
                             const std::string& entryFinal,
                             const std::string& entryInitial) {
    std::string fullSource = cudaCode + KERNEL_WRAPPER;

    nvrtcProgram prog;
    if (nvrtcCreateProgram(&prog, fullSource.c_str(), "generated.cu", 0, nullptr, nullptr) != NVRTC_SUCCESS) {
        fprintf(stderr, "[KorolevCross] nvrtcCreateProgram failed\n");
        return false;
    }

    int device = 0;
    cudaGetDevice(&device);
    int ccMajor = 0, ccMinor = 0;
    cudaDeviceGetAttribute(&ccMajor, cudaDevAttrComputeCapabilityMajor, device);
    cudaDeviceGetAttribute(&ccMinor, cudaDevAttrComputeCapabilityMinor, device);

    char archOpt[64];
    snprintf(archOpt, sizeof(archOpt), "--gpu-architecture=compute_%d%d", ccMajor, ccMinor);

    std::vector<std::string> opts;
    opts.push_back(archOpt);
    opts.push_back("--use_fast_math");
    opts.push_back("--std=c++17");
    opts.push_back("--device-as-default-execution-space");
    opts.push_back("--restrict");

    std::vector<const char*> optPtrs;
    for (const std::string& s : opts) {
        optPtrs.push_back(s.c_str());
    }

    nvrtcResult res = nvrtcCompileProgram(prog, (int)optPtrs.size(), optPtrs.data());

    size_t logSize = 0;
    nvrtcGetProgramLogSize(prog, &logSize);
    if (logSize > 1) {
        std::vector<char> log(logSize);
        nvrtcGetProgramLog(prog, log.data());
        fprintf(stderr, "[KorolevCross] NVRTC log:\n%s\n", log.data());
    }

    if (res != NVRTC_SUCCESS) {
        nvrtcDestroyProgram(&prog);
        return false;
    }

    size_t ptxSize = 0;
    nvrtcGetPTXSize(prog, &ptxSize);
    std::vector<char> ptx(ptxSize);
    nvrtcGetPTX(prog, ptx.data());
    nvrtcDestroyProgram(&prog);

    cudaFree(0);
    CUcontext ctx = nullptr;
    cuCtxGetCurrent(&ctx);
    if (!ctx) {
        CUdevice dev;
        cuDeviceGet(&dev, 0);
#if CUDA_VERSION >= 13000
        cuCtxCreate(&ctx, nullptr, 0, dev);
#else
        cuCtxCreate(&ctx, 0, dev);
#endif
    }

    if (cuModuleLoadData(&m_module, ptx.data()) != CUDA_SUCCESS) {
        fprintf(stderr, "[KorolevCross] cuModuleLoadData failed\n");
        return false;
    }
    if (cuModuleGetFunction(&m_finalKernel, m_module, "kernel_final") != CUDA_SUCCESS) {
        fprintf(stderr, "[KorolevCross] kernel_final not found\n");
        return false;
    }
    if (cuModuleGetFunction(&m_initialKernel, m_module, "kernel_initial") != CUDA_SUCCESS) {
        fprintf(stderr, "[KorolevCross] kernel_initial not found\n");
        return false;
    }

    m_loaded = true;
    return true;
}

bool DensityRuntime::executeFinal(int chunkX, int chunkZ, int minY, int maxY, int seaLevel,
                                  short* d_out, cudaStream_t stream) {
    if (!m_loaded) return false;
    dim3 block(16, 16);
    dim3 grid(1, 1);
    void* args[] = { &chunkX, &chunkZ, &minY, &maxY, &seaLevel, &d_out };
    CUresult r = cuLaunchKernel(m_finalKernel, grid.x, grid.y, grid.z,
                                 block.x, block.y, block.z, 0,
                                 (CUstream)stream, args, nullptr);
    return r == CUDA_SUCCESS;
}

bool DensityRuntime::executeInitial(int chunkX, int chunkZ, int minY, int maxY,
                                    float* d_out, cudaStream_t stream) {
    if (!m_loaded) return false;
    dim3 block(16, 16);
    dim3 grid(1, 1);
    void* args[] = { &chunkX, &chunkZ, &minY, &maxY, &d_out };
    CUresult r = cuLaunchKernel(m_initialKernel, grid.x, grid.y, grid.z,
                                 block.x, block.y, block.z, 0,
                                 (CUstream)stream, args, nullptr);
    return r == CUDA_SUCCESS;
}