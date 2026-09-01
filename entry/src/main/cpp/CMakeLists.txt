cmake_minimum_required(VERSION 3.5.0)
project(BeatPerMile)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# ⚠️ 核心修复：让 libc++ 在 musl 环境下正确处理 time_t
add_compile_definitions(_LIBCPP_HAS_MUSL_LIBC)

# 只保留父级 include 目录，第三方头文件统一用子目录前缀引用（如 libavutil/xxx.h）。
# 切勿把 libavutil 等子目录单独加入 -I，否则其中的 time.h 会遮蔽 musl 的 <time.h>，
# 导致 <ctime> 里的 time_t / nanosleep 无法解析（system_clock.h 编译报错）。
include_directories(
    ${NATIVERENDER_ROOT_PATH}/include
)

set(PREBUILT_LIBS ${NATIVERENDER_ROOT_PATH}/libs/${OHOS_ARCH})

add_library(entry SHARED napi_init.cpp test_audio.h test_audio.cpp audio_process.h audio_process.cpp)

if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(FFTW_LIB ${PREBUILT_LIBS}/libfftw3f.so.3.6.9)
else()
    set(FFTW_LIB ${PREBUILT_LIBS}/libfftw3f.so.3)
endif()



target_link_libraries(entry PUBLIC
    c++_static
    c++abi
    libace_napi.z.so
    libhilog_ndk.z.so
    ${PREBUILT_LIBS}/libessentia.so
    ${FFTW_LIB}
    ${PREBUILT_LIBS}/libavformat.so.58
    ${PREBUILT_LIBS}/libavcodec.so.58
    ${PREBUILT_LIBS}/libavutil.so.56
    ${PREBUILT_LIBS}/libavresample.so.4
    ${PREBUILT_LIBS}/libswresample.so.3
    ${PREBUILT_LIBS}/libsamplerate.so.0
    ${PREBUILT_LIBS}/libtag.so.2
    ${PREBUILT_LIBS}/libyaml-0.so.2
    ${PREBUILT_LIBS}/libchromaprint.so.1
)