cmake_minimum_required(VERSION 3.20)
project(korolev_native LANGUAGES CXX CUDA)

set(CMAKE_CUDA_ARCHITECTURES 89)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CXX_STANDARD 17)

find_package(JNI REQUIRED)

add_library(korolev_native SHARED
        src/kv_native.cu)

target_include_directories(korolev_native PRIVATE ${JNI_INCLUDE_DIRS} src)

target_compile_options(korolev_native PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:--fmad=false -O3 -lineinfo>)

set_target_properties(korolev_native PROPERTIES
        CUDA_SEPARABLE_COMPILATION OFF
        CUDA_RUNTIME_LIBRARY Shared
        PREFIX ""
        OUTPUT_NAME "korolev_native"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../main/resources/native/Release"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../main/resources/native/Release")
