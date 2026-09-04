/*
 * TempoFollower.hpp
 * 跑步电台：让音乐跟随用户步频的 C++ 核心（纯标准库，无外部依赖，可移植到任意 C++ 项目）
 *
 * 一、两个纯函数（供上层直接使用）：
 *   calcMultiplier(songBPM, cadenceBPM)
 *       目标播放倍速 = 步频BPM / 歌曲BPM。例：歌曲 120 BPM、步频 150 BPM -> 1.25x
 *
 *   beatOffset(songSec, songBPM, firstBeatSec)
 *       给定歌曲进度条时间（歌曲原速时间轴，秒），计算该时刻距离最近节拍的归一化偏移：
 *       返回 [-1, 1]：0 = 正中拍点；+1 = 晚半拍；-1 = 早半拍。
 *       例：120BPM(周期0.5s)、第一拍在 0s，songSec=0.15s -> +0.2（略晚）
 *
 * 二、有状态跟随器 TempoFollower：三阶段状态机
 *       调速(ADJUST) -> 追逐(CHASE) -> 保持(HOLD)
 *   - 调速：收集用户最近 N 个脚步墙钟时间，平均间隔（剔除异常值）-> 平均步频 BPM；
 *           目标倍速 = 步频BPM/歌曲BPM，实际倍速按时间常数 tau 指数平滑慢慢逼近。
 *   - 追逐：当调速已settle且近期命中率过低（脚步大量落在节拍判定窗口外）时启动。
 *           倍速越大拍点到得越早：偏晚(offset>0)则减慢、偏早(offset<0)则加快。
 *           追逐期间**绕过 base 平滑**，输出 = 长时目标 stableTarget + 小修正：
 *           修正用比例控制（目标 = -chaseMax×平滑偏移，每步限速 chaseDelta），
 *           命中时冻结修正，避免过冲/来回顶；整体限幅 ±chaseMax。
 *           追逐只在"步频真的变了"（瞬时目标偏离长时均值超过 stabEps）时才退出
 *           回到调速，普通脚步抖动不会打断追逐。
 *   - 保持：连续 holdStreak 次命中后输出步频匹配倍速 stableTarget（追逐修正清除，
 *           相位静止在窗口内不会漂出）；步频变化回调速，相位再失配回追逐。
 *
 *   【稳定性设计】调速是否"已完成"不用瞬时 |target-base| 判定（脚步抖动会让瞬时
 *   target 跳动，导致 ADJUST<->CHASE 反复横跳），而是用 target 的长时 EMA
 *   (stableTarget_)：|target-stableTarget| <= stabEps*stableTarget 且
 *   |base-stableTarget| <= convEps*stableTarget 视为"调速已settle"。
 *
 * 三、时间约定：
 *   - wallSec ：墙钟时间（脚步真实发生的时刻，秒）
 *   - songSec ：歌曲进度条时间（歌曲原速时间轴，秒；
 *               例如 1.25x 倍速播放 10 秒墙上时间 -> songSec = 12.5）
 *   - firstBeatSec：歌曲第一拍在进度条时间轴上的秒数（支持小数）
 *
 * 用法：
 *   tempo::TempoFollower f;
 *   f.setSong(120.0, 0.0);          // 歌曲 BPM、第一拍时间
 *   f.addFootstep(3.21, 2.90);      // 每次脚触地：墙钟时间 + 当前歌曲进度
 *   f.update(3.30);                 // 播放循环里周期推进（平滑调速）
 *   double speed = f.currentMultiplier();   // 交给变速器
 */
#pragma once

#include <cmath>
#include <deque>
#include <vector>
#include <algorithm>

namespace tempo {

// ==================== 两个纯函数 ====================

/** 目标播放倍速：让歌曲 BPM 匹配用户步频 BPM */
inline double calcMultiplier(double songBPM, double cadenceBPM) {
    if (songBPM <= 0.0) return 1.0;
    return cadenceBPM / songBPM;
}

/**
 * 偏移量：songSec（歌曲进度条时间，秒）距离最近节拍的归一化偏移。
 * @return [-1, 1]：0 = 正中拍点；+1 = 晚半拍；-1 = 早半拍
 */
inline double beatOffset(double songSec, double songBPM, double firstBeatSec) {
    if (songBPM <= 0.0) return 0.0;
    const double period = 60.0 / songBPM;
    const double half   = period * 0.5;
    double rem = std::fmod(songSec - firstBeatSec, period);
    if (rem < 0.0) rem += period;
    double off = (rem < half) ? (rem / half) : ((rem - period) / half);
    if (off > 1.0) off = 1.0;
    if (off < -1.0) off = -1.0;
    return off;
}

// ==================== 状态机 ====================

enum class FollowState { ADJUST, CHASE, HOLD };

/** 单个脚步的相位信息（供 GUI/调试显示） */
struct FootstepInfo {
    double wallSec;   // 墙钟时间
    double songSec;   // 脚步发生时歌曲进度条时间
    double offset;    // beatOffset 结果 [-1,1]
    bool   hit;       // |offset| < hitWin
};

class TempoFollower {
public:
    // ---------- 可调参数（默认值，可随时修改，GUI 通过 PARAM 覆盖） ----------
    bool   smoothAdjust = true; // 平滑调速开关：true=按 tau 指数平滑慢慢逼近目标；
                                  // false=直接跳到目标（切歌/手动干预时两首歌瞬时接上，无滑变）
    int    windowN      = 8;     // 步频统计窗口：最近 N 个脚步间隔
    double tau          = 2.0;   // 调速平滑时间常数（秒），越大越"慢"（smoothAdjust=false 时无效）
    double tauStable    = 5.0;   // 步频稳定判定的长时 EMA 时间常数（秒）
    double stabEps      = 0.06;  // |target-stableTarget| > stabEps*stableTarget 视为步频真的变了
                                  // （默认 6%：小于追逐修正上限 ±5% 的步频变化追逐自己追得上，不回调速）
    double convEps      = 0.02;  // |base-stableTarget| > convEps*stableTarget 视为倍速还没收敛
    double hitWin       = 0.25;  // |offset| < hitWin 视为命中（±1/8 拍）
    bool   delayChase   = false; // 延迟调整开关：true 时 CHASE 不调歌曲速度，改调 stepDelaySec
                                  // 使 perfect 窗口平移框住用户脚步（歌曲保持步频匹配，无听感变速）
    double stepDelaySec = 0.0;   // 计步延迟补偿（秒）。正值=计步检测偏晚，perfect 窗口右移(晚侧)；
                                  // 窗口中心偏移 = stepDelaySec × BPM / 30（1 个 offset 单位=半拍）。
                                  // 属于标定值，reset() 不清除，归零请手动设 0
    double missRate     = 0.60;  // 最近脚步命中率 < (1-missRate) 才考虑追逐
    double chaseDelta   = 0.01;  // 追逐每次调整的倍速步长
    double chaseMax     = 0.05;  // 追逐偏离目标倍速的最大幅度
    double multMin      = 0.50;  // 倍速下限
    double multMax      = 2.00;  // 倍速上限
    int    holdStreak   = 4;     // 连续命中多少次后进入保持
    double unsettleDelay = 1.0;   // "调速未settle"持续超过此秒数才允许退出追逐/保持（防抖动误踢）
    double settleEntryDelay = 1.0; // 追逐/保持退出后，需已settle持续超过此秒数才允许重新进入（防快速翻转）
    int    minFootForChase = 4;  // 至少积累多少个脚步才允许触发追逐
    int    recentFootWindow = 8; // 命中率统计窗口（最近多少个脚步）

    // ---------- 输入 ----------
    void setSong(double bpm, double firstBeatSec) {
        songBPM_ = bpm; firstBeatSec_ = firstBeatSec;
    }

    /** 一次脚触地：wallSec = 墙钟时间，songSec = 当前歌曲进度条时间 */
    void addFootstep(double wallSec, double songSec) {
        // 步频估计：最近 windowN 个脚步间隔的平均（先于 advance，不平滑时 base 当拍追上新目标）
        wallBuf_.push_back(wallSec);
        while ((int)wallBuf_.size() > windowN) wallBuf_.pop_front();
        if (wallBuf_.size() >= 2) {
            // 间隔异常值剔除：以中位数为基准，只平均 [0.5*median, 2*median] 内的间隔，
            // 避免跑步者停下/传感器漏检产生的巨大间隔把步频估计冲垮
            std::vector<double> iv;
            iv.reserve(wallBuf_.size() - 1);
            for (size_t i = 1; i < wallBuf_.size(); ++i)
                iv.push_back(wallBuf_[i] - wallBuf_[i - 1]);
            std::vector<double> sorted = iv;
            std::sort(sorted.begin(), sorted.end());
            const double median = sorted[sorted.size() / 2];
            double sum = 0.0; int cnt = 0;
            for (double d : iv) {
                if (d > 0.05 && d >= 0.5 * median && d <= 2.0 * median) { sum += d; ++cnt; }
            }
            if (cnt > 0) cadenceBPM_ = 60.0 / (sum / (double)cnt);
            target_ = calcMultiplier(songBPM_, cadenceBPM_);
        }

        advance(wallSec);   // 平滑推进（目标已更新；不平滑时 base 直接对齐新目标）

        // 相位判定：perfect 窗口中心可被 stepDelaySec 平移（补偿计步算法延迟）
        const double off = beatOffset(songSec, songBPM_, firstBeatSec_);
        const double dOff = delayOffset();
        const bool hit = std::fabs(off - dOff) < hitWin;
        recent_.push_back({wallSec, songSec, off, hit});
        while ((int)recent_.size() > recentFootWindow) recent_.erase(recent_.begin());
        hitStreak_ = hit ? hitStreak_ + 1 : 0;

        onFootstep(hit);
        applyMultiplier();
    }

    /** 播放循环里周期调用（GUI 每帧/每 50ms），推进平滑并复查状态机 */
    void update(double wallSec) {
        advance(wallSec);
        onTick();
        applyMultiplier();
    }

    /** 重置：清空历史，倍速回到 1.0，状态回到调速 */
    void reset() {
        mult_ = base_ = target_ = stableTarget_ = 1.0;
        cadenceBPM_ = 0.0;
        chaseCorr_ = 0.0;
        offsetEMA_ = 0.0;
        hitStreak_ = 0;
        hitRate_ = 0.0;
        unsettledSince_ = -1.0;
        lastUnsettledWall_ = -1e9;
        state_ = FollowState::ADJUST;
        wallBuf_.clear();
        recent_.clear();
        haveLastWall_ = false;
    }

    // ---------- 强制控制（切歌/手动干预用） ----------

    /** 强制把状态机切换到指定状态。
     *  切到 ADJUST 时清空相位历史（旧歌曲节拍网格下的偏移没有意义）；
     *  CHASE/HOLD 保留相位历史。追逐修正、命中连击、未settle计时一并清零。
     *  注意：步频统计窗口（wallBuf_）保留（步频属于跑者，不属于歌曲）。 */
    void forceState(FollowState s) {
        chaseCorr_ = 0.0;
        hitStreak_ = 0;
        unsettledSince_ = -1.0;
        offsetEMA_ = 0.0;
        if (s == FollowState::ADJUST) {
            recent_.clear();
            hitRate_ = 0.0;
        }
        state_ = s;
        applyMultiplier();
    }

    /** 强行把倍速设定为某值，并回到调速状态从该值继续平滑（锚点 base_ 一起设过去，
     *  调速不会立刻把刚设的值拉回去；目标倍速仍由步频估计驱动，会从该值缓慢平滑）。
     *  用于切歌时保持感知BPM连续：sB = sA × BPM_A / BPM_B，直接设上去，
     *  避免重新慢慢变速造成的撕裂感。 */
    void setMultiplier(double speed) {
        if (speed > multMax) speed = multMax;
        if (speed < multMin) speed = multMin;
        mult_ = speed;
        base_ = speed;
        chaseCorr_ = 0.0;
        hitStreak_ = 0;
        unsettledSince_ = -1.0;
        offsetEMA_ = 0.0;
        state_ = FollowState::ADJUST;
    }

    // ---------- 输出 ----------
    double currentMultiplier() const { return mult_; }
    double baseMultiplier()     const { return base_; }      // 平滑后的调速倍速（不含追逐修正）
    double targetMultiplier()   const { return target_; }    // 由步频直接算出的目标
    double stableTarget()       const { return stableTarget_; } // 长时平均目标（步频稳定性基准）
    double cadenceBPM()         const { return cadenceBPM_; }
    double chaseCorrection()    const { return chaseCorr_; }
    double hitRate()            const { return hitRate_; }
    int    hitStreak()          const { return hitStreak_; }
    FollowState state()         const { return state_; }
    double songBPM()            const { return songBPM_; }
    double firstBeatSec()       const { return firstBeatSec_; }
    const std::vector<FootstepInfo>& recentFootsteps() const { return recent_; }

private:
    // ---------- 延迟换算 ----------
    /** stepDelaySec 换算成 perfect 窗口中心的偏移（offset 单位，[-1,1] 尺度）。
     *  1 个 offset 单位 = 半拍 = 30/BPM 秒；窗口中心不越过 ±(1-hitWin)。 */
    double delayOffset() const {
        if (songBPM_ <= 0.0) return 0.0;
        const double lim = 1.0 - hitWin;
        double d = stepDelaySec * songBPM_ / 30.0;
        if (d >  lim) d =  lim;
        if (d < -lim) d = -lim;
        return d;
    }

    // ---------- 平滑推进 ----------
    void advance(double wallSec) {
        if (!haveLastWall_) {
            lastWall_ = wallSec; haveLastWall_ = true;
            if (!smoothAdjust) base_ = target_;  // 不平滑：首个时间点也对齐目标
            return;
        }
        double dt = wallSec - lastWall_;
        lastWall_ = wallSec;
        if (dt > 0.0) {
            double alpha = (smoothAdjust && tau > 1e-9) ? (1.0 - std::exp(-dt / tau)) : 1.0;
            base_ += (target_ - base_) * alpha;  // !smoothAdjust -> alpha=1 直接跳到目标
            if (base_ > multMax) base_ = multMax;
            if (base_ < multMin) base_ = multMin;
            double alphaS = (tauStable > 1e-9) ? (1.0 - std::exp(-dt / tauStable)) : 1.0;
            stableTarget_ += (target_ - stableTarget_) * alphaS;
            if (stableTarget_ > multMax) stableTarget_ = multMax;
            if (stableTarget_ < multMin) stableTarget_ = multMin;
        } else if (!smoothAdjust) {
            base_ = target_;   // dt<=0（时间回跳）但不平滑：仍直接对齐目标
        }
    }

    /**
     * 调速是否已 settle（"调速程序没有在工作"）：
     * 瞬时目标与长时均值接近（步频稳定）且实际倍速已收敛到长时均值。
     * 用长时均值对比，避免瞬时 target 因脚步抖动跳动而误判。
     */
    bool tempoSettled() const {
        if (stableTarget_ <= 1e-9) return false;
        if (std::fabs(target_ - stableTarget_) > stabEps * stableTarget_) return false;
        if (std::fabs(base_ - stableTarget_) > convEps * stableTarget_) return false;
        return true;
    }

    // 记录"未settle"开始时间；settle 时清除
    void checkSettle(double now) {
        if (tempoSettled()) {
            unsettledSince_ = -1.0;
        } else {
            if (unsettledSince_ < 0.0) unsettledSince_ = now;
            lastUnsettledWall_ = now;   // 每次未settle都刷新（进入追逐前需要一段安静期）
        }
    }

    // "未settle"已持续超过 unsettleDelay 秒（步频真的变了，而不是抖动尖峰）
    bool unsettledLongEnough(double now) const {
        return unsettledSince_ >= 0.0 && (now - unsettledSince_) >= unsettleDelay;
    }

    // 距离上一次"未settle"已过去超过 settleEntryDelay 秒（允许重新进入追逐/保持）
    bool settledLongEnough(double now) const {
        return (now - lastUnsettledWall_) >= settleEntryDelay;
    }

    void refreshHitRate() {
        if (recent_.empty()) { hitRate_ = 0.0; return; }
        int hits = 0;
        for (const auto& f : recent_) if (f.hit) ++hits;
        hitRate_ = (double)hits / (double)recent_.size();
    }

    // ---------- 状态机：每个脚步触发 ----------
    void onFootstep(bool hit) {
        refreshHitRate();
        checkSettle(lastWall_);
        switch (state_) {
        case FollowState::ADJUST:
            // 触发追逐：调速已settle（步频稳定且倍速已收敛）、已稳定一段时间、且近期命中率过低
            if (tempoSettled() && settledLongEnough(lastWall_) &&
                (int)recent_.size() >= minFootForChase &&
                hitRate_ < (1.0 - missRate)) {
                chaseCorr_ = 0.0;
                hitStreak_ = 0;
                unsettledSince_ = -1.0;
                state_ = FollowState::CHASE;
            }
            break;

        case FollowState::CHASE:
            if (unsettledLongEnough(lastWall_)) {
                // 步频真的变了（持续偏离，非抖动）：放弃追逐回调速
                chaseCorr_ = 0.0;
                unsettledSince_ = -1.0;
                state_ = FollowState::ADJUST;
            } else if (hitStreak_ >= holdStreak) {
                // 连续命中：进入保持。追逐修正只用于瞬态对齐，保持阶段直接输出
                // 步频匹配倍速 stableTarget（相位在步频匹配时静止，不会漂出窗口）
                state_ = FollowState::HOLD;
            } else if (!hit) {
                const double off = recent_.back().offset;
                offsetEMA_ = (1.0 - 0.5) * offsetEMA_ + 0.5 * off;   // 平滑偏移（两种模式共用）
                if (delayChase) {
                    // 延迟调整模式：不调歌曲速度（无声无息），改把 perfect 窗口中心移向脚步
                    // 平均偏移来"框住"脚步。歌曲保持步频匹配倍速 -> 相位静止，窗口移动无听感副作用。
                    const double curD = delayOffset();
                    double step = offsetEMA_ - curD;      // 窗口需要移动的距离（offset 单位）
                    const double kDStep = 0.10;           // 每步最大移动（offset 单位）
                    if (step >  kDStep) step =  kDStep;
                    if (step < -kDStep) step = -kDStep;
                    if (songBPM_ > 0.0)
                        stepDelaySec += step * 30.0 / songBPM_;   // 换算成秒写回（正值=检测偏晚）
                } else {
                // 只对未命中的脚步调整（命中即冻结修正，相位停在窗口内快速攒命中）。
                // 方向：脚步在墙钟上固定，倍速越大拍点到得越早，
                // 偏晚(offset>0)->减慢，偏早(offset<0)->加快。
                // 比例控制（P）：目标修正量直接正比于平滑后的偏移（|offset|=1 -> ±chaseMax），
                // 实际修正量每步最多变化 chaseDelta（限速），整体限幅 ±chaseMax。
                // 不累加积分 -> 无过冲、无来回顶（摇摆）。
                double targetCorr = -chaseMax * offsetEMA_;
                if (targetCorr >  chaseMax) targetCorr =  chaseMax;
                if (targetCorr < -chaseMax) targetCorr = -chaseMax;
                double d = targetCorr - chaseCorr_;
                if (d >  chaseDelta) d =  chaseDelta;
                if (d < -chaseDelta) d = -chaseDelta;
                chaseCorr_ += d;
                }
            }
            break;

        case FollowState::HOLD:
            if (unsettledLongEnough(lastWall_)) {
                // 步频真的变了：重新调速
                chaseCorr_ = 0.0;
                unsettledSince_ = -1.0;
                state_ = FollowState::ADJUST;
            } else if ((int)recent_.size() >= minFootForChase &&
                       hitRate_ < (1.0 - missRate)) {
                // 保持期间相位又漂了，从当前偏移量继续追逐
                chaseCorr_ = mult_ - stableTarget_;
                if (chaseCorr_ > chaseMax) chaseCorr_ = chaseMax;
                if (chaseCorr_ < -chaseMax) chaseCorr_ = -chaseMax;
                hitStreak_ = 0;
                state_ = FollowState::CHASE;
            }
            break;
        }
    }

    // ---------- 状态机：周期 tick（无新脚步，只复查退出条件） ----------
    void onTick() {
        refreshHitRate();
        checkSettle(lastWall_);
        switch (state_) {
        case FollowState::ADJUST: break;
        case FollowState::CHASE:
            if (unsettledLongEnough(lastWall_)) {
                chaseCorr_ = 0.0;
                unsettledSince_ = -1.0;
                state_ = FollowState::ADJUST;
            }
            break;
        case FollowState::HOLD:
            if (unsettledLongEnough(lastWall_)) {
                chaseCorr_ = 0.0;
                unsettledSince_ = -1.0;
                state_ = FollowState::ADJUST;
            }
            else if ((int)recent_.size() >= minFootForChase &&
                     hitRate_ < (1.0 - missRate)) {
                chaseCorr_ = mult_ - stableTarget_;
                if (chaseCorr_ > chaseMax) chaseCorr_ = chaseMax;
                if (chaseCorr_ < -chaseMax) chaseCorr_ = -chaseMax;
                hitStreak_ = 0;
                state_ = FollowState::CHASE;
            }
            break;
        }
    }

    void applyMultiplier() {
        switch (state_) {
        case FollowState::ADJUST: mult_ = base_;                 break;
        // 追逐期间绕过 base_ 平滑：直接用稳定的长时目标 + 小修正，果断调速不拖泥带水；
        // delayChase 模式下不调速度（chaseCorr 无效），倍速恒为步频匹配值
        case FollowState::CHASE:  mult_ = stableTarget_ + (delayChase ? 0.0 : chaseCorr_); break;
        // 保持：输出步频匹配倍速（追逐修正已清除），并跟随小幅步频漂移，相位保持静止
        case FollowState::HOLD:   mult_ = stableTarget_;         break;
        }
        if (mult_ > multMax) mult_ = multMax;
        if (mult_ < multMin) mult_ = multMin;
    }

    // ---------- 状态 ----------
    double songBPM_ = 120.0;
    double firstBeatSec_ = 0.0;
    double mult_ = 1.0;      // 实际输出倍速
    double base_ = 1.0;      // 平滑后的调速倍速（追逐修正前的基准）
    double target_ = 1.0;    // 目标倍速（步频/歌曲BPM）
    double stableTarget_ = 1.0; // target 的长时 EMA（步频稳定性基准）
    double cadenceBPM_ = 0.0;
    double chaseCorr_ = 0.0;
    double offsetEMA_ = 0.0;   // 最近脚步偏移的 EMA（追逐比例控制用）
    double hitRate_ = 0.0;
    int    hitStreak_ = 0;
    FollowState state_ = FollowState::ADJUST;

    std::deque<double> wallBuf_;                    // 步频窗口
    std::vector<FootstepInfo> recent_;              // 最近脚步（相位）
    double lastWall_ = 0.0;
    bool haveLastWall_ = false;
    double unsettledSince_ = -1.0;   // "调速未settle"的起始墙钟时间（-1=已settle）
    double lastUnsettledWall_ = -1e9; // 最近一次"未settle"的墙钟时间（初始视为从未未settle）
};

} // namespace tempo