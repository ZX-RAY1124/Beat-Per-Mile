/*
 * beatgrid.hpp  --  拍点 / 小节网格的统一表示（纯头文件 · C++11 · 零依赖）
 * =============================================================================
 *
 * 为什么需要这个文件
 * ------------------
 * 切歌、接歌、锚点规范化、相位判定，全都在回答同一个问题：
 *     "第 k 个拍点落在歌曲时间轴的哪一秒？"
 * 以前每个模块各算各的（tempo::beatOffset 算一遍、CppDataAnalyzer 算一遍、
 * 上层再算一遍），只要有一处不一致，就会出现"这边说偏晚 0.1、那边说偏早 0.9"。
 * 本文件提供唯一的一份实现。
 *
 *
 * 一、核心约定：网格是一个【双向无限的等距点集】
 * ----------------------------------------------
 *      Grid = { anchor + n * period : n ∈ ℤ }
 *
 *   - period : 拍周期（歌曲原速时间轴的秒数）= 60 / BPM
 *              小节网格则是 4 * 拍周期
 *   - anchor : 网格上的一个参考点，**已规范化到 [0, period)**
 *
 * 因为点集对 n 是无限的，所以 "把 anchor 加上整数个 period" 得到的是【同一个网格】。
 * 这一条是整份文件的地基。
 *
 *
 * 二、为什么必须规范化 anchor（§10.3）
 * ------------------------------------
 * 分析算法用最小二乘拟合"第一拍时间"，截距可能是负数（弱起 / 前导拍），
 * 例如 f = -0.12、P = 0.353。
 *
 *   ✅ 正确：anchor = f - P * floor(f / P) = -0.12 + 0.353 = 0.233
 *            —— 点集完全不变，只是换了个点当"参考点"
 *   ❌ 错误：anchor = max(0, f) = 0
 *            —— 把【整个网格平移了 0.12 秒】。180 步/分下 = 0.72 个偏移单位，
 *               比整个 "good" 判定窗口还大。症状是"听起来差了半拍"，
 *               但代码每一行看起来都对，极难排查。
 *
 * 规范化在【构造函数里】完成一次，之后所有取点（firstAtOrAfter / nearest ...）
 * 都保证 **结果 ≥ 给定位置**，因此永远不会算出负数。
 * 换句话说：负锚点这个问题，在整个链路上只需要被处理一次。
 *
 *
 * 三、为什么还要保留 origin
 * -------------------------
 * 规范化会丢掉"第 0 拍本来在哪儿"这个信息，而小节网格需要它：
 *     小节线 = 那些满足 (拍序号 + barPhase) ≡ 0 (mod 拍数/小节) 的拍点
 * 没有 origin 就无法知道某个拍点对应的"拍序号"是多少，小节线就会整体错位半小节。
 * 所以 origin 原样保留（可以为负），只用于推导；所有相位计算仍然只用 anchor。
 *
 *
 * 四、偏移（offset）的几何意义
 * ----------------------------
 *      offset(t) ∈ [-1, +1] ：  0 = 正中拍点
 *                              +1 = 晚半拍（拍点落在两步正中间，最坏）
 *                              -1 = 早半拍（与 +1 是同一个物理状态）
 *
 * 它是一个【周长 2 的圆周量】：
 *   - 周期是 1 拍（= 2 个 offset 单位），所以 offset(t) == offset(t + period)
 *   - +1 与 -1 等价，所以比较两个 offset 时必须用圆距离，不能直接相减
 *   - 单位换算：1 个 offset 单位 = period/2 歌曲秒 = (period/2)/m 墙钟秒
 *                                       = 30/C 墙钟秒
 *     其中 C = 步频（步/分）。**只跟步频有关，与歌曲无关。**
 *     180 步/分时 = 167 ms。
 *
 * 注意 offset() 与 tempo::beatOffset() 逐行等价（含 rem==half 时取 -1 的边界行为），
 * 但本实现支持任意锚点（包括负数），不需要先把锚点规范化。
 *
 *
 * 五、时间轴（务必分清，混用是这类系统 90% 的 bug 来源）
 * ------------------------------------------------------
 *      songSec : 歌曲【原速】时间轴（进度条上的秒数）
 *                —— 本文件里所有的 anchor / period / t 都是这个轴
 *      wallSec : 墙钟秒（手机秒表）
 *                两者的换算关系：Δsong = m * Δwall
 *
 * 版本：1.0.0
 * =============================================================================
 */
#ifndef BEATGRID_HPP_INCLUDED
#define BEATGRID_HPP_INCLUDED

#include <cmath>

namespace beatgrid {

const double kPi = 3.14159265358979323846;

// -----------------------------------------------------------------------------
// 网格
// -----------------------------------------------------------------------------
struct Grid {
    // ---- 状态（可以直接读；不要直接写，改写请重新构造）----
    double origin;   // 原始锚点（可为负、可任意大）。只用于推导小节线 / 显示
    double anchor;   // 规范化锚点 ∈ [0, period)。一切计算都用它
    double period;   // 周期（歌曲秒），保证 > 0 且有限

    // ---- 构造 ----
    Grid() : origin(0.0), anchor(0.0), period(0.5) {}

    // rawAnchor  : 拍点时间（歌曲秒），**允许为负**
    // rawPeriod  : 拍周期（歌曲秒）= 60/BPM；小节网格传 4*拍周期
    Grid(double rawAnchor, double rawPeriod) {
        period = sanitizePeriod(rawPeriod);

        double a = rawAnchor;
        if (!std::isfinite(a)) a = 0.0;

        // k = floor(a / period)。用 double 算完再转整数；
        // 极端输入（|k| 超过 double 精确整数范围）直接退化为 0，不崩。
        double kf = std::floor(a / period);
        if (!std::isfinite(kf) || kf > 9.0e15 || kf < -9.0e15) {
            origin = 0.0;
            anchor = 0.0;
            return;
        }

        origin = a;
        anchor = a - kf * period;
        wrapAnchor();
    }

    // 重新规范化（从 origin 恢复不变式）。改了 period 之后调用。
    void renormalize() {
        period = sanitizePeriod(period);
        double kf = std::floor(origin / period);
        if (!std::isfinite(kf) || kf > 9.0e15 || kf < -9.0e15) { origin = 0.0; anchor = 0.0; return; }
        anchor = origin - kf * period;
        wrapAnchor();
    }

    // ---- 相位 ----

    // 圈内相位 ∈ [0, 1)
    double phase01(double t) const {
        double rem = std::fmod(t - anchor, period);
        if (rem < 0.0) rem += period;
        return rem / period;
    }

    // 归一化偏移 ∈ [-1, 1]：0 = 正中拍点，+1 = 晚半拍，-1 = 早半拍
    // 与 tempo::beatOffset() 逐行等价（包括 rem == half 时返回 -1 的边界行为）
    double offset(double t) const {
        const double half = period * 0.5;
        double rem = std::fmod(t - anchor, period);
        if (rem < 0.0) rem += period;
        double off = (rem < half) ? (rem / half) : ((rem - period) / half);
        if (off >  1.0) off =  1.0;
        if (off < -1.0) off = -1.0;
        return off;
    }

    // 连续格点序号（相对 anchor 的整数编号，可为小数/负数）
    double indexAt(double t) const { return (t - anchor) / period; }

    // "原始拍序号"：把 origin 那一拍记作 0 号时，t 处的拍序号（可为小数/负数）。
    // 注意：anchor 对应的原拍序号并不是 0，所以这里用 origin 反推。
    double beatNumberAt(double t) const {
        return (t - origin) / period;
    }

    // ---- 取点：全部保证【结果 ≥ 给定位置】，因此永远 ≥ 0 ----

    // 第一个 ≥ t 的格点
    double firstAtOrAfter(double t) const {
        return anchor + period * std::ceil((t - anchor) / period);
    }
    // 第一个严格 > t 的格点（"下一拍"用这个）
    double firstAfter(double t) const {
        return anchor + period * (std::floor((t - anchor) / period) + 1.0);
    }
    // 离 t 最近的格点
    double nearest(double t) const {
        return anchor + period * std::floor((t - anchor) / period + 0.5);
    }
    // 最后一个 ≤ t 的格点
    double lastAtOrBefore(double t) const {
        return anchor + period * std::floor((t - anchor) / period);
    }

    // 把某个格点前后移动 n 个周期（n 为整数）
    double advance(double t, long long n) const { return t + period * (double)n; }

    // t 是否是格点（在 eps 容差内）
    bool isOnGrid(double t, double eps) const {
        const double d = t - nearest(t);
        return (d < 0.0 ? -d : d) <= eps;
    }

    // ---- 小节网格（§9.5）----
    //
    // barPhase     : **原始第 0 拍**落在小节内的第几拍（0 = 小节第一拍）。
    //                注意是"第 0 拍"，不是 anchor 那一拍 —— 所以必须用 origin 反推。
    // beatsPerBar  : 每小节几拍（4/4 拍 = 4）
    //
    // 返回：以小节线为格点、周期 = beatsPerBar * period 的新网格。
    Grid bars(int barPhase, int beatsPerBar) const {
        int k = beatsPerBar;
        if (k < 1)  k = 4;
        if (k > 64) k = 64;

        // 规范化时从 origin 里减掉了 k0 个周期：origin = anchor + k0 * period
        double k0f = (origin - anchor) / period;
        long long k0 = (long long)std::llround(k0f);

        // 第 0 拍在 origin 处；anchor 对应的是第 k0 拍。
        // 小节线满足 (n + barPhase) ≡ 0 (mod k)，n 是相对第 0 拍的拍序号。
        // 从 anchor（= 第 k0 拍）往后数 m 拍，使 (k0 + m + barPhase) ≡ 0 (mod k)：
        long long m = ((k0 - (long long)barPhase) % (long long)k + (long long)k) % (long long)k;

        return Grid(anchor + period * (double)m, period * (double)k);
    }

    // ---- 健全性 ----
    bool valid() const {
        return std::isfinite(period) && period > 0.0 &&
               std::isfinite(anchor) && anchor >= 0.0 && anchor < period &&
               std::isfinite(origin);
    }

private:
    static double sanitizePeriod(double p) {
        if (!std::isfinite(p) || p <= 1e-9) return 1e-9;   // 挡住 NaN / 0 / 负数
        if (p > 1.0e6) return 1.0e6;
        return p;
    }

    void wrapAnchor() {
        if (!std::isfinite(anchor)) { anchor = 0.0; origin = 0.0; return; }
        // 最多循环一两次；用 while 兜住浮点误差
        for (int i = 0; i < 4 && anchor >= period; ++i) anchor -= period;
        for (int i = 0; i < 4 && anchor < 0.0;     ++i) anchor += period;
        if (!(anchor >= 0.0) || anchor >= period) anchor = 0.0;
    }
};

// -----------------------------------------------------------------------------
// 自由函数形式（与设计文档 §11.0 的写法一致，纯转发）
// -----------------------------------------------------------------------------
inline double firstAtOrAfter(const Grid& g, double t) { return g.firstAtOrAfter(t); }
inline double firstAfter   (const Grid& g, double t) { return g.firstAfter(t); }
inline double nearest      (const Grid& g, double t) { return g.nearest(t); }
inline double lastAtOrBefore(const Grid& g, double t) { return g.lastAtOrBefore(t); }
inline double phase01      (const Grid& g, double t) { return g.phase01(t); }
inline double offset       (const Grid& g, double t) { return g.offset(t); }
inline double indexAt      (const Grid& g, double t) { return g.indexAt(t); }

// -----------------------------------------------------------------------------
// 单位换算（§1.3）
//    1 个 offset 单位 = period/2 歌曲秒 = (period/2)/m 墙钟秒 = 30/C 墙钟秒
// -----------------------------------------------------------------------------
inline double offsetToSongSec(const Grid& g, double off) {
    return off * g.period * 0.5;
}
inline double offsetToWallSec(const Grid& g, double off, double m) {
    if (!(m > 1e-9)) return 0.0;
    return off * g.period * 0.5 / m;
}
inline double wallSecToOffset(const Grid& g, double tauWall, double m) {
    return tauWall * 2.0 * m / g.period;
}

// 墙钟延迟 → tempo::TempoFollower::stepDelaySec
//   TempoFollower::delayOffset() 内部算的是 stepDelaySec * B / 30，
//   相当于把 stepDelaySec 当成"歌曲秒"。要让上层参数保持"墙钟秒"语义，
//   写入前必须除以 m* —— 这是最容易差一个系数的地方（§1.3 的警告）。
inline double wallDelayToStepDelaySec(double tauWall, double mStar) {
    return (mStar > 1e-9) ? (tauWall / mStar) : tauWall;
}

// offset 单位 → TempoFollower::stepDelaySec（推荐上层直接用这个单位）
inline double offsetToStepDelaySec(double off, double period, double mStar) {
    return (mStar > 1e-9) ? (offsetToSongSec(Grid(0.0, period), off) / mStar) : 0.0;
}

// -----------------------------------------------------------------------------
// 混叠折叠（§3.6）
//   offset 是周长 2 的圆周量，所以偏置 d 与 d±2k 完全等价。
//   任何恒定延迟折算出的偏置，都要先折到一个统一代表区间才好用。
//   值域是 [-1, 1) —— 注意 +1 和 -1 是同一个点，都取 -1 作代表。
// -----------------------------------------------------------------------------
inline double fold(double d) {
    if (!std::isfinite(d)) return 0.0;
    d = std::fmod(d + 1.0, 2.0);
    if (d < 0.0) d += 2.0;
    return d - 1.0;
}

// 折到 [-lim, lim]，lim ∈ (0, 1]
// TempoFollower 的 delayOffset() 上限就是 1 - hitWin（默认 0.75）
inline double foldClamped(double d, double lim) {
    if (!(lim > 0.0)) return 0.0;
    if (lim > 1.0) lim = 1.0;
    const double f = fold(d);
    if (f >  lim) return  lim;
    if (f < -lim) return -lim;
    return f;
}

// 圆周距离：两个 offset 之间"最短"的差 ∈ [0, 1]
//   |+0.9 - (-0.9)| = 1.8，但圆距离只有 0.2
inline double circularDistance(double a, double b) {
    double d = a - b;
    d = std::fmod(d, 2.0);
    if (d < 0.0) d += 2.0;          // [0, 2)
    if (d > 1.0) d = 2.0 - d;       // → [0, 1]
    return d;
}


// 带符号的圆周差 ∈ (-1, 1]：a 相对 b 是"晚"了多少（正 = 晚）
// ★ 相位控制器（PhaseTrim 之类）必须用这个，不能直接 a - b
//   例：a = -0.9、b = +0.9，直接相减得 -1.8（差了两圈），圆周差只有 +0.2
inline double circularError(double a, double b) {
    double d = std::fmod(a - b, 2.0);
    if (d < 0.0) d += 2.0;          // [0, 2)
    if (d > 1.0) d -= 2.0;          // (-1, 1]
    return d;
}
// -----------------------------------------------------------------------------
// 版本
// -----------------------------------------------------------------------------
#define BEATGRID_VERSION_MAJOR 1
#define BEATGRID_VERSION_MINOR 0
#define BEATGRID_VERSION_PATCH 0
#define BEATGRID_VERSION_STRING "1.0.0"

} // namespace beatgrid

#endif // BEATGRID_HPP_INCLUDED
