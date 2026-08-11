# HarmonyOS 交叉编译 Essentia 完整技术复盘

> **项目**：Beat Per Mile（BPM 节拍检测）
> **目标平台**：HarmonyOS (aarch64 / x86_64)
> **核心库**：Essentia 2.1 beta5
> **日期**：2026-08

---

## 目录

1. [构建系统对比：CMake / Autotools / Waf](#1-构建系统对比)
2. [.so 文件与头文件的意义](#2-so-文件与头文件的意义)
3. [交叉编译核心参数详解](#3-交叉编译核心参数详解)
4. [sed / libtool 修复原理](#4-sed--libtool-修复原理)
5. [常用排查命令速查表](#5-常用排查命令速查表)
6. [完整编译流程总结](#6-完整编译流程总结)
7. [常见坑与解决方案](#7-常见坑与解决方案)

---

## 1. 构建系统对比

| 特性        | CMake                         | Autotools (configure)         | Python Waf                                 |
|-----------|-------------------------------|-------------------------------|--------------------------------------------|
| **配置文件**  | `CMakeLists.txt`              | `configure.ac` → `configure`  | `wscript`                                  |
| **指定编译器** | `-DCMAKE_C_COMPILER=...`      | `CC=xxx CXX=xxx` 环境变量         | `CXX=xxx CC=xxx` 环境变量                      |
| **安装路径**  | `-DCMAKE_INSTALL_PREFIX=...`  | `--prefix=...`                | `--prefix=...`                             |
| **构建命令**  | `cmake .. && make -j`         | `./configure && make -j`      | `python waf configure && python waf build` |
| **清理**    | `rm -rf build`                | `make clean`                  | `rm -rf build .waf3-*`                     |
| **典型库**   | yaml-cpp, TagLib, chromaprint | FFTW3, libyaml, libsamplerate | Essentia                                   |

### 关键理解

- **CMake**：现代 C++ 项目首选，跨平台能力强。用 `-D变量=值` 传参数。
- **Autotools**：古老的 Unix 构建系统，通过 `./configure` 脚本生成 Makefile。`CC=xxx` 环境变量指定编译器。
- **Waf**：Python 编写的构建系统，Essentia 使用。通过环境变量 `CXX`/`CC` 和命令行参数配置。

### 为什么不能混用

不同系统对"指定编译器"的语法完全不同：
- CMake：`-DCMAKE_CXX_COMPILER=/path/to/clang++`
- Autotools：`CC=/path/to/clang ./configure`
- Waf：`CXX=/path/to/clang++ python waf configure`

用错语法 → 编译器找不到 → 编译失败。

---

## 2. .so 文件与头文件的意义

### 头文件（.h / .hpp）  
作用：声明函数/类的"签名"（叫什么名字、参数是什么）
类比：菜单 —— 告诉你可以点哪些菜
编译阶段需要，运行时不需要
**为什么 `#include <fileref.h>` 找不到：**
- TagLib 的 `fileref.h` 在 `${PREFIX}/include/taglib/` 子目录下
- 编译命令只有 `-I${PREFIX}/include`，没有 `-I${PREFIX}/include/taglib`
- 解决：加 `-I${PREFIX}/include/taglib`

### 动态库（.so）
作用：函数的实体实现（真正干活的代码）
类比：厨房 —— 实际做菜的地方
链接阶段需要，运行时需要

**SONAME 机制：**

```bash
readelf -d libavcodec.so.58 | grep SONAME
# → SONAME: libavcodec.so.58

# 文件名与 SONAME 必须匹配：
libavcodec.so.58          ← 文件名
  ├── libavcodec.so       ← 符号链接（开发时用）
  ├── libavcodec.so.58    ← 符号链接（运行时找这个）
  └── libavcodec.so.58.134.100  ← 真实文件（包含完整版本号）
```
```
CMakeLists.txt 中必须用完整文件名引用带版本号的 so：
# ❌ 错误：链接器找 libfftw3f.so（不存在，你的是 libfftw3f.so.3）
target_link_libraries(entry PUBLIC fftw3f)

# ✅ 正确：直接用完整路径
target_link_libraries(entry PUBLIC ${PREBUILT_LIBS}/libfftw3f.so.3)
```
## 3. 交叉编译核心参数详解
包装脚本参数
```bash
exec clang++ \
    --target=aarch64-linux-ohos \      # ① 目标 CPU-系统-平台 三元组
    --sysroot=/path/to/sysroot \       # ② 系统根目录（头文件+系统库）
    -rtlib=compiler-rt \               # ③ 使用 compiler-rt 替代 libgcc
    -unwindlib=libunwind \             # ④ 栈回溯库
    -stdlib=libc++ \                   # ⑤ C++ 标准库（仅 clang++）
    -fuse-ld=lld \                     # ⑥ 使用 lld 链接器
    "$@"                               # ⑦ 透传用户参数
```

| 参数                             | 含义            | 为什么需要                            |
|--------------------------------|---------------|----------------------------------|
| `--target=aarch64-linux-ohos`	 | 告诉编译器目标不是宿主机	 | 不设就编译出 x86_64 的代码                |
| `--sysroot`                    | 	系统头文件和库的根目录  | 	找不到 `stdio.h`、`libc.so` 等系统基础库  |
| `-rtlib=compiler-rt`           | 	避免依赖 libgcc  | 	HarmonyOS 用 musl libc，没有 libgcc |
| `-stdlib=libc++`	              | C++ 标准库实现	    | HarmonyOS NDK 提供的是 libc++        |
| `-fuse-ld=lld`	                | 使用 LLVM 链接器	  | GNU ld 不认识 OHOS 格式               |

通用编译参数
`CFLAGS="-fPIC -D__MUSL__=1 -O3 -I${PREFIX}/include"`

| 参数             | 	含义                             |
|----------------|---------------------------------|
| `-fPIC `       | 	位置无关代码（动态库必需）                  |
| `-D__MUSL__=1` | 	告诉代码"我们在 musl libc 上运行"，触发兼容分支 |
| `-O3`	         | 最高优化级别                          |
| `-I/path`      | 头文件搜索路径                         |
| `-L/path`	     | 库文件搜索路径（链接阶段）                   |

Autotools 特有参数
`./configure --host=aarch64-unknown-linux-gnu --prefix=${PREFIX}`

| 参数                 | 	含义                        |
|--------------------|----------------------------|
| `--host=三元组`	      | 告诉 configure 这是交叉编译，目标机器架构 |
| `--prefix`	        | make install 装到哪里          |
| `--enable-shared`  | 	编译动态库 (.so)               |
| `--disable-static` | 	不编译静态库 (.a)               |

**--host 的三元组格式：**
```
aarch64-unknown-linux-gnu
  │       │      │    └─ ABI（GNU libc 的约定，即使我们用 musl 也填这个）
  │       │      └────── 操作系统（linux）
  │       └───────────── 厂商（一般填 unknown）
  └───────────────────── CPU 架构（aarch64 = ARM 64位）
```
FFmpeg 特有参数
`./configure --arch=aarch64 --cc=ohos-clang --cross-prefix=...`
- --arch=aarch64：目标架构（非 x86）
- --cc / --cxx：编译器路径（FFmpeg 用自己方式检测编译器）
- --enable-avresample：启用音频重采样（Essentia 需要，FFmpeg 6.x 已废弃）
- --pkg-config=false：禁用 pkg-config（避免找宿主机的库）
CMake 交叉编译参数
``` 
cmake .. \
    -DCMAKE_C_COMPILER=ohos-clang \
    -DCMAKE_CXX_COMPILER=ohos-clang++ \
    -DCMAKE_FIND_ROOT_PATH=${SYSROOT}
```
- CMAKE_FIND_ROOT_PATH：限定 find_library/find_path 的搜索根目录

## 4. sed / libtool 修复原理

>问题   
>Autotools 生成的 libtool 文件在链接时会自动加 -lgcc_s 和 -lgcc，但 HarmonyOS 没有 libgcc。

修复命令:`sed -i 's/-lgcc_s//g; s/-lgcc//g' libtool`
逐段解析
``` 
sed -i                       # in-place 编辑（直接修改文件）
    's/-lgcc_s//g;           # ① 把 -lgcc_s 替换为空（全局替换）
     s/-lgcc//g'             # ② 把 -lgcc 替换为空（全局替换）
    libtool                  # 要修改的文件名
```

| 语法元素         | 	含义                           |
|--------------|-------------------------------|
| `sed`        | 	Stream Editor，流编辑器           |
| `-i`	        | 直接修改文件（in-place）              |
| `s/查找/替换/g`	 | 正则替换，`g` = global（全部替换，不只第一个） |
| `;`	         | 分隔多个 sed 命令                   |

验证是否改干净
```
grep 'lgcc' libtool
# 无输出 = 改干净了
```

## 5. 常用排查命令速查表
**文件分析**    

| 命令                  | 	作用                | 	示例                                 |
|---------------------|--------------------|-------------------------------------|
| `file xxx.so`	      | 查看文件类型和架构	         | `file libessentia.so` → ARM aarch64 |
| `readelf -d xxx.so` | 	查看动态链接依赖（NEEDED）	 | 确认链接了哪些 so                          |
| `readelf -h xxx.so` | 	查看 ELF 头（机器类型）	   | 确认是 AArch64 还是 x86-64               |
| `ldd xxx.so`        | 	查看运行时依赖	          | 只能在目标平台运行                           |
| `ls -la`	           | 查看符号链接	            | `libavcodec.so → libavcodec.so.58`  |

**文本搜索**

| 命令                           | 	作用       | 	示例                               |
|------------------------------|-----------|-----------------------------------|
| `grep -rn "关键词" 目录`	         | 递归搜索文本    | 	`grep -rn "msse" src/`           |         
| `grep -rn --include="*.py"`	 | 限定文件类型    | 	只在 Python 文件里搜                   |                  
| `head -30 文件`	               | 看文件前 30 行 | 	`head -30 config.log `           |
| `tail -40 文件`	               | 看文件后 40 行 | 	看编译日志尾部                          |
| `cat -A 文件`	                 | 显示隐藏字符    | 	检查是否有 Windows 换行 `^M`            |
| `find 目录 -name "*.h"`        | 	按文件名查找   | 	`find include -name "fileref.h"` | 

**编译调试**

| 命令                                      | 	作用           | 	示例           |
|-----------------------------------------|---------------|---------------|
| `make -j$(nproc) 2>&1 \| tee build.log` | 	编译并保存日志	     | 出错后可以 grep    |
| `make -n`	                              | 干跑（只打印命令不执行）	 | 检查链接参数是否正确    |
| `pkg-config --cflags taglib`	           | 查询库的编译参数	     | 确认 include 路径 |
| `pkg-config --libs taglib`	             | 查询库的链接参数	     | 确认 -L 和 -l    |

**环境与路径**

| 命令                            | 	作用            |
|-------------------------------|----------------|
| `echo ${INSTALL_PREFIX}`      | 	确认变量值         |
| `which clang++`               | 	找编译器位置        |
| `ls ${PREFIX}/lib/pkgconfig/` | 	查看已安装的 .pc 文件 |

## 6. 完整编译流程总结
### 6.1 总体思路
```
① 创建包装脚本（隐藏 SDK 路径 + target/sysroot 参数）
② 按依赖顺序编译每个库（FFTW3 → libyaml → libsamplerate → yaml-cpp → FFmpeg → TagLib → chromaprint）
③ 最后编译 Essentia（waf 会通过 pkg-config 找到前面的所有库）
④ 打包：头文件到 include/，.so 到 libs/<arch>/
⑤ 配置 CMakeLists.txt（完整路径引用 .so）
⑥ 配置 build-profile.json5（abiFilters）
```
### 6.2 依赖关系图
```
Essentia
├── FFTW3         ← 先装（FFT 计算）
├── libyaml       ← 先装（配置文件解析）
├── libsamplerate ← 先装（采样率转换）
├── FFmpeg 4.4    ← 先装（音频解码/重采样）
│   ├── libavformat
│   ├── libavcodec
│   ├── libavutil
│   └── libavresample
├── TagLib        ← 依赖 zlib（系统提供）
├── yaml-cpp      ← （Essentia 可选依赖）
└── chromaprint   ← 依赖 FFmpeg
```
### 6.3 每个库的标准模板
**Autotools 模板**
``` 
CC=包装脚本路径 ./configure --host=三元组 --prefix=安装路径 CFLAGS="-fPIC -D__MUSL__=1 -O3"
sed -i 's/-lgcc_s//g; s/-lgcc//g' libtool
make -j$(nproc) && make install
```
**CMake 模板**
```
cmake .. -DCMAKE_C_COMPILER=包装脚本 -DCMAKE_CXX_COMPILER=包装脚本++ -DCMAKE_INSTALL_PREFIX=安装路径
make -j$(nproc) && make install
```

### 6.4 打包清单
``` 
项目/entry/src/main/cpp/
├── libs/
│   ├── arm64-v8a/
│   │   ├── libessentia.so
│   │   ├── libfftw3f.so.3
│   │   ├── libavformat.so.58
│   │   ├── libavcodec.so.58
│   │   ├── libavutil.so.56
│   │   ├── libavresample.so.4
│   │   ├── libsamplerate.so.0
│   │   ├── libtag.so.2
│   │   ├── libyaml-0.so.2
│   │   └── libchromaprint.so.1
│   └── x86_64/
│       └── ...（同上）
├── include/
│   ├── essentia/
│   ├── taglib/
│   ├── fftw3.h
│   ├── samplerate.h
│   ├── chromaprint.h
│   ├── libavcodec/
│   ├── libavformat/
│   ├── libavutil/
│   └── ...
├── napi_init.cpp
└── CMakeLists.txt
```
## 7. 常见坑与解决方案

| 坑                                    | 	原因                              | 	解决                                               |
|--------------------------------------|----------------------------------|---------------------------------------------------|
| "could not configure a C++ compiler" | 	waf 在宿主机上运行交叉编译出的测试程序，运行失败      | 	用环境变量 `CXX=` 而非 `--check-cxx-compiler`           |
| "unknown FP unit 'sse'"              | 	waf 自动加了 x86 的` -msse `到 ARM 编译 | 	`--no-msse` 或设 `-march=armv8-a `                 |
| `fileref.h` 找不到                      | 	TagLib 的头文件在子目录                 | 	CFLAGS 加 `-I${PREFIX}/include/taglib`            |
| `-lfftw3f` 找不到                       | 	so 文件名带版本号（`.so.3`）             | 	CMakeLists.txt 用完整路径                             |
| 模拟器安装失败 (code 9568347)               | 	模拟器 x86_64，so 是 arm64           | 	编译 x86_64 版本或改 `abiFilters `                     |
| libc++ `time_t` unresolved           | 	musl libc 与 libc++ 的类型兼容问题      | 	`add_compile_definitions(_LIBCPP_HAS_MUSL_LIBC)` |
| FFmpeg 版本混淆（.58 vs .60）              | 	装过两个版本的 FFmpeg                  | 	Essentia 需要 FFmpeg 4.4（有 avresample）             |
| sed 修改 libtool 无效                    | 	`make clean` 后 libtool 被重置	     | `./configure` 之后、make 之前执行 sed                    |

*附录：快速启动脚本*
下次从头编译 `arm64-v8a`，可以把这个保存为 `build_all.sh`：
```bash
#!/bin/bash
set -e  # 遇到错误立即退出

export LLVM_BIN=/home/zx_rayer/ohos-sdk/linux/.../llvm/bin
export SYSROOT=/home/zx_rayer/ohos-sdk/linux/.../sysroot
export PREFIX=/home/zx_rayer/essentia_ohos/install/arm64-v8a
export CC_WRAP="${HOME}/essentia_build/ohos-clang"
export CXX_WRAP="${HOME}/essentia_build/ohos-clang++"

mkdir -p ${PREFIX}

# 1. FFTW3
cd ~/essentia_build/fftw-3.3.10
make clean 2>/dev/null
CC=${CC_WRAP} ./configure --host=aarch64-unknown-linux-gnu --prefix=${PREFIX} \
    --enable-shared --disable-static --enable-float CFLAGS="-fPIC -D__MUSL__=1 -O3"
sed -i 's/-lgcc_s//g; s/-lgcc//g' libtool
make -j$(nproc) && make install

# 2. libyaml
cd ~/essentia_build/yaml-0.2.5
make clean 2>/dev/null
CC=${CC_WRAP} ./configure --host=aarch64-unknown-linux-gnu --prefix=${PREFIX} \
    CFLAGS="-fPIC -D__MUSL__=1 -O3" --enable-shared --disable-static
sed -i 's/-lgcc_s//g; s/-lgcc//g' libtool
make -j$(nproc) && make install

# 3. libsamplerate
cd ~/essentia_build/libsamplerate-0.2.2
make clean 2>/dev/null
CC=${CC_WRAP} ./configure --host=aarch64-unknown-linux-gnu --prefix=${PREFIX} \
    CFLAGS="-fPIC -D__MUSL__=1 -O3" --enable-shared --disable-static
sed -i 's/-lgcc_s//g; s/-lgcc//g' libtool
make -j$(nproc) && make install

# 4. yaml-cpp
cd ~/essentia_build/yaml-cpp-0.8.0
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_C_COMPILER=${CC_WRAP} -DCMAKE_CXX_COMPILER=${CXX_WRAP} \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DYAML_BUILD_SHARED_LIBS=ON \
    -DYAML_CPP_BUILD_TESTS=OFF -DCMAKE_FIND_ROOT_PATH=${SYSROOT}
make -j$(nproc) && make install

# 5. FFmpeg
cd ~/essentia_build/ffmpeg-4.4.4
make clean 2>/dev/null
./configure --cc=${CC_WRAP} --cxx=${CXX_WRAP} --arch=aarch64 --target-os=linux \
    --enable-cross-compile --prefix=${PREFIX} --sysroot=${SYSROOT} \
    --extra-cflags="--target=aarch64-linux-ohos -D__MUSL__=1 -fPIC" \
    --extra-ldflags="--target=aarch64-linux-ohos -fPIC" \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-avdevice --disable-postproc --disable-encoders --disable-muxers \
    --disable-filters --disable-bsfs --disable-vulkan --disable-sdl2 \
    --enable-encoder=pcm_s16le \
    --enable-decoder=aac,mp3,flac,vorbis,opus,wavpack,pcm_s16le \
    --enable-demuxer=aac,mp3,flac,ogg,wav,mov,mp4,m4a \
    --enable-parser=aac,mp3,flac,vorbis,opus --enable-protocol=file \
    --enable-avresample --pkg-config=false
make -j$(nproc) && make install

# 6. TagLib
cd ~/essentia_build/taglib-1.13.1
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_C_COMPILER=${CC_WRAP} -DCMAKE_CXX_COMPILER=${CXX_WRAP} \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DCMAKE_FIND_ROOT_PATH=${SYSROOT} \
    -DZLIB_INCLUDE_DIR=${SYSROOT}/usr/include \
    -DZLIB_LIBRARY=${SYSROOT}/usr/lib/aarch64-linux-ohos/libz.so
make -j$(nproc) && make install

# 7. chromaprint
cd ~/essentia_build/chromaprint-1.5.1
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_C_COMPILER=${CC_WRAP} -DCMAKE_CXX_COMPILER=${CXX_WRAP} \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF \
    -DCMAKE_FIND_ROOT_PATH="${SYSROOT};${PREFIX}" -DFFMPEG_ROOT=${PREFIX}
make -j$(nproc) && make install

# 8. Essentia
cd ~/essentia_build/essentia-2.1_beta5
source ~/essentia_venv/bin/activate
rm -rf build .waf3-*
CXX=${CXX_WRAP} CC=${CC_WRAP} \
CFLAGS="-fPIC -D__MUSL__=1 -O3 -I${PREFIX}/include -I${PREFIX}/include/taglib" \
CXXFLAGS="-fPIC -D__MUSL__=1 -O3 -I${PREFIX}/include -I${PREFIX}/include/taglib" \
LDFLAGS="-L${PREFIX}/lib" \
PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="${SYSROOT}" \
python waf configure --prefix=${PREFIX} --mode=release --no-msse
python waf build -j$(nproc)
python waf install

echo "===== 全部完成 ====="
file ${PREFIX}/lib/libessentia.so
```

2026 真离散工作室    
Kirisan Studio 2026
