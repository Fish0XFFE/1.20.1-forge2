#include <jni.h>
#include <cuda_runtime.h>
#include <cstring>

extern "C" __global__ void generateTerrainKernel(int chunkX, int chunkZ, int minY, int maxY, int seed, short* output);

JNIEXPORT jobjectArray JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_generateChunk(
    JNIEnv* env, jclass cls, jint chunkX, jint chunkZ, jint minY, jint maxY, jint seed) {

    int sizeX = 16, sizeZ = 16, sizeY = maxY - minY + 1;
    int total = sizeX * sizeZ * sizeY;

    short* d_output = nullptr;
    short* h_output = new short[total];
    memset(h_output, 0, total * sizeof(short));

    cudaMalloc(&d_output, total * sizeof(short));
    cudaMemset(d_output, 0, total * sizeof(short));

    dim3 block(8, 8, 8);
    dim3 grid((sizeX + block.x - 1) / block.x,
              (sizeZ + block.y - 1) / block.y,
              (sizeY + block.z - 1) / block.z);

    void* args[] = { &chunkX, &chunkZ, &minY, &maxY, &seed, &d_output };
    cudaLaunchKernel((void*)generateTerrainKernel, grid, block, args, 0, 0);
    cudaDeviceSynchronize();

    cudaMemcpy(h_output, d_output, total * sizeof(short), cudaMemcpyDeviceToHost);
    cudaFree(d_output);

    jclass shortArrayClass = env->FindClass("[S");
    if (shortArrayClass == nullptr) {
        delete[] h_output;
        return nullptr;
    }

    jobjectArray result = env->NewObjectArray(sizeX, shortArrayClass, nullptr);
    if (result == nullptr) {
        delete[] h_output;
        return nullptr;
    }

    for (int x = 0; x < sizeX; x++) {
        jshortArray arr = env->NewShortArray(sizeZ * sizeY);
        if (arr == nullptr) {
            delete[] h_output;
            return nullptr;
        }
        jshort* elements = new jshort[sizeZ * sizeY];
        for (int z = 0; z < sizeZ; z++) {
            for (int y = 0; y < sizeY; y++) {
                elements[z * sizeY + y] = h_output[(x * sizeZ + z) * sizeY + y];
            }
        }
        env->SetShortArrayRegion(arr, 0, sizeZ * sizeY, elements);
        env->SetObjectArrayElement(result, x, arr);
        env->DeleteLocalRef(arr);
        delete[] elements;
    }

    delete[] h_output;
    return result;
}

JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_initCUDA(JNIEnv* env, jclass cls) {
    cudaError_t err = cudaSetDevice(0);
    if (err != cudaSuccess) return JNI_FALSE;
    int count;
    cudaGetDeviceCount(&count);
    return (count > 0) ? JNI_TRUE : JNI_FALSE;
}