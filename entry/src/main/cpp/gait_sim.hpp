/*
 * gait_sim.hpp -- 合成步态三轴加速度源（"模拟演示"用）
 * =============================================================================
 * 纯头文件 · C++11 · 零依赖
 *
 * ★ 本文件**故意不包含任何 NAPI / OHOS 头**，理由同工程里其它核心头文件：
 *   这样它能脱离 OHOS SDK 单独编译，在宿主机上就能跑数值比对。
 *   NAPI 包装与注册放在 napi_bridge_center.cpp（唯一模块入口）。
 *
 * 逐样本对齐 pygui/gait_sim.py：连随机数发生器都是它的那一套
 * （xorshift32 + Box-Muller），所以**同一个 seed 下 C++ 与 Python 数值可复现**。
 * ⚠️ 注意 stepAnalyze/tests/test_detector.cpp 里那份 C++ 镜像用的是
 *    std::mt19937，跟 Python 并不逐样本一致 —— 要跟 Python 对齐请用本文件。
 *
 * 信号结构（照着"最能搞坏计步器"的样子造的）：
 *   竖直: A*sin(p) + 0.45*A*sin(2p+0.8)      落脚基频 + 二次谐波
 *   前向: 0.35*A*sin(p+1.9)
 *   侧向: 0.25*A*sin(0.5p+0.4)               身体摆动，f/2
 *   再加上通过固定设备倾角投影的重力、白噪声
 *   起步/停止用一阶包络限带（瞬时开关会产生加速度阶跃，真实加速度计做不出来）
 * =============================================================================
 */

#ifndef GAIT_SIM_HPP_INCLUDED
#define GAIT_SIM_HPP_INCLUDED

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace gaitsim {

const double kPi    = 3.14159265358979323846;
const double kTwoPi = 6.28318530717958647692;
const double kG     = 9.80665;

// -----------------------------------------------------------------------------
// 确定性 RNG：与 gait_sim.py 的 _Rng 完全一致
//   xorshift32  +Box-Muller（保留一个 spare，和 Python 的 spare 语义一致）
//   整数部分按 uint32 自然回绕，等价于 Python 里的 & 0xFFFFFFFF
// -----------------------------------------------------------------------------
class Rng {
public:
    explicit Rng(std::uint32_t seed)
        : s_((std::uint32_t)(seed * 2654435761u)), hasSpare_(false), spare_(0.0) {
        if (s_ == 0u) s_ = 1u;
    }

    std::uint32_t nextU32() {
        std::uint32_t x = s_;
        x ^= (x << 13);
        x ^= (x >> 17);
        x ^= (x << 5);
        s_ = x;
        return s_;
    }

    double uniform() {
        return (static_cast<double>(nextU32()) + 0.5) / 4294967296.0;
    }

    double gauss() {
        if (hasSpare_) {
            hasSpare_ = false;
            return spare_;
        }
        double u1 = uniform();
        if (u1 < 1.0e-12) u1 = 1.0e-12;   // Python: max(uniform(), 1e-12)
        const double u2 = uniform();
        const double r = std::sqrt(-2.0 * std::log(u1));
        spare_ = r * std::sin(kTwoPi * u2);
        hasSpare_ = true;
        return r * std::cos(kTwoPi * u2);
    }

private:
    std::uint32_t s_;
    bool   hasSpare_;
    double spare_;
};

// -----------------------------------------------------------------------------
// 配置（默认值取自 gait_sim.py 的构造函数）
// -----------------------------------------------------------------------------
struct GaitConfig {
    double sample_rate_hz = 50.0;
    double amplitude      = 3.0;    // 竖直基频幅度（m/s^2）
    double noise          = 0.12;   // 白噪声 std（m/s^2）
    double tilt_deg       = 18.0;   // 设备倾角（重力投影）
    double heading_deg    = 35.0;   // 朝向
    double envelope_tau_s = 0.15;   // 起步/停止包络时间常数
    std::uint32_t seed    = 12345u;

    GaitConfig() {}
};

struct GaitSample {
    double ax;
    double ay;
    double az;
    GaitSample() : ax(0.0), ay(0.0), az(0.0) {}
    GaitSample(double x, double y, double z) : ax(x), ay(y), az(z) {}
};

// -----------------------------------------------------------------------------
// 流式合成器。调用方按 50Hz 喂"当前时刻"（秒），拿到三轴。
// -----------------------------------------------------------------------------
class GaitSim {
public:
    explicit GaitSim(const GaitConfig& cfg = GaitConfig())
        : cfg_(cfg),
          rng_(cfg.seed),
          cadence_(1, std::make_pair(0.0, 1.8)),   // Python 默认曲线
          hasLast_(false),
          lastT_(0.0),
          nextT_(0.0),
          phase_(0.0),
          env_(0.0),
          startWalking_(true),
          cycleOnSec_(0.0),
          cycleOffSec_(0.0) {}

    // ---------------- 配置 ----------------

    const GaitConfig& config() const { return cfg_; }
    void setConfig(const GaitConfig& cfg) { cfg_ = cfg; }

    /** 步频曲线：[(时刻秒, 步/秒), ...]，按时刻排序；空则退回 [(0, 1.8)] */
    void setCadenceCurve(const std::vector<std::pair<double, double> >& curve) {
        cadence_ = curve;
        std::sort(cadence_.begin(), cadence_.end());
        if (cadence_.empty()) cadence_.push_back(std::make_pair(0.0, 1.8));
    }

    /** 恒定步频（步/分 → 内部步/秒） */
    void setCadenceSpm(double spm) {
        cadence_.clear();
        cadence_.push_back(std::make_pair(0.0, spm / 60.0));
    }

    /** 起播时是否已经在走 */
    void setStartWalking(bool w) { startWalking_ = w; }

    /**
     * "跑/停/跑"循环：每 (on+off) 秒里前 on 秒在跑。
     * off <= 0 表示一直在跑。用于验证"停下来不误报"和"重新起步"。
     */
    void setCycle(double onSec, double offSec) {
        cycleOnSec_ = onSec;
        cycleOffSec_ = offSec;
    }

    /** 复位到初始状态（同一 seed 下重放结果一致） */
    void reset() {
        rng_ = Rng(cfg_.seed);
        hasLast_ = false;
        lastT_ = 0.0;
        nextT_ = 0.0;
        phase_ = 0.0;
        env_ = 0.0;
    }

    // ---------------- 查询 ----------------

    double cadenceAt(double t) const {
        double c = cadence_.front().second;
        for (std::size_t i = 0; i < cadence_.size(); ++i) {
            if (t >= cadence_[i].first) {
                c = cadence_[i].second;
            }
        }
        return c;
    }

    /** 当前时刻是否在"走/跑"（考虑 startWalking 与 cycle） */
    bool walkingAt(double t) const {
        bool w = startWalking_;
        if (cycleOffSec_ > 0.0 && (cycleOnSec_ + cycleOffSec_) > 0.0) {
            const double period = cycleOnSec_ + cycleOffSec_;
            double ph = std::fmod(t, period);
            if (ph < 0.0) ph += period;
            w = (ph < cycleOnSec_);
        }
        return w;
    }

    // ---------------- 信号 ----------------

    /** 走/跑状态下的一个样本 */
    GaitSample sample(double t) { return emit(t, true); }

    /** 站立不动的样本：只剩重力和噪声，步态平滑淡出 */
    GaitSample sampleStatic(double t) { return emit(t, false); }

    /**
     * 按内部时间轴推进一个采样点：t = nextT_, nextT_ += 1/sample_rate_hz。
     * 调用方（原生线程）按 50Hz 调它即可。
     */
    GaitSample tick() {
        const double t = nextT_;
        nextT_ += (cfg_.sample_rate_hz > 0.0) ? (1.0 / cfg_.sample_rate_hz) : 0.02;
        return emit(t, walkingAt(t));
    }

    /** 当前内部时间（秒），便于上层对齐墙钟 */
    double nextTime() const { return nextT_; }

private:
    void advance(double t, bool walking) {
        if (!hasLast_) {
            hasLast_ = true;
            lastT_ = t;
            env_ = walking ? 1.0 : 0.0;
            return;
        }
        double dt = t - lastT_;
        if (!(dt > 0.0)) {
            dt = 0.0;
        }
        lastT_ = t;
        if (walking && dt > 0.0) {
            phase_ += kTwoPi * cadenceAt(t) * dt;
        }
        const double a = (cfg_.envelope_tau_s > 0.0)
                             ? (1.0 - std::exp(-dt / cfg_.envelope_tau_s))
                             : 1.0;
        env_ += a * ((walking ? 1.0 : 0.0) - env_);
    }

    GaitSample emit(double t, bool walking) {
        advance(t, walking);
        const double A = cfg_.amplitude * env_;
        const double p = phase_;

        const double vert = A * std::sin(p) + 0.45 * A * std::sin(2.0 * p + 0.8);
        const double fwd  = 0.35 * A * std::sin(p + 1.9);
        const double lat  = 0.25 * A * std::sin(0.5 * p + 0.4);

        const double ty = cfg_.tilt_deg * kPi / 180.0;
        const double hz = cfg_.heading_deg * kPi / 180.0;

        // ★ 三次 gauss() 的调用顺序必须固定（ax, ay, az），否则 RNG 流会错位
        const double ax = -kG * std::sin(ty) * std::cos(hz) + fwd + rng_.gauss() * cfg_.noise * 0.5;
        const double ay = -kG * std::sin(ty) * std::sin(hz) + lat + rng_.gauss() * cfg_.noise * 0.5;
        const double az =  kG * std::cos(ty)               + vert + rng_.gauss() * cfg_.noise;
        return GaitSample(ax, ay, az);
    }

    GaitConfig cfg_;
    Rng rng_;
    std::vector<std::pair<double, double> > cadence_;
    bool   hasLast_;
    double lastT_;
    double nextT_;
    double phase_;
    double env_;
    bool   startWalking_;
    double cycleOnSec_;
    double cycleOffSec_;
};

// -----------------------------------------------------------------------------
// 现成演示场景（设置页的"步数检测源"下拉框用）
// -----------------------------------------------------------------------------
struct GaitScenario {
    std::string name;
    GaitConfig  cfg;
    std::vector<std::pair<double, double> > curve;   // (时刻秒, 步/秒)
    bool   startWalking;
    double cycleOnSec;
    double cycleOffSec;

    GaitScenario()
        : startWalking(true), cycleOnSec(0.0), cycleOffSec(0.0) {}
};

namespace scenarios {

inline GaitScenario run160() {
    GaitScenario s;
    s.name = "跑步 160 步/分";
    s.cfg.amplitude = 6.0;
    s.curve.push_back(std::make_pair(0.0, 2.667));
    return s;
}

inline GaitScenario run200() {
    GaitScenario s;
    s.name = "跑步 200 步/分";
    s.cfg.amplitude = 6.0;
    s.curve.push_back(std::make_pair(0.0, 3.333));
    return s;
}

inline GaitScenario runRamp() {
    GaitScenario s;
    s.name = "跑步 120→200 步/分（每 15 秒变档）";
    s.cfg.amplitude = 6.0;
    s.curve.push_back(std::make_pair(0.0, 2.0));
    s.curve.push_back(std::make_pair(15.0, 2.667));
    s.curve.push_back(std::make_pair(30.0, 3.333));
    return s;
}

inline GaitScenario runStopRun() {
    GaitScenario s;
    s.name = "跑 20 秒 / 停 8 秒（循环）";
    s.cfg.amplitude = 6.0;
    s.curve.push_back(std::make_pair(0.0, 3.0));
    s.cycleOnSec = 20.0;
    s.cycleOffSec = 8.0;
    return s;
}

inline GaitScenario walk108() {
    GaitScenario s;
    s.name = "步行 108 步/分";
    s.curve.push_back(std::make_pair(0.0, 1.8));
    return s;
}

inline GaitScenario standingStill() {
    GaitScenario s;
    s.name = "站立不动（只有噪声）";
    s.curve.push_back(std::make_pair(0.0, 1.8));
    s.startWalking = false;
    return s;
}

/** 场景总数 / 按序号取（越界回退到第一个） */
inline int count() { return 6; }

inline GaitScenario at(int index) {
    switch (index) {
    case 0: return run160();
    case 1: return run200();
    case 2: return runRamp();
    case 3: return runStopRun();
    case 4: return walk108();
    case 5: return standingStill();
    default: return run160();
    }
}

/** 按序号构造一个已配置好的模拟器 */
inline GaitSim makeSim(int index) {
    const GaitScenario s = at(index);
    GaitSim sim(s.cfg);
    sim.setCadenceCurve(s.curve);
    sim.setStartWalking(s.startWalking);
    sim.setCycle(s.cycleOnSec, s.cycleOffSec);
    return sim;
}

} // namespace scenarios

} // namespace gaitsim

#endif // GAIT_SIM_HPP_INCLUDED
