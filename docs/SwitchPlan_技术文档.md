# SwitchPlan 技术文档（切歌对拍）

> 源文件：`switch_plan.hpp`（纯头文件 · C++11 · 只依赖 `beatgrid.hpp` · 约 350 行）
> 当前位置：**`entry/src/main/cpp/switch_plan.hpp`（已入工程）**
> 设计背景见 `C++核心协同方案.md` §4；本文只讲"它是什么、怎么用、在哪用"。

---

## 1. 它干了什么（30 秒版）

**换歌时，算出"什么时候起播 B、B 从哪一秒开始播"，让 B 的拍点接上 A 的拍点。**

```
歌 A 正在播 ────|───|───|───|───|───|────►
                                   ┆ tEdge（切片点）
歌 B                              |───|───|───|───|───►
                                  ┆ seekSec
```

**它不干什么**：不碰音频、不碰播放器、不碰线程。它只输出三个数：

| 输出 | 含义 |
|---|---|
| `tEdge` | B 的第一拍应该【被听到】的墙钟时刻（也是硬切的切换点） |
| `tStart` | 调 `playerB.play()` 的墙钟时刻 |
| `seekFrame` | `playerB.seekTo()` 的目标 |

**相位由构造保证** —— 不需要迭代、不需要测量、不需要试错。

---

## 2. 为什么这件事比想象的简单

### 2.1 速度侧自动就是对齐的

只要两首歌都用 "步频 ÷ 它自己的 BPM" 这个倍速：

```
A 的墙钟拍周期 = (60/BPM_A) ÷ (步频/BPM_A) = 60/步频
B 的墙钟拍周期 = (60/BPM_B) ÷ (步频/BPM_B) = 60/步频      ← 完全相同 = T
```

**两首歌的拍点在墙钟上是同一条等距格子上**。所以根本不用管速度，只需要管相位。

### 2.2 两条让它更简单的性质

**① 整拍不变性**：把 B 的入点前后挪整数个拍，相位完全不变
（移整数拍 = 转盘转整数圈）。

> ⇒ **"选好听的入点"和"对不对得齐"是两个独立的问题**。
> 可以先把入点定在音乐上最合适的位置（跳过前奏、从副歌进），再吸附到拍线上。

`planSwitch` 内部就是这么做的：先 `nearest(entryPrefSec)`，再管对齐。

**② 顺延不破坏相位**：准备时间不够时，把 `tEdge` / `tStart` 一起顺延整数个 `T`，
相位关系原封不动。

> ⇒ "等一拍再切"永远是安全的。`planSwitch` 会自己顺延，并在 `deferredBeats` 里告诉你顺延了几拍。

### 2.3 ★ 要对齐 A 的【歌曲网格】，不要对齐【脚步时刻】

因为延迟标定总有残余，A **听到**的拍点相对脚步本来就有一个固定偏移 `r`。

| 对齐目标 | 结果 |
|---|---|
| 对齐**脚步** | B 的网格相对 A 的网格整体平移 `r` → **用户会听到一次相位跳变** |
| 对齐 **A 的网格** ✓ | `r` 被原样继承 → 切歌前后感知完全连续，**标定误差自动抵消** |

所以 `SwitchRequest` 的输入是 `gA`（A 的拍网格），而不是脚步时刻。

**附带好处**：切歌逻辑和延迟标定可以完全独立调试 —— 标定错了也听不出来，因为两边错得一样多。

---

## 3. API 详解

### 3.1 `PlaybackCalib`：两个必须实测的常数

```cpp
struct PlaybackCalib {
    double aLeadSec;   // A（稳态播放中）：getInputPosition()/sr 领先"用户听到"的歌曲秒数
    double bLeadSec;   // B（即将起播）：从 play() 到"第一个输入帧被听到"的墙钟秒数
};
```

**默认值 `0.12 / 0.14` 只是占位符，必须实测**
（方法见设计文档 §4.5 第 5 步与 §6 的实验 1）。

> ⚠️ `aLeadSec` 大致正比于倍速 `mA`。如果实际播放的倍速范围很宽，
> 要么按参考倍速测一个值、要么改测成 `engineLat + m × outputLat` 的形式。

### 3.2 `SwitchRequest`：输入

| 字段 | 含义 |
|---|---|
| `now` | 当前墙钟秒（**单调时钟**） |
| `sA` | A 的歌曲位置 = `getInputPosition() / sr` |
| `mA` | A 的当前倍速 |
| `gA` | A 的拍网格（从 `CppDataAnalyzer` 的分析结果建） |
| `aEndSec` | A 的总时长 |
| `gB` | B 的拍网格 |
| `mB` | B 的目标倍速 = 当前步频 / B 的 BPM |
| `bLenSec` | B 的总时长 |
| `entryPrefSec` | B 的音乐入点偏好（0 = 从头） |
| `wantLeadBeats` | 想要几个整拍的引子（**硬切填 0**） |
| `sampleRate` | 用来把秒换算成 seek 帧 |
| `minLeadSec` | 从 `now` 到 `tStart` 至少留的准备时间（默认 0.6 秒） |
| `cal` | 上面那两个常数 |

> **为什么用结构体**：设计文档 §11.7 里是 12 个位置参数，协作者很容易传错顺序。
> 结构体可以按名字赋值，编译器还能帮着查漏。

### 3.3 `SwitchPlan`：输出

| 字段 | 含义 |
|---|---|
| `ok` / `fail` | 是否成功 / 失败原因（用 `switchFailName()` 转成中文） |
| `tEdge` | B 的第一拍被听到的墙钟时刻 = **硬切的切换点** |
| `tStart` | 调 `play()` 的时刻 |
| `seekSec` / `seekFrame` | B 的入点 |
| `leadBeats` | 实际留了几个整拍的引子 |

**诊断量**（给上层做决策 / 打日志用）：

| 字段 | 含义 |
|---|---|
| `aHearSec` | A 的"被听到"位置（= `sA − aLeadSec`） |
| `aEndWall` | A 自然结束的墙钟时刻 |
| `leadSec` | `tStart − now`，给 B 留了多少准备时间 |
| `beatPeriod` | `T = P_B / mB`，墙钟拍周期（两首歌相同） |
| `overlapSec` | `aEndWall − tEdge`：A 在 B 第一拍之后还剩多久 = **天然淡出窗口** |
| `deferredBeats` | 因为准备时间不足顺延了几拍 |

### 3.4 失败码

| 值 | 名 | 含义 |
|---|---|---|
| 0 | `kSwitchOK` | 成功 |
| 1 | `kSwitchBadParams` | 倍速 / 周期 / 采样率 / 时长 非法 |
| 2 | `kSwitchAPast` | A 已经播过头了 |
| 3 | `kSwitchANoRoom` | A 剩下的时间不够放下 B 的第一拍 |
| 4 | `kSwitchBTooShort` | B 太短，选不出合法入点 |

### 3.5 自检助手

```cpp
// (tEdge − tStart − bLeadSec) / T —— 必须是整数，否则相位没对齐
double k = bpmw::beatsFromStartToEdge(p, cal);
assert(std::fabs(k - std::floor(k + 0.5)) < 1e-6);
```

集成代码里建议直接断言这一条。

### 3.6 降级：B 还没有分析结果

```cpp
bpmw::DegradedSwitchRequest d;
d.now = ...; d.sA = ...; d.mA = ...; d.gA = beatA; d.aEndSec = ...;
d.bLenSec = ...; d.entryPrefSec = 0.0; d.cal = calib;
bpmw::SwitchPlan p = bpmw::planSwitchDegraded(d);
```

不做拍点对齐（没有网格可比），但：
- **保持速度连续**（B 用与 A 相同的倍速起播）
- **仍然切在 A 的下一拍上**

---

## 4. 典型用法

### 4.1 硬切（最常用）

```cpp
bpmw::SwitchRequest req;
req.now  = steadyNow();
req.sA   = playerA.getInputPosition() / (double)sampleRate;
req.mA   = follower.currentMultiplier();
req.gA   = beatA;
req.aEndSec = durationA;
req.gB   = beatB;
req.mB   = cadenceSpm / bpmB;
req.bLenSec = durationB;
req.entryPrefSec  = 0.0;      // 从 B 的开头进
req.wantLeadBeats = 0;        // ★ 硬切
req.cal = calib;

const bpmw::SwitchPlan p = bpmw::planSwitch(req);
if (!p.ok) { /* 见 §4.3 降级 */ }

playerB.loadAudio(...);
playerB.seekTo(p.seekFrame);
sleep_until(p.tStart);
playerB.play();
// 到 p.tEdge 停 A
```

### 4.2 带引子的交叉淡化（接歌）

```cpp
req.wantLeadBeats = 4;        // 留 4 拍引子
// 此时 tStart 比 tEdge 早 4*T + bLeadSec，A 和 B 会重叠
// p.overlapSec 告诉你 A 还能响多久
```

> 真正的交叉淡化还需要**单线程 Mixer**（见设计文档 §9.6），
> `switch_plan.hpp` 只负责算出时刻。

### 4.3 降级

```cpp
if (!p.ok) {
    if (p.fail == bpmw::kSwitchANoRoom) {
        // A 马上要结束了，来不及对齐 —— 直接降级
        p = bpmw::planSwitchDegraded(degradedReq);
    }
    // 还是不行就只能硬起 B（接受一次相位跳变）
}
```

### 4.4 错误示范

```cpp
// ❌ 用"现在的位置"而不是"被听到的位置"
req.sA = playerA.getInputPosition() / sr;   // ✅ 这个是对的（planSwitch 内部会减 aLeadSec）
// 但如果自己算 tEdge 时忘了减 aLeadSec，就会整体晚一个输出延迟

// ❌ 把 aLeadSec / bLeadSec 留在默认值
bpmw::SwitchRequest req;   // 默认 0.12 / 0.14 是占位符！
// 一定要 req.cal = 实测值;

// ❌ 用 wallSec 时钟系统的非单调时钟（比如 Date.now()）
req.now = Date_now();      // 会被系统时间调整影响 ⇒ 用 steady_clock
```

---

## 5. 在哪使用

| 用在哪 | 用来干什么 | 对应任务 |
|---|---|---|
| **切歌流程**（NAPI 层） | 换歌时算 `tEdge / tStart / seekFrame`，然后按时刻驱动两个 player | 任务 1 / 4 |
| **接歌**（交叉淡化） | 用 `wantLeadBeats > 0` 算引子时刻，配合 `overlapSec` | 任务 7a |
| **A 即将自然结束时** | 读 `aEndWall` 决定什么时候必须开始准备 B | 任务 4 |
| **B 没有分析结果时** | `planSwitchDegraded()` | 任务 4 |
| **延迟标定的验证** | 用 `beatsFromStartToEdge()` 断言相位对齐 | 任务 2a |

---

## 6. 注意事项

1. **`now` 必须来自单调时钟**（`steady_clock`）。用系统墙上时钟会被时间同步影响。

2. **`aLeadSec` / `bLeadSec` 一定要实测**，默认值只是占位符。

3. **`seekFrame` 已经夹在 `[0, bLen×sr)` 内**，可以直接用。

4. **`wantLeadBeats > 0` 意味着 A 和 B 会重叠**（交叉淡化场景）。
   重叠时长看 `overlapSec`；如果上层没有 Mixer，就只能硬切（`wantLeadBeats = 0`）。

5. **顺延是正常行为**：`deferredBeats > 0` 说明准备时间不够，计划自动等了整数拍。
   不需要当成错误处理。

---

## 7. 已知边界

### 7.1 它只保证"拍点对齐"，不保证"听起来好"

如果 A 是渐弱结尾、或者 B 的开头是安静的前奏，拍点对齐了也可能不好听。
建议配合 `entryPrefSec` 选一个合适的入点，或者做交叉淡化。

### 7.2 `aLeadSec` 的正比关系

`aLeadSec` 大致是 `engineLat + mA × outputLat`。如果实际倍速范围很宽，
用单一常数会有偏差。**这是刻意保持简单的取舍** —— 先按实测的一个值用，
真机发现偏差大再改成按倍频缩放。

### 7.3 引擎 warmup 的余量

`bLeadSec` 要覆盖"引擎启动到产出第一帧"的全部时间，包括环形缓冲预填。
实测方法见设计文档 §6 的实验 1（用 `stretchbridge dump` 对比首帧）。

### 7.4 变速歌（A 或 B 是多段落）

`gA` / `gB` 是**单个**拍网格（一个 BPM + 一个第一拍）。
如果歌中途变速，需要按段落重锚（见设计文档 §4.8）——
`planSwitch` 只吃一个网格，重锚是上层的事。

---

## 8. 验证情况

自测结果（`-O2 -Wall -Wextra`，全绿）：

| 测试组 | 规模 | 验什么 |
|---|---|---|
| **跨切点拍点落在同一格子** | 3000 组随机场景 | A/B 的所有拍点都在以 `tEdge` 为原点、步长 `T` 的格子上 |
| `tEdge` 正好是 A 的下一拍 | 2000 组 | 反推回 A 的时间轴，必须落在 `gA` 上且不超过一个周期 |
| 整拍不变性 | 1500 组 | 引子 +1 拍 ⇒ `tEdge` 与 `tStart` 的位移差恰好 `T` |
| 顺延整拍 | 1500 组 | `minLeadSec` 很大时自动顺延，相位仍不变 |
| 负锚点 + 极端 BPM | 1500 + 6 组 | `firstBeat` 全负；BPM 40 ~ 400 |
| 失败码 | — | 4 种失败各构造一次 |
| 垃圾输入 | 12 种 | NaN / inf / 负时长 / 非法网格 不崩、不给 NaN |
| 降级路径 | 1000 组 | 仍然切在 A 的下一拍上 |
| **端到端** | 800 组 | 把 A、B 的拍点全列出来，**合并后必须是一条等距数列** |

**合计 9024 项断言，全部通过。**

另外还有一套**本地验证工具**（GUI，**不入库**），它把这件事画出来了：
**三排刻度（理想标尺 / A 的拍点 / B 的拍点）必须上下对齐**，错位一眼就能看出来。
（GUI 只是试验工具，**不会进工程**。）
