#include "EssentiaBeats.hpp"
#include "ffmpeg_decoder.hpp"
#include "audio_process.h"
#include "napi/native_api.h"
#include "hilog/log.h"
#include "test_audio.h"
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <thread>
#include "LiveStretchPlayer.h"
#include <cstring>
#include <algorithm>
#include <atomic>
#include <vector>
#include <memory>
#include <string>
#include <mutex>
#include <unordered_map>
#include <sstream>
// 暂时不引用 essentia，先验证编译链路没问题

// ─── 播放用环形缓冲区：无锁单生产者-单消费者（SPSC） ───
// 生产者：LiveStretchPlayer 的回调线程（只写 writePos_）
// 消费者：OH_AudioRenderer 的写数据回调线程（只写 readPos_）
// 两端各只写自己的下标、用 acquire/release 配对传递数据，因此读端绝不阻塞 ——
// 这是实时音频回调的硬要求（旧版用一把 fill_ 同时被两端读写，是数据竞争）。
// ★ 契约：任一时刻只能各有一个生产者/消费者线程；不得从第三个线程调用 reset()。
//   （多播放器共享本对象属于"全局单例"问题，不在本次修复范围。）
class PlaybackRingBuffer {
public:
    explicit PlaybackRingBuffer(size_t capacity)
        : buffer_(capacity + 1, 0.0f), capacity_(capacity + 1) {}   // 留一格区分「满/空」

    PlaybackRingBuffer(const PlaybackRingBuffer&) = delete;
    PlaybackRingBuffer& operator=(const PlaybackRingBuffer&) = delete;

    /** 生产者写入数据，返回实际写入的 float 个数（满则丢弃新数据） */
    size_t write(const float* data, size_t count) {
        if (data == nullptr || count == 0) return 0;
        const size_t w = writePos_.load(std::memory_order_relaxed);
        const size_t r = readPos_.load(std::memory_order_acquire);
        const size_t used  = (w + capacity_ - r) % capacity_;
        const size_t space = capacity_ - 1 - used;              // 恒空一格 ⇒ 满/空可区分
        const size_t toWrite = (count < space) ? count : space;
        for (size_t i = 0; i < toWrite; ++i) {
            buffer_[(w + i) % capacity_] = data[i];
        }
        // release：保证上面的写入对读到本值的消费者可见
        writePos_.store((w + toWrite) % capacity_, std::memory_order_release);
        return toWrite;
    }

    /** 消费者读取数据（音频回调内，绝不阻塞），返回实际读取的 float 个数 */
    size_t read(float* out, size_t count) {
        if (out == nullptr || count == 0) return 0;
        const size_t r = readPos_.load(std::memory_order_relaxed);
        const size_t w = writePos_.load(std::memory_order_acquire);
        const size_t used = (w + capacity_ - r) % capacity_;
        const size_t toRead = (count < used) ? count : used;
        for (size_t i = 0; i < toRead; ++i) {
            out[i] = buffer_[(r + i) % capacity_];
        }
        // release：保证消费者已拷走的数据不会再被生产者覆盖
        readPos_.store((r + toRead) % capacity_, std::memory_order_release);
        return toRead;
    }

    /** 可读元素个数（诊断用；并发下只是某一瞬间的快照） */
    size_t available() const {
        const size_t w = writePos_.load(std::memory_order_acquire);
        const size_t r = readPos_.load(std::memory_order_acquire);
        return (w + capacity_ - r) % capacity_;
    }
    /** 可写元素个数（诊断用） */
    size_t space() const { return capacity_ - 1 - available(); }

    size_t capacity() const { return capacity_ - 1; }             // 对外报"可用容量"
    bool empty() const { return available() == 0; }
    bool full() const { return available() >= capacity_ - 1; }

    /** ★ 只能在生产者与消费者都已停止时调用（两者都置 0，不能与读写并发） */
    void reset() {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

private:
    std::vector<float> buffer_;
    size_t capacity_;                    // = 请求容量 + 1（多出的一格用于区分满/空）
    std::atomic<size_t> readPos_{0};     // 仅消费者写
    std::atomic<size_t> writePos_{0};    // 仅生产者写
};

// ════════════════════════════════════════════
              

// （原 audioRenderers / builders 两个全局数组已删除：它们在 WorkerThread 里 push_back，
//   却用 playerId-1 去索引；clear() 又 erase(begin())，下标与 id 从第二次播放起必然错位。）

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200   // 0x0000 ~ 0xFFFF，自定义业务领域
#define LOG_TAG   "MyTag"   // 标识模块，不能为NULL

// 自定义上下文结构体
struct TsfnContext {
    napi_ref callbackRef = nullptr; // 强引用 ArkTS 回调
    napi_threadsafe_function tsfn = nullptr;
    
    std::atomic<bool> paused{false};
    std::atomic<bool> cancelled{false};
    std::vector<float> g_interleavedBuf;         //缓冲
    std::string fileName;
    std::thread worker;
    
    // ★ 本任务自己的声卡对象。不再用"全局数组 + playerId-1 下标"反查——
    //   push_back 的顺序不等于 playerId-1，且 clear() 会 erase(begin())，
    //   第二次播放时下标就会越界（详见本次修复说明）。
    OH_AudioRenderer*      renderer = nullptr;
    OH_AudioStreamBuilder* builder  = nullptr;

    int playerId;    //播放任务id
};

struct music_data {
    int block_num;
    int32_t audioDataSize;
    double accelerate = 1.0;

};

// ─── 全局任务管理器（用于按ID查找上下文） ───
static std::unordered_map<int, TsfnContext *> g_downloadMap;
static std::mutex g_mapMutex;
static std::mutex g_dataMutex;                        // 保护 dataClip & ring buffer 并发访问
static int g_nextId = 1; 
static music_data* dataClip = nullptr;
static PlaybackRingBuffer g_ringBuffer(48000 * 2 * 2);   // 2秒立体声 PCM 容量 (192000 floats, 兼容44.1k~48k)
static std::atomic<long long> g_lastCallbackMs;       //最后一次回调时间
bool g_isPlaybackFinished = false;


//自定义音频加载函数
static OH_AudioData_Callback_Result OnWriteData_New(
    OH_AudioRenderer* renderer,
    void* userData,
    void* buffer,
    int32_t bufferLen){
        size_t floatCount = static_cast<size_t>(bufferLen) / sizeof(float);
        size_t floatsRead = g_ringBuffer.read(static_cast<float*>(buffer), floatCount);
        


        // 如果环形缓冲区数据不足，用静音填充剩余部分
        if (floatsRead < floatCount) {
            float* buf = static_cast<float*>(buffer);
            std::memset(buf + floatsRead, 0, (floatCount - floatsRead) * sizeof(float));
            OH_LOG_WARN(LOG_APP, "underrun: need %{public}zu, got %{public}zu", floatCount, floatsRead);
        }
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
    
    };
//自定义音频中断函数
static void OnInterruptEvent_New(
    OH_AudioRenderer* renderer,
    void* userData,
    OH_AudioInterrupt_ForceType type,
    OH_AudioInterrupt_Hint hint){
        
    //改
    };


//异常回调函数
static void OnError_New(
    OH_AudioRenderer* render,
    void* userData,
    OH_AudioStream_Result error
){
    OH_LOG_ERROR(LOG_APP, "Face Error in load the audio");
             //改
};


static void AudioRenderer_BuilderRelease(OH_AudioRenderer* audioRenderer, OH_AudioStreamBuilder* builder){
    // 两者独立判空：原来只在 audioRenderer 非空时才 Destroy builder，
    // 渲染器创建失败时会漏掉构建器。（原先那两句 = nullptr 是对按值形参赋值，本就没有作用。）
    if (audioRenderer) {
        OH_AudioRenderer_Release(audioRenderer);
    }
    if (builder) {
        OH_AudioStreamBuilder_Destroy(builder);
    }
    //这里释放文件进程
    
    
}

// 只创建并配置 builder；渲染器由 GenerateRenderer 生成，由调用方保存到自己的上下文里。
static void AudioRendererInit(OH_AudioStreamBuilder*& builder){
    OH_LOG_INFO(LOG_APP, "Now Add AudioRenderer");
    // （原"事先清理"分支已删除：audioRenderer 是局部变量且从未被赋值，
    //   真正的清理由 AudioRenderer_BuilderRelease() 负责。）
    //============构建音频播放器============ 
    OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
    
    const int SAMPLING_RATE_48K = 48000;
    OH_AudioStreamBuilder_SetSamplingRate(builder, SAMPLING_RATE_48K);
    
    const int channelCount = 2;                     //声道
    OH_AudioStreamBuilder_SetChannelCount(builder, channelCount);
    
    // 设置音频采样格式。
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_F32LE);
    // 设置音频流的编码类型。
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    // 设置输出音频流的工作场景。
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);

    
    //注册三大回调函数
    OH_AudioRenderer_OnInterruptCallback OnInterruptCb = OnInterruptEvent_New;
    OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, OnInterruptCb, nullptr);
    OH_AudioRenderer_OnErrorCallback OnErrorCb = OnError_New;
    OH_AudioStreamBuilder_SetRendererErrorCallback(builder, OnErrorCb, nullptr);
    OH_AudioRenderer_OnWriteDataCallback writeDataCb = OnWriteData_New;
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, writeDataCb, nullptr);
}

static napi_value Add(napi_env env, napi_callback_info info)
{
    size_t argc = 2;       //收集两个参数
    napi_value args[2] = {nullptr};       // 用一个数组接住传进来的参数
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double value0, value1;                //定义两个变量
    napi_get_value_double(env, args[0], &value0);     //args[0] 第一个参数 value0
    napi_get_value_double(env, args[1], &value1);     //args[1] 第二个参数 value1

    napi_value sum;
    napi_create_double(env, value0 + value1, &sum);       //计算结果并且将返回值丢给 sum   
    OH_LOG_INFO(LOG_APP, "used Add");
    return sum;
}

static napi_value Squire(napi_env env, napi_callback_info info){
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double num = 0.0;
    int32_t squire = 0;
    napi_get_value_double(env, args[0], &num);
    napi_get_value_int32(env, args[1], &squire);

    // 计算 num 的 squire 次幂
    double result = 1.0;
    for (int32_t i = 0; i < squire; i++) {
        result *= num;
    }

    napi_value final;
    napi_create_double(env, result, &final);
    return final;
}

static napi_value analyzeMusic(napi_env env, napi_callback_info info){
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    size_t strLen;
    napi_status sourceStatus =  napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
    char* buf = new char[strLen + 1]();
    memset(buf, 0, strLen + 1);
    sourceStatus = napi_get_value_string_utf8(env, args[0], buf, strLen + 1, &strLen);
    if(sourceStatus == napi_ok){
        OH_LOG_INFO(LOG_APP, "%{public}s",buf);
        eb::detect_file_to_csv(buf);
    }

    
    return nullptr;
}

// ════════════════════════════════════════════════════════════════════════
//  音频离线分析（BPM / 拍点 → CSV）—— 异步版本
//
//  为什么必须异步：
//    NAPI 的同步函数是在 ArkTS 的主线程（JS 线程）上直接执行的。
//    eb::detect_file_to_csv 内部走 Essentia 的 MonoLoader 解码 + 
//    RhythmExtractor2013("multifeature") 全曲分析，一首 3~4 分钟的歌要
//    几秒到十几秒。放在主线程上会把 UI/事件循环整段卡死，
//    系统看门狗判定 THREAD_BLOCK_6S，直接杀进程 —— 用户看到的就是
//    "点一下按钮 App 就卡死退出"，而且 CSV 根本来不及写出。
//
//  做法：照搬本文件已有的 music_play 模式
//    主线程只做参数解析 + 建 TSFN，然后立刻返回；
//    真正的分析在 worker 线程上跑；
//    完成后通过 TSFN 把结果/错误回传主线程执行 ArkTS 回调。
//    这样既不阻塞主线程，也能把失败原因告诉上层（旧版返回 void，
//    失败时静默无输出，这正是"日志有、CSV 没有"的来源）。
// ════════════════════════════════════════════════════════════════════════

/** 单调时钟毫秒（steady，不受系统时间调整影响） */
static long long nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

/** 一次分析任务：worker 线程持有它，完成后由 TSFN 终结回调释放。 */
struct AnalyseTask {
    napi_threadsafe_function tsfn = nullptr;
    std::string audioPath;   // 待分析音频的沙箱绝对路径
};

// ─── 分析进度（供 ArkTS 轮询，解决"到底卡在哪 / 要等多久"） ───
// 工作线程写、主线程读，用一把小锁保护。
static std::mutex g_anaMx;
static std::string g_anaPhase = "idle";   // idle/decode/detect/write/done/failed
static int         g_anaPct   = -1;       // 0~100，-1 = 未知
static long long   g_anaStartMs = 0;      // 开始时刻（steady 毫秒）
static long long   g_anaEndMs   = 0;      // 结束时刻
static std::string g_anaErr;

/** 把任意字符串转义成 JSON 字符串字面量的内容（用长度循环，不依赖静态分析） */
static std::string jsonEscape(const std::string& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        const char c = s[i];
        switch (c) {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n";  break;
        case '\r': o += "\\r";  break;
        case '\t': o += "\\t";  break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                o += ' ';   // 控制字符直接替换成空格，够用且安全
            } else {
                o += c;
            }
        }
    }
    return o;
}

/** 更新分析阶段（工作线程调用）。pct < 0 表示百分比未知。 */
static void setAnalysePhase(const std::string& phase, int pct) {
    std::lock_guard<std::mutex> lk(g_anaMx);
    g_anaPhase = phase;
    g_anaPct = pct;
}

/** 读当前分析状态，输出一行 JSON 供 ArkTS 解析 */
static napi_value GetAnalyseStatus(napi_env env, napi_callback_info info) {
    (void)info;
    std::string phase;
    int pct = -1;
    long long startMs = 0, endMs = 0;
    std::string err;
    {
        std::lock_guard<std::mutex> lk(g_anaMx);
        phase = g_anaPhase;
        pct = g_anaPct;
        startMs = g_anaStartMs;
        endMs = g_anaEndMs;
        err = g_anaErr;
    }
    long long now = nowMs();
    const long long end = (endMs > 0) ? endMs : now;
    const long long elapsed = (startMs > 0) ? (end - startMs) : 0;

    std::ostringstream os;
    os << "{\"phase\":\"" << jsonEscape(phase) << "\""
       << ",\"pct\":" << pct
       << ",\"elapsedMs\":" << elapsed
       << ",\"running\":" << ((phase != "idle" && phase != "done" && phase != "failed") ? "true" : "false")
       << ",\"error\":\"" << jsonEscape(err) << "\"}";

    const std::string s = os.str();
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

/** TSFN 终结回调：由 napi_release_threadsafe_function 触发，在创建线程（主线程）执行 */
static void AsyncCleanupCallback(napi_env env, void *finalizeData, void *finalizeHint) {
    (void)env;
    (void)finalizeHint;
    delete static_cast<AnalyseTask *>(finalizeData);
    OH_LOG_INFO(LOG_APP, "[analyse] task released");
}

/** TSFN 主线程回调：把结果或错误交给 ArkTS */
static void AnalyseCallback(napi_env env, napi_value jsCallback, void *context, void *data) {
    (void)context;
    if (jsCallback == nullptr || data == nullptr) return;

    // data 的所有权：本回调负责 delete
    std::unique_ptr<eb::BeatResult> result(static_cast<eb::BeatResult *>(data));

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value argv[2] = {undefined, undefined};
    size_t argc = 0;

    if (result->ok) {
        // 成功：第一个参数 = BPM（ArkTS 侧取数字即代表成功）
        napi_create_double(env, result->bpm, &argv[0]);
        argc = 1;
        OH_LOG_INFO(LOG_APP, "[analyse] ok: bpm=%{public}.3f ticks=%{public}u",
                    result->bpm, static_cast<unsigned int>(result->ticks.size()));
    } else {
        // 失败：第一个参数 = null，第二个参数 = 人类可读原因
        napi_get_null(env, &argv[0]);
        napi_create_string_utf8(env, result->error.c_str(), NAPI_AUTO_LENGTH, &argv[1]);
        argc = 2;
        OH_LOG_ERROR(LOG_APP, "[analyse] failed: %{public}s", result->error.c_str());
    }

    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCallback, argc, argv, nullptr);
}

/** worker 线程：真正干活的地方（解码 + 节拍检测 + 写 CSV） */
static void AnalyseWorkerThread(AnalyseTask *task) {
    std::unique_ptr<eb::BeatResult> result(new eb::BeatResult());
    try {
        // ① 先用项目自己的 FFmpeg 解码成「单声道 44100Hz float」。
        //    Essentia 自带的 AudioLoader 在某些文件上连容器都探测不出来
        //    （AVERROR_INVALIDDATA），而同一份 libavformat 由本工程调用是成功的，
        //    所以这里绕开 Essentia 的加载器，只借它的**分析算法**。
        setAnalysePhase("decode", 0);
        bpmaudio::DecodeOptions dopt;
        // 进度回调运行在**本工作线程**上，只做日志 + 更新状态，不碰 UI
        // note 可能是 "decode 40%"（总长已知）或 "decode 已解码 12s (总长未知)"
        dopt.onProgress = [](double p, const std::string& note) {
            const int pct = (p < 0.0) ? -1 : static_cast<int>(p * 100.0);
            OH_LOG_INFO(LOG_APP, "[analyse] %{public}s", note.c_str());
            setAnalysePhase("decode", pct);
        };
        bpmaudio::DecodeResult dec = bpmaudio::decodeToMono44k(task->audioPath, dopt);
        if (dec.ok) {
            OH_LOG_INFO(LOG_APP,
                        "[analyse] ffmpeg 解码成功: codec=%{public}s rate=%{public}d "
                        "samples=%{public}u dur=%{public}.2fs",
                        dec.codecName.c_str(), dec.sampleRate,
                        static_cast<unsigned int>(dec.samples.size()), dec.durationSec);

            eb::Options opt;
            setAnalysePhase("detect", -1);           // 节拍分析：算不出百分比，只报阶段
            const long long t0 = nowMs();
            *result = eb::detect(dec.samples, opt);
            OH_LOG_INFO(LOG_APP,
                        "[analyse] 节拍分析耗时 %{public}lld ms, ok=%{public}d ticks=%{public}u",
                        static_cast<long long>(nowMs() - t0), result->ok ? 1 : 0,
                        static_cast<unsigned int>(result->ticks.size()));

            if (result->ok && !result->ticks.empty()) {
                // 写 CSV（路径规则与 detect_file_to_csv 保持一致：同名目录 + _beats.csv）
                setAnalysePhase("write", -1);
                const std::string out = eb::detail::strip_extension(task->audioPath) + "_beats.csv";
                const std::string song = eb::detail::base_name(
                    eb::detail::strip_extension(task->audioPath));
                std::string werr;
                if (!eb::save_beats_csv(out, result->ticks, song, "essentia-ffmpeg", &werr)) {
                    result->ok = false;
                    result->error = werr;
                }
                OH_LOG_INFO(LOG_APP, "[analyse] csv -> %{public}s", out.c_str());
            } else {
                // ★ 关键：解码是成功的，这里失败说明"音频能读但算不出拍点"。
                //   必须把这条原因保留下来 —— 不能被下面 Essentia 回退的
                //   "Invalid data found" 覆盖掉，否则会把排查引向完全无关的方向。
                const std::string why =
                    result->error.empty() ? std::string("节拍检测未产出任何拍点") : result->error;
                OH_LOG_ERROR(LOG_APP,
                             "[analyse] 解码成功但节拍检测失败: %{public}s "
                             "(时长 %{public}.2fs，样本 %{public}u) —— 素材可能过短或节奏过弱",
                             why.c_str(), dec.durationSec,
                             static_cast<unsigned int>(dec.samples.size()));
                result->ok = false;
                result->error = std::string("解码成功但节拍检测失败: ") + why;
                // 解码本身没问题，就不必再让 Essentia 去读一遍文件了
                // （那条路对 m4a 必定报 Invalid data found，只会污染日志和错误信息）
            }
        } else {
            OH_LOG_ERROR(LOG_APP, "[analyse] ffmpeg 解码失败: %{public}s", dec.error.c_str());

            // ② 仅当 ffmpeg 连"解码"这一步都没成功时，才回退到 Essentia 自带的加载器。
            OH_LOG_INFO(LOG_APP, "[analyse] 回退到 eb::detect_file_to_csv（ffmpeg 解码未成功）");
            const std::string primaryErr = dec.error;
            eb::BeatResult fallback = eb::detect_file_to_csv(task->audioPath);
            if (fallback.ok) {
                *result = fallback;
            } else {
                // 两条路都失败：把两个原因都报出来，便于判断到底哪一层坏了
                std::string both = "ffmpeg: " + (primaryErr.empty() ? std::string("(无)") : primaryErr);
                both += " | essentia: ";
                both += fallback.error.empty() ? std::string("(无)") : fallback.error;
                result->ok = false;
                result->error = both;
            }
        }
    } catch (const std::exception &e) {
        result->ok = false;
        result->error = std::string("分析异常: ") + e.what();
    } catch (...) {
        result->ok = false;
        result->error = "分析异常: 未知错误";
    }

    // 落定终态：这个阶段串是"任务确实跑完了"的最后证据
    {
        std::lock_guard<std::mutex> lk(g_anaMx);
        g_anaPhase = result->ok ? "done" : "failed";
        g_anaPct   = result->ok ? 100 : -1;
        g_anaEndMs = nowMs();
        g_anaErr   = result->ok ? std::string() : result->error;
    }
    OH_LOG_INFO(LOG_APP, "[analyse] 任务结束: %{public}s", result->ok ? "OK" : "FAILED");

    napi_call_threadsafe_function(task->tsfn, result.get(), napi_tsfn_blocking);
    result.release();   // 所有权已移交给 AnalyseCallback
    napi_release_threadsafe_function(task->tsfn, napi_tsfn_release);
}

/**
 * analyzeMusicAsync(path, callback) —— 异步分析音频文件并生成 <同名>_beats.csv
 *   path     : 沙箱内音频文件的绝对路径
 *   callback : (bpm: number | null, err?: string) => void
 *              成功 → bpm 为数字；失败 → bpm 为 null 且第二个参数给出原因
 *   返回     : 无（立即返回，不阻塞主线程）
 */
static napi_value analyzeMusicAsync(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2 || args[0] == nullptr || args[1] == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[analyse] 需要 (path, callback) 两个参数");
        return nullptr;
    }

    // ---- 取路径（napi_get_value_string_utf8 会把长度写进 strLen）----
    size_t strLen = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "[analyse] 第一个参数不是字符串");
        return nullptr;
    }
    std::string path(strLen, '\0');
    napi_get_value_string_utf8(env, args[0], &path[0], strLen + 1, &strLen);
    path.resize(strLen);

    // ---- 建任务（path 由 std::string 拥有，不留裸 new[] 泄漏）----
    AnalyseTask *task = new AnalyseTask();
    task->audioPath = path;

    // 重置进度状态：开始计时，阶段先置 decode（工作线程马上会接手）
    {
        std::lock_guard<std::mutex> lk(g_anaMx);
        g_anaPhase = "decode";
        g_anaPct = 0;
        g_anaStartMs = nowMs();
        g_anaEndMs = 0;
        g_anaErr.clear();
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "MusicAnalyse", NAPI_AUTO_LENGTH, &resourceName);

    napi_status st = napi_create_threadsafe_function(env,
                                                     args[1],          // jsCallback
                                                     nullptr,
                                                     resourceName,
                                                     1,                // 队列容量：只回传一次结果
                                                     1,                // 初始线程数
                                                     task,             // finalizeData
                                                     AsyncCleanupCallback,
                                                     nullptr,
                                                     AnalyseCallback,
                                                     &task->tsfn);
    if (st != napi_ok || task->tsfn == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[analyse] 创建 threadsafe function 失败: %{public}d", (int)st);
        delete task;
        return nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[analyse] start async: %{public}s", task->audioPath.c_str());
    std::thread(AnalyseWorkerThread, task).detach();
    return nullptr;
}



static napi_value test_audio(napi_env env, napi_callback_info info){       //测试和外部库链接
    size_t argc = 1;
    napi_value result;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char buf[1024] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);
    // -----------------------
    std::string name;    
    name = std::string(buf, len);
    struct test_audio audio;       //声明构建
    audio.make_name(name); 
    //------------------------
    napi_create_string_utf8(env, audio.get_name().c_str(), audio.get_name().length(), &result);
    return result;
    
}

static napi_value speedChange(napi_env env,napi_callback_info info){
    double speed;
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_get_value_double(env, args[0], &speed);
    dataClip->accelerate = speed;
    OH_LOG_INFO(LOG_APP, "set speed to %{public}fx", speed);
    return nullptr;
}

static void TsfnFinalizeCallback(napi_env env, void *finalizeData, void *finalizeHint) {
    auto *ctx = static_cast<TsfnContext *>(finalizeData);
    if (ctx) {
        if (ctx->callbackRef) {
            napi_delete_reference(env, ctx->callbackRef);
        }
        delete ctx;
    }
    OH_LOG_INFO(LOG_APP, "[TSFN] Thread-safe function finalized");
}

static void clear(TsfnContext* ctx){
    // 先从表里摘掉：之后任何按 id 的查找都拿不到它，缩小与 JS 线程的竞态窗口。
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        g_downloadMap.erase(ctx->playerId);
    }
    // 只释放本任务自己的声卡对象（不再按下标去数组里找，那可能找的是别人的）
    AudioRenderer_BuilderRelease(ctx->renderer, ctx->builder);
    ctx->renderer = nullptr;
    ctx->builder  = nullptr;
    napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
}

// 按任务 id 取渲染器。查不到（id 非法、或已经 clear/释放）返回 nullptr，
// 调用方必须判空 —— 不要再用 id-1 去索引任何容器。
static OH_AudioRenderer* rendererForId(int id) {
    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    return (it != g_downloadMap.end()) ? it->second->renderer : nullptr;
}



static void WorkerThread(TsfnContext *ctx, char filePath[]){
    bool finished = false;
    bool quit = false;
    //============分析音频=============
    napi_acquire_threadsafe_function(ctx->tsfn);
    //work
    audio_processor audio_processor;
    audio_processor.load_audio(filePath);            //音频位置
    AudioRendererInit(ctx->builder);                 //初始化（只建 builder）

    
    // 渲染器/构建器保存在 ctx 里，不再往全局数组里塞
    
    
    
    
    // 使用源音频采样率覆盖 builder（源文件 vs 硬编码 48kHz）
    OH_AudioStreamBuilder_SetSamplingRate(ctx->builder, audio_processor.sample_rate);
    OH_AudioStreamBuilder_GenerateRenderer(ctx->builder, &ctx->renderer);   
    
    //===========LiveStretchPlayer==============
    LiveStretchPlayer player(2, audio_processor.sample_rate, audio_processor.total_frame, 1.0, 512);
    if (dataClip == nullptr) {
        dataClip = new music_data();
    }
    {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        dataClip->block_num = 0;
    }
    player.setSilenceOnPause(false);      // ★ 暂停期间不产生任何回调数据

    player.setAudioCallback([&ctx](const float* data, int frame, int ch) {
        g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);         //获取当前回调时间
        
        if(ctx->paused.load(std::memory_order_relaxed)){return;};            //暂停时丢弃本块
        int sampleCount = frame * ch;      //本块采样总数
        
        if(ctx->g_interleavedBuf.size() < sampleCount){
            ctx->g_interleavedBuf.resize(sampleCount);
        }

        // ── planar → interleaved 转换 ──
        // LiveStretchPlayer 输出为 planar: LLL...RRR...
        // AudioRenderer 需要 interleaved: LRLRLR...
        for (int c = 0; c < ch; c++) {
            for (int i = 0; i < frame; i++) {
                ctx->g_interleavedBuf[i * ch + c] = data[c * frame + i];
            }
        }
        {
            g_ringBuffer.write(ctx->g_interleavedBuf.data(), static_cast<size_t>(ctx->g_interleavedBuf.size()));
            dataClip->block_num += 1;
        }

    });
    
    player.loadAudio(audio_processor.make_planner_data(), audio_processor.total_frame);
    OH_AudioRenderer_Start(ctx->renderer);                  //开始播放

    player.play();                                     //加载音频流
    g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);         //获取当前回调时间
    //播放器循环
    while(!finished && !quit){
        player.setSpeed(dataClip->accelerate);
        if(ctx->cancelled.load()){
            quit = true;
            OH_AudioRenderer_Stop(ctx->renderer);
            clear(ctx);
            continue;

        }
        
        while (ctx->paused.load()) {
            if(ctx->cancelled.load()){
                quit = true;
                OH_AudioRenderer_Stop(ctx->renderer);
                clear(ctx);
                break;
            }
            player.pause();
            std::this_thread::sleep_for(std::chrono::milliseconds(10));       //停止忙等，释放
        }
        player.resume();
        

        
        
        
        long long last = g_lastCallbackMs.load(std::memory_order_relaxed);

        if(!finished && !quit){
            //判断结束
            //finished = true;
            if (last > 0 && !ctx->paused.load() &&
                (nowMs() - last) > 500) {    // 自然结束检测：未暂停且超过 500ms 没有回调 => 播放结束
                finished = true;
                break;
            }
            
            
        }
        /*
        if(nowMs() - last >= 200){
            last = nowMs();
            napi_call_threadsafe_function(ctx->tsfn, dataClip, napi_tsfn_nonblocking);          //回调函数
        }      
        */

        
        
    }
    if(finished){
        OH_LOG_INFO(LOG_APP, "DONE");
        OH_AudioRenderer_Stop(ctx->renderer);   // ← 原来这里传的是从未赋值的局部 audioRenderer
        clear(ctx);
        return;
    }
    
    
}



static void CallJSCallback(napi_env env, napi_value jsCallback, void *context, void *data){
    if(dataClip == nullptr)
        return;
    std::lock_guard<std::mutex> lock(g_dataMutex);
    music_data* callBackData = static_cast<music_data *>(dataClip);

    napi_value music_data = nullptr;
    napi_create_int32(env, callBackData->block_num, &music_data);
    //回调
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCallback, 1, &music_data, nullptr);
    
   // delete progressData;
}



static napi_value musicPause(napi_env env, napi_callback_info info){
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int id;
    napi_get_value_int32(env, args[0], &id);
    
    if (OH_AudioRenderer* r = rendererForId(id)) {          //暂停音频
        OH_AudioRenderer_Pause(r);
    }
    
    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->paused.store(true);
        OH_LOG_INFO(LOG_APP, "[NAPI] Music %{public}d paused", id);
    }
    return nullptr;

}

static napi_value musicResume(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int id;
    napi_get_value_int32(env, args[0], &id);
    
    // 先取消暂停标记 → WorkerThread 退出暂停循环 → player.resume() → 环形缓冲区开始被填充
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_downloadMap.find(id);
        if(it != g_downloadMap.end()) {
            it->second->paused.store(false);
        }
    }
    
    // 最后启动 AudioRenderer（此时环形缓冲区已有数据，避免 underrun）
    if (OH_AudioRenderer* r = rendererForId(id)) {
        OH_AudioRenderer_Start(r);
    }
    
    return nullptr;
}

static napi_value musicCancel(napi_env env, napi_callback_info info) {             // 先Release audio Render 再 musicCancel
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value number;
    
    int id;
 
    napi_get_value_int32(env, args[0], &id);
    if (OH_AudioRenderer* r = rendererForId(id)) {          //结束播放
        OH_AudioRenderer_Stop(r);
    }


    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->cancelled.store(true);
        it->second->paused.store(false); 
        OH_LOG_INFO(LOG_APP, "[NAPI] Download %{public}d cancelled", id);
    }

    return nullptr;
}



//音乐调度bridge



static napi_value musicPlay(napi_env env, napi_callback_info info){
    OH_LOG_INFO(LOG_APP, "[NAPI] Now loading music play");
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_value jsCallback = nullptr;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    jsCallback = args[1];
    
    size_t strLen;
    napi_status sourceStatus =  napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
    char* buf = new char[strLen + 1]();
    memset(buf, 0, strLen + 1);
    sourceStatus = napi_get_value_string_utf8(env, args[0], buf, strLen + 1, &strLen);
    
    OH_LOG_INFO(LOG_APP, "Step2 status: %{public}d, length: %{public}zu, buf[0]=%{public}d, buf=%{public}s",
    sourceStatus, strLen, buf[0], buf);
    

    //创建上下文
    auto *ctx = new TsfnContext;
    // 强引用 ArkTS 回调，防止被 GC 回收
    napi_create_reference(env, jsCallback, 1, &ctx->callbackRef);
     // 创建资源名称（调试用）
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "Music_data", NAPI_AUTO_LENGTH, &resourceName);
    //创建安全进程函数

    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        ctx->playerId = g_nextId++;
        g_downloadMap[ctx->playerId] = ctx;
        
    }
    
    napi_create_threadsafe_function(env,
                                    jsCallback,
                                    nullptr,
                                    resourceName,
                                    10,
                                    1,
                                    ctx,
                                    TsfnFinalizeCallback,      //回调销毁
                                    nullptr,
                                    CallJSCallback,       //主线程真正的回调
                                    &ctx->tsfn);
    ctx->worker = std::thread(WorkerThread, ctx, buf);
    OH_LOG_INFO(LOG_APP, "Add sub thread");
    ctx->worker.detach();
    
    napi_value progressId;
    napi_create_int32(env, ctx->playerId, &progressId);
    return progressId;
    
}





//注册函数，告诉系统有一个叫add的函数
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "Init called!");
    napi_property_descriptor desc[] = {
                // { "add" 是 ArkTS 侧调用时用的名字, Add 是上面的 C++ 函数 }
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr },
        {"squire", nullptr, Squire, nullptr,nullptr,nullptr, napi_default, nullptr},
        {"test_audio", nullptr, test_audio, nullptr, nullptr,nullptr, napi_writable, nullptr},
        {"music_play", nullptr, musicPlay, nullptr, nullptr, nullptr, napi_writable, nullptr},
        {"music_resume", nullptr, musicResume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_cancel", nullptr, musicCancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_pause", nullptr, musicPause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"changeSpeed", nullptr, speedChange, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"musicAnalyse", nullptr, analyzeMusic, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ App 请用这个：异步，不阻塞主线程，且会回传 BPM / 失败原因
        {"analyzeMusicAsync", nullptr, analyzeMusicAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 轮询分析进度：返回 JSON 字符串 {phase,pct,elapsedMs,running,error}
        {"getAnalyseStatus", nullptr, GetAnalyseStatus, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

//定义模块
static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    OH_LOG_INFO(LOG_APP, "RegisterEntryModule called!");
    napi_module_register(&demoModule);
}