// ============================================================================
//  CppDataAnalyzer.hpp —— 节拍表 → 多 BPM 段落分析（header-only 库）
//
//  这是 CppDataAnalyzer.cpp 的"库化"版本：
//    * 原来的 CLI（main 函数）拆掉了，全部改成可调用的函数；
//    * 算法与 CppDataAnalyzer.cpp 一致（同样的聚类归一化 + 二次回归 + 递归分裂），
//      做了三处必要的工程化处理（详见技术文档第 6 节）：
//        1) k-means 不再依赖"单次随机初始化"：k=2 时改用一维精确最优划分（确定、与种子无关），
//           k>2 时用 n_init 次重启取最优 —— 对应 Python 版 sklearn 的 KMeans(n_init=10)。
//           原版 std::random_shuffle 还会在 C++17 下编译失败
//        2) 参数收敛到一个 Options 结构体，不再用散落的函数默认参数
//        3) 错误通过返回值/Result::error 报告，库本身不打印任何东西
//
//  用法（3 行）：
//      #include "CppDataAnalyzer.hpp"
//      cda::Result r = cda::analyze_file("song_beats.csv");
//      for (size_t i = 0; i < r.paragraphs.size(); ++i) { ... }
//
//  详细用法见 CppDataAnalyzer_使用文档.md；算法原理见 CppDataAnalyzer_技术文档.md。
//
//  编译要求：C++11 起（无外部依赖，不需要 linking，把头文件复制走即可用）
// ============================================================================

#ifndef CPP_DATA_ANALYZER_HPP
#define CPP_DATA_ANALYZER_HPP

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <limits>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace cda {

// ============================================================================
//  1. 数据结构
// ============================================================================

// 节拍表：从一个 *_beats.csv 读出来的内容
struct BeatTable {
    std::string song;               // "# song=" 行（可能为空）
    std::string model;              // "# model=" 行（madmom / essentia，可能为空）
    std::vector<double> beats;      // 节拍时间戳（秒），升序

    BeatTable() {}
};

// 一个"速度段落"的拟合结果
// 模型：t(n) = a*n^2 + b*n + c    （n = 段落内第几拍，t = 该拍的时间戳，单位秒）
struct Paragraph {
    double start;        // 段落起始时间（秒）＝第一拍时间
    double end;          // 段落结束时间（秒）＝最后一拍时间
    double a, b, c;      // 二次回归系数
    double bpm_start;    // 段落**起始** BPM（第 0 拍处的瞬时速度）
    double bpm_trend;    // BPM 每拍变化量（线性近似，正=渐快，负=渐慢）
    double r2;           // 决定系数（拟合优度，越接近 1 越可信）
    double rmse;         // 残差标准差（秒）
    int    beat_count;   // 段落内节拍数

    Paragraph()
        : start(0), end(0), a(0), b(0), c(0),
          bpm_start(0), bpm_trend(0), r2(0), rmse(0), beat_count(0) {}

    // 段落时长（秒）
    double duration() const { return end - start; }

    // 第 n 拍的**瞬时**周期（秒）：p(n) = t(n+1) - t(n) = a*(2n+1) + b
    double period_at(size_t n) const {
        return a * (2.0 * static_cast<double>(n) + 1.0) + b;
    }

    // 第 n 拍的瞬时 BPM。比 bpm_start 更适合"实时跟随"场景。
    double bpm_at(size_t n) const {
        const double p = period_at(n);
        return (p > 0.0) ? (60.0 / p) : 0.0;
    }

    // 第 n 拍的时间戳（秒）
    double time_at(size_t n) const {
        const double dn = static_cast<double>(n);
        return a * dn * dn + b * dn + c;
    }

    // 这个时间点是否落在本段落内
    bool contains(double t) const { return t >= start && t <= end; }

    // 给定时间（秒），求该时刻的**瞬时 BPM** —— 实时跟随场景用这个。
    // 做法：先解 t = a·n² + b·n + c 反推出拍序号 n（可以是小数），
    // 再用 p(n) = a(2n+1) + b 求周期，最后换算 BPM。
    // 注意它比 bpm_start + bpm_trend·k 的线性近似精确：后者只在段落起点附近准。
    double bpm_at_time(double t) const {
        const double max_n = (beat_count > 0) ? static_cast<double>(beat_count - 1) : 0.0;
        double n = 0.0;
        if (std::abs(a) < 1e-12) {
            n = (b != 0.0) ? ((t - c) / b) : 0.0;          // 退化成一元一次
        } else {
            const double disc = b * b - 4.0 * a * (c - t);
            if (disc < 0.0) return bpm_at(0);
            const double sq = std::sqrt(disc);
            const double n1 = (-b + sq) / (2.0 * a);
            const double n2 = (-b - sq) / (2.0 * a);
            // 取落在段落范围内的那个根，没有就退到更近的端点
            if (n1 >= 0.0 && n1 <= max_n) n = n1;
            else if (n2 >= 0.0 && n2 <= max_n) n = n2;
            else n = (std::abs(n1) < std::abs(n2)) ? n1 : n2;
        }
        if (n < 0.0) n = 0.0;
        if (n > max_n) n = max_n;
        const double period = a * (2.0 * n + 1.0) + b;
        return (period > 0.0) ? (60.0 / period) : 0.0;
    }
};

// 算法参数。默认值 = CppDataAnalyzer.cpp 的默认值，改之前请先读技术文档。
struct Options {
    // ---- 递归分裂的停止条件 ----
    double r2_threshold;      // 拟合优度达到此值就不再分裂（默认 0.99999）
    int    min_beats;         // 一个段落的最小节拍数（默认 5）
    int    max_depth;         // 递归深度上限，防止病态数据无限分裂（默认 32）

    // ---- 置信度剪枝 ----
    double min_r2_keep;       // 低于此 R² ... （默认 0.9）
    double min_duration_keep; // ... 且时长小于此值，则丢弃该段落（默认 5.0 秒）

    // ---- 聚类归一化 ----
    int    kmeans_k;          // k-means 聚类数（默认 2）
    int    kmeans_max_iter;   // 最大迭代次数（默认 100，仅 k>2 时用）
    int    kmeans_n_init;     // 重启次数，取最优（默认 10，仅 k>2 时用；对应 sklearn 的 n_init）
    double multiplier_tol;    // 整数倍判定的容忍度（默认 0.5，超过则不缩放）
    unsigned int seed;        // k-means 随机种子（默认 0 = 固定，保证可复现）

    Options()
        : r2_threshold(0.99999),
          min_beats(5),
          max_depth(32),
          min_r2_keep(0.9),
          min_duration_keep(5.0),
          kmeans_k(2),
          kmeans_max_iter(100),
          kmeans_n_init(10),
          multiplier_tol(0.5),
          seed(0) {}
};

// 分析结果（高层 API 的返回值）
struct Result {
    bool ok;                      // 是否成功（失败时看 error）
    std::string error;            // ok=false 时的人类可读原因
    std::string song;             // 歌曲名
    std::string model;            // 节拍来源（madmom / essentia）
    size_t total_beats;           // 输入节拍总数
    std::vector<Paragraph> paragraphs;

    Result() : ok(false), total_beats(0) {}

    // 各段落起始 BPM 的算术平均（没有段落时返回 0）
    double average_start_bpm() const {
        if (paragraphs.empty()) return 0.0;
        double sum = 0.0;
        for (size_t i = 0; i < paragraphs.size(); ++i) sum += paragraphs[i].bpm_start;
        return sum / static_cast<double>(paragraphs.size());
    }

    // 是否所有段落都足够可信
    bool all_confident(double r2 = 0.99) const {
        if (paragraphs.empty()) return false;
        for (size_t i = 0; i < paragraphs.size(); ++i)
            if (paragraphs[i].r2 <= r2) return false;
        return true;
    }
};

// ============================================================================
//  2. 低层算法（一般不需要直接调用，除非你要自己组合流程）
// ============================================================================

// ---------- 1D k-means 聚类 ----------
// 对一维数据做 k-means，返回每个样本的簇标签。
//
// 说明（这是相对 CppDataAnalyzer.cpp 的一处**有意的改进**）：
//   原版只做一次随机初始化（std::random_shuffle）。实测这会带来两个问题：
//     1) 结果随初始化变化 —— 同一首歌的段落数会在 11~15 之间跳（见技术文档第 6 节）；
//     2) 数据退化时（大量间隔完全相同）两个中心会重合，形成空簇，整段直接失败。
//   Python 版用的是 sklearn 的 KMeans(n_init=10)，即"重启 10 次取最优"，本身就更稳。
//   这里对应地做了两件事：
//     * k == 2：直接用**一维精确最优划分**（排序后枚举切分点，取簇内平方和最小者），
//       结果确定、与随机种子无关，等价于 n_init → ∞ 的效果；
//     * k > 2：做 n_init 次重启，按簇内平方和(SSE)选最优，并处理空簇。
inline std::vector<int> kmeans_1d(const std::vector<double>& data,
                                  int k,
                                  int max_iter = 100,
                                  unsigned int seed = 0,
                                  int n_init = 10) {
    const int n = static_cast<int>(data.size());
    std::vector<int> labels;
    if (n == 0 || k <= 0) return labels;
    if (k > n) k = n;                    // 簇数不能超过样本数（原版这里会越界）
    labels.assign(n, 0);
    if (k == 1) return labels;           // 只有一个簇：全是 0

    // ---- k == 2：一维最优二划分（确定性）----
    if (k == 2) {
        std::vector<int> order(n);
        for (int i = 0; i < n; ++i) order[i] = i;
        // 按数值排序（比较器只用 data，不受标签影响）
        const std::vector<double>& d = data;
        std::sort(order.begin(), order.end(),
                  [&d](int lhs, int rhs) { return d[lhs] < d[rhs]; });

        // 前缀和与前缀平方和，用于 O(1) 求一段的 SSE
        std::vector<double> pre(n + 1, 0.0), pre2(n + 1, 0.0);
        for (int i = 0; i < n; ++i) {
            const double v = data[order[i]];
            pre[i + 1] = pre[i] + v;
            pre2[i + 1] = pre2[i] + v * v;
        }
        // 把前 s 个划给簇 0、其余划给簇 1，枚举所有 s，取总 SSE 最小
        double best_sse = -1.0;
        int best_split = 1;
        for (int s = 1; s < n; ++s) {
            const double c1n = static_cast<double>(s);
            const double c2n = static_cast<double>(n - s);
            const double sse1 = (pre2[s] - pre2[0]) - (pre[s] - pre[0]) * (pre[s] - pre[0]) / c1n;
            const double sse2 = (pre2[n] - pre2[s]) - (pre[n] - pre[s]) * (pre[n] - pre[s]) / c2n;
            const double sse = sse1 + sse2;
            if (best_sse < 0.0 || sse < best_sse) { best_sse = sse; best_split = s; }
        }
        for (int i = 0; i < n; ++i) labels[order[i]] = (i < best_split) ? 0 : 1;
        return labels;
    }

    // ---- k > 2：n_init 次 Lloyd 迭代，取 SSE 最优 ----
    double best_sse = -1.0;
    std::vector<int> best_labels(labels);
    for (int run = 0; run < n_init; ++run) {
        std::vector<int> indices(n);
        for (int i = 0; i < n; ++i) indices[i] = i;
        std::mt19937 rng(seed + static_cast<unsigned int>(run));
        std::shuffle(indices.begin(), indices.end(), rng);

        std::vector<double> centers(k);
        for (int i = 0; i < k; ++i) centers[i] = data[indices[i]];

        std::vector<int> cur(n, 0);
        bool changed = true;
        for (int iter = 0; iter < max_iter && changed; ++iter) {
            changed = false;
            for (int i = 0; i < n; ++i) {
                int best = 0;
                double best_dist = std::abs(data[i] - centers[0]);
                for (int j = 1; j < k; ++j) {
                    const double dd = std::abs(data[i] - centers[j]);
                    if (dd < best_dist) { best_dist = dd; best = j; }
                }
                if (cur[i] != best) changed = true;
                cur[i] = best;
            }
            for (int j = 0; j < k; ++j) {
                double sum = 0.0;
                int count = 0;
                for (int i = 0; i < n; ++i) {
                    if (cur[i] == j) { sum += data[i]; ++count; }
                }
                if (count > 0) centers[j] = sum / static_cast<double>(count);
            }
        }
        // 计算 SSE，并跳过有空簇的解（空簇对后面的整数倍判定没有意义）
        double sse = 0.0;
        bool empty_cluster = false;
        for (int j = 0; j < k; ++j) {
            double sum = 0.0;
            int count = 0;
            for (int i = 0; i < n; ++i) if (cur[i] == j) { sum += data[i]; ++count; }
            if (count == 0) { empty_cluster = true; break; }
            const double mean = sum / static_cast<double>(count);
            for (int i = 0; i < n; ++i)
                if (cur[i] == j) sse += (data[i] - mean) * (data[i] - mean);
        }
        if (empty_cluster) continue;
        if (best_sse < 0.0 || sse < best_sse) { best_sse = sse; best_labels = cur; }
    }
    return best_labels;
}

// ---------- 二次回归（最小二乘，正规方程 + 列主元高斯消元）----------
// 拟合 y = a*x^2 + b*x + c。成功返回 true 并填好 a/b/c。
inline bool quadratic_regression(const std::vector<double>& x,
                                 const std::vector<double>& y,
                                 double& a, double& b, double& c) {
    const int n = static_cast<int>(x.size());
    if (n < 3 || static_cast<int>(y.size()) != n) return false;

    double sum_x = 0, sum_x2 = 0, sum_x3 = 0, sum_x4 = 0;
    double sum_y = 0, sum_xy = 0, sum_x2y = 0;
    for (int i = 0; i < n; ++i) {
        const double xi = x[i];
        const double yi = y[i];
        sum_x   += xi;
        sum_x2  += xi * xi;
        sum_x3  += xi * xi * xi;
        sum_x4  += xi * xi * xi * xi;
        sum_y   += yi;
        sum_xy  += xi * yi;
        sum_x2y += xi * xi * yi;
    }

    // 正规方程（未知数顺序 c, b, a）：
    // [ n      sum_x   sum_x2 ] [c]   [sum_y  ]
    // [ sum_x  sum_x2  sum_x3 ] [b] = [sum_xy ]
    // [ sum_x2 sum_x3  sum_x4 ] [a]   [sum_x2y]
    double A[3][3] = {
        { static_cast<double>(n), sum_x,  sum_x2 },
        { sum_x,                  sum_x2, sum_x3 },
        { sum_x2,                 sum_x3, sum_x4 }
    };
    double B[3] = { sum_y, sum_xy, sum_x2y };

    // 列主元高斯消元
    for (int col = 0; col < 3; ++col) {
        int max_row = col;
        double max_val = std::abs(A[col][col]);
        for (int row = col + 1; row < 3; ++row) {
            if (std::abs(A[row][col]) > max_val) {
                max_val = std::abs(A[row][col]);
                max_row = row;
            }
        }
        if (max_val < 1e-12) return false;           // 奇异矩阵
        if (max_row != col) {
            for (int j = col; j < 3; ++j) std::swap(A[col][j], A[max_row][j]);
            std::swap(B[col], B[max_row]);
        }
        for (int row = col + 1; row < 3; ++row) {
            const double factor = A[row][col] / A[col][col];
            for (int j = col; j < 3; ++j) A[row][j] -= factor * A[col][j];
            B[row] -= factor * B[col];
        }
    }
    double sol[3];
    for (int i = 2; i >= 0; --i) {
        sol[i] = B[i];
        for (int j = i + 1; j < 3; ++j) sol[i] -= A[i][j] * sol[j];
        sol[i] /= A[i][i];
    }
    c = sol[0]; b = sol[1]; a = sol[2];
    return true;
}

// ---------- 一个段落的参数估计：聚类归一化 + 二次回归 ----------
// 这是整个算法的核心：先把"忽长忽短的拍间隔"归一化成均匀拍，
// 再对归一化序列做二次拟合，得到起始 BPM 与 BPM 变化趋势。
inline bool estimate_segment_parameters(const std::vector<double>& beats,
                                        const Options& opt,
                                        Paragraph& out) {
    if (static_cast<int>(beats.size()) < opt.min_beats) return false;

    std::vector<double> intervals;
    intervals.reserve(beats.size());
    for (size_t i = 1; i < beats.size(); ++i)
        intervals.push_back(beats[i] - beats[i - 1]);
    if (intervals.size() < 2) return false;

    // ---- 步骤 1：对拍间隔做 k-means 聚类 ----
    const std::vector<int> labels =
        kmeans_1d(intervals, opt.kmeans_k, opt.kmeans_max_iter, opt.seed, opt.kmeans_n_init);

    std::vector<double> centers(opt.kmeans_k, 0.0);
    std::vector<int> counts(opt.kmeans_k, 0);
    for (size_t i = 0; i < intervals.size(); ++i) {
        const int lbl = labels[i];
        centers[lbl] += intervals[i];
        ++counts[lbl];
    }
    for (int i = 0; i < opt.kmeans_k; ++i) {
        if (counts[i] == 0) return false;            // 有空簇 → 无法归一化（与原版一致）
        centers[i] /= static_cast<double>(counts[i]);
    }
    std::sort(centers.begin(), centers.end());

    // ---- 步骤 2：每个间隔归到最接近的整数倍，得到归一化序列 ----
    const double base_center = centers[0];           // 最小簇 = 基本拍
    std::vector<double> multipliers(intervals.size(), 1.0);
    for (size_t i = 0; i < intervals.size(); ++i) {
        const double ratio = centers[labels[i]] / base_center;
        double best_mult = 1.0;
        double best_diff = std::abs(ratio - 1.0);
        for (int m = 2; m <= 4; ++m) {
            const double d = std::abs(ratio - static_cast<double>(m));
            if (d < best_diff) { best_diff = d; best_mult = static_cast<double>(m); }
        }
        if (best_diff > opt.multiplier_tol) best_mult = 1.0;
        multipliers[i] = best_mult;
    }

    std::vector<double> norm_beats;
    norm_beats.reserve(beats.size());
    norm_beats.push_back(beats[0]);
    for (size_t i = 1; i < beats.size(); ++i) {
        const double raw_interval = beats[i] - beats[i - 1];
        const double norm_interval = raw_interval / multipliers[i - 1];
        norm_beats.push_back(norm_beats.back() + norm_interval);
    }

    // ---- 步骤 3：二次回归 t(n) = a*n^2 + b*n + c ----
    std::vector<double> x(norm_beats.size());
    for (size_t i = 0; i < norm_beats.size(); ++i) x[i] = static_cast<double>(i);
    double a = 0, b = 0, c = 0;
    if (!quadratic_regression(x, norm_beats, a, b, c)) return false;

    // ---- 步骤 4：由系数换算出 BPM 与趋势 ----
    const double p0 = a + b;                          // 第 0 拍的周期 ≈ t(1)-t(0)
    if (p0 <= 0.0) return false;
    const double bpm_start = 60.0 / p0;
    const double period_trend = 2.0 * a;              // 每拍周期变化量
    const double bpm_trend = -60.0 * period_trend / (p0 * p0);

    // ---- 步骤 5：拟合优度 R² 与残差 RMSE ----
    double ss_tot = 0.0, ss_res = 0.0, mean_norm = 0.0;
    for (size_t i = 0; i < norm_beats.size(); ++i) mean_norm += norm_beats[i];
    mean_norm /= static_cast<double>(norm_beats.size());
    for (size_t i = 0; i < norm_beats.size(); ++i) {
        const double dn = static_cast<double>(i);
        const double pred = a * dn * dn + b * dn + c;
        ss_res += (norm_beats[i] - pred) * (norm_beats[i] - pred);
        ss_tot += (norm_beats[i] - mean_norm) * (norm_beats[i] - mean_norm);
    }
    const double rmse = std::sqrt(ss_res / static_cast<double>(norm_beats.size()));
    const double r2 = (ss_tot > 0.0) ? (1.0 - ss_res / ss_tot) : 0.0;

    out.start = beats.front();
    out.end = beats.back();
    out.a = a; out.b = b; out.c = c;
    out.bpm_start = bpm_start;
    out.bpm_trend = bpm_trend;
    out.r2 = r2;
    out.rmse = rmse;
    out.beat_count = static_cast<int>(beats.size());
    return true;
}

// ---------- 递归动态 BPM 检测（核心入口，低层版）----------
// 返回按时间顺序排列的速度段落。正常情况不会返回空——
// 只有当输入太短、或整体置信度低且时长短时才会是空。
inline std::vector<Paragraph> detect_dynamic_bpm(const std::vector<double>& beats,
                                                 const Options& opt,
                                                 int depth = 0) {
    std::vector<Paragraph> result;
    if (static_cast<int>(beats.size()) < opt.min_beats) return result;

    Paragraph whole;
    if (!estimate_segment_parameters(beats, opt, whole)) return result;

    // 置信度剪枝：R² 为负（比"用均值预测"还差），或"低置信度且太短"→ 直接丢弃
    const double duration = beats.back() - beats.front();
    if (whole.r2 < 0.0 || (whole.r2 < opt.min_r2_keep && duration < opt.min_duration_keep))
        return result;

    // 停止条件 1：已经够稳
    // 停止条件 2：拍数太少，切了也没意义
    // 停止条件 3：递归太深（保护）
    if (whole.r2 >= opt.r2_threshold ||
        beats.size() < static_cast<size_t>(opt.min_beats * 2) ||
        depth >= opt.max_depth) {
        result.push_back(whole);
        return result;
    }

    // ---- 尝试分裂：按拍间隔的聚类标签把序列切成若干连续块 ----
    std::vector<double> intervals;
    intervals.reserve(beats.size());
    for (size_t i = 1; i < beats.size(); ++i)
        intervals.push_back(beats[i] - beats[i - 1]);
    if (intervals.size() < 4) {        // 拍太少，不切
        result.push_back(whole);
        return result;
    }

    const std::vector<int> labels =
        kmeans_1d(intervals, 2, opt.kmeans_max_iter, opt.seed, opt.kmeans_n_init);

    // 间隔 labels 有 n-1 个，映射到 n 个拍上：
    // 第 0 拍用第 0 个间隔的标签，最后一拍用最后一个间隔的标签
    std::vector<int> beat_labels(beats.size());
    beat_labels[0] = labels[0];
    for (size_t i = 1; i + 1 < beats.size(); ++i) beat_labels[i] = labels[i - 1];
    beat_labels[beats.size() - 1] = labels.back();

    // 按标签变化点切段，只保留长度 >= min_beats 的段
    std::vector<std::vector<double> > segments;
    size_t start_idx = 0;
    int current_label = beat_labels[0];
    for (size_t i = 1; i < beat_labels.size(); ++i) {
        if (beat_labels[i] != current_label) {
            std::vector<double> seg(beats.begin() + start_idx, beats.begin() + i);
            if (static_cast<int>(seg.size()) >= opt.min_beats) segments.push_back(seg);
            start_idx = i;
            current_label = beat_labels[i];
        }
    }
    if (start_idx < beats.size()) {
        std::vector<double> seg(beats.begin() + start_idx, beats.end());
        if (static_cast<int>(seg.size()) >= opt.min_beats) segments.push_back(seg);
    }

    // 切不出来（只有一段）→ 就当整段是结果
    if (segments.size() <= 1) {
        result.push_back(whole);
        return result;
    }

    // ---- 对每个子段递归 ----
    for (size_t i = 0; i < segments.size(); ++i) {
        std::vector<Paragraph> sub = detect_dynamic_bpm(segments[i], opt, depth + 1);
        result.insert(result.end(), sub.begin(), sub.end());
    }
    return result;
}

// 便捷重载：用默认参数
inline std::vector<Paragraph> detect_dynamic_bpm(const std::vector<double>& beats) {
    return detect_dynamic_bpm(beats, Options(), 0);
}

// ============================================================================
//  3. CSV 读写
// ============================================================================

// ---------- 解析节拍表 CSV ----------
// 格式：# song=... / # model=... / 每行一个时间戳
// 解析不了的行会被跳过（与原版一致）。
inline bool parse_beats_csv(const std::string& filename,
                            BeatTable& out,
                            std::string* error = 0) {
    out.song.clear();
    out.model.clear();
    out.beats.clear();

    std::ifstream file(filename.c_str());
    if (!file.is_open()) {
        if (error) *error = "无法打开文件: " + filename;
        return false;
    }
    std::string line;
    while (std::getline(file, line)) {
        if (!line.empty() && line[line.size() - 1] == '\r') line.erase(line.size() - 1);
        if (line.empty()) continue;
        if (line[0] == '#') {
            if (line.compare(0, 7, "# song=") == 0)       out.song  = line.substr(7);
            else if (line.compare(0, 8, "# model=") == 0) out.model = line.substr(8);
        } else {
            std::istringstream iss(line);
            double t = 0.0;
            if (iss >> t) out.beats.push_back(t);
        }
    }
    if (out.beats.empty()) {
        if (error) *error = "文件里没有解析到任何节拍: " + filename;
        return false;
    }
    std::sort(out.beats.begin(), out.beats.end());
    return true;
}

// ---------- 把段落导出成 CSV（给 song_database 用）----------
// 表头：song,model,index,start,end,duration,bpm_start,bpm_trend,r2,rmse,beat_count
inline std::string paragraphs_to_csv(const std::string& song,
                                     const std::string& model,
                                     const std::vector<Paragraph>& paragraphs) {
    std::ostringstream os;
    os << "song,model,index,start,end,duration,bpm_start,bpm_trend,r2,rmse,beat_count\r\n";
    for (size_t i = 0; i < paragraphs.size(); ++i) {
        const Paragraph& p = paragraphs[i];
        os << std::setprecision(9)
           << song << ',' << model << ',' << (i + 1) << ','
           << p.start << ',' << p.end << ',' << p.duration() << ','
           << p.bpm_start << ',' << p.bpm_trend << ','
           << p.r2 << ',' << p.rmse << ',' << p.beat_count << "\r\n";
    }
    return os.str();
}

// ============================================================================
//  4. 高层入口
// ============================================================================

// ---------- 直接分析一组节拍时间戳 ----------
inline Result analyze_beats(const std::vector<double>& beats,
                            const Options& opt = Options()) {
    Result r;
    r.total_beats = beats.size();
    if (static_cast<int>(beats.size()) < opt.min_beats) {
        r.error = "节拍数不足（少于 min_beats）";
        return r;
    }
    r.paragraphs = detect_dynamic_bpm(beats, opt, 0);
    if (r.paragraphs.empty()) {
        r.error = "未检测到有效段落（整体置信度太低或时长太短）";
        return r;
    }
    r.ok = true;
    return r;
}

// ---------- 读 CSV 并分析（最常用）----------
inline Result analyze_file(const std::string& csv_path,
                           const Options& opt = Options()) {
    Result r;
    BeatTable table;
    std::string err;
    if (!parse_beats_csv(csv_path, table, &err)) {
        r.error = err;
        return r;
    }
    r = analyze_beats(table.beats, opt);
    r.song = table.song;
    r.model = table.model;
    r.total_beats = table.beats.size();
    return r;
}

// ============================================================================
//  5. 输出格式化（库本身不打印，需要打印时用这些函数拿字符串）
// ============================================================================

// 与 CppDataAnalyzer.cpp 的打印格式一致（"R?" 已修正为 "R²"）
inline std::string format_paragraphs(const std::vector<Paragraph>& paragraphs) {
    std::ostringstream os;
    os << "\n检测到 " << paragraphs.size() << " 个速度段落：\n";
    for (size_t i = 0; i < paragraphs.size(); ++i) {
        const Paragraph& p = paragraphs[i];
        os << std::fixed << std::setprecision(2)
           << "  段落 " << (i + 1) << ": " << p.start << "s - " << p.end << "s, "
           << "起始BPM=" << std::setprecision(3) << p.bpm_start
           << ", 趋势=" << std::setprecision(6) << p.bpm_trend << " BPM/拍"
           << ", R²=" << std::setprecision(6) << p.r2
           << ", 拍数=" << p.beat_count << "\n";
    }
    return os.str();
}

// 完整摘要（歌曲 / 模型 / 节拍数 / 段落 / 平均 BPM / 结论）
inline std::string format_summary(const Result& r) {
    std::ostringstream os;
    if (!r.ok) {
        os << "分析失败: " << r.error << "\n";
        return os.str();
    }
    os << "歌曲: " << r.song << "\n";
    os << "模型: " << r.model << "\n";
    os << "节拍总数: " << r.total_beats << "\n";
    os << format_paragraphs(r.paragraphs);
    os << "\n平均起始BPM: " << std::fixed << std::setprecision(3)
       << r.average_start_bpm() << "\n";
    os << (r.all_confident()
               ? "✓ 所有段落节奏稳定，检测结果可靠。\n"
               : "⚠ 部分段落置信度较低，请人工验证。\n");
    return os.str();
}

}  // namespace cda

#endif  // CPP_DATA_ANALYZER_HPP
