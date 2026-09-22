/*
 * step_pipeline.hpp -- 步频 → 倍速 的管线（模拟源版）
 * =============================================================================
 * 纯头文件 · C++11 · 零 NAPI
 *
 * 装配：gaitsim::GaitSim → steplib::StepDetector → tempo::TempoFollower → 倍速
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

#include <cstddef>
#include <cstdint>
#include <deque>
#include <utility>

namespace steprun {

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
    int           followState;   // 0=ADJUST 1=CHASE 2=HOLD
    double        lastStepSec;   // 最近一次落脚时刻

    Status()
        : cadenceSpm(0.0), multiplier(1.0), targetBpm(0.0), songSec(0.0),
          steps(0), followState(0), lastStepSec(0.0) {}
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
          curSongSec_(0.0) {
        det_.onStep(StepCallback(this));
    }

    /** 设置歌曲（BPM 与首拍），切歌时调 */
    void setSong(double songBpm, double firstBeatSec) {
        follower_.setSong(songBpm, firstBeatSec);
    }

    /** 选择模拟场景（索引见 gaitsim::scenarios::at） */
    void setScenario(int index) {
        sim_ = gaitsim::scenarios::makeSim(index);
    }

    /** 整条管线复位（保留歌曲设置） */
    void reset() {
        det_.reset();
        sim_.reset();
        follower_.reset();
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
        const gaitsim::GaitSample s = sim_.tick();

        // ★ 先记历史，再喂检测器：这样本 tick 的位置也能被本次脚步查到
        clock_.push(wallSec_, songPositionSec);
        curSongSec_ = songPositionSec;

        det_.update(s.ax, s.ay, s.az, wallSec_);
        follower_.update(wallSec_);

        wallSec_ += dtSec;
    }

    Status status() const {
        Status st;
        st.cadenceSpm  = cadenceSpm_;
        st.multiplier  = follower_.currentMultiplier();
        st.targetBpm   = follower_.targetMultiplier();
        st.songSec     = curSongSec_;
        st.steps       = steps_;
        st.followState = static_cast<int>(follower_.state());
        st.lastStepSec = lastStepSec_;
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
        lastStepSec_ = e.timestamp;
        cadenceSpm_  = e.cadence_spm;
        // ★ 回填：用脚步发生时刻去查歌曲位置，而不是"现在"
        const double songAtStep = clock_.songSecAt(e.timestamp, curSongSec_);
        follower_.addFootstep(e.timestamp, songAtStep);
    }

    steplib::StepDetector  det_;
    gaitsim::GaitSim       sim_;
    tempo::TempoFollower   follower_;
    SongClock              clock_;
    double                 wallSec_;
    double                 sampleRateHz_;
    std::uint64_t          steps_;
    double                 lastStepSec_;
    double                 curSongSec_;
    double                 cadenceSpm_ = 0.0;
};

} // namespace steprun

#endif // STEP_PIPELINE_HPP_INCLUDED
