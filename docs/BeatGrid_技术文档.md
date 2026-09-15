# BeatGrid 技术文档（拍点 / 小节网格）

> 源文件：`beatgrid.hpp`（纯头文件 · C++11 · 零第三方依赖 · 约 320 行）
> 当前位置：**`entry/src/main/cpp/beatgrid.hpp`（已入工程）**
> 完整设计背景见 `C++核心协同方案.md`，本文只讲"它是什么、怎么用、在哪用"。

---

## 1. 它干了什么（30 秒版）

**它把"第 k 个拍点落在歌曲时间轴的第几秒"这件事，收敛成一个类型。**

以前每个模块各算各的坐标：TempoFollower 自己算一遍 `beatOffset()`、CppDataAnalyzer 自己算一遍段落起点、
切歌逻辑再算一遍"下一拍在哪"——只要有一处不一致，就会出现
**"这边说偏晚 0.1、那边说偏早 0.9"** 这种灾难。

`beatgrid.hpp` 提供**唯一的一份实现**，并且顺手解决三件事：

| 解决什么 | 怎么解决 |
|---|---|
| **负的 `firstBeatSec` 会炸**<br>（最小二乘拟合截距戳到负数） | 构造函数里**取模规范化**，把锚点折进 `[0, period)`。取点函数全部保证"结果 >= 给定位置"，所以永远不会算出负数 |
| **切歌 / 接歌 / 小节线坐标对不上** | 拍网格和小节网格用**同一个类型** `Grid` 表示，小节网格由 `bars()` 从拍网格派生 |
| **和 `TempoFollower` 行为不一致** | `Grid::offset()` 与 `tempo::beatOffset()` **逐行等价**，实测 30000 组**逐位相等** |

---

## 2. 三个核心概念

### 2.1 网格 = 一个双向无限的等距点集

```
Grid = { anchor + n × period : n 为任意整数 }
```

- `period` ：拍周期（歌曲原速时间轴的秒数）= `60 / BPM`；小节网格则是 `4 × 拍周期`
- `anchor` ：网格上的一个参考点

**关键性质**：点集对 `n` 是无限的，所以"把 anchor 加上整数个 period"得到的是**同一个网格**。
这一条后面反复用到。

### 2.2 为什么 anchor 要规范化

分析算法拟合出的"第一拍时间"可能是负数（弱起 / 前导拍），例如 `f = -0.12`、`P = 0.353`。

```
✅ 取模：anchor = f - P × floor(f / P) = -0.12 + 0.353 = 0.233
        —— 点集完全不变，只是换了个点当"参考点"

❌ clamp：anchor = max(0, f) = 0
        —— 把【整个网格平移了 0.12 秒】
           180 步/分下 = 0.68 个偏移单位，比整个 "good" 判定窗口还大
```

**clamp 是错的，取模才是对的。** 规范化在构造函数里做一次，之后所有取点都安全了。

### 2.3 为什么还要保留 origin

规范化会丢掉"第 0 拍本来在哪儿"，而**小节网格需要它**：

```
小节线 = 那些满足 (拍序号 + barPhase) 能被每小节拍数整除的拍点
```

没有 `origin` 就不知道某个拍点对应"第几拍"，小节线会**整体错位半小节**。
所以 `origin` 原样保留（可为负），只用于推导小节线；**所有相位计算仍然只用 anchor**。

### 2.4 offset 的几何意义

```
offset(t) 的值域 [-1, +1] ：  0 = 正中拍点
                             +1 = 晚半拍（拍点落在两步正中间，最坏）
                             -1 = 早半拍（与 +1 是同一个物理状态）
```

它是一个**周长 2 的圆周量**：

- 周期是 1 拍，所以 `offset(t) == offset(t + period)`
- `+1` 与 `-1` 等价，所以**比较两个 offset 必须用 `circularDistance()`**，不能直接相减
- 单位换算：**1 个 offset 单位 = `period/2` 歌曲秒 = `30/C` 墙钟秒**（`C` = 步频，步/分）
  —— **只跟步频有关，与放哪首歌无关**。180 步/分时 = 167 ms。

> 想直观理解：把 offset 画在转盘上，绿针是你的脚步（固定 12 点），
> 橙针是音乐拍点，**两针夹角就是 offset**。

---

## 3. API 详解

### 3.1 构造

```cpp
Grid();                                    // 默认：anchor=0, period=0.5
Grid(double rawAnchor, double rawPeriod);  // ★ 主要用法
```

- `rawAnchor` ：拍点时间（歌曲秒），**允许为负、允许任意大**
- `rawPeriod` ：拍周期 = `60 / BPM`；小节网格传 `4 × 拍周期`
- 垃圾输入（NaN / inf / 0 / 1e300）一律兜底，不崩

### 3.2 成员（可直接读，不要直接写）

| 成员 | 含义 |
|---|---|
| `anchor` | 规范化后的锚点，落在 `[0, period)` —— **一切计算都用它** |
| `origin` | 原始锚点（可为负）—— **只用于推导小节线 / 显示** |
| `period` | 周期，保证 > 0 且有限 |

### 3.3 相位

| 函数 | 返回 | 说明 |
|---|---|---|
| `offset(t)` | `[-1, 1]` | 0 = 正中拍，+1 = 晚半拍，-1 = 早半拍。**与 `tempo::beatOffset()` 逐行等价** |
| `phase01(t)` | `[0, 1)` | 圈内相位 |
| `indexAt(t)` | 实数 | 相对 `anchor` 的连续拍序号 |
| `beatNumberAt(t)` | 实数 | 相对 `origin` 的连续拍序号（"这是第几拍"） |

### 3.4 取点（★ 全部保证"结果 >= 给定位置"，因此永远 >= 0）

| 函数 | 返回 | 典型用途 |
|---|---|---|
| `firstAtOrAfter(t)` | 第一个 >= t 的格点 | **seek 目标用这个** |
| `firstAfter(t)` | 第一个严格 > t 的格点 | "下一拍在哪" |
| `nearest(t)` | 离 t 最近的格点 | 吸附入点。**可能为负，不能直接当 seek 目标** |
| `lastAtOrBefore(t)` | 最后一个 <= t 的格点 | 反向查找 |
| `advance(t, n)` | t 平移 n 个周期 | 整拍平移 |
| `isOnGrid(t, eps)` | bool | t 是否落在格点上（带容差） |

### 3.5 小节网格

```cpp
Grid bars(int barPhase, int beatsPerBar) const;
```

- `barPhase` ：**原始第 0 拍**落在小节内的第几拍（0 = 小节第一拍）
- `beatsPerBar` ：每小节几拍（4/4 拍 = 4），内部夹到 `[1, 64]`
- 返回：以小节线为格点、周期 = `beatsPerBar × period` 的新 `Grid`
- **内部用的是 `origin` 而不是 `anchor`**（见 2.3），这个坑已经踩过一次

### 3.6 单位换算（自由函数）

```cpp
beatgrid::offsetToSongSec(g, off);              // offset → 歌曲秒
beatgrid::offsetToWallSec(g, off, m);           // offset → 墙钟秒（要倍速 m）
beatgrid::wallSecToOffset(g, tauWall, m);       // 墙钟秒 → offset
beatgrid::wallDelayToStepDelaySec(tauWall, mStar);   // 写进 TempoFollower::stepDelaySec
beatgrid::offsetToStepDelaySec(off, period, mStar);
```

### 3.7 混叠折叠与圆距离（自由函数）

```cpp
beatgrid::fold(x);                    // → [-1, 1)，注意 fold(+1) == -1
beatgrid::foldClamped(x, 0.75);       // → [-lim, lim]，TempoFollower 的 delayOffset 上限就是 1-hitWin
beatgrid::circularDistance(a, b);     // 圆周最短距离（绝对值）∈ [0, 1]
beatgrid::circularError(a, b);        // 带符号圆周差 ∈ (-1, 1]，正 = a 比 b 晚
                                      // ★ 相位控制器必须用这个，不能直接 a - b
```

---

## 4. 典型用法

### 4.1 从分析结果建网格（最基础）

```cpp
#include "beatgrid.hpp"

// EssentiaBeats 给出 BPM 与第一拍时间（可能为负）
const double B = 170.0;
const double firstBeat = -0.12;            // 弱起，负的

beatgrid::Grid beat(firstBeat, 60.0 / B);  // 构造函数自动规范化
// beat.anchor  = 0.232941...
// beat.origin  = -0.12        （原样保留）
// beat.period  = 0.352941...
```

### 4.2 当前音乐和脚步错开了多少（跟随 / 开环都要）

```cpp
const double songSec = player.getInputPosition() / sampleRate;
const double off = beat.offset(songSec);   // [-1, 1]
// off ≈ 0  → 踩在点上
// |off| > 0.5 → 已经失配
```

### 4.3 切歌：求下一首歌的入点

```cpp
// 需求：B 的某条拍线要和 A 的下一拍在同一个墙钟时刻响
const double sAHear = sA - cal.aLeadSec;                     // A 的"被听到"位置
double tEdge = now + (beatA.firstAfter(sAHear) - sAHear) / mA;

// B 的入点吸附到最近拍线（整拍不变性 ⇒ 这步不影响相位）
double sB0 = beatB.nearest(entryPrefSec);
if (sB0 < 0.0) sB0 += beatB.period;                          // ★ nearest 可能为负，必须兜住
if (sB0 >= bLenSec) sB0 = beatB.lastAtOrBefore(bLenSec - 1e-6);

const long long seekFrame = (long long)std::llround(sB0 * sampleRate);
```

### 4.4 接歌：求小节网格

```cpp
// barPhase 由 downbeat 分析给出（见设计文档 §9.5）
beatgrid::Grid barA = beatA.bars(barPhaseA, 4);
beatgrid::Grid barB = beatB.bars(barPhaseB, 4);

// A 的下一条小节线（混音出点）
const double tEdge = now + (barA.firstAfter(sAHear) - sAHear) / mA;
// B 的小节线（混音入点，与 tEdge 完全独立）
double sB = barB.nearest(entryPrefSec);
if (sB < 0.0) sB += barB.period;
```

### 4.5 延迟标定：墙钟延迟 → TempoFollower 参数

```cpp
const double mStar = cadenceSpm / songBPM;
// dOff = (τ_检测 − m* × L_输出) × C / 30
const double dOff = (tauSensor - mStar * outputLatSec) * cadenceSpm / 30.0;

const double lim  = 1.0 - hitWin;              // TempoFollower 内部上限
const double dFold = beatgrid::foldClamped(dOff, lim);
follower.stepDelaySec = beatgrid::offsetToStepDelaySec(dFold, 60.0 / songBPM, mStar);
```

### 4.6 把"延迟"折成"看得见的那部分"（混叠定理）

```cpp
// 180 步/分、120 BPM：一步 333 ms，1 个 offset 单位 = 167 ms
const double visible = beatgrid::fold(tauWall * 2.0 * mStar / g.period);
// tauWall = 167 ms（半步）  → visible = ±1   最坏
// tauWall = 333 ms（一整步）→ visible =  0   等于没有延迟
```

### 4.7 错误示范

```cpp
// ❌ 把负锚点 clamp 到 0 —— 整个网格被平移了 |firstBeat|
Grid bad(std::max(0.0, firstBeat), period);

// ❌ 把 nearest 当 seek 目标 —— nearest 可能为负，seekTo 直接失败
player.seekTo((long long)(beat.nearest(t) * sr));

// ❌ 直接相减比较两个 offset —— +0.9 与 -0.9 其实只差 0.2
if (std::fabs(off1 - off2) < 0.1) { ... }
// ✅ 正确：
if (beatgrid::circularDistance(off1, off2) < 0.1) { ... }
```

---

## 5. 在哪使用

| 用在哪 | 用来干什么 | 对应任务 |
|---|---|---|
| `TempoFollower.hpp` | 它的 `beatOffset()` 就是 `Grid::offset()`。将来可以改成内部持有一个 `Grid`，两边彻底统一 | 已有 |
| `CppDataAnalyzer.hpp` | 分析完成后把 `Paragraph` 转成 `Grid`；锚点改用相位圆均值后落库 | 任务 5 |
| 延迟标定模块 | `wallDelayToStepDelaySec()` / `foldClamped()` 换算出 `stepDelaySec` | 任务 2a |
| 开环速度模块（曲线 / 恒定 BPM） | 用 `offset()` 观测相位，用 `fold()` 判断要不要拉一把 | 任务 3 |
| 切歌对拍模块 | `firstAfter()` 求 A 的下一拍，`nearest()` 吸附 B 的入点 | 任务 4 |
| 接歌模块 | `bars()` 求小节网格，两条小节线各自 `firstAfter()` | 任务 7a |
| `napi_bridge_center.cpp` | 最终接线处：每次拿到脚步事件后算相位、推倍速 | 任务 1 |

---

## 6. 四条必须记住的注意事项

1. **seek 目标必须用 `firstAtOrAfter()`**。
   `nearest()` 找的是"最近的格点"，可能落在 0 之前。**它会返回负数，这是设计如此，不是 bug。**

2. **`fold(+1) == -1`**。值域是 `[-1, 1)`，正负 1 是同一个点，取 -1 作代表。
   比较两个 offset 必须用 `circularDistance()`。

3. **`Grid::bars()` 内部用 `origin` 而不是 `anchor`**。
   规范化会把 anchor 挪走整数个周期，拿 anchor 推小节线会让小节线**整体错位半小节**。

4. **单位别搞混**：`anchor` / `period` / 所有 `t` 参数都是**歌曲原速时间轴**（进度条秒数），
   不是墙钟秒。两者换算要乘 / 除倍速 `m`。

---

## 7. 验证情况

自测结果（`-O2 -Wall -Wextra`，全绿）：

| 项目 | 结果 |
|---|---|
| C++ 自测（10 组） | **80 项全过** |
| 与 `tempo::beatOffset()` 逐值比对 | 锚点未规范化时 **30000 组逐位相等（0.0e+00）**；<br>需规范化时 40000 组最大差异 **3.04e-13**（浮点噪声，上界内） |
| 三方交叉验证（C++ 网格 / C++ 参考 / Python 镜像） | **全部 0.000e+00（位级一致）** |
| `-std=c++11 -Werror -pedantic` | 通过（工程里是 C++11） |
| 取点函数永不为负 | 6000 组负锚点，`firstAtOrAfter(0) < 0` **0 次** |
| 小节网格 | 1500 组随机 BPM / 锚点 / 拍号 / 小节相位 全部通过 |
| 垃圾输入 | NaN / inf / 0 / 1e300 全部不崩 |

另外还有一套**本地验证工具**（GUI，起"可视化的单元测试"的作用，**不入库**）：
转盘看夹角、时间轴看格点、偏移曲线看锯齿，还有「负锚点对照」和「clamp 错误示范」两个按钮把上面的结论直接摆出来。
（GUI 只是试验工具，**不会进工程**。）
