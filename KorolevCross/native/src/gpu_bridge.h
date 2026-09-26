#ifndef GPU_BRIDGE_H
#define GPU_BRIDGE_H

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_initCUDA(JNIEnv*, jclass);
JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_initOptiX(JNIEnv*, jclass);
JNIEXPORT jlong JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_createChunkMatrix(JNIEnv*, jclass, jint, jint, jint, jint);
JNIEXPORT void JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_destroyChunkMatrix(JNIEnv*, jclass, jlong);
JNIEXPORT jfloatArray JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_generateTerrainNoise(JNIEnv*, jclass, jlong, jint, jint, jint);
JNIEXPORT jintArray JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_generateBlockStates(JNIEnv*, jclass, jlong, jfloatArray, jint);
JNIEXPORT jboolean JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_buildAccelerationStructure(JNIEnv*, jclass, jlong);
JNIEXPORT jfloatArray JNICALL Java_com_fish_korolevcross_gpu_GPUBridge_traceTerrain(JNIEnv*, jclass, jlong, jfloat, jfloat, jfloat, jfloat, jfloat, jfloat);

#ifdef __cplusplus
}
#endif

#endif