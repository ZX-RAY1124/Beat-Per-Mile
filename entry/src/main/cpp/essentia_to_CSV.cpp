// ============================================================================
//  essentia_to_CSV.cpp
//  用 Essentia 检测节拍并导出节拍表 CSV —— essentia_to_CSV.py 的 C++ 等价实现
//
//  ── 音频从哪来（两种模式，按平台自动选择）──────────────────────────────────
//  Python 版用 es.MonoLoader 读音频，MonoLoader 依赖 Essentia 的 AudioLoader，
//  后者是用 FFmpeg(libav) 实现的。所以能不能用 MonoLoader，取决于链的那份 Essentia
//  有没有带 FFmpeg 支持：
//
//   * ESSENTIA_USE_MONOLOADER = 1  —— Essentia 自带 FFmpeg 时用（**鸿蒙工程用这个**，
//       工程里那份 libessentia.so 是带 FFmpeg 4.4.4 编的）。与 Python 版行为完全一致。
//
//   * ESSENTIA_USE_MONOLOADER = 0  —— Essentia 不带 FFmpeg 时用（桌面这份就是：
//       Essentia 2.1_beta5 用的是 FFmpeg 4 时代的 API —— av_register_all /
//       avcodec_decode_audio4 / avresample_* / AVCodecContext->channels，这些在
//       FFmpeg 5.0、7.0 已被删除，而本机只有 FFmpeg 9，链不上）。
//       此时改成调用 **ffmpeg 命令行**解码成 44100Hz 单声道 f32le 裸流，
//       再直接喂给 RhythmExtractor2013。解码/降混/重采样仍然全由 FFmpeg 完成。
//
//  默认：OHOS / Android 用 1，其它平台用 0；也可用 -DESSENTIA_USE_MONOLOADER=x 覆盖。
//
//  ── CSV 格式（与 madmom_to_CSV.py / essentia_to_CSV.py 一致）──────────────
//    # song=<不含扩展名的音频文件名>
//    # model=essentia
//    <时间戳，全精度，每行一个>
//  编码 UTF-8（无 BOM），行尾 CRLF。
//
//  编译（Windows / MSYS2 ucrt64，链接本地编译的 Essentia 静态库）：
//    g++ -std=gnu++11 -O2 essentia_to_CSV.cpp -o essentia_to_CSV.exe -I$ESS/include
//        $ESS/lib/libessentia.a -lfftw3f -lsamplerate -ltag -lyaml -lchromaprint -lz
//  编译（Linux / macOS，已装 Essentia）：
//    g++ -std=gnu++11 -O2 essentia_to_CSV.cpp -o essentia_to_CSV $(pkg-config --cflags --libs essentia)
//
//  用法：
//    essentia_to_CSV <音频文件路径> [-o 输出CSV] [--ffmpeg 路径] [--min-tempo N] [--max-tempo N] [--verbose]
// ============================================================================

#include <essentia/algorithmfactory.h>
#include <essentia/essentia.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

// 平台判定集中在这里。这样做既清晰，也允许用 -DESSENTIA_PLATFORM_WINDOWS=0
// 在 Windows 上编译验证 POSIX 分支（否则那条分支在本地永远测不到）。
#ifndef ESSENTIA_PLATFORM_WINDOWS
#  ifdef _WIN32
#    define ESSENTIA_PLATFORM_WINDOWS 1
#  else
#    define ESSENTIA_PLATFORM_WINDOWS 0
#  endif
#endif

#if ESSENTIA_PLATFORM_WINDOWS
#  include <windows.h>
#endif

using essentia::Real;
using essentia::standard::Algorithm;
using essentia::standard::AlgorithmFactory;

// 见文件顶部说明：1 = 用 Essentia 自己的 MonoLoader；0 = 用 ffmpeg 命令行解码
#ifndef ESSENTIA_USE_MONOLOADER
#  if defined(__OHOS__) || defined(__ANDROID__) || defined(__APPLE__)
#    define ESSENTIA_USE_MONOLOADER 1
#  else
#    define ESSENTIA_USE_MONOLOADER 0
#  endif
#endif

namespace {

// ---- 与 Python 版一致的常量 ------------------------------------------------
const double kSampleRate = 44100.0;     // es.MonoLoader(..., sampleRate=44100)
const char* const kModelName = "essentia";
const double kDefaultMinTempo = 40.0;   // RhythmExtractor2013 默认值
const double kDefaultMaxTempo = 208.0;  // RhythmExtractor2013 默认值
const char* const kDefaultFfmpeg = "ffmpeg";

struct Options {
  std::string audioFile;
  std::string outputCsv;      // 空 = 自动推导为 <音频路径去扩展名>_beats.csv
  std::string ffmpegExe;      // ffmpeg 可执行文件（默认走 PATH）
  bool verbose;
  bool explicitTempo;         // 是否显式指定了 min/max tempo
  double minTempo;
  double maxTempo;

  Options()
      : ffmpegExe(kDefaultFfmpeg),
        verbose(false),
        explicitTempo(false),
        minTempo(kDefaultMinTempo),
        maxTempo(kDefaultMaxTempo) {}
};

// ---- Windows 上的编码处理 ---------------------------------------------------
// Python 3 的 argv 是 Unicode；C 的 main() 拿到的是当前代码页(中文系统为 GBK)。
// 这里统一转成 UTF-8，保证含中文的路径/文件名不出乱码。
#if ESSENTIA_PLATFORM_WINDOWS

std::string acpToUtf8(const char* s) {
  if (s == NULL) return std::string();
  const int wlen = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
  if (wlen <= 0) return std::string(s);
  std::vector<wchar_t> w(static_cast<size_t>(wlen));
  MultiByteToWideChar(CP_ACP, 0, s, -1, &w[0], wlen);
  const int u8len = WideCharToMultiByte(CP_UTF8, 0, &w[0], -1, NULL, 0, NULL, NULL);
  if (u8len <= 0) return std::string(s);
  std::string out(static_cast<size_t>(u8len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, &w[0], -1, &out[0], u8len, NULL, NULL);
  out.resize(static_cast<size_t>(u8len - 1));
  return out;
}

std::wstring utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int wlen = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, NULL, 0);
  if (wlen <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(wlen), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], wlen);
  w.resize(static_cast<size_t>(wlen - 1));
  return w;
}

void enableUtf8Console() {
  if (GetConsoleOutputCP() != 0) SetConsoleOutputCP(CP_UTF8);
}

#else

std::string acpToUtf8(const char* s) { return std::string(s == NULL ? "" : s); }

#endif

// ---- 路径处理（对齐 os.path） ----------------------------------------------
std::string baseName(const std::string& path) {
  const size_t slash = path.find_last_of("/\\");
  return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

// 等价于 os.path.splitext(path)[0]
std::string stripExtension(const std::string& path) {
  const size_t slash = path.find_last_of("/\\");
  const size_t start = (slash == std::string::npos) ? 0 : slash + 1;
  const size_t dot = path.find_last_of('.');
  if (dot == std::string::npos || dot <= start) return path;
  return path.substr(0, dot);
}

// 等价于 os.path.isfile：存在且不是目录
bool fileExists(const std::string& path) {
#if ESSENTIA_PLATFORM_WINDOWS
  const std::wstring w = utf8ToWide(path);
  const DWORD attrs = GetFileAttributesW(w.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
#else
  std::ifstream f(path.c_str(), std::ios::binary);
  return f.good();
#endif
}

bool writeFileUtf8(const std::string& path, const std::string& content) {
#if ESSENTIA_PLATFORM_WINDOWS
  const std::wstring w = utf8ToWide(path);
  std::FILE* fp = _wfopen(w.c_str(), L"wb");
#else
  std::FILE* fp = std::fopen(path.c_str(), "wb");
#endif
  if (fp == NULL) return false;
  const size_t written = std::fwrite(content.data(), 1, content.size(), fp);
  std::fclose(fp);
  return written == content.size();
}

// ============================================================================
//  只有在"不用 MonoLoader"时才需要下面这段：用 ffmpeg 命令行解码音频
//  （鸿蒙/安卓/iOS 上走 MonoLoader，整段都不参与编译）
// ============================================================================
#if !ESSENTIA_USE_MONOLOADER


// 把字节流按 float 追加到 samples（处理读取边界上的半个 float）
// 注意：这个函数两个平台共用，必须放在平台分支**外面**。
void appendFloats(std::vector<Real>& samples, std::vector<char>& carry,
                  const char* data, size_t bytes) {
  size_t start = 0;
  if (!carry.empty()) {
    while (carry.size() < 4 && start < bytes) carry.push_back(data[start++]);
    if (carry.size() < 4) return;
    float v;
    std::memcpy(&v, &carry[0], 4);
    samples.push_back(static_cast<Real>(v));
    carry.clear();
  }
  const size_t whole = ((bytes - start) / 4) * 4;
  for (size_t i = 0; i < whole; i += 4) {
    float v;
    std::memcpy(&v, data + start + i, 4);
    samples.push_back(static_cast<Real>(v));
  }
  for (size_t i = start + whole; i < bytes; ++i) carry.push_back(data[i]);
}

// 拼出 ffmpeg 解码命令：解码 -> f32le / 单声道 / 44100Hz -> stdout("-")
std::string buildFfmpegCommand(const std::string& ffmpegExe, const std::string& audioPath) {
  std::ostringstream cmd;
  cmd << '"' << ffmpegExe << '"'
      << " -hide_banner -loglevel error -nostdin -i " << '"' << audioPath << '"'
      << " -vn -f f32le -acodec pcm_f32le -ac 1 -ar " << static_cast<int>(kSampleRate)
      << " -";
  return cmd.str();
}

#  if ESSENTIA_PLATFORM_WINDOWS

bool loadAudioViaFfmpeg(const std::string& ffmpegExe, const std::string& audioPath,
                        std::vector<Real>& samples) {
  const std::wstring wcmd = utf8ToWide(buildFfmpegCommand(ffmpegExe, audioPath));

  SECURITY_ATTRIBUTES sa;
  sa.nLength = sizeof(sa);
  sa.lpSecurityDescriptor = NULL;
  sa.bInheritHandle = TRUE;

  HANDLE rd = NULL, wr = NULL;
  if (!CreatePipe(&rd, &wr, &sa, 0)) {
    std::cerr << "错误：无法创建管道" << std::endl;
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
    std::cerr << "错误：无法启动 ffmpeg（" << ffmpegExe << "）。"
              << "请确认它在 PATH 里，或用 --ffmpeg 指定完整路径。" << std::endl;
    return false;
  }

  samples.clear();
  std::vector<char> buffer(65536);
  std::vector<char> carry;
  DWORD n = 0;
  while (ReadFile(rd, &buffer[0], static_cast<DWORD>(buffer.size()), &n, NULL) && n > 0) {
    appendFloats(samples, carry, &buffer[0], static_cast<size_t>(n));
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD exitCode = 1;
  GetExitCodeProcess(pi.hProcess, &exitCode);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  CloseHandle(rd);

  if (exitCode != 0) {
    std::cerr << "错误：ffmpeg 解码失败（退出码 " << exitCode
              << "）。请先单独运行 ffmpeg 看具体报错。" << std::endl;
    return false;
  }
  if (samples.empty()) {
    std::cerr << "错误：ffmpeg 没有输出任何采样" << std::endl;
    return false;
  }
  return true;
}

#  else  // ---------- POSIX（Linux / macOS）：用 popen ----------

bool loadAudioViaFfmpeg(const std::string& ffmpegExe, const std::string& audioPath,
                        std::vector<Real>& samples) {
  std::FILE* p = popen(buildFfmpegCommand(ffmpegExe, audioPath).c_str(), "r");
  if (p == NULL) {
    std::cerr << "错误：无法启动 ffmpeg" << std::endl;
    return false;
  }
  samples.clear();
  std::vector<char> buffer(65536);
  std::vector<char> carry;
  size_t n = 0;
  while ((n = std::fread(&buffer[0], 1, buffer.size(), p)) > 0) {
    appendFloats(samples, carry, &buffer[0], n);
  }
  const int rc = pclose(p);
  if (rc != 0 || samples.empty()) {
    std::cerr << "错误：ffmpeg 解码失败（退出码 " << rc << "）" << std::endl;
    return false;
  }
  return true;
}

#  endif

#endif  // !ESSENTIA_USE_MONOLOADER

// ---- 参数解析 --------------------------------------------------------------
void printUsage(const char* prog) {
  std::cout << "用法: " << prog
            << " <音频文件路径> [-o 输出CSV] [--ffmpeg 路径] [--min-tempo N] [--max-tempo N] [--verbose]\n"
            << "示例: " << prog << " \"song.flac\"\n"
            << "输出: 同目录下生成 <音频文件名>_beats.csv" << std::endl;
}

bool parseArgs(const std::vector<std::string>& args, Options& opt) {
  for (size_t i = 1; i < args.size(); ++i) {
    const std::string& a = args[i];
    if (a == "-o" || a == "--output") {
      if (i + 1 >= args.size()) return false;
      opt.outputCsv = args[++i];
    } else if (a == "--ffmpeg") {
      if (i + 1 >= args.size()) return false;
      opt.ffmpegExe = args[++i];
    } else if (a == "--min-tempo") {
      if (i + 1 >= args.size()) return false;
      opt.minTempo = std::atof(args[++i].c_str());
      opt.explicitTempo = true;
    } else if (a == "--max-tempo") {
      if (i + 1 >= args.size()) return false;
      opt.maxTempo = std::atof(args[++i].c_str());
      opt.explicitTempo = true;
    } else if (a == "--verbose" || a == "-v") {
      opt.verbose = true;
    } else if (a == "-h" || a == "--help") {
      return false;
    } else if (!a.empty() && a[0] == '-') {
      std::cerr << "未知参数: " << a << std::endl;
      return false;
    } else if (opt.audioFile.empty()) {
      opt.audioFile = a;
    } else {
      std::cerr << "参数过多: " << a << std::endl;
      return false;
    }
  }
  return !opt.audioFile.empty();
}

// ---- 节拍检测（对应 Python 的 detect_beats） --------------------------------
// 返回 ticks：节拍时间戳（秒）。bpm / confidence 通过出参带回，仅用于 --verbose。
std::vector<Real> detectBeats(const Options& opt, std::vector<Real>& signal,
                              Real& bpm, Real& confidence) {
  AlgorithmFactory& factory = AlgorithmFactory::instance();
  const std::string method("multifeature");  // Python: RhythmExtractor2013(method="multifeature")

#if ESSENTIA_USE_MONOLOADER
  Algorithm* loader = factory.create("MonoLoader",
                                     "filename", std::string(opt.audioFile),
                                     "sampleRate", kSampleRate);
#else
  (void)opt;
#endif

  // Python 版没有传 minTempo/maxTempo，走 Essentia 默认值；
  // 只有命令行显式给出时才覆盖，保持与 Python 版默认行为一致。
  Algorithm* rhythm = NULL;
  if (opt.explicitTempo) {
    rhythm = factory.create("RhythmExtractor2013",
                            "method", method,
                            "minTempo", opt.minTempo,
                            "maxTempo", opt.maxTempo);
  } else {
    rhythm = factory.create("RhythmExtractor2013", "method", method);
  }

  std::vector<Real> ticks;
  std::vector<Real> estimates;
  std::vector<Real> bpmIntervals;

  // 标准模式(standard)用 set() 把端口绑到变量上（流式模式的 Source >> Sink 在这里不适用）
#if ESSENTIA_USE_MONOLOADER
  loader->output("audio").set(signal);
#endif
  rhythm->input("signal").set(signal);

  // 端口名对应 Python 的 5 个返回值：(bpm, beats, confidence, estimates, bpm_intervals)
  rhythm->output("bpm").set(bpm);
  rhythm->output("ticks").set(ticks);
  rhythm->output("confidence").set(confidence);
  rhythm->output("estimates").set(estimates);
  rhythm->output("bpmIntervals").set(bpmIntervals);

#if ESSENTIA_USE_MONOLOADER
  loader->compute();
#endif
  rhythm->compute();

#if ESSENTIA_USE_MONOLOADER
  delete loader;
#endif
  delete rhythm;

  return ticks;
}

// ---- CSV 写出（对应 Python 的 save_beats_to_csv） ----------------------------
bool saveBeatsToCsv(const std::vector<Real>& beats, const std::string& csvPath,
                    const std::string& songName) {
  std::ostringstream text;
  text << "# song=" << songName << "\r\n";
  text << "# model=" << kModelName << "\r\n";

  // 用 Real 的 round-trip 精度写出，等价于 Python 直接 str(float) 不丢精度
  text << std::setprecision(std::numeric_limits<Real>::max_digits10);
  for (size_t i = 0; i < beats.size(); ++i) {
    text << beats[i] << "\r\n";
  }

  return writeFileUtf8(csvPath, text.str());
}

int run(const std::vector<std::string>& args) {
  Options opt;
  if (!parseArgs(args, opt)) {
    printUsage(args.empty() ? "essentia_to_CSV" : args[0].c_str());
    return 1;
  }

  if (!fileExists(opt.audioFile)) {
    std::cerr << "错误：文件不存在 - " << opt.audioFile << std::endl;
    return 1;
  }

  std::string csvPath = opt.outputCsv;
  if (csvPath.empty()) csvPath = stripExtension(opt.audioFile) + "_beats.csv";
  const std::string songName = baseName(stripExtension(opt.audioFile));

  std::cout << "正在分析音频: " << opt.audioFile << std::endl;

  std::vector<Real> beats;
  Real bpm = 0.0f;
  Real confidence = 0.0f;
  try {
    std::vector<Real> signal;
#if !ESSENTIA_USE_MONOLOADER
    if (!loadAudioViaFfmpeg(opt.ffmpegExe, opt.audioFile, signal)) return 1;
    if (opt.verbose) {
      std::cout << "[verbose] 已解码 " << signal.size() << " 个采样 ("
                << static_cast<double>(signal.size()) / kSampleRate << " 秒)" << std::endl;
    }
#endif
    essentia::init();
    beats = detectBeats(opt, signal, bpm, confidence);
    essentia::shutdown();
  } catch (const std::exception& e) {
    essentia::shutdown();
    std::cerr << "节拍检测失败: " << e.what() << std::endl;
    return 1;
  }

  if (beats.empty()) {
    std::cerr << "警告：未检测到任何节拍，将生成空文件" << std::endl;
  }

  if (!saveBeatsToCsv(beats, csvPath, songName)) {
    std::cerr << "错误：无法写入文件 - " << csvPath << std::endl;
    return 1;
  }

  std::cout << "节拍表已保存至: " << csvPath << std::endl;
  std::cout << "共 " << beats.size() << " 个节拍" << std::endl;

  if (opt.verbose) {
    std::cout << "[verbose] Essentia BPM: " << bpm
              << "  ticks confidence: " << confidence << std::endl;
  }

  return 0;
}

}  // namespace

int main(int argc, char* argv[]) {
#if ESSENTIA_PLATFORM_WINDOWS
  enableUtf8Console();
#endif
  std::vector<std::string> args;
  args.reserve(static_cast<size_t>(argc));
  for (int i = 0; i < argc; ++i) args.push_back(acpToUtf8(argv[i]));
  return run(args);
}
