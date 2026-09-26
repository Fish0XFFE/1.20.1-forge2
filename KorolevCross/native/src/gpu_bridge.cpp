#include <jni.h>
#include <cuda_runtime.h>
#include <cuda.h>
#include <string>
#include <mutex>
#include <unordered_map>
#include <memory>
#include "json.hpp"
#include "density_parser.h"
#include "code_generator.h"
#include "density_runtime.h"

struct DimensionEntry {
    std::shared_ptr<DensityRuntime> runtime;
    uint64_t seed;
    short* d_out;
    size_t d_capacity;
    cudaStream_t stream;
};

static std::string g_lastError = "none";
static std::mutex g_lastErrorMutex;

static bool g_initialized = false;
static std::mutex g_mutex;
static std::unordered_map<std::string, DimensionEntry> g_runtimes;

static std::unordered_map<std::string, std::string> g_rawDensityFunctions;
static std::unordered_map<std::string, std::string> g_rawNoises;
static std::mutex g_rawMutex;

static std::unordered_map<std::string, uint64_t> g_failedDimensions;

static void setLastError(const std::string& msg) {
    std::lock_guard<std::mutex> lock(g_lastErrorMutex);
    g_lastError = msg;
}

static void freeDimensionEntry(DimensionEntry& entry) {
    if (entry.d_out) { cudaFree(entry.d_out); entry.d_out = nullptr; }
    if (entry.stream) { cudaStreamDestroy(entry.stream); entry.stream = nullptr; }
    entry.d_capacity = 0;
    entry.runtime.reset();
}

extern "C" {

JNIEXPORT jint JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_ping(
    JNIEnv* env, jclass cls) {
    return 12345;
}

JNIEXPORT jstring JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_getLastError(
    JNIEnv* env, jclass cls) {
    std::lock_guard<std::mutex> lock(g_lastErrorMutex);
    return env->NewStringUTF(g_lastError.c_str());
}

JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_initCUDA(
    JNIEnv* env, jclass cls) {
    try {
        cudaError_t err = cudaSetDevice(0);
        if (err != cudaSuccess) return JNI_FALSE;
        int count = 0;
        cudaGetDeviceCount(&count);
        if (count == 0) return JNI_FALSE;
        cuInit(0);
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, 0);
        printf("[KorolevCross] GPU: %s SM:%d CC:%d.%d\n",
               prop.name, prop.multiProcessorCount, prop.major, prop.minor);
        g_initialized = true;
        return JNI_TRUE;
    } catch (...) {
        return JNI_FALSE;
    }
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_registerDensityFunction(
    JNIEnv* env, jclass cls, jstring id, jstring jsonStr) {
    try {
        const char* idC = env->GetStringUTFChars(id, nullptr);
        const char* jsonC = env->GetStringUTFChars(jsonStr, nullptr);
        if (idC && jsonC) {
            std::string key(idC);
            if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);
            std::lock_guard<std::mutex> lock(g_rawMutex);
            g_rawDensityFunctions[key] = std::string(jsonC);
        }
        if (idC) env->ReleaseStringUTFChars(id, idC);
        if (jsonC) env->ReleaseStringUTFChars(jsonStr, jsonC);
    } catch (...) {}
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_registerNoise(
    JNIEnv* env, jclass cls, jstring id, jstring jsonStr) {
    try {
        const char* idC = env->GetStringUTFChars(id, nullptr);
        const char* jsonC = env->GetStringUTFChars(jsonStr, nullptr);
        if (idC && jsonC) {
            std::string key(idC);
            if (key.rfind("minecraft:", 0) == 0) key = key.substr(10);
            std::lock_guard<std::mutex> lock(g_rawMutex);
            g_rawNoises[key] = std::string(jsonC);
        }
        if (idC) env->ReleaseStringUTFChars(id, idC);
        if (jsonC) env->ReleaseStringUTFChars(jsonStr, jsonC);
    } catch (...) {}
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_clearDensityCache(
    JNIEnv* env, jclass cls) {
    try {
        std::lock_guard<std::mutex> lock(g_rawMutex);
        g_rawDensityFunctions.clear();
        g_rawNoises.clear();
    } catch (...) {}
}

JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_registerDimension(
    JNIEnv* env, jclass cls, jstring dimName, jstring noiseJson, jlong seed) {
    if (!g_initialized) return JNI_FALSE;

    const char* nameC = env->GetStringUTFChars(dimName, nullptr);
    const char* noiseC = env->GetStringUTFChars(noiseJson, nullptr);
    if (!nameC || !noiseC) {
        if (nameC) env->ReleaseStringUTFChars(dimName, nameC);
        if (noiseC) env->ReleaseStringUTFChars(noiseJson, noiseC);
        return JNI_FALSE;
    }

    std::string dimNameStr(nameC);
    std::string noiseStr(noiseC);
    uint64_t seedU = (uint64_t)seed;

    env->ReleaseStringUTFChars(dimName, nameC);
    env->ReleaseStringUTFChars(noiseJson, noiseC);

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_failedDimensions.find(dimNameStr);
        if (it != g_failedDimensions.end() && it->second == seedU) {
            return JNI_FALSE;
        }
    }

    try {
        {
            std::lock_guard<std::mutex> lock(g_rawMutex);
            for (auto& kv : g_rawDensityFunctions) {
                try {
                    auto j = nlohmann::json::parse(kv.second);
                    DensityParser::registerDensityFunction(kv.first, j);
                } catch (...) {}
            }
            for (auto& kv : g_rawNoises) {
                try {
                    auto j = nlohmann::json::parse(kv.second);
                    DensityParser::registerNoise(kv.first, j);
                } catch (...) {}
            }
        }

        auto noiseJsonObj = nlohmann::json::parse(noiseStr);
        auto routerJsonObj = noiseJsonObj.at("noise_router");
        auto settings = DensityParser::parseNoiseSettings(noiseJsonObj, routerJsonObj, dimNameStr);

        CodeGenerator gen;
        gen.setSeed(seedU);
        std::string code = gen.generate(settings);

        auto rt = std::make_shared<DensityRuntime>();
        if (rt->compile(code, "kernel_final", "kernel_initial")) {
            short* d_out = nullptr;
            cudaStream_t stream = nullptr;
            size_t capacity = 16 * 16 * 512;

            cudaError_t e1 = cudaMalloc(&d_out, capacity * sizeof(short));
            cudaError_t e2 = cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking);
            if (e1 != cudaSuccess || e2 != cudaSuccess) {
                if (d_out) cudaFree(d_out);
                if (stream) cudaStreamDestroy(stream);
                setLastError("cudaMalloc/StreamCreate failed");
                std::lock_guard<std::mutex> lock(g_mutex);
                g_failedDimensions[dimNameStr] = seedU;
                return JNI_FALSE;
            }

            std::lock_guard<std::mutex> lock(g_mutex);
            auto existing = g_runtimes.find(dimNameStr);
            if (existing != g_runtimes.end()) {
                freeDimensionEntry(existing->second);
                g_runtimes.erase(existing);
            }
            DimensionEntry entry;
            entry.runtime = rt;
            entry.seed = seedU;
            entry.d_out = d_out;
            entry.d_capacity = capacity;
            entry.stream = stream;
            g_runtimes[dimNameStr] = entry;
            printf("[KorolevCross] Registered dimension %s with seed %lld\n",
                   dimNameStr.c_str(), (long long)seed);
            return JNI_TRUE;
        } else {
            setLastError("NVRTC compile failed");
            fprintf(stderr, "[KorolevCross] compile failed for %s\n", dimNameStr.c_str());
            std::lock_guard<std::mutex> lock(g_mutex);
            g_failedDimensions[dimNameStr] = seedU;
            return JNI_FALSE;
        }
    } catch (const std::exception& e) {
        std::string msg = std::string("exception: ") + e.what();
        setLastError(msg);
        fprintf(stderr, "[KorolevCross] registerDimension %s failed: %s\n",
                dimNameStr.c_str(), e.what());
        std::lock_guard<std::mutex> lock(g_mutex);
        g_failedDimensions[dimNameStr] = seedU;
        return JNI_FALSE;
    } catch (...) {
        setLastError("unknown exception");
        fprintf(stderr, "[KorolevCross] registerDimension %s failed: unknown\n",
                dimNameStr.c_str());
        std::lock_guard<std::mutex> lock(g_mutex);
        g_failedDimensions[dimNameStr] = seedU;
        return JNI_FALSE;
    }
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_generateChunk(
    JNIEnv* env, jclass cls, jstring dimName, jint chunkX, jint chunkZ,
    jint minY, jint maxY, jint seaLevel, jshortArray outputArray) {

    if (!g_initialized) return;
    const char* nameC = env->GetStringUTFChars(dimName, nullptr);
    if (!nameC) return;
    std::string dimNameStr(nameC);
    env->ReleaseStringUTFChars(dimName, nameC);

    std::shared_ptr<DensityRuntime> rt;
    short* d_out = nullptr;
    size_t d_capacity = 0;
    cudaStream_t stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_runtimes.find(dimNameStr);
        if (it == g_runtimes.end()) return;
        rt = it->second.runtime;
        d_out = it->second.d_out;
        d_capacity = it->second.d_capacity;
        stream = it->second.stream;
    }
    if (!rt || !rt->isLoaded() || !d_out) return;

    int sizeY = maxY - minY + 1;
    int total = 16 * 16 * sizeY;
    if ((size_t)total > d_capacity) return;

    rt->executeFinal(chunkX, chunkZ, minY, maxY, seaLevel, d_out, stream);
    cudaStreamSynchronize(stream);

    short* h_out = (short*)env->GetPrimitiveArrayCritical(outputArray, nullptr);
    if (h_out) {
        cudaMemcpy(h_out, d_out, total * sizeof(short), cudaMemcpyDeviceToHost);
        env->ReleasePrimitiveArrayCritical(outputArray, h_out, 0);
    }
}

JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_shutdown(
    JNIEnv* env, jclass cls) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto& pair : g_runtimes) freeDimensionEntry(pair.second);
    g_runtimes.clear();
    g_failedDimensions.clear();
    g_initialized = false;
}

}