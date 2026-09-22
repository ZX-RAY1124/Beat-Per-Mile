/*
 * ffmpeg_decoder.hpp  --  用 FFmpeg 解码音频文件为「单声道 / 44100Hz / float」
 * =============================================================================
 * 纯头文件 · C++11 · 只依赖项目已链接的 FFmpeg
 *
 * 为什么需要它
 * ------------
 * Essentia 的 MonoLoader / AudioLoader 内部自己调 FFmpeg，但它对某些文件会在
 * **探测容器**这一步就失败，抛出：
 *     AudioLoader: Could not open file "...", error = Invalid data found when processing input
 * 这句是 FFmpeg 的 AVERROR_INVALIDDATA —— 来自 avformat_open_input 的格式探测，
 * 也就是**连容器都没认出来**，根本没走到解码。
 *
 * 而本工程自己的 audio_process.cpp 用**同一批 libavformat/libavcodec.so**
 * （libessentia.so 的 DT_NEEDED 里就是它们，两者共用同一份 FFmpeg）对同一个文件
 * 调 avformat_open_input 是成功的 —— 播放链路一直正常。
 * 既然同一份 FFmpeg 能打开这个文件，就没必要受制于 Essentia 的加载器实现：
 * 自己解码成 44100 单声道 float，再喂给 Essentia 的**分析算法**（eb::detect()）。
 *
 * 另一个好处：把「文件读取 / 容器解码」与「节拍分析」解耦，
 * 以后换格式、换解码器都不影响 BPM 算法。
 *
 * 输出约定（必须与 eb::detect 的要求一致）
 * ----------------------------------------
 *   单声道 · 44100Hz · AV_SAMPLE_FMT_FLT（float32，[-1,1]）
 * =============================================================================
 */

#ifndef BPM_FFMPEG_DECODER_HPP
#define BPM_FFMPEG_DECODER_HPP

#include <string>
#include <vector>
#include <cstdint>
#include <functional>

// 日志：设备上有真正的 hilog；在没有该头的宿主环境（纯语法检查）下退化为 printf，
// 这样这个头文件可以脱离 OHOS SDK 单独编译验证。
#if defined(__has_include)
#  if __has_include("hilog/log.h")
#    include "hilog/log.h"
#  endif
#endif

#ifndef OH_LOG_INFO
#  include <cstdio>
#  ifndef LOG_APP
#    define LOG_APP 0
#  endif
#  define OH_LOG_INFO(tag, ...) do { printf(__VA_ARGS__); printf("\n"); } while (0)
#  define OH_LOG_WARN(tag, ...) do { printf(__VA_ARGS__); printf("\n"); } while (0)
#  define OH_LOG_ERROR(tag, ...) do { printf(__VA_ARGS__); printf("\n"); } while (0)
#endif

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}

namespace bpmaudio {

/** 每次 swr_convert 的输出缓冲容量（float 个数）。
 *  它只需容下「一个 AVFrame 重采样后的样本数」（通常几百~几千），
 *  给 65536 是极宽松的上界，因此缓冲可一次分配、反复复用。 */
static const int kSwrChunkFloats = 65536;

/** 解码结果 */
struct DecodeResult {
    bool ok;
    std::string error;
    std::vector<float> samples;   // 单声道 44100Hz float
    int sampleRate;               // 固定 44100
    double durationSec;           // 时长（秒），便于诊断
    std::string codecName;        // 实际使用的解码器名，便于诊断
    // ---- 容器元数据（供上层填充歌曲信息）----
    std::string title;            // 歌曲名；取不到时为空，由上层退回文件名
    std::string artist;           // 作者/艺术家；取不到时为空

    DecodeResult() : ok(false), sampleRate(44100), durationSec(0.0) {}
};

/**
 * 在 metadata 字典里按一组候选键查找。
 * 各容器用的标签名不一样，候选键必须都覆盖到：
 *   · MP4/M4A (iTunes)：©nam / ©ART —— 注意是 U+00A9 后跟字母，不是 ASCII 的 'c'
 *   · MP3 (ID3v2)     ：title/artist、TIT2/TPE1
 *   · FLAC / OGG      ：TITLE / ARTIST
 * 返回原始字符串；找不到返回空串。
 */
inline std::string dictGetAny(AVDictionary* dict, const char* const* keys, int n) {
    if (dict == nullptr) return std::string();
    for (int i = 0; i < n; ++i) {
        AVDictionaryEntry* e = av_dict_get(dict, keys[i], nullptr, 0);
        if (e != nullptr && e->value != nullptr && e->value[0] != '\0') {
            return std::string(e->value);
        }
    }
    return std::string();
}

/** 从容器元数据里取「歌曲名 / 作者」 */
inline void readSongTags(AVFormatContext* fmt, DecodeResult& r) {
    static const char* const kTitleKeys[] = {
        "\xC2\xA9nam",          // ©nam (MP4/M4A)
        "title", "TIT2", "TITLE", "Title", "name"
    };
    static const char* const kArtistKeys[] = {
        "\xC2\xA9" "ART",       // ©ART (MP4/M4A)
        "artist", "TPE1", "ARTIST", "Artist",
        "album_artist", "albumartist", "ALBUMARTIST", "author", "AUTHOR"
    };
    r.title = dictGetAny(fmt->metadata, kTitleKeys,
                         (int)(sizeof(kTitleKeys) / sizeof(kTitleKeys[0])));
    r.artist = dictGetAny(fmt->metadata, kArtistKeys,
                          (int)(sizeof(kArtistKeys) / sizeof(kArtistKeys[0])));
}

/** 进度回调：pct ∈ [0,1]，-1 表示总时长未知；note 供上层打日志 */
typedef std::function<void(double pct, const std::string& note)> ProgressFn;

/**
 * 解码参数。用结构体而不是位置参数，避免"两个 int/两个回调传错顺序"
 * （同 switch_plan.hpp 用 SwitchRequest 的理由）。
 */
struct DecodeOptions {
    int targetRate;          // 目标采样率，默认 44100（Essentia 硬性要求）
    ProgressFn onProgress;   // 可选进度回调（在工作线程上同步执行，勿碰 UI）

    DecodeOptions() : targetRate(44100) {}
};

/**
 * 解码音频文件为单声道 44100Hz float。
 * @param path 音频文件绝对路径
 * @param opt  解码参数（目标采样率 / 进度回调）
 *
 * onProgress 说明：长音频里耗时几乎全在解码这一段，所以它是"到底卡在哪、
 * 还要等多久"最直接的可见手段。⚠️ 它在**工作线程**上同步执行，
 * 只允许打日志 / 更新状态，不能碰 UI。
 */
inline DecodeResult decodeToMono44k(const std::string& path, const DecodeOptions& opt = DecodeOptions()) {
    const int targetRate = opt.targetRate;
    const ProgressFn& onProgress = opt.onProgress;
    DecodeResult r;

    // ---- 1. 打开容器（与 audio_process.cpp 的调用方式保持一致：format 传 nullptr）----
    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(ret, buf, sizeof(buf));
        r.error = std::string("avformat_open_input 失败(") + std::to_string(ret) + "): " + buf;
        return r;
    }

    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        r.error = "avformat_find_stream_info 失败";
        avformat_close_input(&fmt);
        return r;
    }

    // ---- 2. 找第一条音频流（不依赖 av_find_best_stream 的版本差异）----
    int audioIdx = -1;
    for (unsigned int i = 0; i < fmt->nb_streams; ++i) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioIdx = static_cast<int>(i);
            break;
        }
    }
    if (audioIdx < 0) {
        r.error = "文件里没有音频流";
        avformat_close_input(&fmt);
        return r;
    }

    AVCodecParameters* par = fmt->streams[audioIdx]->codecpar;

    // ---- 2.5 顺手取容器元数据（歌曲名 / 作者）----
    // 必须在 avformat_close_input 之前取：fmt 一关，metadata 就失效了。
    readSongTags(fmt, r);
    OH_LOG_INFO(LOG_APP, "[decode] 元数据: title=\"%{public}s\" artist=\"%{public}s\"",
                r.title.c_str(), r.artist.c_str());

    const AVCodec* codec = avcodec_find_decoder(par->codec_id);
    if (codec == nullptr) {
        r.error = std::string("找不到解码器 codec_id=") + std::to_string(par->codec_id);
        avformat_close_input(&fmt);
        return r;
    }
    r.codecName = (codec->name != nullptr) ? codec->name : "?";

    // ---- 3. 打开解码器 ----
    AVCodecContext* cc = avcodec_alloc_context3(codec);
    if (cc == nullptr) {
        r.error = "avcodec_alloc_context3 失败";
        avformat_close_input(&fmt);
        return r;
    }
    if (avcodec_parameters_to_context(cc, par) < 0) {
        r.error = "avcodec_parameters_to_context 失败";
        avcodec_free_context(&cc);
        avformat_close_input(&fmt);
        return r;
    }
    ret = avcodec_open2(cc, codec, nullptr);
    if (ret < 0) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(ret, buf, sizeof(buf));
        r.error = std::string("avcodec_open2 失败: ") + buf;
        avcodec_free_context(&cc);
        avformat_close_input(&fmt);
        return r;
    }

    // ---- 4. 重采样器：任意输入 → 单声道 / targetRate / FLT ----
    const int64_t inLayout = (cc->channel_layout != 0)
                                 ? static_cast<int64_t>(cc->channel_layout)
                                 : av_get_default_channel_layout(cc->channels);
    SwrContext* swr = swr_alloc_set_opts(nullptr,
                                         AV_CH_LAYOUT_MONO, AV_SAMPLE_FMT_FLT, targetRate,
                                         inLayout, cc->sample_fmt, cc->sample_rate,
                                         0, nullptr);
    if (swr == nullptr) {
        r.error = "swr_alloc_set_opts 失败";
        avcodec_free_context(&cc);
        avformat_close_input(&fmt);
        return r;
    }
    ret = swr_init(swr);
    if (ret < 0) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(ret, buf, sizeof(buf));
        r.error = std::string("swr_init 失败: ") + buf;
        swr_free(&swr);
        avcodec_free_context(&cc);
        avformat_close_input(&fmt);
        return r;
    }

    AVPacket* pkt = av_packet_alloc();
    AVFrame*  frm = av_frame_alloc();
    std::vector<float> outBuf(static_cast<size_t>(kSwrChunkFloats));
    bool failed = false;

    // 总时长（毫秒）——用来算解码进度百分比。
    // 依次尝试：① 音频流自身的 duration/time_base（最准）
    //          ② 容器 duration
    // 两个都拿不到就保持 0 ⇒ 进度百分比未知，退化为只报"已处理秒数"。
    int64_t totalMs = 0;
    {
        AVStream* as = fmt->streams[audioIdx];
        if (as->duration != AV_NOPTS_VALUE && as->duration > 0 &&
            as->time_base.num > 0 && as->time_base.den > 0) {
            totalMs = static_cast<int64_t>(
                (static_cast<double>(as->duration) * as->time_base.num * 1000.0) /
                static_cast<double>(as->time_base.den));
        }
        if (totalMs <= 0 && fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) {
            totalMs = fmt->duration / (AV_TIME_BASE / 1000);
        }
    }

    if (pkt == nullptr || frm == nullptr) {
        r.error = "av_packet_alloc / av_frame_alloc 失败";
        if (pkt) av_packet_free(&pkt);
        if (frm) av_frame_free(&frm);
        swr_free(&swr);
        avcodec_free_context(&cc);
        avformat_close_input(&fmt);
        return r;
    }

    OH_LOG_INFO(LOG_APP, "[decode] 开始解码: codec=%{public}s inRate=%{public}d ch=%{public}d "
                         "layout=%{public}lld sampleFmt=%{public}s totalMs=%{public}lld",
                r.codecName.c_str(), cc->sample_rate, cc->channels,
                static_cast<long long>(inLayout),
                av_get_sample_fmt_name(cc->sample_fmt) ? av_get_sample_fmt_name(cc->sample_fmt) : "?",
                static_cast<long long>(totalMs));

    // ---- 5. 解码 + 重采样 ----
    // 每帧独立处理：send_packet → 收干 receive_frame，再统一冲刷。
    // 用同一个复用缓冲，避免每帧分配。
    auto feedFrame = [&](const AVFrame* frame) {
        if (failed) return;
        uint8_t* dst[1] = { reinterpret_cast<uint8_t*>(outBuf.data()) };
        const uint8_t** src = const_cast<const uint8_t**>(frame->extended_data);
        int got = swr_convert(swr, dst, kSwrChunkFloats, src, frame->nb_samples);
        if (got < 0) {
            failed = true;
            r.error = "swr_convert 失败";
            return;
        }
        if (got > 0) {
            r.samples.insert(r.samples.end(), outBuf.begin(), outBuf.begin() + got);
        }
    };

    // 进度节流：只在跨过 10% 台阶时上报一次，避免每包都刷日志。
    // 总时长已知 → 报百分比；总时长未知（totalMs==0，某些 m4a 的 moov 里没写）
    // → 退化为报"已解码秒数"，绝不再出现一个毫无信息量的 "-1%"。
    int lastPctStep = -1;
    auto reportProgress = [&]() {
        if (!onProgress) return;
        const double sec = static_cast<double>(r.samples.size()) / static_cast<double>(targetRate);
        int step;
        if (totalMs > 0) {
            double p = sec * 1000.0 / static_cast<double>(totalMs);
            if (p > 1.0) p = 1.0;
            step = static_cast<int>(p * 10.0 + 0.5);
            if (step == lastPctStep) return;
            lastPctStep = step;
            char buf[64];
            std::snprintf(buf, sizeof(buf), "%.0f%%", p * 100.0);
            onProgress(p, std::string("decode ") + buf);   // 形如 "decode 40%"
        } else {
            step = static_cast<int>(sec);                  // 每过 1 秒报一次
            if (step == lastPctStep) return;
            lastPctStep = step;
            char buf[64];
            std::snprintf(buf, sizeof(buf), "已解码 %.0fs (总长未知)", sec);
            onProgress(-1.0, std::string("decode ") + buf);
        }
    };

    while (!failed) {
        ret = av_read_frame(fmt, pkt);
        if (ret < 0) {
            break;   // EOF 或错误，统一靠下面的冲刷收尾
        }
        if (pkt->stream_index == audioIdx) {
            if (avcodec_send_packet(cc, pkt) >= 0) {
                while (avcodec_receive_frame(cc, frm) == 0) {
                    feedFrame(frm);
                    av_frame_unref(frm);
                    if (failed) break;
                }
                reportProgress();   // ← 处理完这一包之后按"已产出秒数"上报
            }
        }
        av_packet_unref(pkt);
    }

    // ---- 6. 冲刷解码器 ----
    if (!failed) {
        avcodec_send_packet(cc, nullptr);
        while (avcodec_receive_frame(cc, frm) == 0) {
            feedFrame(frm);
            av_frame_unref(frm);
            if (failed) break;
        }
    }

    av_frame_free(&frm);
    av_packet_free(&pkt);
    swr_free(&swr);
    avcodec_free_context(&cc);
    avformat_close_input(&fmt);

    if (failed) return r;
    if (r.samples.empty()) {
        r.error = "解码结果为空（0 个样本）";
        return r;
    }

    r.durationSec = static_cast<double>(r.samples.size()) / static_cast<double>(targetRate);
    r.ok = true;
    OH_LOG_INFO(LOG_APP, "[decode] 完成: 产出 %{public}.2fs 单声道 @%{public}dHz（%{public}u 样本）",
                r.durationSec, targetRate, static_cast<unsigned int>(r.samples.size()));
    return r;
}

} // namespace bpmaudio

#endif // BPM_FFMPEG_DECODER_HPP
