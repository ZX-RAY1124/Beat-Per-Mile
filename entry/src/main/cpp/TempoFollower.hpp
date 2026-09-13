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
 *
 * ==================== 修订记录 ====================
 * [2026-09-13] 针对"慢步频+快歌状态机死锁"等缺陷的修复：
 *  1.[修] 目标倍速在**源头**夹取到 [multMin, multMax]（clampMultiplier）。
 *         原来 target_ 不夹取、而下游的长时 EMA stableTarget_ 被夹取，当 步频/歌曲BPM
 *         超出倍速上下限时（例：慢走 55BPM 配 120BPM 歌，target=0.458 < multMin=0.5），
 *         两者恒不相等 -> tempoSettled() 永远 false -> 追逐/保持永不触发，状态机死锁在调速。
 *  2.[修] delayOffset() 的限幅上限不小于 0。hitWin>=1 时 1.0-hitWin 为负，会把 perfect
 *         窗口中心推到 |hitWin-1|（实测 hitWin=2.0 -> 中心 +1.0，本应为 0）。
 *  3.[修] offsetEMA_ 改为**每个脚步都更新**（命中只冻结"修正量"，不冻结 EMA），并在进入
 *         追逐时用当前脚步的偏移重新播种。原来只在"追逐且未命中"时更新：跨状态残留 +
 *         命中期冻结，重新进入追逐的头 1~2 个脚步可能按几秒前（甚至反号）的偏移算修正。
 *  4.[修] 参数自检 sanitize()：公开成员可被上层直接写坏（window<=0 会让步频永不更新、
 *         hitWin<=0 会让状态机永远在追逐），每次 addFootstep/update 夹到安全区间。
 *  5.[修] setSong() 立刻按当前步频重算目标倍速并清空相位历史（旧歌节拍网格下的偏移
 *         无意义，且会让设歌到下一个脚步之间的倍速停在旧歌比例上）。
 *  6.[改] 删掉 HOLD->CHASE 里恒为 0 的 chaseCorr_ 播种（HOLD 下 mult_ == stableTarget_），
 *         改为播种 offsetEMA_；进入 HOLD 时也清 chaseCorr_，让 chaseCorrection() 不再报旧值。
 *  7.[加] maxDtSec：单次推进允许的最大时间步，防息屏/时钟跳变造成倍速阶跃。
 *  8.[加] offsetEmaAlpha：偏移 EMA 系数（原为硬编码 0.5）提为参数。
 *  9.[改] 追逐/保持的退出逻辑抽成 backToAdjust()/enterChase()，onFootstep 与 onTick 共用，
 *         避免两处代码将来走偏。
 * 备份见 TempoFollower.hpp.bak（修改前原版）。
 * =================================================
 *
 * ==================== 修订记录 2 ====================
 * [2026-09-13] perfect / good 双窗口迟滞（解决"追逐只追到窗口边缘"与"窗口调小后频繁跳回追逐"）：
 *  1.[加] goodWin 参数（good 区域，默认 0.50 = ±1/4 拍），与 hitWin（perfect 区域）构成迟滞：
 *           CHASE -> HOLD：连续 holdStreak 个脚步落在 **perfect**(hitWin) 内才进保持；
 *           HOLD  -> CHASE：近期落在 **good**(goodWin) 内的比例 < 1-missRate 才回追逐。
 *         perfect 越紧，追逐就越要把相位压到中心附近才肯进保持；good 越宽，保持期的
 *         小幅漂移就越不会把状态踢回追逐。goodWin < hitWin 时按 hitWin 处理（=关闭迟滞，
 *         行为与旧版一致）。
 *  2.[改] "命中即冻结修正"用 perfect 判定（原来就是 hitWin，含义不变）：只要还没进 perfect
 *         就继续修正，所以追逐会追到中心而不是窗口边缘。
 *  3.[加] 命中率拆两条：hitRate()（perfect）用于 ADJUST->CHASE 触发，goodRate()（good）
 *         用于 HOLD->CHASE；FootstepInfo 增加 good 标志（供 GUI 区分三色脚步）。
 * =================================================
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
    bool   hit;       // perfect：|offset - 窗口中心| < hitWin（进保持的判定，紧）
    bool   good;      // good   ：|offset - 窗口中心| < goodWin（留在保持的判定，宽）
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
    double lockEps      = 0.02;  // 【快照阈值】|target-base| <= lockEps*target 时认为"调速已经到位"：
                                  // 直接把 base 拍成 target（指数收敛的尾巴比如 25% 变化下的最后 1%
                                  // 要花好几秒，而这期间倍速差早就小到听不出来了），并允许按此判据
                                  // 进追逐。1% 倍速差 == 1% BPM 差，听感上基本不可辨；设 0 = 关闭快照
    double hitWin       = 0.25;  // 【perfect 区域】|offset-窗口中心| < hitWin 视为 perfect（±1/8 拍）。
                                  // CHASE->HOLD 要求连续 holdStreak 个 perfect：越紧，追逐越会把
                                  // 相位压到中心附近才进保持（代价是更不容易攒够连击）
    double goodWin      = 0.50;  // 【good 区域】|offset-窗口中心| < goodWin 视为 good（±1/4 拍）。
                                  // HOLD->CHASE 只看 good 比例：越宽，保持期的小幅漂移越不会把
                                  // 状态踢回追逐。与 hitWin 构成迟滞；< hitWin 时按 hitWin 处理
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
    double offsetEmaAlpha = 0.5; // 偏移 EMA 的每步更新系数（0.01~1）：越大反应越快、越不抗噪。
                                  // 注意它是"每个脚步"更新一次，等效时间常数随步频变化
    double maxDtSec      = 0.5;  // 单次 advance 允许的最大时间步（秒）。防息屏/时钟跳变时
                                  // 一次性把倍速跳到位（平滑调速要的是平滑，不是阶跃）

    // ---------- 输入 ----------

    /** 设置歌曲 BPM 与第一拍时间（切歌用）。
     *  会立刻按当前步频重算目标倍速，并清空相位历史：旧歌节拍网格下的 offset 没有意义，
     *  留着还会污染命中率。步频窗口（wallBuf_）保留 —— 步频属于跑者，不属于歌曲。
     *  注意：倍速平滑锚点 base_ 不动，因此切歌不会造成撕裂式突变；若想"两首感知BPM连续"，
     *  再调一次 setMultiplier()。 */
    void setSong(double bpm, double firstBeatSec) {
        songBPM_ = bpm; firstBeatSec_ = firstBeatSec;
        if (cadenceBPM_ > 0.0) target_ = clampMultiplier(calcMultiplier(songBPM_, cadenceBPM_));
        recent_.clear();
        hitRate_   = 0.0;
        goodRate_  = 0.0;
        hitStreak_ = 0;
        offsetEMA_ = 0.0;
        chaseCorr_ = 0.0;
    }

    /** 一次脚触地：wallSec = 墙钟时间，songSec = 当前歌曲进度条时间 */
    void addFootstep(double wallSec, double songSec) {
        sanitize();

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
            if (cnt > 0) {
                cadenceBPM_ = 60.0 / (sum / (double)cnt);
                // 目标倍速在源头就夹到倍速上下限：保证 target_ 与 stableTarget_/base_ 永远
                // 处在同一个区间里，否则饱和时 tempoSettled() 恒为 false，状态机会卡在调速
                target_ = clampMultiplier(calcMultiplier(songBPM_, cadenceBPM_));
            }
        }

        advance(wallSec);   // 平滑推进（目标已更新；不平滑时 base 直接对齐新目标）

        // 相位判定：perfect 窗口中心可被 stepDelaySec 平移（补偿计步算法延迟）
        const double off = beatOffset(songSec, songBPM_, firstBeatSec_);
        const double dOff = delayOffset();
        const double err = std::fabs(off - dOff);
        const bool perfect = err < hitWin;          // 紧窗口：决定能不能进保持
        const bool good    = err < effGoodWin();    // 宽窗口：决定会不会被踢出保持
        recent_.push_back({wallSec, songSec, off, perfect, good});
        while ((int)recent_.size() > recentFootWindow) recent_.erase(recent_.begin());
        hitStreak_ = perfect ? hitStreak_ + 1 : 0;

        onFootstep(perfect);
        applyMultiplier();
    }

    /** 播放循环里周期调用（GUI 每帧/每 50ms），推进平滑并复查状态机 */
    void update(double wallSec) {
        sanitize();
        advance(wallSec);
        onTick();
        applyMultiplier();
    }

    /** 重置：清空历史，倍速回到 1.0（若超出 multMin/multMax 则夹取），状态回到调速 */
    void reset() {
        sanitize();
        const double m0 = clampMultiplier(1.0);
        mult_ = base_ = target_ = stableTarget_ = m0;
        cadenceBPM_ = 0.0;
        chaseCorr_ = 0.0;
        offsetEMA_ = 0.0;
        hitStreak_ = 0;
        hitRate_ = 0.0;
        goodRate_ = 0.0;
        unsettledSince_ = -1.0;
        lastUnsettledWall_ = -1e9;
        state_ = FollowState::ADJUST;
        wallBuf_.clear();
        recent_.clear();
        haveLastWall_ = false;
    }

    /** 参数自检：公开成员可以被上层（GUI/配置/协议）直接写坏，这里把非法值夹到安全区间。
     *  每次 addFootstep/update 调用，代价是十几次比较。也可由宿主在写完参数后手动调用。 */
    void sanitize() {
        // 倍速区间：必须 0 < multMin <= multMax
        if (multMin < 1e-3) multMin = 1e-3;
        if (multMin > 10.0) multMin = 10.0;
        if (multMax > 10.0) multMax = 10.0;
        if (multMax < multMin) multMax = multMin;

        // 窗口类：windowN<2 会让步频估计永不更新；recentFootWindow<=0 会让命中率恒为 0
        if (windowN < 2) windowN = 2;
        if (windowN > 64) windowN = 64;
        if (recentFootWindow < 1) recentFootWindow = 1;
        if (minFootForChase < 1) minFootForChase = 1;

        // 时间常数与时间步
        if (tau < 0.0) tau = 0.0;
        if (tauStable < 0.0) tauStable = 0.0;
        if (!(maxDtSec > 0.0)) maxDtSec = 0.5;      // 也挡住 NaN
        if (maxDtSec > 60.0) maxDtSec = 60.0;

        // 阈值类
        if (stabEps < 0.0) stabEps = 0.0;
        if (convEps < 0.0) convEps = 0.0;
        if (hitWin < 1e-3) hitWin = 1e-3;           // 命中窗口不能为 0，否则永远在追逐
        if (goodWin < 0.0) goodWin = 0.0;           // good 窗口 < hitWin 时按 hitWin 处理（关闭迟滞）
        if (chaseMax < 0.0) chaseMax = 0.0;
        if (chaseDelta < 0.0) chaseDelta = 0.0;
        if (holdStreak < 1) holdStreak = 1;
        if (missRate < 0.0) missRate = 0.0;
        if (missRate > 1.0) missRate = 1.0;
        if (unsettleDelay < 0.0) unsettleDelay = 0.0;
        if (settleEntryDelay < 0.0) settleEntryDelay = 0.0;
        if (lockEps < 0.0) lockEps = 0.0;
        if (lockEps > 0.5) lockEps = 0.5;
        if (offsetEmaAlpha < 0.01) offsetEmaAlpha = 0.01;
        if (offsetEmaAlpha > 1.0) offsetEmaAlpha = 1.0;
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
            goodRate_ = 0.0;
        } else if (!recent_.empty()) {
            offsetEMA_ = recent_.back().offset;   // 用最近的脚步播种，别用 0 起步
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
        if (!(speed == speed)) speed = 1.0;      // NaN 防护
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
    double targetMultiplier()   const { return target_; }    // 由步频直接算出的目标（已夹到倍速上下限）
    double stableTarget()       const { return stableTarget_; } // 长时平均目标（步频稳定性基准）
    double cadenceBPM()         const { return cadenceBPM_; }
    double chaseCorrection()    const { return chaseCorr_; }
    double hitRate()            const { return hitRate_; }   // perfect 比例（进保持/触发追逐用）
    double goodRate()           const { return goodRate_; }  // good 比例（退出保持用）
    double goodWinValue()       const { return effGoodWin(); } // good 区域实际生效宽度（供 GUI 画带）
    int    hitStreak()          const { return hitStreak_; }
    FollowState state()         const { return state_; }
    double songBPM()            const { return songBPM_; }
    double firstBeatSec()       const { return firstBeatSec_; }
    double offsetEMA()          const { return offsetEMA_; }   // 偏移 EMA（调试用）
    const std::vector<FootstepInfo>& recentFootsteps() const { return recent_; }

private:
    // ---------- 夹取 ----------
    /** good 区域实际生效宽度：不小于 perfect。goodWin<hitWin 时等价于关闭迟滞（旧版行为）。 */
    double effGoodWin() const { return goodWin > hitWin ? goodWin : hitWin; }

    double clampMultiplier(double v) const {
        if (v > multMax) v = multMax;
        if (v < multMin) v = multMin;
        return v;
    }

    // ---------- 延迟换算 ----------
    /** stepDelaySec 换算成 perfect 窗口中心的偏移（offset 单位，[-1,1] 尺度）。
     *  1 个 offset 单位 = 半拍 = 30/BPM 秒；窗口中心不越过 ±(1-hitWin)。
     *  hitWin >= 1 时窗口已经覆盖整个半拍，中心只能留在 0（lim 不能取负）。 */
    double delayOffset() const {
        if (songBPM_ <= 0.0) return 0.0;
        double lim = 1.0 - hitWin;
        if (lim < 0.0) lim = 0.0;
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
        if (dt > maxDtSec) dt = maxDtSec;   // 息屏/时钟跳变：不要一次把整段时间灌进 EMA
        if (dt > 0.0) {
            double alpha = (smoothAdjust && tau > 1e-9) ? (1.0 - std::exp(-dt / tau)) : 1.0;
            base_ += (target_ - base_) * alpha;  // !smoothAdjust -> alpha=1 直接跳到目标
            if (base_ > multMax) base_ = multMax;
            if (base_ < multMin) base_ = multMin;
            // 快照：与目标只差 lockEps 以内就直接对齐过去，省掉指数收敛那条听不出来的尾巴，
            // 也让 tempoSettled() 能立刻判定"调速已到位"（见那里的二选一判据）
            if (target_ > 0.0 && lockEps > 0.0 &&
                std::fabs(target_ - base_) <= lockEps * target_) base_ = target_;
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
        // 判据一【快照】：倍速已经贴到当前目标上。base_ 是对 target_ 做 tau 平滑的结果，
        // 能贴到 lockEps 以内，本身就说明步频已经稳了几秒 -> 直接认定"调速干完了"。
        // 这条是为了跳过指数收敛的尾巴 + 长时均值的滞后：那几秒倍速差早就听不出来了，
        // 却让状态机干等在 ADJUST（原来冷启动要 14 秒才肯进追逐，其中大部分是干等）。
        if (lockEps > 0.0 && target_ > 0.0 &&
            std::fabs(base_ - target_) <= lockEps * target_) return true;
        // 判据二【长时均值】抗抖动：瞬时目标贴近长时均值（步频稳了）且倍速收敛到长时均值
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

    /** 两条命中率：perfect 用于"该不该进追逐/能不能进保持"，good 用于"要不要被踢回追逐" */
    void refreshRates() {
        if (recent_.empty()) { hitRate_ = 0.0; goodRate_ = 0.0; return; }
        int ph = 0, gh = 0;
        for (const auto& f : recent_) {
            if (f.hit)  ++ph;
            if (f.good) ++gh;
        }
        const double n = (double)recent_.size();
        hitRate_  = (double)ph / n;
        goodRate_ = (double)gh / n;
    }

    // ---------- 状态转移（onFootstep / onTick 共用，避免两处逻辑走偏） ----------

    /** 保持阶段的输出基准 stableTarget_ 是否已经收敛到当前步频匹配值。
     *  保持只输出 stableTarget_（不调速度），基准偏多少，相位就以多快的速度自己漂出窗口：
     *  实测基准偏 5% 时约 10 秒就漂出 good 区、被踢回追逐。所以基准没收敛就先待在追逐里
     *  —— 追逐本来就在干活，用户感觉不到差别，而且比"进了保持又漂出去"稳得多。 */
    bool holdBasisReady() const {
        if (target_ <= 0.0) return false;
        return std::fabs(stableTarget_ - target_) <= convEps * target_;
    }

    /** 进入追逐：用**当前脚步**的偏移播种 offset EMA。
     *  不播种的话会沿用上次追逐遗留的旧值（甚至反号），重新进入追逐的头 1~2 个脚步
     *  会按几秒前的相位算修正，方向可能是错的。 */
    void enterChase() {
        if (state_ == FollowState::ADJUST) {
            // 从调速切进来：追逐的输出基准是 stableTarget_，而 ADJUST 的输出是 base_。
            // 两者可能差一截（长时均值滞后），这里对齐到 base_，保证切进追逐的瞬间倍速不跳。
            stableTarget_ = base_;
        }
        if (!recent_.empty()) offsetEMA_ = recent_.back().offset;
        chaseCorr_ = 0.0;
        hitStreak_ = 0;
        unsettledSince_ = -1.0;
        state_ = FollowState::CHASE;
    }

    /** 回到调速：步频真的变了（或宿主强制），放弃追逐修正 */
    void backToAdjust() {
        chaseCorr_ = 0.0;
        offsetEMA_ = 0.0;
        unsettledSince_ = -1.0;
        state_ = FollowState::ADJUST;
    }

    // ---------- 状态机：每个脚步触发 ----------
    void onFootstep(bool perfect) {
        refreshRates();
        checkSettle(lastWall_);

        // 偏移 EMA：每个脚步都更新（不论命中与否）。命中只冻结"修正量"（见下），
        // 不冻结 EMA —— 否则命中一段时间后 EMA 停在旧值，下次未命中时用的是几秒前、
        // 甚至反号的偏移。
        if (!recent_.empty()) {
            const double off = recent_.back().offset;
            offsetEMA_ = (1.0 - offsetEmaAlpha) * offsetEMA_ + offsetEmaAlpha * off;
        }

        switch (state_) {
        case FollowState::ADJUST:
            // 触发追逐：调速已settle（步频稳定且倍速已收敛）、已稳定一段时间、且近期命中率过低
            if (tempoSettled() && settledLongEnough(lastWall_) &&
                (int)recent_.size() >= minFootForChase &&
                hitRate_ < (1.0 - missRate)) {
                enterChase();
            }
            break;

        case FollowState::CHASE:
            if (unsettledLongEnough(lastWall_)) {
                // 步频真的变了（持续偏离，非抖动）：放弃追逐回调速
                backToAdjust();
            } else if (hitStreak_ >= holdStreak && holdBasisReady()) {
                // 连续命中：进入保持。追逐修正只用于瞬态对齐，保持阶段直接输出
                // 步频匹配倍速 stableTarget（相位在步频匹配时静止，不会漂出窗口）
                chaseCorr_ = 0.0;      // 保持阶段修正无效，清掉以免 chaseCorrection() 报旧值
                state_ = FollowState::HOLD;
            } else if (!perfect) {
                // 只对还没进 **perfect** 的脚步调整（进了 perfect 就冻结修正，让相位停在
                // 中心附近快速攒够连击）。注意判据是紧窗口 perfect 而不是宽窗口 good：
                // 否则倍速一进 good 就停止修正，追逐又会停在 good 的边缘。
                // 方向：脚步在墙钟上固定，倍速越大拍点到得越早，
                // 偏晚(offset>0)->减慢，偏早(offset<0)->加快。
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
                backToAdjust();
            } else if ((int)recent_.size() >= minFootForChase &&
                       goodRate_ < (1.0 - missRate)) {
                // 迟滞：退出保持看的是**宽**的 good 区域。相位只要漂出 good 才算真失配，
                // 在 perfect 与 good 之间来回蹭不会把状态踢回追逐（这正是 old 版横跳的来源）
                enterChase();
            }
            break;
        }
    }

    // ---------- 状态机：周期 tick（无新脚步，只复查退出条件） ----------
    void onTick() {
        refreshRates();
        checkSettle(lastWall_);
        switch (state_) {
        case FollowState::ADJUST: break;
        case FollowState::CHASE:
            if (unsettledLongEnough(lastWall_)) backToAdjust();
            break;
        case FollowState::HOLD:
            if (unsettledLongEnough(lastWall_)) {
                backToAdjust();
            } else if ((int)recent_.size() >= minFootForChase &&
                       goodRate_ < (1.0 - missRate)) {   // 迟滞：退出保持只看 good 区域
                enterChase();
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
    double target_ = 1.0;    // 目标倍速（步频/歌曲BPM，已夹到倍速上下限）
    double stableTarget_ = 1.0; // target 的长时 EMA（步频稳定性基准）
    double cadenceBPM_ = 0.0;
    double chaseCorr_ = 0.0;
    double offsetEMA_ = 0.0;   // 最近脚步偏移的 EMA（追逐比例控制用）
    double hitRate_ = 0.0;   // perfect 比例
    double goodRate_ = 0.0;  // good 比例
    int    hitStreak_ = 0;
    FollowState state_ = FollowState::ADJUST;

    std::deque<double> wallBuf_;                    // 步频窗口
    std::vector<FootstepInfo> recent_;              // 最近脚步（相位）
    double lastWall_ = 0.0;
    bool   haveLastWall_ = false;
    double unsettledSince_ = -1.0;   // "调速未settle"的起始墙钟时间（-1=已settle）
    double lastUnsettledWall_ = -1e9; // 最近一次"未settle"的墙钟时间（初始视为从未未settle）
};

} // namespace tempo
