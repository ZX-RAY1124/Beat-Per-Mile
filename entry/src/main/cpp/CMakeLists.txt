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

add_library(entry SHARED napi_bridge_center.cpp test_audio.h test_audio.cpp audio_process.h audio_process.cpp)

# ★★ 关键：必须开优化 ★★
#   signalsmith-stretch 跑在 -O0 下**达不到实时**，音频生产线程跟不上声卡，
#   表现就是日志里的 "underrun: need N, got 0"（掉音/卡顿）。
#   TimeStretchEngine.hpp 原话："编译选项：至少 -O2，否则性能严重下降"。
#   DevEco 的 debug 构建默认给 -O0，所以给目标显式追加 -O2 ——
#   target_compile_options 在命令行里排在 CMAKE_CXX_FLAGS_<CONFIG>(-O0) 之后，
#   后出现的 -O 生效，所以能盖掉它。
#   ⚠️ 必须写在 add_library 之后：CMake 不允许给还不存在的 target 设选项。
target_compile_options(entry PRIVATE -O2)

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
    libohaudio.so
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
    qos                      # OH_QoS_SetThreadQoS：音频线程优先级
)