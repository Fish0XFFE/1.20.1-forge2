cmake_minimum_required(VERSION 3.18)
project(korolev_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(JNI REQUIRED)

set(CUDA_TOOLKIT_ROOT_DIR "E:/CUDA")
set(NVCC_EXECUTABLE "${CUDA_TOOLKIT_ROOT_DIR}/bin/nvcc.exe")

# 构建包含目录参数（用于 nvcc）
set(CUDA_INCLUDES "")
list(APPEND CUDA_INCLUDES "${CUDA_TOOLKIT_ROOT_DIR}/include")
list(APPEND CUDA_INCLUDES ${JNI_INCLUDE_DIRS})
list(APPEND CUDA_INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/src")

# 生成包含目录字符串
set(INCLUDE_ARGS "")
foreach(dir ${CUDA_INCLUDES})
    set(INCLUDE_ARGS "${INCLUDE_ARGS} -I\"${dir}\"")
endforeach()

# 自定义命令：编译 terrain_kernel.cu -> terrain_kernel.obj
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/terrain_kernel.obj
    COMMAND ${NVCC_EXECUTABLE} -c -arch=native -Xcompiler "/EHsc /MD" ${INCLUDE_ARGS} -o ${CMAKE_CURRENT_BINARY_DIR}/terrain_kernel.obj ${CMAKE_CURRENT_SOURCE_DIR}/src/terrain_kernel.cu
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/terrain_kernel.cu
    COMMENT "Compiling CUDA kernel with nvcc"
)

# 主库：普通 C++ 源文件 + 编译好的 CUDA obj
add_library(korolev_native SHARED src/gpu_bridge.cpp ${CMAKE_CURRENT_BINARY_DIR}/terrain_kernel.obj)

target_include_directories(korolev_native PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${JNI_INCLUDE_DIRS}
    ${CUDA_TOOLKIT_ROOT_DIR}/include
)

target_link_libraries(korolev_native
    "${CUDA_TOOLKIT_ROOT_DIR}/lib/x64/cuda.lib"
    "${CUDA_TOOLKIT_ROOT_DIR}/lib/x64/cudart.lib"
)

set_target_properties(korolev_native PROPERTIES
    PREFIX ""
    SUFFIX ".dll"
)

if(WIN32)
    set_target_properties(korolev_native PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/../main/resources/native"
    )
endif()