/*
 * stretchbridge.cpp
 * LiveStretchPlayer 实时测试桥接程序。
 *
 * 协议（stdin，UTF-8 行协议）:
 *   LOAD <path>            - 指定输入 WAV 路径（UTF-8，可含空格）
 *   PLAY <blockSize> <speed> - 加载并开始实时播放（流式输出 PCM）
 *   SPEED <x>              - 实时变速（0.01 ~ 5.0）
 *   PAUSE / RESUME         - 暂停 / 恢复
 *   RECSTART <path>        - 开始服务端录音（WAV 16bit）
 *   RECSTOP                - 结束录音并写盘
 *   STOP                   - 停止播放（保留进程，可再次 PLAY）
 *   QUIT                   - 退出
 *
 * 输出:
 *   stdout - 播放期间输出 float32 交错 PCM（二进制，帧率恒定 = 采样率）
 *   stderr - 状态行: INFO ... / READY ... / DONE / ERR ... / LOG ...
 *
 * 命令行模式（离线渲染）:
 *   stretchbridge.exe dump <in.wav> <out.wav> <blockSize> <speed>
 */

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "LiveStretchPlayer.h"   // 包含 TimeStretchEngine.hpp 与 signalsmith_stretch.h

#ifdef _WIN32
#include <windows.h>
// UTF-8 -> UTF-16，用于以宽字符路径打开文件（支持中文文件名）
static std::wstring utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], len);
    return w;
}
// UTF-16 -> UTF-8（用于 wmain 宽字符 argv -> 统一 UTF-8 内部表示）
static std::string wideToUtf8(const std::wstring& w) {
    if (w.empty()) return "";
    int len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], len, nullptr, nullptr);
    return s;
}
#endif

// 兼容窄字符串路径：Windows 下按 UTF-8 解释（协议路径均为 UTF-8）
static std::ifstream openInput(const std::string& filename) {
#ifdef _WIN32
    return std::ifstream(utf8ToWide(filename).c_str(), std::ios::binary);
#else
    return std::ifstream(filename, std::ios::binary);
#endif
}
static std::ofstream openOutput(const std::string& filename) {
#ifdef _WIN32
    return std::ofstream(utf8ToWide(filename).c_str(), std::ios::binary);
#else
    return std::ofstream(filename, std::ios::binary);
#endif
}

// ==================== 全局状态 ====================
static std::atomic<bool>  g_pausedMirror{false};
static std::atomic<long long> g_lastCallbackMs{0};
static std::atomic<bool>  g_recording{false};
static std::vector<float> g_recordBuf;           // 仅在回调线程写, 主线程在结束时读
static std::string        g_recordPath;
static int g_recordChannels = 2;
static int g_recordSampleRate = 44100;

// 平面 -> 交错 转换缓冲区（音频线程复用，仅在首次分配）
static std::vector<float> g_interBuf;

// 进度 / 跳转相关
static std::atomic<long long> g_totalOutFrames{0};  // 本次播放累计输出帧（含暂停静音）
static std::atomic<long long> g_lastPosTime{0};     // 上次 POS 上报时间（ms）
static long long g_nextSeek = 0;                    // 空闲态 SEEK 记录，供下次 PLAY 使用

// 平面格式音频数据（一个 float* 数组）
struct AudioData {
    int channels = 0;
    int sampleRate = 0;
    std::vector<float> planar;   // ch0 全部样本, ch1 全部样本, ...
    int totalFrames = 0;

    const float* channel(int ch) const {
        return planar.data() + static_cast<size_t>(ch) * totalFrames;
    }
};

// ==================== 工具 ====================
static void logLine(const std::string& s) {
    std::fprintf(stderr, "%s\n", s.c_str());
    std::fflush(stderr);
}

static long long nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// 读取一行 stdin（UTF-8），返回 false 表示 EOF
static bool readLine(std::string& line) {
    line.clear();
    int c;
    while ((c = std::fgetc(stdin)) != EOF) {
        if (c == '\n') return true;
        if (c != '\r') line.push_back(static_cast<char>(c));
    }
    return !line.empty();
}

// ==================== WAV 读取（支持 PCM16 / IEEE float, 1/2 声道） ====================
static bool readWav(const std::string& filename, AudioData& out) {
    std::ifstream f = openInput(filename);
    if (!f) { logLine("ERR 无法打开文件: " + filename); return false; }

    char riff[4] = {0};
    f.read(riff, 4);
    if (std::memcmp(riff, "RIFF", 4) != 0) { logLine("ERR 不是 RIFF/WAV 文件"); return false; }
    uint32_t dummy = 0;
    f.read(reinterpret_cast<char*>(&dummy), 4);
    char wave[4] = {0};
    f.read(wave, 4);
    if (std::memcmp(wave, "WAVE", 4) != 0) { logLine("ERR 不是 WAVE 格式"); return false; }

    int channels = 0, sampleRate = 0, bits = 0, audioFormat = 0;
    std::vector<int16_t> pcmData;     // 16bit 交错
    std::vector<float>   fltData;     // float 交错
    bool haveFmt = false, haveData = false;

    while (f.good() && !f.eof()) {
        char ck[4] = {0};
        f.read(ck, 4);
        uint32_t sz = 0;
        f.read(reinterpret_cast<char*>(&sz), 4);
        if (!f) break;

        if (std::memcmp(ck, "fmt ", 4) == 0) {
            uint16_t fmt = 0, ch = 0;
            uint32_t sr = 0, br = 0;
            uint16_t ba = 0, bps = 0;
            f.read(reinterpret_cast<char*>(&fmt), 2);
            f.read(reinterpret_cast<char*>(&ch), 2);
            f.read(reinterpret_cast<char*>(&sr), 4);
            f.read(reinterpret_cast<char*>(&br), 4);
            f.read(reinterpret_cast<char*>(&ba), 2);
            f.read(reinterpret_cast<char*>(&bps), 2);
            audioFormat = fmt; channels = ch; sampleRate = static_cast<int>(sr); bits = bps;
            haveFmt = true;
            long remaining = static_cast<long>(sz) - 16;
            if (remaining > 0) f.seekg(remaining, std::ios::cur);
        } else if (std::memcmp(ck, "data", 4) == 0) {
            if (!haveFmt) { f.seekg(sz, std::ios::cur); continue; }
            size_t bytesPerSample = static_cast<size_t>(bits) / 8;
            size_t totalSamples = sz / bytesPerSample;
            if (audioFormat == 1 && bits == 16) {
                pcmData.resize(totalSamples);
                f.read(reinterpret_cast<char*>(pcmData.data()), static_cast<std::streamsize>(totalSamples * 2));
            } else if (audioFormat == 3 && bits == 32) {
                fltData.resize(totalSamples);
                f.read(reinterpret_cast<char*>(fltData.data()), static_cast<std::streamsize>(totalSamples * 4));
            } else {
                logLine("ERR 仅支持 PCM16bit 或 IEEE float32 WAV");
                return false;
            }
            haveData = true;
            break;  // data 之后不再需要
        } else {
            f.seekg(sz + (sz & 1), std::ios::cur);  // 跳过 padding
        }
    }

    if (!haveFmt || !haveData || channels < 1 || channels > 2 || sampleRate <= 0) {
        logLine("ERR WAV 解析失败");
        return false;
    }

    out.channels = channels;
    out.sampleRate = sampleRate;
    size_t totalSamples = audioFormat == 1 ? pcmData.size() : fltData.size();
    out.totalFrames = static_cast<int>(totalSamples / channels);
    out.planar.assign(static_cast<size_t>(out.totalFrames) * channels, 0.0f);

    // 关键：WAV 文件为交错(L,R,L,R,...)，必须去交错为平面(L...L, R...R)
    for (size_t i = 0; i < totalSamples; ++i) {
        size_t frame = i / channels;
        size_t ch    = i % channels;
        float v = audioFormat == 1
                      ? pcmData[i] / 32768.0f
                      : fltData[i];
        out.planar[ch * out.totalFrames + frame] = v;
    }
    return true;
}

// ==================== WAV 写入（16bit PCM 交错） ====================
static bool writeWav16(const std::string& filename, const float* interleaved,
                       size_t totalSamples, int channels, int sampleRate) {
    std::ofstream f = openOutput(filename);
    if (!f) return false;

    auto putStr = [&](const char* s) { f.write(s, 4); };
    auto putU32 = [&](uint32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); };
    auto putU16 = [&](uint16_t v) { f.write(reinterpret_cast<const char*>(&v), 2); };

    uint32_t dataSize = static_cast<uint32_t>(totalSamples * 2);
    putStr("RIFF"); putU32(36 + dataSize); putStr("WAVE");
    putStr("fmt "); putU32(16); putU16(1); putU16(static_cast<uint16_t>(channels));
    putU32(static_cast<uint32_t>(sampleRate));
    putU32(static_cast<uint32_t>(sampleRate * channels * 2));
    putU16(static_cast<uint16_t>(channels * 2)); putU16(16);
    putStr("data"); putU32(dataSize);

    std::vector<int16_t> pcm(totalSamples);
    for (size_t i = 0; i < totalSamples; ++i) {
        float v = interleaved[i];
        if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
        pcm[i] = static_cast<int16_t>(v * 32767.0f);
    }
    f.write(reinterpret_cast<const char*>(pcm.data()), static_cast<std::streamsize>(pcm.size() * 2));
    f.close();
    return true;
}

// 平面 -> 交错 辅助
static std::vector<float> planarToInterleaved(const AudioData& d) {
    std::vector<float> out(static_cast<size_t>(d.totalFrames) * d.channels);
    for (int ch = 0; ch < d.channels; ++ch) {
        const float* src = d.channel(ch);
        for (int i = 0; i < d.totalFrames; ++i) out[static_cast<size_t>(i) * d.channels + ch] = src[i];
    }
    return out;
}

// ==================== 录音最终化 ====================
static void finalizeRecording() {
    if (!g_recording.load()) return;
    g_recording.store(false);
    if (g_recordBuf.empty()) { logLine("LOG 录音为空，未写入文件"); return; }
    size_t nsamples = g_recordBuf.size();
    if (writeWav16(g_recordPath, g_recordBuf.data(), nsamples, g_recordChannels, g_recordSampleRate)) {
        logLine("LOG 录音已保存: " + g_recordPath + " (" + std::to_string((double)nsamples / g_recordChannels / g_recordSampleRate) + "s)");
    } else {
        logLine("ERR 录音写入失败: " + g_recordPath);
    }
    g_recordBuf.clear();
}

// ==================== 播放会话 ====================
// 返回 false 表示应退出进程
static bool runPlayback(const AudioData& audio, int blockSize, double speed,
                        long long seekOffset, bool* needQuit) {
    int channels = audio.channels;
    int sampleRate = audio.sampleRate;
    int totalFrames = audio.totalFrames;
    if (seekOffset < 0) seekOffset = 0;
    if (seekOffset >= totalFrames) seekOffset = 0;

    // 环形缓冲区按整文件扩容，避免丢数据
    int ringBufferSize = totalFrames + blockSize * 2 + 4096;

    LiveStretchPlayer player(channels, sampleRate, ringBufferSize, speed, blockSize);

    // 音频回调：平面(Planar) -> 交错(Interleaved) 后写 stdout + 可选录音
    // LiveStretchPlayer 回调给出 [L0..Ln-1 | R0..Rn-1]（平面），
    // stdout 协议为 [L0,R0,L1,R1,...]（交错），必须在此转换，否则声像撕裂。
    player.setAudioCallback([&player](const float* data, int frames, int ch) {
        g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);
        g_totalOutFrames.fetch_add(frames, std::memory_order_relaxed);
        // 每 ~200ms 上报一次精确输入位置（C++ 侧进度，权威来源）
        long long now = nowMs();
        long long last = g_lastPosTime.load(std::memory_order_relaxed);
        if (now - last >= 200) {
            g_lastPosTime.store(now, std::memory_order_relaxed);
            std::fprintf(stderr, "POS in=%d out=%lld\n",
                         player.getInputPosition(),
                         (long long)g_totalOutFrames.load(std::memory_order_relaxed));
            std::fflush(stderr);
        }
        size_t n = static_cast<size_t>(frames) * ch;
        if (g_interBuf.size() < n) g_interBuf.resize(n);
        float* dst = g_interBuf.data();
        if (ch == 2) {
            const float* L = data;
            const float* R = data + frames;
            for (int i = 0; i < frames; ++i) {
                dst[2 * i]     = L[i];
                dst[2 * i + 1] = R[i];
            }
        } else {
            std::memcpy(dst, data, sizeof(float) * frames);
        }
        std::fwrite(dst, sizeof(float), n, stdout);
        std::fflush(stdout);
        if (g_recording.load(std::memory_order_relaxed)) {
            g_recordBuf.insert(g_recordBuf.end(), dst, dst + n);
        }
    });

    g_lastCallbackMs.store(0, std::memory_order_relaxed);
    g_pausedMirror.store(false, std::memory_order_relaxed);
    g_recordChannels = channels;
    g_recordSampleRate = sampleRate;
    g_totalOutFrames.store(0, std::memory_order_relaxed);

    player.loadAudio(audio.planar.data(), totalFrames);  // 保留源数据
    if (seekOffset > 0) {
        player.seekTo(static_cast<int>(seekOffset));     // 从未播放状态直接定位
    }
    logLine("READY ch=" + std::to_string(channels) + " sr=" + std::to_string(sampleRate) +
            " block=" + std::to_string(blockSize) + " speed=" + std::to_string(speed) +
            " inFrames=" + std::to_string(totalFrames) +
            " seek=" + std::to_string(seekOffset));
    player.play();

    // 主循环：处理命令，直到自然结束 / STOP / QUIT
    bool finished = false;
    bool quit = false;
    std::string line;
    while (!finished && !quit) {
        if (!readLine(line)) { quit = true; break; }   // stdin EOF
        if (line.empty()) continue;
        std::istringstream iss(line);
        std::string cmd;
        iss >> cmd;

        if (cmd == "SPEED") {
            double s; iss >> s;
            player.setSpeed(s);
            g_pausedMirror.store(false, std::memory_order_relaxed);
        } else if (cmd == "PAUSE") {
            player.pause();
            g_pausedMirror.store(true, std::memory_order_relaxed);
        } else if (cmd == "RESUME") {
            player.resume();
            g_pausedMirror.store(false, std::memory_order_relaxed);
        } else if (cmd == "RECSTART") {
            std::string path;
            std::getline(iss, path);
            if (!path.empty() && path[0] == ' ') path.erase(path.begin());
            g_recordBuf.clear();
            g_recordPath = path;
            g_recording.store(true, std::memory_order_relaxed);
            logLine("LOG 开始录音 -> " + path);
        } else if (cmd == "RECSTOP") {
            finalizeRecording();
        } else if (cmd == "SEEK") {
            long long f = 0;
            iss >> f;
            if (f < 0) f = 0;
            if (player.seekTo(static_cast<int>(f))) {
                g_totalOutFrames.store(0, std::memory_order_relaxed);
                // g_pausedMirror 不变：seekTo 会按 seek 前的暂停/播放状态恢复
                if (g_recording.load(std::memory_order_relaxed)) {
                    g_recordBuf.clear();
                    logLine("LOG 录音已重置（跳转后重新录制）");
                }
                logLine("LOG seek -> 帧 " + std::to_string(f) +
                        "（位置 " + std::to_string(player.getInputPosition()) + "）");
            } else {
                logLine("ERR seek 失败（越界）: " + std::to_string(f));
            }
        } else if (cmd == "STOP") {
            finished = true;
        } else if (cmd == "QUIT") {
            quit = true;
        } else {
            logLine("LOG 未知命令: " + cmd);
        }

        // 自然结束检测：未暂停且超过 500ms 没有回调 => 播放结束
        if (!finished && !quit) {
            long long last = g_lastCallbackMs.load(std::memory_order_relaxed);
            if (last > 0 && !g_pausedMirror.load(std::memory_order_relaxed) &&
                (nowMs() - last) > 500) {
                finished = true;
            }
        }
    }

    player.stop();
    finalizeRecording();
    if (finished && !quit) {
        logLine("DONE");
        // 自然结束：退出进程，供 GUI 重新拉起
        *needQuit = true;
        return true;
    }
    if (quit) {
        logLine("QUIT");
        *needQuit = true;
        return true;
    }
    // STOP：保留进程
    return false;
}

// ==================== 离线 dump 模式 ====================
static int sampleRateHint(const AudioData& a) { return a.sampleRate; }

static int dumpMode(const std::string& inFile, const std::string& outFile,
                    int blockSize, double speed) {
    AudioData audio;
    if (!readWav(inFile, audio)) return 1;

    TimeStretchEngine engine(audio.channels, audio.sampleRate,
                             audio.totalFrames + blockSize * 2 + 4096, speed);

    const float* inPtrs[2] = { audio.channel(0), audio.channel(1) };
    int written = engine.feedAudio(inPtrs, audio.totalFrames);
    logLine("LOG dump: 已喂入 " + std::to_string(written) + "/" + std::to_string(audio.totalFrames) + " 帧");
    engine.finish();

    std::vector<float> outL(blockSize), outR(blockSize);
    float* outPtrs[2] = { outL.data(), outR.data() };
    std::vector<float> interleaved;
    interleaved.reserve(static_cast<size_t>(audio.totalFrames / speed + 4096) * audio.channels);

    long long t0 = nowMs();
    size_t totalOut = 0;
    int produced;
    while ((produced = engine.process(outPtrs, blockSize)) > 0) {
        for (int i = 0; i < produced; ++i) {
            for (int ch = 0; ch < audio.channels; ++ch) {
                interleaved.push_back(ch == 0 ? outL[i] : outR[i]);
            }
        }
        totalOut += static_cast<size_t>(produced);
        if (totalOut % (sampleRateHint(audio) * 5) == 0) {
            logLine("LOG dump: " + std::to_string(totalOut / sampleRateHint(audio)) + "s ...");
        }
    }
    (void)t0;

    bool ok = writeWav16(outFile, interleaved.data(), interleaved.size(),
                         audio.channels, audio.sampleRate);
    logLine(ok ? "LOG dump: 完成 -> " + outFile + " (" + std::to_string(interleaved.size() / audio.channels / audio.sampleRate) + "s)"
               : "ERR dump: 写入失败");
    return ok ? 0 : 1;
}

// ==================== 主程序 ====================
// Windows 下用 wmain 获取宽字符 argv（支持中文路径），统一转 UTF-8 字符串
#ifdef _WIN32
int wmain(int argc, wchar_t* argv[]) {
    std::vector<std::string> a;
    for (int i = 0; i < argc; ++i) a.push_back(wideToUtf8(argv[i]));
    auto arg = [&](int i) -> const std::string& { return a[i]; };
#else
int main(int argc, char* argv[]) {
    std::vector<std::string> a(argv, argv + argc);
    auto arg = [&](int i) -> const std::string& { return a[i]; };
#endif
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif

    // dump 模式
    if (argc >= 6 && arg(1) == "dump") {
        int block = std::atoi(arg(4).c_str());
        double speed = std::atof(arg(5).c_str());
        if (block < 64) block = 512;
        if (speed < 0.01) speed = 1.0;
        return dumpMode(arg(2), arg(3), block, speed);
    }

    std::string inputPath;
    if (argc >= 2) inputPath = arg(1);

    bool needQuit = false;
    std::string line;
    while (!needQuit) {
        if (!readLine(line)) break;
        if (line.empty()) continue;
        std::istringstream iss(line);
        std::string cmd;
        iss >> cmd;

        if (cmd == "LOAD") {
            std::string path;
            std::getline(iss, path);
            if (!path.empty() && path[0] == ' ') path.erase(path.begin());
            if (path.empty()) { logLine("ERR LOAD 缺少路径"); continue; }
            inputPath = path;
            // 预解析 WAV 元数据
            AudioData probe;
            if (readWav(inputPath, probe)) {
                logLine("INFO loaded ch=" + std::to_string(probe.channels) +
                        " sr=" + std::to_string(probe.sampleRate) +
                        " frames=" + std::to_string(probe.totalFrames) +
                        " dur=" + std::to_string(probe.totalFrames / (double)probe.sampleRate));
            }
        } else if (cmd == "PLAY") {
            int block = 512;
            double speed = 1.0;
            iss >> block >> speed;
            if (block < 64) block = 512;
            if (speed < 0.01) speed = 1.0;
            if (inputPath.empty()) { logLine("ERR 未设置输入文件 (LOAD)"); continue; }
            AudioData audio;
            if (!readWav(inputPath, audio)) continue;
            long long startOffset = g_nextSeek;
            g_nextSeek = 0;
            logLine("LOG 开始播放: " + inputPath + " block=" + std::to_string(block) +
                    " speed=" + std::to_string(speed) +
                    " startSeek=" + std::to_string(startOffset));
            runPlayback(audio, block, speed, startOffset, &needQuit);
        } else if (cmd == "SEEK") {
            // 空闲态：记录起始偏移，供下次 PLAY 使用
            long long f = 0;
            iss >> f;
            if (f < 0) f = 0;
            g_nextSeek = f;
            logLine("LOG 已设置起始位置（空闲）: 帧 " + std::to_string(f));
        } else if (cmd == "QUIT") {
            needQuit = true;
        } else if (cmd == "STOP") {
            // 空闲态 STOP 无操作
        } else if (cmd == "RECSTART") {
            std::string path;
            std::getline(iss, path);
            if (!path.empty() && path[0] == ' ') path.erase(path.begin());
            g_recordBuf.clear();
            g_recordPath = path;
            g_recording.store(true, std::memory_order_relaxed);
            logLine("LOG 开始录音 -> " + path);
        } else if (cmd == "RECSTOP") {
            finalizeRecording();
        } else {
            logLine("LOG 未知命令: " + cmd + "（可用: LOAD/PLAY/SPEED/PAUSE/RESUME/RECSTART/RECSTOP/STOP/QUIT）");
        }
    }
    return 0;
}
