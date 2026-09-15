/*
 * switch_plan.hpp  --  切歌对拍（换歌时让 B 的拍点接上 A 的拍点）
 * =============================================================================
 * 纯头文件 · C++11 · 只依赖 beatgrid.hpp
 *
 *
 * 它解决什么问题
 * --------------
 * 歌 A 放到一半要换成歌 B。用户正按某个步频在跑，**不能让音乐在换歌那一瞬间"跳"一下**。
 * 要保证两件事：
 *      速度对齐：换歌前后快慢不变
 *      相位对齐：拍点落在同一个位置上
 *
 * 好消息：只要两首歌都用 "步频 ÷ 它自己的BPM" 这个倍速，
 *         **墙钟拍周期都是 T = 60/步频**，所以速度侧【自动就是一样的】，
 *         根本不需要额外处理。
 *
 * 所以本文件只做一件事：**算出"什么时候起播 B、B 从哪一秒开始播"**。
 *
 *
 * 一次切歌要算三个量
 * ------------------
 *      tEdge  : B 的第一拍应该【被听到】的墙钟时刻
 *      tStart : 调 playerB.play() 的墙钟时刻   （= tEdge − 引子 − bLeadSec）
 *      seekSec: playerB 的入点（歌曲秒）
 *
 *      相位由构造保证 —— 不需要迭代、不需要测量、不需要试错。
 *
 *
 * 两条让它变简单的性质
 * --------------------
 *  1. 【整拍不变性】把 B 的入点前后挪整数个拍，相位完全不变
 *     （移整数拍 = 转盘转整数圈）。所以"选好听的入点"和"对不对得齐"
 *     是两个独立的问题 —— 先挑入点，再管对齐。
 *
 *  2. 【顺延不破坏相位】准备时间不够时，把 tEdge / tStart 一起顺延整数个 T，
 *     相位关系原封不动。所以"等一拍再切"是安全的。
 *
 *
 * ★ 要对齐 A 的【歌曲网格】，不要对齐【脚步时刻】
 * ----------------------------------------------
 * 因为延迟标定总有残余，A 听到的拍点相对脚步本来就有一个固定偏移。
 * 如果让 B 去对齐脚步，B 的网格就会整体平移那个偏移 —— 用户会听到一次相位跳变。
 * 对齐 A 的网格，偏移被原样继承，**切歌前后感知完全连续，标定误差自动抵消**。
 *
 * 所以本文件的输入是 gA（A 的拍网格），而不是脚步时刻。
 *
 *
 * 用法
 * ----
 *      bpmw::SwitchRequest req;
 *      req.now        = steadyNow();
 *      req.sA         = playerA.getInputPosition() / (double)sampleRate;
 *      req.mA         = follower.currentMultiplier();
 *      req.gA         = beatA;          // 从 CppDataAnalyzer 的分析结果建
 *      req.aEndSec    = durationA;
 *      req.gB         = beatB;
 *      req.mB         = cadenceSpm / bpmB;
 *      req.bLenSec    = durationB;
 *      req.entryPrefSec = 0.0;          // B 从哪进（0 = 开头；也可以给副歌位置）
 *      req.wantLeadBeats = 0;           // 不要引子（硬切）；要淡入淡出就填 4~8
 *      req.cal        = calib;          // 一次标定，永久使用
 *
 *      bpmw::SwitchPlan p = bpmw::planSwitch(req);
 *      if (!p.ok) { 降级处理 }          // 见 switchFailName(p.fail)
 *      playerB.loadAudio(...);
 *      playerB.seekTo(p.seekFrame);
 *      sleep_until(p.tStart);  playerB.play();
 *
 * 版本：1.0.0
 * =============================================================================
 */
#ifndef SWITCH_PLAN_HPP_INCLUDED
#define SWITCH_PLAN_HPP_INCLUDED

#include <cmath>
#include "beatgrid.hpp"

namespace bpmw {

// =============================================================================
// 播放链路标定（一次实测，永久使用）
// =============================================================================
struct PlaybackCalib {
    // A（稳态播放中）：getInputPosition()/sr 领先"用户听到"的歌曲秒数
    //   ≈ 引擎固有延迟 + 倍速 × 输出延迟
    double aLeadSec;

    // B（即将起播）：从 play() 到"第一个输入帧被听到"的墙钟秒数
    //   ≈ 引擎固有延迟 + 输出延迟 + 环形缓冲预填
    double bLeadSec;

    // 默认值只是占位符，**必须实测**（见设计文档 §4.5 第 5 步）
    PlaybackCalib() : aLeadSec(0.12), bLeadSec(0.14) {}
    PlaybackCalib(double a, double b) : aLeadSec(a), bLeadSec(b) {}
};

// =============================================================================
// 失败原因（对应设计文档 §4.10 的降级）
// =============================================================================
enum SwitchFail {
    kSwitchOK = 0,
    kSwitchBadParams,      // 倍速 / 周期 / 采样率 / 时长 非法
    kSwitchAPast,          // A 已经播过头了（sA 超出了 aEndSec）
    kSwitchANoRoom,        // A 剩下的时间不够放下 B 的第一拍
    kSwitchBTooShort       // B 太短，选不出合法入点
};

inline const char* switchFailName(int f) {
    switch (f) {
        case kSwitchOK:          return "OK";
        case kSwitchBadParams:   return "参数非法";
        case kSwitchAPast:       return "A 已播完";
        case kSwitchANoRoom:     return "A 剩余时间不够";
        case kSwitchBTooShort:   return "B 太短";
    }
    return "?";
}

// =============================================================================
// 请求
// =============================================================================
struct SwitchRequest {
    double now;              // 当前墙钟秒（单调时钟）

    // ---- A（正在播的那首）----
    double         sA;       // A 的歌曲位置（秒）= getInputPosition()/sr
    double         mA;       // A 的当前倍速
    beatgrid::Grid gA;       // A 的拍网格
    double         aEndSec;  // A 的总时长（秒）

    // ---- B（要接上的那首）----
    beatgrid::Grid gB;       // B 的拍网格
    double         mB;       // B 的目标倍速 = 当前步频 / B 的 BPM
    double         bLenSec;  // B 的总时长（秒）
    double         entryPrefSec;   // B 的音乐入点偏好（0 = 从头）
    int            wantLeadBeats;  // 想要几个整拍的引子（硬切填 0）

    // ---- 通用 ----
    double        sampleRate;      // 用于把秒换算成 seek 帧
    double        minLeadSec;      // 从 now 到 tStart 至少要留的准备时间
    PlaybackCalib cal;

    SwitchRequest()
        : now(0.0), sA(0.0), mA(1.0), aEndSec(0.0),
          mB(1.0), bLenSec(0.0), entryPrefSec(0.0), wantLeadBeats(0),
          sampleRate(44100.0), minLeadSec(0.6) {}
};

// =============================================================================
// 结果
// =============================================================================
struct SwitchPlan {
    bool  ok;
    int   fail;

    double    tEdge;        // B 的第一拍【被听到】的墙钟时刻（也是硬切的切换点）
    double    tStart;       // 调 playerB.play() 的时刻
    double    seekSec;      // playerB 的入点（歌曲秒）
    long long seekFrame;    // playerB 的入点（帧）
    int       leadBeats;    // 实际留了几个整拍的引子

    // ---- 诊断 / 给上层做决策用 ----
    double aHearSec;      // A 的"被听到"位置
    double aEndWall;      // A 自然结束的墙钟时刻
    double leadSec;       // tStart − now（给 B 留了多少准备时间）
    double beatPeriod;    // T = P_B / mB（墙钟拍周期，两首歌相同）
    double overlapSec;    // aEndWall − tEdge：A 在 B 第一拍之后还剩多久（淡出窗口）
    int    deferredBeats; // 因为准备时间不足而顺延了几个整拍

    SwitchPlan()
        : ok(false), fail(kSwitchBadParams), tEdge(0.0), tStart(0.0), seekSec(0.0),
          seekFrame(0), leadBeats(0), aHearSec(0.0), aEndWall(0.0), leadSec(0.0),
          beatPeriod(0.0), overlapSec(0.0), deferredBeats(0) {}
};

// =============================================================================
// 主函数
// =============================================================================
inline SwitchPlan planSwitch(const SwitchRequest& r) {
    SwitchPlan p;

    // ---- 0) 参数检查 ----
    if (!std::isfinite(r.now) || !std::isfinite(r.sA) ||
        !std::isfinite(r.mA) || !std::isfinite(r.mB) ||
        !(r.mA > 1e-9) || !(r.mB > 1e-9) ||
        !(r.sampleRate > 0.0) || !(r.aEndSec > 0.0) || !(r.bLenSec > 0.0) ||
        !r.gA.valid() || !r.gB.valid() ||
        !(r.gA.period > 1e-9) || !(r.gB.period > 1e-9)) {
        p.fail = kSwitchBadParams;
        return p;
    }

    const double T = r.gB.period / r.mB;      // 墙钟拍周期（两首歌相同）
    const double P = r.gB.period;             // B 的拍周期（歌曲秒）
    if (!(T > 1e-9) || !(P > 1e-9)) { p.fail = kSwitchBadParams; return p; }

    // ---- 1) A 的"被听到"位置 ----
    p.aHearSec = r.sA - r.cal.aLeadSec;
    if (p.aHearSec >= r.aEndSec) { p.fail = kSwitchAPast; return p; }
    p.aEndWall = r.now + (r.aEndSec - p.aHearSec) / r.mA;

    // ---- 2) A 的下一拍（听到时刻）作为对齐点 ----
    double tEdge = r.now + (r.gA.firstAfter(p.aHearSec) - p.aHearSec) / r.mA;

    // ---- 3) B 的音乐入点 → 吸附到最近拍线 ----
    //     由【整拍不变性】，这一步不影响相位
    double pref = r.entryPrefSec;
    if (!std::isfinite(pref)) pref = 0.0;
    if (pref < 0.0)           pref = 0.0;
    if (pref > r.bLenSec)     pref = r.bLenSec;

    double sB0 = r.gB.nearest(pref);
    if (sB0 < 0.0)        sB0 += P;                       // nearest 可能为负
    if (sB0 >= r.bLenSec) sB0 = r.gB.lastAtOrBefore(r.bLenSec - 1e-9);
    if (sB0 < 0.0 || sB0 >= r.bLenSec) { p.fail = kSwitchBTooShort; return p; }

    // ---- 4) 引子：整拍前移（相位不变），同时保证入点 >= 0 ----
    int lead = r.wantLeadBeats;
    if (lead < 0) lead = 0;
    if (lead > 100000) lead = 100000;
    while (lead > 0 && (sB0 - (double)lead * P) < 0.0) --lead;

    double sB     = sB0 - (double)lead * P;
    double tStart = tEdge - (double)lead * T - r.cal.bLeadSec;

    // ---- 5) 准备时间不足 → 整体顺延整拍（相位不变）----
    const double minStart = r.now + (r.minLeadSec > 0.0 ? r.minLeadSec : 0.0);
    int deferred = 0;
    while (tStart < minStart) {
        tEdge  += T;
        tStart += T;
        ++deferred;
        if (deferred > 1000000) { p.fail = kSwitchBadParams; return p; }
    }

    // ---- 6) 边界检查 ----
    if (sB < 0.0 || sB >= r.bLenSec) { p.fail = kSwitchBTooShort; return p; }
    if (tEdge > p.aEndWall)          { p.fail = kSwitchANoRoom;  return p; }

    // ---- 7) 填结果 ----
    p.ok            = true;
    p.fail          = kSwitchOK;
    p.tEdge         = tEdge;
    p.tStart        = tStart;
    p.seekSec       = sB;
    p.seekFrame     = (long long)std::floor(sB * r.sampleRate + 0.5);
    p.leadBeats     = lead;
    p.leadSec       = tStart - r.now;
    p.beatPeriod    = T;
    p.overlapSec    = p.aEndWall - tEdge;
    p.deferredBeats = deferred;

    // 帧号可能越界（浮点/时长的边角），夹一下
    if (p.seekFrame < 0) p.seekFrame = 0;
    const long long maxFrame = (long long)std::floor(r.bLenSec * r.sampleRate) - 1;
    if (maxFrame > 0 && p.seekFrame > maxFrame) p.seekFrame = maxFrame;

    return p;
}

// =============================================================================
// 降级：B 还没有分析结果（没有 BPM / 拍网格）时怎么办
//
//   对应设计文档 §4.10。做法：
//     · 不追求拍点对齐（没有网格可比）
//     · 但**保证速度连续**：B 用和 A 一样的倍速起播
//     · 起播时刻仍然取 A 的下一拍 —— 这样至少切在拍上
// =============================================================================
struct DegradedSwitchRequest {
    double           now;
    double           sA;
    double           mA;
    beatgrid::Grid   gA;        // 只需要 A 的网格（用来找下一拍）
    double           aEndSec;
    double           bLenSec;
    double           entryPrefSec;
    double           sampleRate;
    double           minLeadSec;
    PlaybackCalib    cal;

    DegradedSwitchRequest()
        : now(0.0), sA(0.0), mA(1.0), aEndSec(0.0), bLenSec(0.0),
          entryPrefSec(0.0), sampleRate(44100.0), minLeadSec(0.6) {}
};

inline SwitchPlan planSwitchDegraded(const DegradedSwitchRequest& r) {
    SwitchPlan p;
    if (!(r.mA > 1e-9) || !r.gA.valid() || !(r.sampleRate > 0.0) ||
        !(r.aEndSec > 0.0) || !(r.bLenSec > 0.0)) {
        p.fail = kSwitchBadParams;
        return p;
    }

    p.aHearSec = r.sA - r.cal.aLeadSec;
    if (p.aHearSec >= r.aEndSec) { p.fail = kSwitchAPast; return p; }
    p.aEndWall = r.now + (r.aEndSec - p.aHearSec) / r.mA;

    double tEdge = r.now + (r.gA.firstAfter(p.aHearSec) - p.aHearSec) / r.mA;
    double tStart = tEdge - r.cal.bLeadSec;

    const double minStart = r.now + (r.minLeadSec > 0.0 ? r.minLeadSec : 0.0);
    const double T = r.gA.period / r.mA;          // 用 A 的拍周期顺延
    int deferred = 0;
    while (tStart < minStart && T > 1e-9) {
        tEdge  += T;
        tStart += T;
        ++deferred;
        if (deferred > 1000000) { p.fail = kSwitchBadParams; return p; }
    }
    if (tStart < minStart) { p.fail = kSwitchBadParams; return p; }
    if (tEdge > p.aEndWall) { p.fail = kSwitchANoRoom; return p; }

    double sB = r.entryPrefSec;
    if (!std::isfinite(sB) || sB < 0.0) sB = 0.0;
    if (sB >= r.bLenSec) sB = r.bLenSec * 0.5;    // 兜底：从中间开始
    if (sB >= r.bLenSec) { p.fail = kSwitchBTooShort; return p; }

    p.ok            = true;
    p.fail          = kSwitchOK;
    p.tEdge         = tEdge;
    p.tStart        = tStart;
    p.seekSec       = sB;
    p.seekFrame     = (long long)std::floor(sB * r.sampleRate + 0.5);
    p.leadBeats     = 0;
    p.leadSec       = tStart - r.now;
    p.beatPeriod    = T;
    p.overlapSec    = p.aEndWall - tEdge;
    p.deferredBeats = deferred;
    return p;
}

// =============================================================================
// 自检助手：tEdge 与 tStart 之间必须差【整数个 T】
//
//   这是相位对齐的充要条件。写集成代码时可以断言：
//       const double k = beatsFromStartToEdge(p);
//       assert(std::fabs(k - std::floor(k + 0.5)) < 1e-6);
// =============================================================================
inline double beatsFromStartToEdge(const SwitchPlan& p, const PlaybackCalib& cal) {
    if (!(p.beatPeriod > 1e-9)) return 0.0;
    return (p.tEdge - p.tStart - cal.bLeadSec) / p.beatPeriod;
}

#define SWITCHPLAN_VERSION_MAJOR 1
#define SWITCHPLAN_VERSION_MINOR 0
#define SWITCHPLAN_VERSION_PATCH 0
#define SWITCHPLAN_VERSION_STRING "1.0.0"

} // namespace bpmw

#endif // SWITCH_PLAN_HPP_INCLUDED
