cmake_minimum_required(VERSION 3.18)
project(korolev_native LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

set(CUDA_TOOLKIT_ROOT_DIR "E:/CUDA")
find_package(CUDAToolkit REQUIRED)
find_package(JNI REQUIRED)

set(SOURCES
    src/gpu_bridge.cpp
    src/density_parser.cpp
    src/code_generator.cpp
    src/density_runtime.cu
)

add_library(korolev_native SHARED ${SOURCES})

set_source_files_properties(src/density_runtime.cu PROPERTIES LANGUAGE CUDA)

target_include_directories(korolev_native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${JNI_INCLUDE_DIRS}
    "${CUDA_TOOLKIT_ROOT_DIR}/include"
)

target_compile_options(korolev_native PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math>
)

target_link_libraries(korolev_native
    "${CUDA_TOOLKIT_ROOT_DIR}/lib/x64/cuda.lib"
    "${CUDA_TOOLKIT_ROOT_DIR}/lib/x64/cudart.lib"
    "${CUDA_TOOLKIT_ROOT_DIR}/lib/x64/nvrtc.lib"
)

set_target_properties(korolev_native PROPERTIES
    CUDA_ARCHITECTURES "native"
    PREFIX ""
    SUFFIX ".dll"
    MSVC_RUNTIME_LIBRARY "MultiThreaded"
)

if(WIN32)
    set_target_properties(korolev_native PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/../main/resources/native"
    )
endif()