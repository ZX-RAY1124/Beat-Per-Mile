// =============================================================================
//  step_detector.hpp  --  用三轴加速度计实时检测走路的脚步
//                          纯头文件、C++11、零第三方依赖
// =============================================================================
//
//  快速开始
//  --------
//      #include "step_detector.hpp"
//
//      steplib::StepDetector det;              // 默认配置，50 Hz
//      det.onStep([](const steplib::StepEvent& e) {
//          printf("第 %llu 步  t=%.3fs  步频=%.1f 步/分\n",
//                 (unsigned long long)e.index, e.timestamp, e.cadence_spm);
//      });
//
//      // 采样循环里（设备实际速率必须和配置一致）：
//      while (running) {
//          double ax, ay, az, t;
//          read_sensor(&ax, &ay, &az, &t);     // 单位 m/s^2，时间单位秒
//          det.update(ax, ay, az, t);          // 回调就是在这一行里被触发的
//      }
//
//      // 拿不到时间戳？用不带时间戳的那个重载：
//      det.update(ax, ay, az);                 // 内部按 1/sample_rate_hz 推进时间
//
//  算法（全程因果/流式，每个样本约 200 纳秒，不做动态分配）
//  --------------------------------------------------------
//    1. 合加速度    m = |a|
//    2. 去重力      x = m - 低通(m)              （一阶低通，约 0.5 Hz）[可关闭]
//    3. 带通滤波    s = 低通(高通(x))            （二阶巴特沃斯，约 0.4-5 Hz）
//    4. 自适应统计  对 s 做约 1.5 秒的滑动均值/方差（指数窗口）
//    5. 自适应阈值  上 = 均值 + max(k*sigma, 下限)，下 = 均值 - max(k*sigma, 下限)
//    6. 状态机      空闲 --(s 跌破下阈值)--> 等波峰 --(波峰确认且冲上上阈值)--> 报一步
//                   报完回到空闲；两步之间至少间隔 min_step_interval_s
//    7. 一步只有在 峰谷幅度、谷→峰时延、与上一步的间隔 全部通过闸门时才会报出
//
//    这种"先谷后峰"的结构是计步器的标准做法：阈值跟着信号自身的幅度走
//    （慢走、快走都不用重调参数），能挡掉静止噪声（sigma 闸门），而且一个
//    谷峰周期最多只能产生一步，天然不会把一步数成两步。
//
//  线程：单个 StepDetector 实例**不是线程安全的**。请始终从同一个生产者线程
//  喂数据。回调就在那个线程里、在 update() 内部同步执行；回调要短，并且不要
//  在回调里再回头调用本检测器。
//
//  时间戳：单位秒，原点任意，通常单调不减。如果时钟倒退（比如设备重连），
//  检测器会把内部记录的时间重锚到新的时间基准，而不是卡住等新时钟追上旧时钟，
//  所以设备重连不需要你额外调用 reset()。
// =============================================================================

#ifndef STEP_DETECTOR_HPP_INCLUDED
#define STEP_DETECTOR_HPP_INCLUDED

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <utility>

#define STEPLIB_VERSION_MAJOR 1
#define STEPLIB_VERSION_MINOR 0
#define STEPLIB_VERSION_PATCH 0
#define STEPLIB_VERSION_STRING "1.0.0"

namespace steplib {

namespace detail {
// "还没有上一步"的哨兵时间值。放在命名空间作用域是为了让它成为常量表达式
// （在 C++11 里，类内的 `static const double` 不算常量表达式）。
constexpr double kNoStep = -1.0e18;
constexpr double kPi     = 3.14159265358979323846;
} // namespace detail

// -----------------------------------------------------------------------------
// 可调参数。默认值针对 50 Hz、戴在身上的手机/可穿戴设备（口袋、腰、手腕）
// 走路场景标定。
// -----------------------------------------------------------------------------
struct StepConfig {
    // --- 输入 ---------------------------------------------------------------
    double sample_rate_hz      = 50.0;   // 标称输入速率，用来设计滤波器
    bool   input_has_gravity   = true;   // true  ：原始加速度计数据（含重力，m/s^2）
                                         // false ：设备已做过去重力（线性加速度）

    // --- 信号调理 -----------------------------------------------------------
    double gravity_cutoff_hz   = 0.5;    // 重力跟踪低通的截止频率
    double bandpass_high_hz    = 0.4;    // 带通高通拐点（压掉漂移）
    double bandpass_low_hz     = 5.0;    // 带通低通拐点（压掉抖动）
    double filter_q            = 0.70710678118654752440;  // 巴特沃斯 Q 值

    // --- 自适应阈值 ---------------------------------------------------------
    double stats_window_s      = 1.5;    // 求 s 的均值/sigma 的平均窗口
    double adaptive_k          = 0.8;    // 阈值 = 均值 ± k*sigma
    double threshold_floor     = 0.08;   // ……但也不允许比这个距离更近（m/s^2）
    double min_sigma           = 0.15;   // sigma 低于此值即认为"人没在走路"。
                                         // 实测两者差得很开：带通后的传感器噪声
                                         // 约 0.05 m/s^2，而真实步态约 2 m/s^2，
                                         // 所以这道闸门是"人没走时别乱报"的
                                         // 第一道防线。

    // --- 步态判定闸门 -------------------------------------------------------
    double min_step_amplitude  = 0.30;   // 最小峰谷幅度（m/s^2）
    double min_valley_peak_dt  = 0.08;   // 谷→峰最短时延（秒）
    double max_valley_peak_dt  = 0.70;   // 谷→峰最长时延（秒）
    double max_valley_peak_ratio = 0.75; // 谷→峰时延不得超过"它将要产生的那一步
                                         // 间隔"的这个比例。稳态步态下这个比例
                                         // 约 0.5，所以 0.75 是相当宽松的包络；
                                         // 它能挡掉横跨起步/停止瞬间的伪周期 ——
                                         // 那种周期的波谷是从上一段运动继承来的。
    double min_dwell_s         = 0.04;   // 一个周期内，信号停留在上、下阈值之外
                                         // 各自的最短时间。这是把真实步态周期和
                                         // "只是擦过阈值一下"的噪声尖峰区分开的
                                         // 关键。
    double min_step_interval_s = 0.25;   // 两步之间的最短时间（等价步频上限 240 步/分）
    double max_step_interval_s = 2.00;   // 超过这个间隔就认为步态重新开始

    // --- 其他 ---------------------------------------------------------------
    double turn_down_ratio     = 0.20;   // 信号从波峰回落 ratio*sigma 之后，
                                         // 才确认这个峰
    double warmup_s            = 2.0;    // 观察这么久之前不做任何检测
    double cadence_tau_s       = 4.0;    // 步频估计的平滑时间常数
    double max_dt_s            = 0.5;    // 时间戳间隔超过它就做钳制（数据流中断）
};

// -----------------------------------------------------------------------------
// 现成的整套配置（预设）。
//
// 这些数字都是**实测**选出来的，不是猜的。每一个都来自测试台合成步态的多次
// 运行；而实测表明"没帮助"的字段则被有意保持原样（见 running() 里的注释）。
// 不要在没有重跑测试台的情况下"顺手优化"它们。
// -----------------------------------------------------------------------------
namespace presets {

// 步行。这就是默认配置，按大约 50-220 步/分标定。
inline StepConfig walking() { return StepConfig(); }

// 跑步，约 120-240 步/分（2.0-3.33 Hz）。
//
// 在合成测试台上相对 walking() 的实测差异（8 个随机种子，每次 50 秒）：
//   * 可靠范围      220 -> 240 步/分（240 步/分处：52% -> 100%）
//   * 起步          1.5 秒后开始出结果，而不是 2.0 秒
//                   （200 步/分时，2 秒预热会丢掉约 7 步）
//   * 3 Hz 的小幅非步态晃动：
//                   幅度 0.25 m/s^2：误报 79 -> 0 次 / 60 秒
//                   幅度 0.40 m/s^2：误报 172 -> 12 次 / 60 秒
//   * 最坏检测延迟不变，仍是 60 ms；静止误报 0 次。
//
// 以下几个字段**故意不动**，因为实测它们会让结果变差：
//   * bandpass_low_hz 保持 5.0。调到 8 或 10 Hz 会让 200 步/分的检出率掉到
//     95%/88%，220 步/分掉到 50%：通带一放宽，抖动就会制造出多余的局部极大
//     值，而"波峰确认"会提前锁到这些假峰上。
//   * min_valley_peak_dt 保持 0.08 / max_valley_peak_dt 保持 0.70。把它们收紧
//     到 0.10 / 0.40 的版本在 200 步/分处崩到 58% —— 那里半个步周期只有
//     0.15 秒，余量本来就很薄。
//
// 已知限制（**任何参数都改不掉**）：一个站着的人以 2-3.5 Hz 挥手臂，大约每挥
// 一次就会误报一步，本预设和默认配置的表现完全一样。单个加速度计无法把它和
// 跑步区分开；详见 README 第 9 节。
inline StepConfig running() {
    StepConfig c;
    c.stats_window_s      = 1.2;   // 步频变化时跟得更快
    c.warmup_s            = 1.5;   // 开始运动后更快出结果
    c.min_sigma           = 0.25;  // 跑步信号很大，抬高门槛滤掉小幅晃动
    c.min_step_amplitude  = 0.60;
    c.min_step_interval_s = 0.22;  // 给 200 步/分（0.30 秒一步）留出余量
    return c;
}

} // namespace presets

// -----------------------------------------------------------------------------
// 每检测到一次落脚，就产出一个这个结构。
// -----------------------------------------------------------------------------
struct StepEvent {
    std::uint64_t index       = 0;    // 第几步，从 0 开始
    double timestamp          = 0.0;  // 加速度波峰的时刻 == 落脚时刻（秒）
    double interval_s         = 0.0;  // 距上一步的间隔；第一步为 0
    double cadence_spm        = 0.0;  // 平滑后的步频，单位"步/分钟"
    double peak               = 0.0;  // 波峰处的带通信号值（m/s^2）
    double valley             = 0.0;  // 前一个波谷处的带通信号值
    double amplitude          = 0.0;  // 波峰 - 波谷（m/s^2）
    double detection_latency_s= 0.0;  // update() 被调用的时刻 - timestamp（秒）
    double confidence         = 0.0;  // 0..1 的启发式可信度评分
};

// -----------------------------------------------------------------------------
// 检测器的实时内部状态。用于画图 / 调试（GUI 测试台的阈值曲线就是从这里读的）。
// -----------------------------------------------------------------------------
struct DetectorSnapshot {
    double timestamp    = 0.0;
    double magnitude    = 0.0;  // |a| 合加速度
    double gravity      = 0.0;  // 跟踪到的重力大小
    double filtered     = 0.0;  // 带通滤波后的信号 s
    double mean         = 0.0;  // s 的自适应均值
    double sigma        = 0.0;  // s 的自适应标准差
    double level_hi     = 0.0;  // 上阈值
    double level_lo     = 0.0;  // 下阈值
    double peak         = 0.0;  // 自上一个波谷以来的运行波峰
    double valley       = 0.0;  // 最近的波谷
    std::uint64_t step_count = 0;
    int    state        = 0;    // 0 = 空闲，1 = 等波峰
    bool   warm         = false;// 预热完成且信号足够活跃
};

// -----------------------------------------------------------------------------
// 二阶双二阶滤波器（转置直接 II 型）。
// -----------------------------------------------------------------------------
struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double s1 = 0.0, s2 = 0.0;

    void reset() { s1 = 0.0; s2 = 0.0; }

    inline double process(double x) {
        const double y = b0 * x + s1;
        s1 = b1 * x - a1 * y + s2;
        s2 = b2 * x - a2 * y;
        return y;
    }

    // RBJ audio-EQ-cookbook 的系数公式，已按 a0 归一化。
    void configure(bool highpass, double fs, double f0, double q) {
        if (!(fs > 0.0)) return;
        const double nyq = 0.5 * fs;
        if (f0 < 1e-4)          f0 = 1e-4;
        if (f0 > 0.45 * fs)     f0 = 0.45 * fs;
        if (f0 > 0.99 * nyq)    f0 = 0.99 * nyq;
        if (!(q > 0.0))         q = 0.70710678118654752440;

        const double w0 = 2.0 * 3.14159265358979323846 * f0 / fs;
        const double cw = std::cos(w0);
        const double sw = std::sin(w0);
        const double alpha = sw / (2.0 * q);
        const double a0 = 1.0 + alpha;

        double nb0, nb1, nb2;
        if (highpass) { nb0 = (1.0 + cw) * 0.5; nb1 = -(1.0 + cw); nb2 = (1.0 + cw) * 0.5; }
        else          { nb0 = (1.0 - cw) * 0.5; nb1 =  (1.0 - cw); nb2 = (1.0 - cw) * 0.5; }

        b0 = nb0 / a0;  b1 = nb1 / a0;  b2 = nb2 / a0;
        a1 = (-2.0 * cw) / a0;  a2 = (1.0 - alpha) / a0;
    }
};

// -----------------------------------------------------------------------------
// 检测器本体。
// -----------------------------------------------------------------------------
class StepDetector {
public:
    using Callback = std::function<void(const StepEvent&)>;

    enum State { kIdle = 0, kWaitPeak = 1 };

    StepDetector() { configureFilters(true); }

    explicit StepDetector(const StepConfig& cfg) : cfg_(cfg) { configureFilters(true); }

    // ---- 配置 ---------------------------------------------------------------

    // 应用一套配置，并从零开始（步数、统计量全部清零）。
    void setConfig(const StepConfig& cfg) {
        cfg_ = cfg;
        configureFilters(true);
        reset();
    }

    // 应用一套配置，但**保留运行状态**（步数、自适应统计量、滤波器记忆）。
    // 这正是实时调参界面需要的：拖动阈值滑块不该把步数清零。
    void reconfigure(const StepConfig& cfg) {
        cfg_ = cfg;
        configureFilters(false);
    }
    const StepConfig& config() const { return cfg_; }

    // ---- 回调 ---------------------------------------------------------------

    // 注册的回调会在确认一次落脚的瞬间，由 update() 同步调用。
    void onStep(Callback cb) { callback_ = std::move(cb); }

    // 套用某个预设，同时保留输入相关设置（采样率、输入是否含重力），
    // 因为预设调的是检测逻辑，不是"设备怎么接线"。
    void setPreset(const StepConfig& preset) {
        StepConfig c = preset;
        c.sample_rate_hz    = cfg_.sample_rate_hz;
        c.input_has_gravity = cfg_.input_has_gravity;
        c.bandpass_low_hz   = preset.bandpass_low_hz;
        reconfigure(c);
    }
    bool hasCallback() const { return static_cast<bool>(callback_); }

    // ---- 生命周期 -----------------------------------------------------------

    void reset() {
        hpf_.reset();
        lpf_.reset();
        gravity_        = 0.0;
        have_gravity_   = false;
        mean_           = 0.0;
        var_            = 0.0;
        state_          = kIdle;
        step_count_     = 0;
        cadence_        = 0.0;
        last_step_time_ = detail::kNoStep;
        has_last_event_ = false;
        valley_ = peak_ = 0.0;
        valley_t_ = peak_t_ = 0.0;
        crossed_hi_     = false;
        dwell_hi_       = 0.0;
        dwell_lo_       = 0.0;
        elapsed_        = 0.0;
        have_first_ts_  = false;
        internal_t_     = 0.0;
        snap_           = DetectorSnapshot();
    }

    // ---- 流式输入 -----------------------------------------------------------

    // 带时间戳的样本。返回 true 表示**这一次调用**产生了新的一步
    // （如果有回调，回调在我们返回之前就已经执行完了）。
    bool update(double ax, double ay, double az, double timestamp_s) {
        double dt;
        if (!have_first_ts_) {
            have_first_ts_ = true;
            t0_            = timestamp_s;
            dt             = 1.0 / safeRate();
        } else if (timestamp_s < last_ts_) {
            // 调用方的时钟倒退了 —— 设备重连，或者数据流重启。把所有已记录的
            // 时间整体平移一下，让本次运行在新时间基准上无缝继续，而不是一直
            // 卡到新时钟追上旧时钟为止。
            const double shift = timestamp_s - last_ts_;
            t0_ += shift;
            if (last_step_time_ != detail::kNoStep) last_step_time_ += shift;
            valley_t_ += shift;
            peak_t_   += shift;
            dt = 1.0 / safeRate();
        } else {
            dt = timestamp_s - last_ts_;
            if (!(dt > 0.0)) dt = 1.0 / safeRate();          // 时间戳重复
        }
        last_ts_ = timestamp_s;

        if (dt > cfg_.max_dt_s) dt = cfg_.max_dt_s;          // 停摆后又恢复
        if (dt < 1e-6)          dt = 1e-6;

        elapsed_ = timestamp_s - t0_;
        const double alpha_stats = alphaForTau(cfg_.stats_window_s * 0.5, dt);
        return process(ax, ay, az, timestamp_s, dt, alpha_stats);
    }

    // 不带时间戳的样本：内部按 1 / sample_rate_hz 自己推进时间。
    bool update(double ax, double ay, double az) {
        const double dt = 1.0 / safeRate();
        internal_t_ += dt;
        if (!have_first_ts_) { have_first_ts_ = true; t0_ = 0.0; }
        elapsed_ = internal_t_;
        last_ts_ = internal_t_;
        const double alpha_stats = alphaForTau(cfg_.stats_window_s * 0.5, dt);
        return process(ax, ay, az, internal_t_, dt, alpha_stats);
    }

    // ---- 输出 ---------------------------------------------------------------

    std::uint64_t stepCount()   const { return step_count_; }
    double        cadenceSpm()  const { return cadence_; }
    const DetectorSnapshot& snapshot() const { return snap_; }
    bool lastEvent(StepEvent& out) const {
        if (!has_last_event_) return false;
        out = last_event_;
        return true;
    }

private:
    double safeRate() const { return (cfg_.sample_rate_hz > 1.0) ? cfg_.sample_rate_hz : 1.0; }

    // 由时间常数换算指数平滑系数。
    static double alphaForTau(double tau, double dt) {
        if (!(tau > 0.0)) return 1.0;
        const double a = 1.0 - std::exp(-dt / tau);
        return (a < 0.0) ? 0.0 : ((a > 1.0) ? 1.0 : a);
    }

    // 按当前采样率重新设计两个滤波器的系数。clear_state 为 true 时同时清空
    // 滤波器的历史状态（换采样率时才需要）。
    void configureFilters(bool clear_state) {
        const double fs = safeRate();
        if (clear_state) { hpf_.reset(); lpf_.reset(); }
        hpf_.configure(true,  fs, cfg_.bandpass_high_hz, cfg_.filter_q);
        lpf_.configure(false, fs, cfg_.bandpass_low_hz,  cfg_.filter_q);
        gravity_alpha_ = 1.0 - std::exp(-2.0 * 3.14159265358979323846 *
                                        cfg_.gravity_cutoff_hz / fs);
    }

    bool process(double ax, double ay, double az, double ts, double dt, double alpha_stats) {
        // ---- 1. 合加速度 -----------------------------------------------------
        const double mag = std::sqrt(ax * ax + ay * ay + az * az);

        // ---- 2. 去重力 -------------------------------------------------------
        double lin = mag;
        if (cfg_.input_has_gravity) {
            if (!have_gravity_) {
                gravity_      = mag;                 // 用第一个样本做初值
                have_gravity_ = true;
            } else {
                gravity_ += gravity_alpha_ * (mag - gravity_);
            }
            lin = mag - gravity_;
        }

        // ---- 3. 带通滤波 -----------------------------------------------------
        const double s = lpf_.process(hpf_.process(lin));

        // ---- 4. 自适应统计量（指数窗口）--------------------------------------
        const double delta = s - mean_;
        mean_ += alpha_stats * delta;
        var_   = (1.0 - alpha_stats) * (var_ + alpha_stats * delta * delta);
        const double sigma = std::sqrt(var_ > 0.0 ? var_ : 0.0);

        // ---- 5. 阈值 ---------------------------------------------------------
        const double span    = std::max(cfg_.adaptive_k * sigma, cfg_.threshold_floor);
        const double level_hi = mean_ + span;
        const double level_lo = mean_ - span;

        const bool warm = (elapsed_ >= cfg_.warmup_s) && (sigma >= cfg_.min_sigma);

        // ---- 6. 状态机 -------------------------------------------------------
        bool fired = false;
        if (!warm) {
            state_ = kIdle;                          // 信号不足以做判断
        } else if (state_ == kIdle) {
            // 信号一跌破下阈值，就开启一个新的步态周期。
            if (s < level_lo) {
                valley_ = s; valley_t_ = ts;
                peak_   = s; peak_t_   = ts;
                crossed_hi_ = false;
                dwell_hi_   = 0.0;
                dwell_lo_   = dt;
                state_      = kWaitPeak;
            }
        } else { /* kWaitPeak */
            if (s > level_hi)      dwell_hi_ += dt;
            else if (s < level_lo) dwell_lo_ += dt;

            if (s < valley_) {
                // 波谷还在继续变深：把周期从这个新的最低点重新算起，而不是
                // 从第一次跌破阈值的那一点算起。
                valley_ = s; valley_t_ = ts;
                peak_   = s; peak_t_   = ts;
                crossed_hi_ = false;
                dwell_hi_   = 0.0;
            } else if (s > peak_) {
                peak_ = s; peak_t_ = ts;
            }
            if (s > level_hi) crossed_hi_ = true;

            const bool timed_out = (ts - valley_t_) > cfg_.max_valley_peak_dt;
            const bool turned_down =
                (peak_ - s) > std::max(cfg_.turn_down_ratio * sigma, 0.02);

            if (crossed_hi_ && (turned_down || timed_out)) {
                const double dt_vp = peak_t_ - valley_t_;
                const double amp   = peak_ - valley_;
                const double since_last =
                    (last_step_time_ == detail::kNoStep) ? 1e18 : (peak_t_ - last_step_time_);

                // 谷→峰时延还要相对"这一步将要产生的间隔"做个上限。一个横跨
                // 起步/停止瞬间闭合的周期，它的波谷是从上一段运动继承来的，
                // 否则看起来会是一步幅度巨大、时间也完全合理的"步"。
                double max_vp = cfg_.max_valley_peak_dt;
                if (since_last < 1.0e17) {
                    const double rel = cfg_.max_valley_peak_ratio * since_last;
                    if (rel < max_vp) max_vp = rel;
                }

                const bool ok =
                    !timed_out &&
                    dwell_hi_ >= cfg_.min_dwell_s &&   // 是真实周期，不是噪声尖峰
                    dwell_lo_ >= cfg_.min_dwell_s &&
                    dt_vp >= cfg_.min_valley_peak_dt &&
                    dt_vp <= max_vp &&
                    amp   >= cfg_.min_step_amplitude &&
                    since_last >= cfg_.min_step_interval_s;

                if (ok) fired = emit(ts, dt_vp, amp, level_hi, sigma);
                state_ = kIdle;
            } else if (timed_out) {
                state_ = kIdle;
            }
        }

        // ---- 7. 供调试 / 绘图用的快照 ----------------------------------------
        snap_.timestamp  = ts;
        snap_.magnitude  = mag;
        snap_.gravity    = gravity_;
        snap_.filtered   = s;
        snap_.mean       = mean_;
        snap_.sigma      = sigma;
        snap_.level_hi   = level_hi;
        snap_.level_lo   = level_lo;
        snap_.peak       = peak_;
        snap_.valley     = valley_;
        snap_.step_count = step_count_;
        snap_.state      = state_;
        snap_.warm       = warm;
        (void)dt;
        return fired;
    }

    // 组装并派发一个脚步事件。返回 true。
    bool emit(double now_ts, double dt_vp, double amp, double level_hi, double sigma) {
        StepEvent ev;
        const bool first = (step_count_ == 0);

        ev.index    = step_count_;
        ev.timestamp= peak_t_;
        ev.peak     = peak_;
        ev.valley   = valley_;
        ev.amplitude= amp;
        ev.detection_latency_s = now_ts - peak_t_;

        if (first || last_step_time_ == detail::kNoStep) {
            ev.interval_s = 0.0;
        } else {
            ev.interval_s = peak_t_ - last_step_time_;
        }

        // ---- 步频（平滑；停顿之后重新起算）-----------------------------------
        if (ev.interval_s > 0.0 && ev.interval_s <= cfg_.max_step_interval_s) {
            const double inst = 60.0 / ev.interval_s;
            if (cadence_ <= 0.0 || first) {
                cadence_ = inst;
            } else {
                const double a = alphaForTau(cfg_.cadence_tau_s, ev.interval_s);
                cadence_ += a * (inst - cadence_);
            }
        } else if (first) {
            cadence_ = 0.0;
        }
        ev.cadence_spm = cadence_;

        // ---- 可信度启发式 ----------------------------------------------------
        const double thr_score = clamp01((peak_ - level_hi) / (2.0 * sigma + 1e-9));
        const double amp_score = clamp01(amp / cfg_.min_step_amplitude - 1.0);
        const double dt_score  = clamp01(1.0 - std::fabs(dt_vp - 0.28) / 0.28);
        ev.confidence = clamp01(0.45 * thr_score + 0.35 * amp_score + 0.20 * dt_score);

        last_step_time_ = peak_t_;
        last_event_     = ev;
        has_last_event_ = true;
        ++step_count_;

        if (callback_) callback_(ev);        // <-- 用户回调，同步执行
        return true;
    }

    static double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

    // ---- 成员 ---------------------------------------------------------------
    StepConfig cfg_;
    Biquad     hpf_, lpf_;
    Callback   callback_;

    double gravity_        = 0.0;
    double gravity_alpha_  = 0.0;
    bool   have_gravity_   = false;

    double mean_           = 0.0;
    double var_            = 0.0;

    int    state_          = kIdle;
    double valley_         = 0.0, peak_ = 0.0;
    double valley_t_       = 0.0, peak_t_ = 0.0;
    bool   crossed_hi_     = false;
    double dwell_hi_       = 0.0;   // 本周期内停留在 level_hi 之上的累计时间
    double dwell_lo_       = 0.0;   // 本周期内停留在 level_lo 之下的累计时间

    std::uint64_t step_count_ = 0;
    double cadence_        = 0.0;
    double last_step_time_ = detail::kNoStep;

    double t0_             = 0.0;
    double last_ts_        = 0.0;
    double internal_t_     = 0.0;
    double elapsed_        = 0.0;
    bool   have_first_ts_  = false;

    StepEvent        last_event_;
    bool             has_last_event_ = false;
    DetectorSnapshot snap_;
};

} // namespace steplib

#endif // STEP_DETECTOR_HPP_INCLUDED
