# C++ 开发注意事项

> **来源**：从本次「`ctime` / `system_clock` 编译报错」Debug 过程总结的经验
> **项目**：Beat Per Mile（HarmonyOS 原生 C++ / ArkTS）
> **适用对象**：C++ 架构还不熟、但需要维护 C++ 交叉编译项目的开发者
> **日期**：2026-08

---

## 目录

1. [一句话总结](#一句话总结)
2. [本次问题的完整因果链](#本次问题的完整因果链)
3. [核心概念一：编译器如何查找头文件](#核心概念一编译器如何查找头文件)
4. [核心概念二：头文件遮蔽（Shadowing）](#核心概念二头文件遮蔽shadowing)
5. [核心概念三：`#include <...>` 与 `#include "..."`](#核心概念三include--与-include-)
6. [第三方库集成的正确姿势](#第三方库集成的正确姿势)
7. [HarmonyOS NDK 特殊注意点](#harmonyos-ndk-特殊注意点)
8. [高效 Debug 方法论](#高效-debug-方法论)
9. [避坑清单速查表](#避坑清单速查表)

---

## 一句话总结

> 本次报错的本质**不是** `ctime` 和 `system_clock` 有冲突，而是 **FFmpeg 自带的 `time.h` 遮蔽（覆盖）了系统 musl 的 `time.h`**，导致 `time_t`、`nanosleep` 等类型/函数「凭空消失」。

理解这一点，就理解了 C++ 开发里最容易踩、也最隐蔽的一类坑：**头文件同名冲突**。

---

## 本次问题的完整因果链

```
① CMakeLists.txt 把 FFmpeg 的每个子目录都加成了 -I 搜索路径
      include_directories(.../include/libavutil)   ← 问题源头
      include_directories(.../include/libavcodec)
      ...

② 编译 napi_init.cpp 时，代码里有 #include <string>
      → <string> 内部又引入 <atomic>
      → <atomic> 引入 <__thread/poll_with_backoff.h>
      → 最终引入 libc++ 的 <ctime>

③ <ctime> 头文件内部执行 #include <time.h>
      → 编译器按「就近原则」在 -I 路径里找 time.h
      → 找到了 FFmpeg 的 include/libavutil/time.h（而不是 musl 的 time.h）

④ FFmpeg 的 time.h 只声明了 av_gettime() 等函数
      → 没有定义 time_t
      → 没有声明 nanosleep

⑤ 于是报错：
      system_clock.h:37  → time_t 无法解析（unresolved using declaration）
      __threading_support:412 → nanosleep 未声明
```

**关键启示**：错误信息指向的是「受害者」（`system_clock.h`、`<ctime>`），但**真正的凶手**是「头文件搜索路径配置」。Debug 时不要只盯着报错的那一行，要顺着 `#include` 链条往上追。

---

## 核心概念一：编译器如何查找头文件

编译器（Clang/Clang++）遇到 `#include <xxx.h>` 时，按**固定顺序**依次搜索目录，**谁先找到就用谁**：

```
#include <xxx.h> 的搜索顺序：
  1. 命令行 -I 指定的目录（按出现的先后顺序）
  2. 命令行 -isystem 指定的目录（按出现的先后顺序）
  3. 系统默认头文件目录（--sysroot 下的 usr/include）
```

HarmonyOS 项目里，这三类路径分别对应：

| 来源 | 命令行参数 | 实际内容 |
|------|-----------|---------|
| 项目自己的头文件 | `-I 项目/include` | essentia、taglib、ffmpeg 等第三方头 |
| 系统头文件 | `--sysroot=.../sysroot` | musl 的 `stdio.h`、`time.h` 等 |
| C++ 标准库 | 编译器内置 | libc++ 的 `string`、`ctime` 等 |

> **记忆点**：`-I` 的优先级 **高于** 系统目录。只要 `-I` 里有一个同名文件，系统目录里那个就会被「挡住」。

---

## 核心概念二：头文件遮蔽（Shadowing）

当两个不同目录里存在**同名头文件**时，先被搜到的那个会「遮蔽」后一个。这就是本次 Bug 的本质：

```
musl 系统的 time.h（正常，包含 time_t、nanosleep）
     ↑ 被遮蔽
FFmpeg 的 libavutil/time.h（被错误地优先命中，没有 time_t）
```

**常见的高危文件名**（很多第三方库内部都有自己的同名头文件，极容易遮蔽系统头）：

| 头文件名 | 可能来自 | 风险 |
|---------|---------|------|
| `time.h` | FFmpeg libavutil | 遮蔽 musl `time.h`，丢失 `time_t` |
| `stdint.h` | 某些库自带 | 遮蔽系统整数类型定义 |
| `config.h` | 几乎所有 autotools 项目 | 不同库的配置互相覆盖 |
| `version.h` | 各库通用 | 版本宏冲突 |
| `log.h` | 很多库都有 | 和系统日志头冲突 |

> **结论**：**永远不要**把第三方库的「内部子目录」直接放进 `-I` 搜索路径，否则它里面的 `time.h`、`config.h` 等就会变成「全局可见」，污染整个项目的编译。

---

## 核心概念三：`#include <...>` 与 `#include "..."`

两者唯一的区别是**搜索起点不同**，最终都会走到上面那套搜索顺序：

| 写法 | 搜索起点 | 用途 |
|------|---------|------|
| `#include "xxx.h"` | 先搜**当前源文件所在目录**，再走 `-I` / 系统目录 | 引用「本项目自己的头文件」 |
| `#include <xxx.h>` | 直接走 `-I` / 系统目录 | 引用「系统/第三方/标准库」头文件 |

> 经验法则：
> - 项目自己写的头文件用 `"..."`；
> - 第三方库和标准库用 `<...>`；
> - 两者都不会「跳过」`-I` 路径，所以上面的遮蔽问题对两种写法**同样存在**。

---

## 第三方库集成的正确姿势

本次修复的核心：**只保留父级 `include` 目录，引用时带子目录前缀**。

### ❌ 错误做法（把每个子目录都暴露成全局搜索路径）

```cmake
include_directories(
    ${ROOT}/include/libavutil     # ← time.h 会遮蔽系统 time.h
    ${ROOT}/include/libavcodec
    ${ROOT}/include/taglib
)
```

### ✅ 正确做法（只保留父目录，用带前缀的标准路径引用）

```cmake
include_directories(
    ${ROOT}/include
)
```

```cpp
// 引用时带子目录前缀（FFmpeg 官方约定）
#include <libavutil/avutil.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <essentia/essentia.h>
#include <taglib/taglib.h>
```

**好处**：
1. 头文件命名空间清晰，一眼看出来自哪个库；
2. 子目录内部的 `time.h`、`config.h` 不会被暴露成全局头文件；
3. 避免不同库之间同名头文件互相冲突。

> 大多数正规第三方库（FFmpeg、TagLib、Essentia、OpenCV 等）在设计上**就要求**用 `库名/头文件.h` 的方式引用，所以「只加父目录」才是它们的标准用法。

---

## HarmonyOS NDK 特殊注意点

HarmonyOS 的 C++ 开发用的是「Clang + musl libc + libc++」组合，和传统 Linux（GNU libc + libstdc++）有几个关键差异：

| 概念 | HarmonyOS 用的 | 传统 Linux 用的 | 需要注意什么 |
|------|---------------|----------------|-------------|
| C 标准库 | **musl libc** | glibc | 部分宏/函数行为不同，交叉编译要定义 `__MUSL__` |
| C++ 标准库 | **libc++** | libstdc++ | 头文件路径不同（`c++/v1/`） |
| 编译器 | **Clang/Clang++** | GCC | 必须用 `--target=aarch64-linux-ohos` |
| 系统头文件根 | `--sysroot` 指定 | 系统默认 `/usr/include` | 不设 sysroot 就找不到 `stdio.h` |

**几个必须记住的点**：

1. **`--sysroot` 指向 musl 的系统头文件目录**。没有它，`#include <stdio.h>` 都找不到。
2. **`--target=aarch64-linux-ohos`** 告诉编译器目标不是宿主机（否则会编译出 x86 代码）。
3. **musl 与 libc++ 是两个独立的东西**：
   - musl 提供 C 语言的基础（`time_t`、`nanosleep`、`printf` 等）；
   - libc++ 提供 C++ 的容器和算法（`std::string`、`<chrono>` 等）；
   - `<ctime>` 是 libc++ 的，但它内部要 `#include <time.h>` 去拿 musl 的 `time_t` —— 这正是本次冲突发生的位置。
4. **旧的「`_LIBCPP_HAS_MUSL_LIBC` 修复」是误诊**：它只是冗余的兼容开关，**不是**本次报错的真正原因。真正原因是头文件遮蔽。

---

## 高效 Debug 方法论

这次 Debug 之所以能快速定位，靠的是下面这套「缩小范围」的套路，建议以后遇到编译错误照做：

### ① 最小复现（Minimal Reproduce）

把问题从「整个项目」缩小到「几行代码」：

```cpp
// 先试最小单元
#include <string>          // 逐步排查是哪个头文件触发的
int main() { return 0; }
```

> 能用 5 行代码复现的问题，绝不在 5000 行项目里大海捞针。

### ② 二分法（Bisect）

逐个排除「嫌疑因素」，本案例中的排查顺序：

```
① <chrono>/<thread>/<ctime> 单独编译  → ✅ 通过（排除标准库本身的问题）
② <string> 单独编译                 → ✅ 通过（排除 <string> 的问题）
③ 加上所有 -I 第三方路径再编译 <string> → ❌ 复现（锁定是 -I 路径的问题）
④ 逐个去掉 -I 路径                    → 锁定 libavutil 里的 time.h
```

### ③ 直接手动调用编译器

不依赖 IDE 的「一键编译」，直接手动跑 clang++ 命令，可以精确控制参数：

```powershell
clang++.exe --target=aarch64-linux-ohos --sysroot=... -fsyntax-only napi_init.cpp
```

- `-fsyntax-only`：只检查语法、不生成产物，**速度快、适合反复试错**；
- 逐步加/减 `-I` 参数，观察报错是否消失，就能定位元凶。

### ④ 顺着 `#include` 链条往上追

报错行往往只是「最后的受害者」。用编译器输出的 `included from` 链，从报错点一路回溯到**真正引入问题头文件的那一行**。

---

## 避坑清单速查表

| 坑 | 原因 | 正确做法 |
|----|------|---------|
| 系统类型（`time_t` 等）凭空消失 | 第三方库的同名头文件遮蔽了系统头文件 | 不要把第三方子目录加进 `-I`，用带前缀路径引用 |
| `#include` 找不到第三方头文件 | 只加了父目录，却用「不带前缀」的方式引用 | 要么加对路径，要么改用 `库名/头文件.h` |
| 不同库的 `config.h` / `version.h` 冲突 | 多个库的内部头文件都暴露成全局 | 保持子目录结构，不扁平化头文件 |
| 交叉编译出 x86 代码 | 忘了 `--target` | 始终带 `--target=aarch64-linux-ohos` |
| 找不到 `stdio.h` 等系统头 | 忘了 `--sysroot` | 指向 NDK 的 `sysroot` 目录 |
| `.so` 链接时 `cannot find -lxxx` | 库文件名带版本号（`.so.3`） | 用完整路径 `libfftw3f.so.3` 链接 |

---

## 相关文件

- 本次修改：`entry/src/main/cpp/CMakeLists.txt`（移除子目录 `-I`）
- 交叉编译完整复盘：`docs/cross_compile_guide.md`
- 头文件目录结构：`entry/src/main/cpp/include/`

---

> 一句话带走：**C++ 里「同名头文件谁先被搜到就用谁」，所以永远别把第三方库内部目录暴露成全局搜索路径。**
