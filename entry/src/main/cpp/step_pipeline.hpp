/*
 * step_pipeline.hpp -- 步频 → 倍速 的管线（模拟源版）
 * =============================================================================
 * 纯头文件 · C++11 · 零 NAPI
 *
 * 装配：gaitsim::GaitSim → steplib::StepDetector → ┬ TempoFollower  → 倍速（FOLLOW 动态模式）
 *                                              └  bpmw::PhaseTrim → 规定倍速×(1+δ)（PRESET 恒速/曲线）
 *
 * 刻意做成"纯逻辑 + tick(dt, songPos)"而不是自带线程：
 *   这样它能在宿主机上被完全验证（见 _work/step_pipeline_test.cpp），
 *   线程与 NAPI 留在 napi_bridge_center.cpp。
 *
 * ★ 回填：脚步的歌曲位置必须用 **StepEvent.timestamp**（波峰=落脚时刻）去查历史，
 *   不能读"现在"的位置 —— 否则等于把几十毫秒检测抖动加了回去（docs 坑①）。
 *   这里用一个小环形历史 SongClock 做这件事。
 * =============================================================================
 */

#ifndef STEP_PIPELINE_HPP_INCLUDED
#define STEP_PIPELINE_HPP_INCLUDED

#include "gait_sim.hpp"
#include "step_detector.hpp"
#include "TempoFollower.hpp"
#include "phase_trim.hpp"        // 预设模式的相位对齐工具（团队已验证）

#include <cstddef>
#include <cstdint>
#include <deque>
#include <utility>

namespace steprun {

// ─── 两种控制律 ────────────────────────────────────────────────────────
//   FOLLOW（动态模式）：闭环。倍速 = 实测步频 / 歌曲BPM，TempoFollower 顺带修相位。
//   PRESET（恒速/曲线）：开环 + 微调。倍速 = 规定步频 / 歌曲BPM，再乘 PhaseTrim 的 (1+δ)。
//     ★ 同一时刻只能有一个"相位所有者"：两种模式绝不叠加，否则两个控制器抢同一个量。
enum { kModeFollow = 0, kModePreset = 1 };

// 倍速上下限（与 TempoFollower 默认一致）
const double kMultMin = 0.50;
const double kMultMax = 2.00;

/** (墙钟秒, 歌曲位置秒) 的历史，用于按脚步时间戳回填歌曲位置 */
class SongClock {
public:
    explicit SongClock(std::size_t cap = 1024) : cap_(cap) {}

    void push(double wallSec, double songSec) {
        hist_.push_back(std::make_pair(wallSec, songSec));
        while (hist_.size() > cap_) {
            hist_.pop_front();
        }
    }

    /** 取"不晚于 wallSec 的最近一条"；找不到就用 fallback（通常是当前位置） */
    double songSecAt(double wallSec, double fallback) const {
        for (std::size_t i = hist_.size(); i > 0; --i) {
            if (hist_[i - 1].first <= wallSec) {
                return hist_[i - 1].second;
            }
        }
        return fallback;
    }

    void clear() { hist_.clear(); }

private:
    std::size_t cap_;
    std::deque<std::pair<double, double> > hist_;
};

struct Status {
    double        cadenceSpm;    // 实测步频（模拟源）
    double        multiplier;    // 当前倍速（要交给播放器）
    double        targetBpm;     // 由步频直接算出的目标（已夹到上下限）
    double        songSec;       // 最近一次上报的歌曲位置
    std::uint64_t steps;         // 累计步数
    int           followState;   // FOLLOW：0=ADJUST 1=CHASE 2=HOLD；PRESET：1=正在拉相位 2=已对齐
    double        lastStepSec;   // 最近一次落脚时刻
    int           mode;          // kModeFollow / kModePreset
    double        phaseOffset;   // PRESET：最近一次实测相位偏置（offset 单位，圆量）
    double        delta;         // PRESET：当前 δ（叠在基准倍速上的临时偏差）

    Status()
        : cadenceSpm(0.0), multiplier(1.0), targetBpm(0.0), songSec(0.0),
          steps(0), followState(0), lastStepSec(0.0),
          mode(kModeFollow), phaseOffset(0.0), delta(0.0) {}
};

class StepPipeline {
public:
    explicit StepPipeline(const steplib::StepConfig& detCfg = steplib::presets::running())
        : det_(detCfg),
          sim_(gaitsim::scenarios::makeSim(0)),
          wallSec_(0.0),
          sampleRateHz_(50.0),
          steps_(0),
          lastStepSec_(0.0),
          lastStepSecPrev_(0.0),
          havePrevStep_(false),
          curSongSec_(0.0),
          mode_(kModeFollow),
          songBpm_(0.0),
          firstBeatSec_(0.0),
          presetTargetBpm_(0.0),
          trimMult_(1.0),
          phaseOffset_(0.0) {
        det_.onStep(StepCallback(this));
    }

    /** 设置歌曲（BPM 与首拍），切歌时调 */
    void setSong(double songBpm, double firstBeatSec) {
        songBpm_ = songBpm;
        firstBeatSec_ = firstBeatSec;
        follower_.setSong(songBpm, firstBeatSec);
    }

    /**
     * 选控制律。切换时清掉相位状态 —— 两个控制器的状态不能互相污染
     * （docs：同一时刻只能有一个"相位所有者"）。
     */
    void setMode(int m) {
        mode_ = (m == kModePreset) ? kModePreset : kModeFollow;
        trim_.reset();
        trimMult_ = 1.0;
        phaseOffset_ = 0.0;
    }

    int mode() const { return mode_; }

    /** PRESET 模式下的规定目标步频（曲线推进时随时更新） */
    void setPresetTargetBpm(double bpm) {
        presetTargetBpm_ = bpm;
        // ★ PRESET 的语义是"音乐是主、人跟着跑"。所以要模拟一个**跟着鼓点跑的跑者**：
        //   让模拟源按规定步频出步。
        //   否则模拟源会固执地跑自己的步频 —— 那相位就没有不动点
        //   （差多少漂多少），δ 会永远顶在限幅上，表现为"一直在拉相位"。
        //   注意：这只影响**模拟演示源**。真实传感器进来的人本来就是跟着音乐跑的，
        //   这一步对真实路径无意义。
        if (mode_ == kModePreset && bpm > 0.0) {
            sim_.setCadenceSpm(bpm);
        }
    }

    /** 选择模拟场景（索引见 gaitsim::scenarios::at） */
    void setScenario(int index) {
        sim_ = gaitsim::scenarios::makeSim(index);
    }

    /** 直接换一个配好的模拟器（测试用：可以钉死一个"固执的跑者"做对照） */
    void setSimulator(const gaitsim::GaitSim& s) {
        sim_ = s;
    }

    /**
     * 动态模式「起步延迟校正」窗口（秒）。
     *
     * 窗口内 CHASE 走 delayChase=true —— **不改歌曲速度**，只把 perfect 窗口平移去
     * "框住"脚步（TempoFollower 已有的延迟调整模式，无听感变速）；窗口过后自动回到
     * 普通相位调整。起步阶段计步延迟还没标定，先校正延迟比直接调相位/速度更稳。
     *
     * 0 = 关闭，全程用相位调整。默认 50 秒。
     * ★ reset() 不清这个值（它是设置，不是运行时状态）；窗口按 wallSec() 从 0 重新计。
     */
    void setChaseDelayWindow(double sec) {
        chaseDelayWindowSec_ = (sec > 0.0) ? sec : 0.0;
    }

    /** 整条管线复位（保留歌曲设置） */
    void reset() {
        det_.reset();
        sim_.reset();
        follower_.reset();
        trim_.reset();
        trimMult_ = 1.0;
        phaseOffset_ = 0.0;
        clock_.clear();
        wallSec_ = 0.0;
        steps_ = 0;
        lastStepSec_ = 0.0;
        curSongSec_ = 0.0;
    }

    /**
     * 推进一步。dtSec 通常是 1/50；songPositionSec 是**当前**歌曲位置（秒）。
     * 内部会把 (当前时刻, 歌曲位置) 记进历史，供脚步回填。
     */
    void tick(double dtSec, double songPositionSec) {
        // ★ 起步延迟校正窗口：必须在 det_.update() 之前设好 ——
        //   脚步回调里就会用到 delayChase。窗口按 wallSec_（reset 后从 0 起）计。
        follower_.delayChase =
            (chaseDelayWindowSec_ > 0.0 && wallSec_ < chaseDelayWindowSec_);

        const gaitsim::GaitSample s = sim_.tick();

        // ★ 先记历史，再喂检测器：这样本 tick 的位置也能被本次脚步查到
        clock_.push(wallSec_, songPositionSec);
        curSongSec_ = songPositionSec;

        det_.update(s.ax, s.ay, s.az, wallSec_);
        follower_.update(wallSec_);

        wallSec_ += dtSec;
    }

    /**
     * 真实传感器路径：喂一个采样点（时间戳由调用方给，不推进内部 wallSec_ 时钟）。
     *   ax/ay/az 单位 m/s²、含重力（与 GaitSim 输出同一约定）；wallSec 是单调墙钟秒。
     * ★ 与 tick() 的唯一区别：跳过 sim_.tick()，样本来自外部。
     */
    void pushSample(double ax, double ay, double az, double wallSec) {
        // 与 tick() 一致：起步延迟校正窗口必须在 det_.update() 之前设好
        follower_.delayChase =
            (chaseDelayWindowSec_ > 0.0 && wallSec < chaseDelayWindowSec_);
        det_.update(ax, ay, az, wallSec);
        follower_.update(wallSec);
        wallSec_ = wallSec;
    }

    /** 真实传感器路径：记一次 (墙钟, 歌曲位置)，供脚步按时间戳回填（每批一次即可） */
    void sampleSongClock(double wallSec, double songSec) {
        clock_.push(wallSec, songSec);
        curSongSec_ = songSec;
    }

    Status status() const {
        Status st;
        st.cadenceSpm  = cadenceSpm_;
        st.songSec     = curSongSec_;
        st.steps       = steps_;
        st.lastStepSec = lastStepSec_;
        st.mode        = mode_;

        if (mode_ == kModePreset) {
            const double base = baseMultiplier();
            st.multiplier  = clampMult(base * trimMult_);
            // 与 FOLLOW 保持一致：这个字段装的是"目标倍速"（历史命名，不是 BPM）
            st.targetBpm   = base;
            // 1 = 正在拉相位（δ 还在动），2 = 已对齐（δ 已收回 0）
            st.followState = trim_.engaged() ? 1 : 2;
            st.phaseOffset = phaseOffset_;
            st.delta       = trimMult_ - 1.0;
        } else {
            st.multiplier  = follower_.currentMultiplier();
            st.targetBpm   = follower_.targetMultiplier();
            st.followState = static_cast<int>(follower_.state());
            st.phaseOffset = 0.0;
            st.delta       = 0.0;
        }
        return st;
    }

    /** 直接拿跟随器（调参用） */
    tempo::TempoFollower& follower() { return follower_; }
    const tempo::TempoFollower& follower() const { return follower_; }

    double wallSec() const { return wallSec_; }

private:
    /** 把成员函数包成检测器要的回调（C++11 没有 lambda 捕获成员的直接写法） */
    struct StepCallback {
        StepPipeline* self;
        explicit StepCallback(StepPipeline* p) : self(p) {}
        void operator()(const steplib::StepEvent& e) const { self->onStep(e); }
    };

    void onStep(const steplib::StepEvent& e) {
        ++steps_;
        cadenceSpm_ = e.cadence_spm;
        // ★ 回填：用脚步发生时刻去查歌曲位置，而不是"现在"
        const double songAtStep = clock_.songSecAt(e.timestamp, curSongSec_);

        if (mode_ == kModePreset) {
            // 预设模式：我们**不改**倍速去追步频（规定倍速是死的），
            // 只量"拍点相对脚步错开多少"，让 PhaseTrim 叠一个有界 δ 把它折回 0。
            //   r = 0    ⇒ 拍点正中踩在脚步上
            //   r > 0    ⇒ 当前拍点偏晚（音乐慢了点，要稍微加快）
            const double r = tempo::beatOffset(songAtStep, songBpm_, firstBeatSec_);
            phaseOffset_ = r;
            const double dtStep = (havePrevStep_ && e.timestamp > lastStepSecPrev_)
                                      ? (e.timestamp - lastStepSecPrev_)
                                      : 0.0;
            // update() 返回 (1+δ)；δ 有界（|δ|<=deltaMax）且限速（slewPerSec），
            // 不介入时会把 δ 平滑收回 0 ⇒ 长期平均速度严格等于规定倍速。
            trimMult_ = trim_.update(r, dtStep);
        } else {
            follower_.addFootstep(e.timestamp, songAtStep);
        }

        lastStepSecPrev_ = e.timestamp;
        havePrevStep_ = true;
        lastStepSec_ = e.timestamp;
    }

    double clampMult(double m) const {
        if (m < kMultMin) return kMultMin;
        if (m > kMultMax) return kMultMax;
        return m;
    }

    /** 规定倍速 = 规定步频 / 歌曲BPM（夹到上下限） */
    double baseMultiplier() const {
        if (presetTargetBpm_ > 0.0 && songBpm_ > 0.0) {
            return clampMult(presetTargetBpm_ / songBpm_);
        }
        return 1.0;
    }

    steplib::StepDetector  det_;
    gaitsim::GaitSim       sim_;
    tempo::TempoFollower   follower_;
    SongClock              clock_;
    double                 wallSec_;
    double                 sampleRateHz_;
    std::uint64_t          steps_;
    double                 lastStepSec_;
    double                 lastStepSecPrev_;
    bool                   havePrevStep_;
    double                 curSongSec_;
    double                 cadenceSpm_ = 0.0;
    /** 起步延迟校正窗口（秒）；见 setChaseDelayWindow()。默认 50s */
    double                 chaseDelayWindowSec_ = 50.0;

    // ---- 预设模式（开环 + PhaseTrim 微调）----
    int                    mode_;
    double                 songBpm_;
    double                 firstBeatSec_;
    double                 presetTargetBpm_;
    bpmw::PhaseTrim        trim_;
    double                 trimMult_;      // (1+δ)，未介入时是 1.0
    double                 phaseOffset_;   // 最近一次实测相位偏置
};

} // namespace steprun

#endif // STEP_PIPELINE_HPP_INCLUDED
