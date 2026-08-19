cmake_minimum_required(VERSION 3.22.1)

project(llama_jni)

# Set C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Android 15 16KB page size compliance
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

# ARM64 optimizations
#
# EXPERIMENT -- see the note below before shipping this.
#
# This was -march=armv8-a+crc, the 2013 baseline, and because it lands in the
# global CMAKE_C_FLAGS every one of ggml's translation units got it: a build
# log check found -march=armv8-a+crc on all 358 compile commands and nothing
# else, so GGML_DOTPROD below never produced a flag. That compiles out the
# dotprod and fp16 kernels ggml uses for quantized matmul, which is most of
# what a ViT encode and a prompt prefill do.
#
# The test device (Dimensity 7300, Cortex-A78) reports asimddp, fphp and
# asimdhp in /proc/cpuinfo, so the silicon has both and the binary was not
# asking for either. No i8mm or sve on ARMv8.2, so those stay out.
#
# CAUTION: armv8.2-a is a hard floor -- an ARMv8.0 device (pre-2017) gets
# SIGILL, not a slow path. Shipping this needs ggml's runtime dispatch
# (GGML_CPU_ALL_VARIANTS + GGML_BACKEND_DL) instead of a raised baseline.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -march=armv8.2-a+crc+dotprod+fp16")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -march=armv8.2-a+crc+dotprod+fp16")
endif()

# llama.cpp options
set(GGML_CPU_AARCH64 ON CACHE BOOL "Enable ARM64 support")
set(GGML_DOTPROD ON CACHE BOOL "Enable ARM NEON dot product")
# ggml-vulkan.cpp includes <vulkan/vulkan.hpp> and <spirv/unified1/spirv.hpp>.
# The NDK sysroot carries the Vulkan *C* headers only (no vulkan.hpp) and no
# SPIR-V headers at all, and taking the C++ ones from whatever the host distro
# happens to ship mixes header versions with the sysroot's C headers. So the
# matching Khronos sets (both vulkan-sdk-1.3.275, same as the NDK's loader) are
# vendored here and pointed at explicitly -- the build is then identical on a
# dev machine and on a CI runner, with nothing to apt-install first.
set(VULKAN_HEADERS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/vulkan-headers)
set(Vulkan_INCLUDE_DIR ${VULKAN_HEADERS_DIR} CACHE PATH "Khronos headers for the Vulkan backend")

# Compile the shaders with the NDK's own glslc rather than whatever the host
# happens to have. find_package(Vulkan COMPONENTS glslc REQUIRED) hard-fails when
# the host has none -- which is the case on a stock CI runner -- and when the host
# DOES have one, its version silently decides which shader variants get built.
#
# The NDK's glslc is older, so the cooperative-matrix, bfloat16 and
# integer-dot-product shader sets are skipped. That is the right trade here: those
# first two need hardware no Mali GPU has, and the whole set costs 27 MB of
# embedded SPIR-V (59 MB of .so against 32 MB). To build them anyway on a machine
# with a current Vulkan SDK, override this: -DVulkan_GLSLC_EXECUTABLE=/usr/bin/glslc
if(ANDROID AND NOT DEFINED Vulkan_GLSLC_EXECUTABLE)
    file(GLOB _ndk_shader_tools ${ANDROID_NDK}/shader-tools/*/glslc)
    if(_ndk_shader_tools)
        list(GET _ndk_shader_tools 0 Vulkan_GLSLC_EXECUTABLE)
        set(Vulkan_GLSLC_EXECUTABLE ${Vulkan_GLSLC_EXECUTABLE} CACHE FILEPATH "glslc from the NDK")
        message(STATUS "Using the NDK's glslc: ${Vulkan_GLSLC_EXECUTABLE}")
    endif()
endif()

# Vulkan GPU backend. The NDK sysroot provides libvulkan.so to link against, and
# llama.cpp's ggml-vulkan CMake cross-compiles vulkan-shaders-gen for the host on
# its own, so this needs no toolchain patching -- unlike the llama.rn route, which
# has to rename every ggml_* symbol to lm_ggml_*.
set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan GPU backend")
set(GGML_OPENMP OFF CACHE BOOL "Disable OpenMP to avoid packaging libomp.so" FORCE)
set(GGML_STATIC OFF CACHE BOOL "Build as shared library")
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared libraries")

# Disable unused features
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Disable tests")
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Disable examples")
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Disable server")

# Add llama.cpp
add_subdirectory(src/main/cpp/llama.cpp)

# ggml-base is linked as a standalone shared object and contains C++ sources.
# On Android/NDK it must explicitly link libc++ or symbols such as operator new
# and std::runtime_error stay unresolved during the native build.
if(ANDROID)
    foreach(target ggml-base ggml ggml-cpu ggml-vulkan llama)
        if(TARGET ${target})
            target_link_libraries(${target} PRIVATE c++_shared)
        endif()
    endforeach()
endif()

# --- libmtmd: multimodal (vision + audio) input for GGUF models ---------------
#
# Vendored from upstream tools/mtmd at commit 4fbdabdc6, which is the revision
# the llama.cpp copy under src/main/cpp/llama.cpp matches. The target is
# declared here rather than via add_subdirectory because upstream's CMakeLists
# also builds llama-mtmd-cli and install() rules that make no sense in an .apk.
#
# mtmd must NOT link against common -- upstream enforces that with a
# FATAL_ERROR, since mtmd is a public library and common is not.
set(MTMD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/llama.cpp/tools/mtmd)

file(GLOB MTMD_MODEL_SOURCES ${MTMD_DIR}/models/*.cpp)

add_library(mtmd STATIC
    ${MTMD_DIR}/mtmd.cpp
    ${MTMD_DIR}/mtmd-audio.cpp
    ${MTMD_DIR}/mtmd-image.cpp
    ${MTMD_DIR}/mtmd-helper.cpp
    ${MTMD_DIR}/clip.cpp
    ${MTMD_MODEL_SOURCES}
)

target_link_libraries(mtmd PUBLIC ggml llama PRIVATE c++_shared)

target_include_directories(mtmd PUBLIC ${MTMD_DIR})
target_include_directories(mtmd PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/llama.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/llama.cpp/vendor
)
target_compile_features(mtmd PRIVATE cxx_std_17)

# Static library folded into a shared one: without -fPIC the link fails on arm64.
set_target_properties(mtmd PROPERTIES POSITION_INDEPENDENT_CODE ON)

# stb_image.h and miniaudio.h are header-only C and trip this warning wholesale.
target_compile_options(mtmd PRIVATE -Wno-cast-qual)

# JNI wrapper library - simplified without common library
add_library(llama_jni SHARED
    src/main/cpp/jni_wrapper.cpp
)

target_link_libraries(llama_jni
    llama
    mtmd
    c++_shared
    android
    log
)

target_include_directories(llama_jni PRIVATE
    src/main/cpp/llama.cpp/include
    src/main/cpp/llama.cpp/ggml/include
    src/main/cpp/llama.cpp/tools/mtmd
)
