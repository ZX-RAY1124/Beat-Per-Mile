/*
 * phase_trim.hpp  --  有界相位微调（对齐微调 / 防反拍护栏）
 * =============================================================================
 * 纯头文件 · C++11 · 零第三方依赖（只依赖 beatgrid.hpp）
 *
 *
 * ★ 职责边界（先读这一条）
 * ------------------------
 *      动态模式（步频跟随）  →  相位归 TempoFollower 的 CHASE 管，
 *                              【不要】在这里跑 PhaseTrim（两个控制器抢同一个变量会打架）
 *      预设模式（恒定BPM / 曲线） →  没有 CHASE，PhaseTrim 就是【唯一的同步工具】
 *
 *      一句话：TempoFollower 管动态模式，PhaseTrim 管预设模式。各司其职。
 *
 *      判断依据：如果播放倍速是由"实测步频"算出来的，就用 TempoFollower；
 *                如果是由"规定步频"（常数或曲线）算出来的，就用 PhaseTrim。
 *
 *
 * 它解决什么问题
 * --------------
 * 实测出来的相位偏置可能有几十毫秒到几百毫秒（计步延迟 + 耳机输出延迟），
 * 表现为"音乐的拍点固定地落在脚步前面或后面"。要把这个偏置折回 0。
 *
 * 但**不能直接跳**：改播放位置会有可听的内容跳跃（seek），改倍速又会破坏
 * "倍速 = 步频 / BPM" 这个让相位静止的前提。
 *
 * 所以做法是：给倍速叠加一个**有界、双向、临时**的偏差 δ
 *
 *      m = (规定倍速) × (1 + δ)        δ ∈ [-deltaMax, +deltaMax]
 *
 * 这样相位会以 2·δ·(C/60) 个 offset 单位 / 秒 的速度被搬动，而
 * **平均速度仍然等于规定值**（δ 有界、双向、最后收回 0）。
 *
 * 实数感受（180 步/分，δ = 1.5%）：
 *      搬运速率 = 2 × 0.015 × 3 = 0.09 offset 单位/秒
 *      把 1/4 拍（0.5 单位）拉回 0 需要 ≈ 5.6 秒
 *      1.5% 的速度偏差在听感上基本不可辨
 *
 *
 * ★ 方向约定（最容易搞反的地方，务必按这个来）
 * --------------------------------------------
 *      r        : 实测相位偏置（offset 单位，圆量）
 *                 r > 0 = 脚步相对拍点"偏晚" = 拍点来得太早
 *      rTarget  : 想要的位置（通常 0）
 *      err      = circularError(r, rTarget)   ∈ (-1, 1]，正 = 当前偏晚
 *
 *      偏晚(err>0) ⇒ 要让拍点【晚点来】 ⇒ 【减慢】 ⇒ δ < 0
 *      偏早(err<0) ⇒ 要让拍点【早点来】 ⇒ 【加快】 ⇒ δ > 0
 *
 *      所以：  targetDelta = -gain × err
 *
 *      漂移动力学（来自设计文档 §2.1）：
 *          d(r)/dt = +2·δ·(C/60)        C = 步频（步/分）
 *      代入 δ < 0 ⇒ r 减小 ⇒ 朝 0 收敛 ✓
 *
 *
 * 两种模式（默认就是第一种，另一种按需开）
 * ----------------------------------------
 *
 *      ┌────────────┬────────────────────────────┬────────────────────────┐
 *      │            │ guardOnly = false  【默认】 │ guardOnly = true       │
 *      │            │ 同步工具（伺服）            │ 护栏（可选）            │
 *      ├────────────┼────────────────────────────┼────────────────────────┤
 *      │ 介入条件    │ 绝对误差 > deadband(0.08)   │ 绝对误差 > guardAt(0.60)│
 *      │ 退出条件    │ 绝对误差 < deadband        │ 绝对误差 < guardExit    │
 *      │            │ （内部带 0.6 倍迟滞）        │ (0.20)，迟滞更宽        │
 *      │ 干什么      │ 把相位持续压进死区          │ 平时完全不动，只在快     │
 *      │            │ = 标定 / 对齐 / 拖滑条      │ 跑到反拍时拉一把        │
 *      │ 什么时候用  │ **预设模式下的默认选择**     │ 只想"别反拍"、不想让     │
 *      │            │                            │ 音乐偏离曲线时           │
 *      └────────────┴────────────────────────────┴────────────────────────┘
 *
 *      ⚠️ 护栏模式下 **0.5 的偏置是不会被修正的**（0.5 < 0.60），这是故意的。
 *         它的职责是"别跑到反拍"，不是"精确对齐"——
 *         所以要当同步工具用，**必须用默认的伺服模式**。
 *
 *      ⚠️ 用户大幅偏离曲线时（比如快 9%），相位会以约 0.5 单位/秒 扫过
 *         （一整圈只要 4 秒），而 δ 的修正能力只有 0.12 单位/秒 —— 差 4 倍，
 *         这时【两种模式都挡不住】。这是预设模式的本分：音乐是主，人跟着跑。
 *         想真正跟住用户，请改用动态模式（TempoFollower）。
 *
 *      两种模式都保证 δ 最终回到 0，所以长期平均速度仍然严格等于规定倍速。
 *
 *
 * 这个类**不改变平均速度**：δ 最终一定回到 0（死区规则保证），
 * 所以长期来看 播放倍速的平均值仍然严格等于 规定倍速。
 *
 *
 * 用法（★ 只在预设模式用）
 * ------------------------
 *      // 倍速 = 规定步频 / 歌曲BPM   才是 PhaseTrim 的地盘
 *      // 倍速 = 实测步频 / 歌曲BPM   请交给 TempoFollower，别在这里再跑一遍
 *      bpmw::PhaseTrim trim;
 *      // 每次控制周期（例如每 50ms / 每个脚步）
 *      const double r = beat.offset(songSec);          // 实测相位
 *      const double factor = trim.update(r, dtWall);   // 返回 (1 + δ)
 *      player.setSpeed(规定倍速 * factor);
 *
 * 版本：1.0.0
 * =============================================================================
 */
#ifndef PHASE_TRIM_HPP_INCLUDED
#define PHASE_TRIM_HPP_INCLUDED

#include <cmath>
#include "beatgrid.hpp"

namespace bpmw {

// =============================================================================
class PhaseTrim {
public:
    // ---------------- 参数（可直接写；update() 每次都会夹取到安全区间）----------------

    // 目标相位（offset 单位）。0 = 让拍点正中踩在脚步上；非 0 = 用户偏好
    double rTarget = 0.0;

    // |δ| 上限。0.02 = 最多 ±2% 变速
    double deltaMax = 0.02;

    // 死区：|err| 小于它时把 δ 收回 0（保证没有长期速度偏差）
    double deadband = 0.08;

    // 比例增益：targetDelta = -gain × err
    double gain = 0.5;

    // δ 的变化速率上限（每秒）。防速度阶跃
    double slewPerSec = 0.01;

    // ★ 默认 false = 伺服（同步工具）。预设模式要的就是精确对齐
    //   true = 护栏：只在绝对误差 > guardAt 时才介入，修不了 0.5 这种偏置
    bool guardOnly = false;

    // 护栏进入阈值（|err| 超过它才介入）
    double guardAt = 0.60;

    // 护栏退出阈值（|err| 低于它才退出），必须 <= guardAt
    double guardExit = 0.20;

    // 总开关
    bool enabled = true;

    // ---------------- 构造 / 重置 ----------------
    PhaseTrim() : delta_(0.0), targetDelta_(0.0), engaged_(false) {}
    void reset() { delta_ = 0.0; targetDelta_ = 0.0; engaged_ = false; }

    // ---------------- 参数自检 ----------------
    void sanitize() {
        if (!(deltaMax > 0.0)) deltaMax = 0.0;
        if (deltaMax > 0.1)    deltaMax = 0.1;
        if (!(deadband >= 0.0)) deadband = 0.0;
        if (deadband > 1.0)    deadband = 1.0;
        if (!(gain >= 0.0))    gain = 0.0;
        if (gain > 10.0)       gain = 10.0;
        if (!(slewPerSec >= 0.0)) slewPerSec = 0.0;
        if (slewPerSec > 1.0)  slewPerSec = 1.0;
        if (!std::isfinite(rTarget)) rTarget = 0.0;
        rTarget = beatgrid::fold(rTarget);               // 折进 [-1, 1)
        if (!(guardAt >= 0.0))   guardAt = 0.0;
        if (guardAt > 1.0)       guardAt = 1.0;
        if (!(guardExit >= 0.0)) guardExit = 0.0;
        if (guardExit > guardAt) guardExit = guardAt;
        if (deadband > guardExit) deadband = guardExit;  // 死区不能比退出阈值还大
    }

    // ---------------- 目标设置 ----------------

    // 直接设目标相位（一次性标定也走这里）
    void setTargetOffset(double r) {
        rTarget = std::fabs(r) <= 1.0 ? r : beatgrid::fold(r);
    }

    // 用户微调滑条：nudge ∈ [-50, +50] → rTarget ∈ [-0.5, +0.5]（±1/4 拍）
    void setNudge(int nudge) {
        if (nudge < -50) nudge = -50;
        if (nudge >  50) nudge =  50;
        rTarget = (double)nudge / 100.0;
    }

    // ---------------- 推进 ----------------
    //
    //   r  : 实测相位偏置（offset 单位，圆量）
    //   dt : 距上次调用经过的墙钟秒
    //   返回：应乘到"规定倍速"上的系数 (1 + δ)
    //
    //   注意：dt <= 0 或非有限时只返回当前系数，不做任何状态改变。
    double update(double r, double dt) {
        sanitize();

        const bool canStep = (dt > 0.0) && std::isfinite(dt);

        double err = beatgrid::circularError(r, rTarget);   // (-1, 1]，正 = 当前偏晚
        if (!std::isfinite(err)) err = 0.0;

        // ---- 1) 决定要不要介入（engaged_ 同时是护栏迟滞的锁存位）----
        if (enabled && canStep) {
            if (guardOnly) {
                if (!engaged_) {
                    if (std::fabs(err) > guardAt)  engaged_ = true;    // 进入
                } else {
                    if (std::fabs(err) < guardExit) engaged_ = false;  // 退出（迟滞）
                }
            } else {
                // 伺服：带 0.6 倍迟滞，避免在死区边界反复启停
                const double exitAt = deadband * 0.6;
                if (!engaged_) {
                    if (std::fabs(err) > deadband) engaged_ = true;    // 进入
                } else {
                    if (std::fabs(err) < exitAt)   engaged_ = false;   // 退出
                }
            }
        } else {
            engaged_ = false;
        }

        // ---- 2) 目标 δ（不介入时归零，保证没有长期速度偏差）----
        targetDelta_ = engaged_ ? (-gain * err) : 0.0;
        if (targetDelta_ >  deltaMax) targetDelta_ =  deltaMax;
        if (targetDelta_ < -deltaMax) targetDelta_ = -deltaMax;

        // ---- 3) 限速逼近 ----
        //   注意：关掉（enabled=false）时 target 是 0，所以 δ 会平滑收回 0，
        //   不会把音乐永久留在错误的倍速上。dt 非法时不动（没法积分）。
        if (canStep) {
            double d = targetDelta_ - delta_;
            const double lim = slewPerSec * dt;
            if (d >  lim) d =  lim;
            if (d < -lim) d = -lim;
            delta_ += d;
            if (delta_ >  deltaMax) delta_ =  deltaMax;
            if (delta_ < -deltaMax) delta_ = -deltaMax;
        }

        return factor();
    }

    // ---------------- 读数 ----------------
    double factor() const { return 1.0 + delta_; }
    double delta() const { return delta_; }
    double targetDelta() const { return targetDelta_; }
    bool   engaged() const { return engaged_; }
    double errorOf(double r) const { return beatgrid::circularError(r, rTarget); }

    // 当前相位搬运速率（offset 单位/秒）。正 = 相位在变大（脚步相对拍点越来越晚）
    double unitsPerSec(double cadenceSpm) const {
        return 2.0 * delta_ * cadenceSpm / 60.0;
    }

    // 按当前搬运速率，把 err 拉到 0 大约需要几秒（诊断用；不考虑限速与回收）
    double secondsToFix(double err, double cadenceSpm) const {
        if (!(std::fabs(err) > 1e-9)) return 0.0;
        const double dd = (std::fabs(delta_) > 1e-9) ? std::fabs(delta_) : deltaMax;
        const double rate = 2.0 * dd * cadenceSpm / 60.0;
        if (!(rate > 1e-9)) return 0.0;
        return std::fabs(err) / rate;
    }

private:
    double delta_;         // 当前叠加的倍速偏差
    double targetDelta_;   // 本次算出的目标偏差
    bool   engaged_;       // 是否正在介入
};

#define PHASETRIM_VERSION_MAJOR 1
#define PHASETRIM_VERSION_MINOR 0
#define PHASETRIM_VERSION_PATCH 0
#define PHASETRIM_VERSION_STRING "1.0.0"

} // namespace bpmw

#endif // PHASE_TRIM_HPP_INCLUDED
