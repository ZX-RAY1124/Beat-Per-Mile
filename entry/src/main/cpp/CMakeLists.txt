cmake_minimum_required(VERSION 3.5.0)
project(BeatPerMile)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# ⚠️ 核心修复：让 libc++ 在 musl 环境下正确处理 time_t
add_compile_definitions(_LIBCPP_HAS_MUSL_LIBC)

include_directories(
    ${NATIVERENDER_ROOT_PATH}/include
    ${NATIVERENDER_ROOT_PATH}/include/essentia
    ${NATIVERENDER_ROOT_PATH}/include/taglib
    ${NATIVERENDER_ROOT_PATH}/include/libavutil
    ${NATIVERENDER_ROOT_PATH}/include/libavcodec
    ${NATIVERENDER_ROOT_PATH}/include/libavformat
    ${NATIVERENDER_ROOT_PATH}/include/libavresample
    ${NATIVERENDER_ROOT_PATH}/include/libswresample
    ${NATIVERENDER_ROOT_PATH}/include/libswscale
)

set(PREBUILT_LIBS ${NATIVERENDER_ROOT_PATH}/libs/${OHOS_ARCH})

add_library(entry SHARED napi_init.cpp)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    ${PREBUILT_LIBS}/libessentia.so
    ${PREBUILT_LIBS}/libfftw3f.so.3
    ${PREBUILT_LIBS}/libavformat.so.58
    ${PREBUILT_LIBS}/libavcodec.so.58
    ${PREBUILT_LIBS}/libavutil.so.56
    ${PREBUILT_LIBS}/libavresample.so.4
    ${PREBUILT_LIBS}/libsamplerate.so.0
    ${PREBUILT_LIBS}/libtag.so.2
    ${PREBUILT_LIBS}/libyaml-0.so.2
    ${PREBUILT_LIBS}/libchromaprint.so.1
)