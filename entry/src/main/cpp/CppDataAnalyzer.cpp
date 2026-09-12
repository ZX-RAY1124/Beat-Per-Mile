// cppDataAnalyzer.cpp
// 编译: g++ -std=c++11 -O2 cppDataAnalyzer.cpp -o cppDataAnalyzer
// 用法: ./cppDataAnalyzer <beats_csv> [threshold] [min_beats]

#include <iostream>
#include <fstream>
#include <random>
#include <sstream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <algorithm>
#include <iomanip>

struct Paragraph {
    double start, end;
    double a, b, c;          // 二次系数 t(n) = a*n^2 + b*n + c
    double bpm_start;        // 起始BPM
    double bpm_trend;        // BPM每拍变化量
    double r2, rmse;
};

// ---------- 1D K-Means 聚类 ----------
std::vector<int> kmeans_1d(const std::vector<double>& data, int k, int max_iter = 100) {
    if (data.empty()) return {};
    int n = data.size();
    std::random_device rd;
    std::mt19937 g(rd());
    std::vector<double> centers(k);
    std::vector<int> labels(n);
    std::vector<int> indices(n);
    for (int i = 0; i < n; ++i) indices[i] = i;
    std::shuffle(indices.begin(), indices.end(),g);
    for (int i = 0; i < k; ++i) centers[i] = data[indices[i]];

    bool changed = true;
    for (int iter = 0; iter < max_iter && changed; ++iter) {
        changed = false;
        for (int i = 0; i < n; ++i) {
            int best = 0;
            double best_dist = std::abs(data[i] - centers[0]);
            for (int j = 1; j < k; ++j) {
                double d = std::abs(data[i] - centers[j]);
                if (d < best_dist) { best_dist = d; best = j; }
            }
            if (labels[i] != best) changed = true;
            labels[i] = best;
        }
        for (int j = 0; j < k; ++j) {
            double sum = 0.0;
            int count = 0;
            for (int i = 0; i < n; ++i) {
                if (labels[i] == j) { sum += data[i]; count++; }
            }
            if (count > 0) centers[j] = sum / count;
        }
    }
    return labels;
}

// ---------- 二次回归（最小二乘法） ----------
bool quadratic_regression(const std::vector<double>& x, const std::vector<double>& y,
                          double& a, double& b, double& c) {
    int n = x.size();
    if (n < 3) return false;

    // 构造正规方程矩阵
    double sum_x = 0, sum_x2 = 0, sum_x3 = 0, sum_x4 = 0;
    double sum_y = 0, sum_xy = 0, sum_x2y = 0;
    for (int i = 0; i < n; ++i) {
        double xi = x[i];
        double yi = y[i];
        sum_x += xi;
        sum_x2 += xi * xi;
        sum_x3 += xi * xi * xi;
        sum_x4 += xi * xi * xi * xi;
        sum_y += yi;
        sum_xy += xi * yi;
        sum_x2y += xi * xi * yi;
    }

    // 解 3x3 方程组（使用克拉默法则或高斯消元，这里用简单的高斯消元）
    // 矩阵:
    // [ n    sum_x   sum_x2 ] [c]   [sum_y]
    // [ sum_x sum_x2  sum_x3 ] [b] = [sum_xy]
    // [ sum_x2 sum_x3 sum_x4 ] [a]   [sum_x2y]
    // 注意：变量顺序为 c, b, a，这里我们按系数顺序 a, b, c 存储，但方程组按未知数 c,b,a 排列
    // 我们使用高斯消元求解未知数 [c, b, a]
    double A[3][3] = {
        { (double)n, sum_x, sum_x2 },
        { sum_x, sum_x2, sum_x3 },
        { sum_x2, sum_x3, sum_x4 }
    };
    double B[3] = { sum_y, sum_xy, sum_x2y };

    // 高斯消元（列主元）
    for (int col = 0; col < 3; ++col) {
        // 选主元
        int max_row = col;
        double max_val = std::abs(A[col][col]);
        for (int row = col+1; row < 3; ++row) {
            if (std::abs(A[row][col]) > max_val) {
                max_val = std::abs(A[row][col]);
                max_row = row;
            }
        }
        if (max_val < 1e-12) return false;
        // 交换行
        if (max_row != col) {
            for (int j = col; j < 3; ++j) std::swap(A[col][j], A[max_row][j]);
            std::swap(B[col], B[max_row]);
        }
        // 消元
        for (int row = col+1; row < 3; ++row) {
            double factor = A[row][col] / A[col][col];
            for (int j = col; j < 3; ++j) A[row][j] -= factor * A[col][j];
            B[row] -= factor * B[col];
        }
    }
    // 回代
    double sol[3];
    for (int i = 2; i >= 0; --i) {
        sol[i] = B[i];
        for (int j = i+1; j < 3; ++j) sol[i] -= A[i][j] * sol[j];
        sol[i] /= A[i][i];
    }
    // sol[0]=c, sol[1]=b, sol[2]=a
    c = sol[0];
    b = sol[1];
    a = sol[2];
    return true;
}

// ---------- 核心算法：聚类归一化 + 二次回归 ----------
bool estimate_segment_parameters(const std::vector<double>& beats,
                                 double& a, double& b, double& c,
                                 double& bpm_start, double& bpm_trend,
                                 double& r2, double& rmse) {
    if (beats.size() < 5) return false;

    std::vector<double> intervals;
    for (size_t i = 1; i < beats.size(); ++i)
        intervals.push_back(beats[i] - beats[i-1]);
    if (intervals.size() < 2) return false;

    // 聚类归一化
    auto labels = kmeans_1d(intervals, 2);
    std::vector<double> centers(2, 0.0);
    std::vector<int> counts(2, 0);
    for (size_t i = 0; i < intervals.size(); ++i) {
        int lbl = labels[i];
        centers[lbl] += intervals[i];
        counts[lbl]++;
    }
    if (counts[0] == 0 || counts[1] == 0) return false;
    for (int i = 0; i < 2; ++i) centers[i] /= counts[i];
    if (centers[0] > centers[1]) std::swap(centers[0], centers[1]);

    double base_center = centers[0];
    std::vector<double> multipliers(intervals.size());
    for (size_t i = 0; i < intervals.size(); ++i) {
        int lbl = labels[i];
        double ratio = centers[lbl] / base_center;
        double best_mult = 1;
        double best_diff = std::abs(ratio - 1);
        for (int m = 2; m <= 4; ++m) {
            double d = std::abs(ratio - m);
            if (d < best_diff) { best_diff = d; best_mult = m; }
        }
        if (best_diff > 0.5) best_mult = 1;
        multipliers[i] = best_mult;
    }

    // 构建归一化节拍序列
    std::vector<double> norm_beats;
    norm_beats.push_back(beats[0]);
    for (size_t i = 1; i < beats.size(); ++i) {
        double raw_interval = beats[i] - beats[i-1];
        double norm_interval = raw_interval / multipliers[i-1];
        norm_beats.push_back(norm_beats.back() + norm_interval);
    }

    // 二次回归
    std::vector<double> x(norm_beats.size());
    for (size_t i = 0; i < norm_beats.size(); ++i) x[i] = i;
    if (!quadratic_regression(x, norm_beats, a, b, c))
        return false;

    // 计算起始周期 p0 = t(1)-t(0) ≈ a + b
    double p0 = a + b;
    if (p0 <= 0) return false;
    bpm_start = 60.0 / p0;

    double period_trend = 2 * a;
    bpm_trend = -60.0 * period_trend / (p0 * p0);

    // 计算 R? 和 RMSE
    double ss_tot = 0, ss_res = 0;
    double mean_norm = 0;
    for (double v : norm_beats) mean_norm += v;
    mean_norm /= norm_beats.size();
    for (size_t i = 0; i < norm_beats.size(); ++i) {
        double pred = a * i * i + b * i + c;
        ss_res += (norm_beats[i] - pred) * (norm_beats[i] - pred);
        ss_tot += (norm_beats[i] - mean_norm) * (norm_beats[i] - mean_norm);
    }
    rmse = std::sqrt(ss_res / norm_beats.size());
    r2 = (ss_tot > 0) ? 1 - ss_res / ss_tot : 0.0;

    return true;
}

// ---------- 递归动态检测 ----------
std::vector<Paragraph> detect_dynamic_bpm(const std::vector<double>& beats,
                                          double threshold = 0.99999,
                                          int min_beats = 5) {
    std::vector<Paragraph> result;
    if (beats.size() < (size_t)min_beats) return result;

    double a, b, c, bpm_start, bpm_trend, r2, rmse;
    if (!estimate_segment_parameters(beats, a, b, c, bpm_start, bpm_trend, r2, rmse))
        return result;

    double duration = beats.back() - beats.front();
    if (r2 < 0.0 || (r2 < 0.9 && duration < 5.0))
        return result;

    if (r2 >= threshold || beats.size() < (size_t)(min_beats * 2)) {
        result.push_back({beats.front(), beats.back(),
                         a, b, c, bpm_start, bpm_trend, r2, rmse});
        return result;
    }

    // 尝试分裂
    std::vector<double> intervals;
    for (size_t i = 1; i < beats.size(); ++i)
        intervals.push_back(beats[i] - beats[i-1]);
    if (intervals.size() < 4) {
        result.push_back({beats.front(), beats.back(),
                         a, b, c, bpm_start, bpm_trend, r2, rmse});
        return result;
    }

    auto labels = kmeans_1d(intervals, 2);
    std::vector<int> beat_labels(beats.size());
    beat_labels[0] = labels[0];
    for (size_t i = 1; i < beats.size() - 1; ++i)
        beat_labels[i] = labels[i-1];
    beat_labels[beats.size()-1] = labels.back();

    std::vector<std::vector<double>> segments;
    size_t start_idx = 0;
    int current_label = beat_labels[0];
    for (size_t i = 1; i < beat_labels.size(); ++i) {
        if (beat_labels[i] != current_label) {
            std::vector<double> seg(beats.begin() + start_idx, beats.begin() + i);
            if (seg.size() >= (size_t)min_beats)
                segments.push_back(seg);
            start_idx = i;
            current_label = beat_labels[i];
        }
    }
    if (start_idx < beats.size()) {
        std::vector<double> seg(beats.begin() + start_idx, beats.end());
        if (seg.size() >= (size_t)min_beats)
            segments.push_back(seg);
    }

    if (segments.size() <= 1) {
        result.push_back({beats.front(), beats.back(),
                         a, b, c, bpm_start, bpm_trend, r2, rmse});
        return result;
    }

    for (auto& seg : segments) {
        auto sub = detect_dynamic_bpm(seg, threshold, min_beats);
        result.insert(result.end(), sub.begin(), sub.end());
    }
    return result;
}

// ---------- CSV 解析 ----------
bool parse_beats_csv(const std::string& filename, std::string& song_name,
                     std::string& model_name, std::vector<double>& beats) {
    std::ifstream file(filename);
    if (!file.is_open()) return false;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty()) continue;
        if (line[0] == '#') {
            if (line.find("# song=") == 0)
                song_name = line.substr(7);
            else if (line.find("# model=") == 0)
                model_name = line.substr(8);
        } else {
            try { beats.push_back(std::stod(line)); } catch (...) {}
        }
    }
    file.close();
    return !beats.empty();
}

// ---------- 主程序 ----------
int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "用法: " << argv[0] << " <节拍表CSV> [阈值] [最小节拍数]\n";
        return 1;
    }

    std::string csv_path = argv[1];
    double threshold = (argc > 2) ? std::stod(argv[2]) : 0.99999;
    int min_beats = (argc > 3) ? std::stoi(argv[3]) : 5;

    std::string song_name, model_name;
    std::vector<double> beats;
    if (!parse_beats_csv(csv_path, song_name, model_name, beats)) {
        std::cerr << "错误：读取 CSV 失败或无节拍数据\n";
        return 1;
    }

    std::cout << "歌曲: " << song_name << "\n";
    std::cout << "模型: " << model_name << "\n";
    std::cout << "节拍总数: " << beats.size() << "\n";

    auto paragraphs = detect_dynamic_bpm(beats, threshold, min_beats);
    if (paragraphs.empty()) {
        std::cout << "未检测到有效段落\n";
        return 1;
    }

    std::cout << "\n检测到 " << paragraphs.size() << " 个速度段落：\n";
    for (size_t i = 0; i < paragraphs.size(); ++i) {
        auto& p = paragraphs[i];
        std::cout << std::fixed << std::setprecision(2)
                  << "  段落 " << (i+1) << ": " << p.start << "s - " << p.end << "s, "
                  << "起始BPM=" << std::setprecision(3) << p.bpm_start
                  << ", 趋势=" << std::setprecision(6) << p.bpm_trend << " BPM/拍"
                  << ", R?=" << std::setprecision(6) << p.r2 << "\n";
    }

    double avg_bpm = 0;
    for (auto& p : paragraphs) avg_bpm += p.bpm_start;
    avg_bpm /= paragraphs.size();
    std::cout << "\n平均起始BPM: " << std::fixed << std::setprecision(3) << avg_bpm << "\n";

    bool all_high = true;
    for (auto& p : paragraphs)
        if (p.r2 <= 0.99) { all_high = false; break; }
    if (all_high)
        std::cout << "? 所有段落节奏稳定，检测结果可靠。\n";
    else
        std::cout << "? 部分段落置信度较低，请人工验证。\n";

    return 0;
}