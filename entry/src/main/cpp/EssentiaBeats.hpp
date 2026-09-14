// ============================================================================
//  EssentiaBeats.hpp —— 用 Essentia(C++) 做节拍检测的 header-only 库
//
//  这是 essentia_to_CSV.cpp 的"库化"版本：去掉 main()、去掉命令行解析、
//  去掉所有屏幕输出，只留下可被 App / NAPI / 其它 C++ 代码直接调用的函数。
//
//  ── 三个入口，按需要选 ────────────────────────────────────────────────────
//   1) detect(signal, opt)            直接分析**内存里的音频采样**。
//                                    App 里最推荐：你已经有解码好的 PCM，不需要再读文件。
//   2) detect_file(path, opt)         从文件分析。分两种情况：
//                                        鸿蒙/安卓/iOS(Essentia 自带 FFmpeg) → MonoLoader
//                                        桌面(Essentia 不带 FFmpeg)           → 调 ffmpeg 命令行
//   3) detect_file_to_csv(path, csv)  一站式：分析 + 写节拍表 CSV
//
//  ── 依赖 ─────────────────────────────────────────────────────────────────
//   * 必须有 Essentia 的 C++ 库与头文件（libessentia + include/essentia）
//   * 只用 C++11 标准库，不需要 Python、不需要 bash
//   * 鸿蒙工程里 libessentia.so 已经就位，直接把本文件加进 cpp 目录即可
//
//  ── 生命周期（重要）──────────────────────────────────────────────────────
//   Essentia 必须先 init() 注册算法才能 create()。本库用 ensure_initialized()
//   自动做一次（C++11 的 magic static，线程安全），之后一直保持初始化状态。
//   不建议在 App 运行期间调 shutdown()；进程退出时由静态析构处理即可。
//
//  ── 采样率 ───────────────────────────────────────────────────────────────
//   Essentia 的 RhythmExtractor2013 **只支持 44100Hz**。传给 detect() 的信号
//   必须已经是 44100Hz 单声道；detect_file() 会自动重采样到 44100。
// ============================================================================

#ifndef ESSENTIA_BEATS_HPP
#define ESSENTIA_BEATS_HPP

#include <essentia/algorithmfactory.h>
#include <essentia/essentia.h>

#include <cstdio>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#ifdef _WIN32
#  include <windows.h>
#endif 

namespace eb {

// ============================================================================
//  0. 平台 / 解码方式开关（与 essentia_to_CSV.cpp 保持一致，可用 -D 覆盖）
// ============================================================================

// 1 = 用 Essentia 自己的 MonoLoader（Essentia 编译时带了 FFmpeg，**鸿蒙用这个**）
// 0 = 用 ffmpeg 命令行解码（Essentia 不带 FFmpeg，桌面用这个）
#ifndef ESSENTIA_USE_MONOLOADER
#  if defined(__OHOS__) || defined(__ANDROID__) || defined(__APPLE__)
#    define ESSENTIA_USE_MONOLOADER 1
#  else
#    define ESSENTIA_USE_MONOLOADER 0
#  endif
#endif

// 平台判定（单独抽出来是为了能用 -DESSENTIA_PLATFORM_WINDOWS=0 在 Windows 上验证 POSIX 分支）
#ifndef ESSENTIA_PLATFORM_WINDOWS
#  ifdef _WIN32
#    define ESSENTIA_PLATFORM_WINDOWS 1
#  else
#    define ESSENTIA_PLATFORM_WINDOWS 0
#  endif
#endif

// ============================================================================
//  1. 数据结构
// ============================================================================

struct Options {
    double sample_rate;        // 必须 44100（Essentia 硬性要求）
    bool   explicit_tempo;     // 是否使用下面的 min/max tempo（默认不用，走 Essentia 默认 40/208）
    int    min_tempo;          // 注意是 int：Essentia 的 minTempo/maxTempo 参数就是整数类型
    int    max_tempo;          // 传 double 会触发 "losing resolution while truncating" 警告
    std::string ffmpeg_exe;    // 仅 ESSENTIA_USE_MONOLOADER==0 时有效

    Options()
        : sample_rate(44100.0),
          explicit_tempo(false),
          min_tempo(40),
          max_tempo(208),
          ffmpeg_exe("ffmpeg") {}
};

struct BeatResult {
    bool ok;                        // 是否成功
    std::string error;              // ok=false 时的人类可读原因
    std::vector<double> ticks;      // 拍点时间戳（秒），升序
    double bpm;                     // Essentia 给出的全局 tempo 估计
    double confidence;              // ticks 置信度
    size_t sample_count;            // 参与分析的采样数（= 音频秒数 × 44100）

    BeatResult() : ok(false), bpm(0.0), confidence(0.0), sample_count(0) {}
};

// ============================================================================
//  2. 生命周期
// ============================================================================

namespace detail {

struct EssentiaGuard {
    EssentiaGuard() { essentia::init(); }
    // 故意不做 shutdown：静态析构顺序不可控，而且 App 通常一直要用，留着更安全
};

}  // namespace detail

// 保证 Essentia 已初始化（幂等、线程安全）。detect* 内部会自动调用，一般不用手动调。
inline void ensure_initialized() {
    static detail::EssentiaGuard guard;
    (void)guard;
}

// 需要显式释放时调用（一般不需要）
inline void shutdown() { essentia::shutdown(); }

// ============================================================================
//  3. 文件工具（内部）
// ============================================================================

namespace detail {

#if ESSENTIA_PLATFORM_WINDOWS

inline std::wstring utf8_to_wide(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int wlen = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, NULL, 0);
    if (wlen <= 0) return std::wstring();
    std::wstring w(static_cast<size_t>(wlen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], wlen);
    w.resize(static_cast<size_t>(wlen - 1));
    return w;
}

#endif

// 以 UTF-8 字节原样写文件（二进制模式，行尾由调用方给）
inline bool write_file_utf8(const std::string& path, const std::string& content) {
#if ESSENTIA_PLATFORM_WINDOWS
    const std::wstring w = utf8_to_wide(path);
    std::FILE* fp = _wfopen(w.c_str(), L"wb");
#else
    std::FILE* fp = std::fopen(path.c_str(), "wb");
#endif
    if (fp == NULL) return false;
    const size_t written = std::fwrite(content.data(), 1, content.size(), fp);
    std::fclose(fp);
    return written == content.size();
}

// 等价于 os.path.basename / splitext(path)[0]
inline std::string base_name(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

inline std::string strip_extension(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    const size_t start = (slash == std::string::npos) ? 0 : slash + 1;
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || dot <= start) return path;
    return path.substr(0, dot);
}

inline bool file_exists(const std::string& path) {
#if ESSENTIA_PLATFORM_WINDOWS
    const std::wstring w = utf8_to_wide(path);
    const DWORD attrs = GetFileAttributesW(w.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
#else
    std::FILE* fp = std::fopen(path.c_str(), "rb");
    if (fp == NULL) return false;
    std::fclose(fp);
    return true;
#endif
}

}  // namespace detail

// ============================================================================
//  4. 核心：分析内存中的音频信号（最通用，App 里推荐用这个）
// ============================================================================
//  signal 必须是 **44100Hz 单声道** 的 float 采样，取值范围 [-1, 1]。
//  返回 ticks（拍点时间戳，秒）。
inline BeatResult detect(const std::vector<essentia::Real>& signal,
                         const Options& opt = Options()) {
    using essentia::Real;
    using essentia::standard::Algorithm;
    using essentia::standard::AlgorithmFactory;

    BeatResult r;
    if (signal.empty()) {
        r.error = "输入信号为空";
        return r;
    }
    r.sample_count = signal.size();

    try {
        ensure_initialized();
        AlgorithmFactory& factory = AlgorithmFactory::instance();

        Algorithm* rhythm = NULL;
        if (opt.explicit_tempo) {
            rhythm = factory.create("RhythmExtractor2013",
                                    "method", std::string("multifeature"),
                                    "minTempo", opt.min_tempo,
                                    "maxTempo", opt.max_tempo);
        } else {
            rhythm = factory.create("RhythmExtractor2013", "method", std::string("multifeature"));
        }

        std::vector<Real> ticks, estimates, bpmIntervals;
        Real bpm = 0.0f, confidence = 0.0f;

        // 标准模式用 set() 绑端口（不是流式的 Source >> Sink）
        rhythm->input("signal").set(signal);
        rhythm->output("bpm").set(bpm);
        rhythm->output("ticks").set(ticks);
        rhythm->output("confidence").set(confidence);
        rhythm->output("estimates").set(estimates);
        rhythm->output("bpmIntervals").set(bpmIntervals);

        rhythm->compute();
        delete rhythm;

        r.ticks.reserve(ticks.size());
        for (size_t i = 0; i < ticks.size(); ++i)
            r.ticks.push_back(static_cast<double>(ticks[i]));
        r.bpm = static_cast<double>(bpm);
        r.confidence = static_cast<double>(confidence);
        r.ok = true;
    } catch (const std::exception& e) {
        r.ok = false;
        r.error = std::string("节拍检测失败: ") + e.what();
    }
    return r;
}

// ============================================================================
//  5. 从文件分析
// ============================================================================

#if !ESSENTIA_USE_MONOLOADER
// ---------- 桌面路径：调用 ffmpeg 命令行解码成 f32le / 单声道 / 44100Hz ----------
namespace detail {

// 把字节流按 float 追加到 samples（处理读取边界上的半个 float）
inline void append_floats(std::vector<essentia::Real>& samples, std::vector<char>& carry,
                          const char* data, size_t bytes) {
    size_t start = 0;
    if (!carry.empty()) {
        while (carry.size() < 4 && start < bytes) carry.push_back(data[start++]);
        if (carry.size() < 4) return;
        float v;
        std::memcpy(&v, &carry[0], 4);
        samples.push_back(static_cast<essentia::Real>(v));
        carry.clear();
    }
    const size_t whole = ((bytes - start) / 4) * 4;
    for (size_t i = 0; i < whole; i += 4) {
        float v;
        std::memcpy(&v, data + start + i, 4);
        samples.push_back(static_cast<essentia::Real>(v));
    }
    for (size_t i = start + whole; i < bytes; ++i) carry.push_back(data[i]);
}

inline std::string build_ffmpeg_command(const std::string& ffmpegExe,
                                        const std::string& audioPath,
                                        int sampleRate) {
    std::ostringstream cmd;
    cmd << '"' << ffmpegExe << '"'
        << " -hide_banner -loglevel error -nostdin -i " << '"' << audioPath << '"'
        << " -vn -f f32le -acodec pcm_f32le -ac 1 -ar " << sampleRate
        << " -";
    return cmd.str();
}

#if ESSENTIA_PLATFORM_WINDOWS

inline bool load_audio_via_ffmpeg(const std::string& ffmpegExe, const std::string& audioPath,
                                  int sampleRate, std::vector<essentia::Real>& samples,
                                  std::string* error) {
    const std::wstring wcmd = utf8_to_wide(build_ffmpeg_command(ffmpegExe, audioPath, sampleRate));

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    HANDLE rd = NULL, wr = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) {
        if (error) *error = "无法创建管道";
        return false;
    }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    std::memset(&si, 0, sizeof(si));
    std::memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = wr;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

    std::vector<wchar_t> cmdline(wcmd.begin(), wcmd.end());
    cmdline.push_back(L'\0');

    const BOOL ok = CreateProcessW(NULL, &cmdline[0], NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    CloseHandle(wr);
    if (!ok) {
        CloseHandle(rd);
        if (error) *error = "无法启动 ffmpeg（" + ffmpegExe + "），请检查路径";
        return false;
    }

    samples.clear();
    std::vector<char> buffer(65536);
    std::vector<char> carry;
    DWORD n = 0;
    while (ReadFile(rd, &buffer[0], static_cast<DWORD>(buffer.size()), &n, NULL) && n > 0) {
        append_floats(samples, carry, &buffer[0], static_cast<size_t>(n));
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(rd);

    if (exitCode != 0) {
        if (error) *error = "ffmpeg 解码失败（退出码 " + std::to_string(exitCode) + "）";
        return false;
    }
    if (samples.empty()) {
        if (error) *error = "ffmpeg 没有输出任何采样";
        return false;
    }
    return true;
}

#else  // POSIX：popen

inline bool load_audio_via_ffmpeg(const std::string& ffmpegExe, const std::string& audioPath,
                                  int sampleRate, std::vector<essentia::Real>& samples,
                                  std::string* error) {
    std::FILE* p = popen(build_ffmpeg_command(ffmpegExe, audioPath, sampleRate).c_str(), "r");
    if (p == NULL) {
        if (error) *error = "无法启动 ffmpeg";
        return false;
    }
    samples.clear();
    std::vector<char> buffer(65536);
    std::vector<char> carry;
    size_t n = 0;
    while ((n = std::fread(&buffer[0], 1, buffer.size(), p)) > 0) {
        append_floats(samples, carry, &buffer[0], n);
    }
    const int rc = pclose(p);
    if (rc != 0 || samples.empty()) {
        if (error) *error = "ffmpeg 解码失败（退出码 " + std::to_string(rc) + "）";
        return false;
    }
    return true;
}

#endif

}  // namespace detail
#endif  // !ESSENTIA_USE_MONOLOADER

// ---------- 从音频文件检测节拍 ----------
inline BeatResult detect_file(const std::string& audio_path,
                              const Options& opt = Options()) {
    using essentia::Real;
    using essentia::standard::Algorithm;
    using essentia::standard::AlgorithmFactory;

    BeatResult r;
    if (audio_path.empty()) {
        r.error = "音频路径为空";
        return r;
    }
    if (!detail::file_exists(audio_path)) {
        r.error = "文件不存在: " + audio_path;
        return r;
    }

#if ESSENTIA_USE_MONOLOADER
    // ---- 鸿蒙 / 安卓 / iOS：Essentia 自带 FFmpeg，直接走 MonoLoader（纯 C++，无外部进程）----
    try {
        ensure_initialized();
        AlgorithmFactory& factory = AlgorithmFactory::instance();
        Algorithm* loader = factory.create("MonoLoader",
                                           "filename", std::string(audio_path),
                                           "sampleRate", opt.sample_rate);

        Algorithm* rhythm = NULL;
        if (opt.explicit_tempo) {
            rhythm = factory.create("RhythmExtractor2013",
                                    "method", std::string("multifeature"),
                                    "minTempo", opt.min_tempo,
                                    "maxTempo", opt.max_tempo);
        } else {
            rhythm = factory.create("RhythmExtractor2013", "method", std::string("multifeature"));
        }

        std::vector<Real> audio, ticks, estimates, bpmIntervals;
        Real bpm = 0.0f, confidence = 0.0f;

        loader->output("audio").set(audio);
        rhythm->input("signal").set(audio);
        rhythm->output("bpm").set(bpm);
        rhythm->output("ticks").set(ticks);
        rhythm->output("confidence").set(confidence);
        rhythm->output("estimates").set(estimates);
        rhythm->output("bpmIntervals").set(bpmIntervals);

        loader->compute();
        rhythm->compute();
        delete loader;
        delete rhythm;

        r.sample_count = audio.size();
        r.ticks.reserve(ticks.size());
        for (size_t i = 0; i < ticks.size(); ++i)
            r.ticks.push_back(static_cast<double>(ticks[i]));
        r.bpm = static_cast<double>(bpm);
        r.confidence = static_cast<double>(confidence);
        r.ok = true;
    } catch (const std::exception& e) {
        r.ok = false;
        r.error = std::string("节拍检测失败: ") + e.what();
    }
    return r;

#else
    // ---- 桌面：Essentia 不带 FFmpeg，用 ffmpeg 命令行解码后再喂给 detect() ----
    std::vector<Real> signal;
    std::string err;
    if (!detail::load_audio_via_ffmpeg(opt.ffmpeg_exe, audio_path,
                                       static_cast<int>(opt.sample_rate), signal, &err)) {
        r.error = err;
        return r;
    }
    return detect(signal, opt);
#endif
}

// ============================================================================
//  6. 节拍表 CSV（格式与 madmom_to_CSV.py / essentia_to_CSV.py 完全一致）
// ============================================================================
//    # song=<歌曲名>
//    # model=<模型名>
//    <时间戳，每行一个，全精度>
//  编码 UTF-8（无 BOM），行尾 CRLF。
inline std::string beats_to_csv(const std::vector<double>& beats,
                                const std::string& song,
                                const std::string& model) {
    std::ostringstream text;
    text << "# song=" << song << "\r\n";
    text << "# model=" << model << "\r\n";
    text << std::setprecision(9);   // float32 的 round-trip 精度
    for (size_t i = 0; i < beats.size(); ++i) text << beats[i] << "\r\n";
    return text.str();
}

inline bool save_beats_csv(const std::string& csv_path,
                           const std::vector<double>& beats,
                           const std::string& song,
                           const std::string& model,
                           std::string* error = 0) {
    if (!detail::write_file_utf8(csv_path, beats_to_csv(beats, song, model))) {
        if (error) *error = "无法写入文件: " + csv_path;
        return false;
    }
    return true;
}

// ============================================================================
//  7. 一站式：文件 → CSV（等价于旧版命令行程序的行为）
// ============================================================================
//  csv_path 为空时，自动推导成 <音频路径去扩展名>_beats.csv
inline BeatResult detect_file_to_csv(const std::string& audio_path,
                                     const std::string& csv_path = std::string(),
                                     const Options& opt = Options()) {
    BeatResult r = detect_file(audio_path, opt);
    if (!r.ok) return r;

    const std::string out = csv_path.empty()
                                ? (detail::strip_extension(audio_path) + "_beats.csv")
                                : csv_path;
    const std::string song = detail::base_name(detail::strip_extension(audio_path));

    std::string err;
    if (!save_beats_csv(out, r.ticks, song, "essentia", &err)) {
        r.ok = false;
        r.error = err;
        return r;
    }
    return r;
}

}  // namespace eb

#endif  // ESSENTIA_BEATS_HPP
