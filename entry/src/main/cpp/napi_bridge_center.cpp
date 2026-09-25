#include "EssentiaBeats.hpp"
#include "CppDataAnalyzer.hpp"   // 节拍表 CSV → 多 BPM 段落（header-only）
#include "ffmpeg_decoder.hpp"
#include "audio_process.h"
#include "napi/native_api.h"
#include "hilog/log.h"
#include "test_audio.h"
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <thread>
#include <condition_variable>
#include "LiveStretchPlayer.h"
#include "step_pipeline.hpp"   // 纯头：GaitSim → StepDetector → TempoFollower → 倍速
#include <qos/qos.h>             // OH_QoS_SetThreadQoS：把音频生产线程提到交互级
#include <cstring>
#include <algorithm>
#include <atomic>
#include <vector>
#include <memory>
#include <string>
#include <mutex>
#include <unordered_map>
#include <sstream>
#include <cmath>
// 暂时不引用 essentia，先验证编译链路没问题

// ─── 播放用环形缓冲区：无锁单生产者-单消费者（SPSC） ───
// 生产者：LiveStretchPlayer 的回调线程（只写 writePos_）
// 消费者：OH_AudioRenderer 的写数据回调线程（只写 readPos_）
// 两端各只写自己的下标、用 acquire/release 配对传递数据，因此读端绝不阻塞 ——
// 这是实时音频回调的硬要求（旧版用一把 fill_ 同时被两端读写，是数据竞争）。
// ★ 契约：任一时刻只能各有一个生产者/消费者线程；不得从第三个线程调用 reset()。
//   ★ 现在**每个会话各持一份**（见 TsfnContext::ring）：原先全局一份时，两个会话
//     会互相抢音频，接歌（尤其交叉淡化）根本不可能 —— 这正是 S1 会话化要解决的。
const size_t kRingFloats = 48000 * 2 * 6;   // 6 秒立体声 PCM 容量（抗调度抖动）
class PlaybackRingBuffer {
public:
    explicit PlaybackRingBuffer(size_t capacity = kRingFloats)
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

    // ── ★ 会话私有状态（S1 会话化）────────────────────────────
    //   ① 输出环形缓冲：每个会话一份。原来是全局一份 ⇒ 两个会话互相抢音频。
    //      userData 也改成传本 ctx，声卡回调才知道读谁的缓冲。
    PlaybackRingBuffer     ring;
    int                    blockNum = 0;    // 已产出音频块数（进度回调预留）
    //   ② 本会话的播放器指针（由 WorkerThread 用 RAII 注册/注销），
    //      供 musicGetStatus(id) 读本会话的真实位置。
    LiveStretchPlayer*     player = nullptr;
    //   ③ 播放状态：musicGetStatus(id) 按 id 查这一份。原来是一组全局量，
    //      "B 在后台准备"会把 A 的状态覆盖掉。
    std::atomic<int>       playState{0};    // 0=idle 1=loading 2=ready 3=failed 4=prepared
    std::atomic<long long> playFrames{0};
    std::atomic<int>       playRate{0};
    std::mutex             errMx;
    std::string            error;
    //   ④ ★ S2 预解码/起播分离：准备线程把"解码 + 建引擎 + 喂数据"干完后，
    //      就停在这里等 musicStart(id) 的信号。收到后只做 Start + play()，
    //      所以起播是**瞬时**的 —— 这也是接歌时"B 提前备好、到点立刻上"的前提。
    std::mutex              startMx;
    std::condition_variable startCv;
    bool                    startRequested = false;

    //   ⑤ ★ 起播延迟测量：**发 start 信号** → **第一块真音频回调**。
    //      这个差值就是接歌硬切要的"提前量"：A 必须在 B 真正出声之前才淡出，
    //      而 B 从收到信号到出声要跨一次 IPC，固定常数不准，所以直接量。
    std::atomic<long long> startSignalMs{0};
    std::atomic<long long> firstAudioMs{0};
};

// （原 music_data / dataClip 已删除：它是个裸全局指针，speedChange 里无判空解引用
//   在 dataClip 还没建好时闪退过一次（SIGSEGV@0x8）。倍速现在由 g_speed 承担，
//   block_num 移进会话。）

// ─── 全局任务管理器（用于按ID查找上下文） ───
static std::unordered_map<int, TsfnContext *> g_downloadMap;
static std::mutex g_mapMutex;
static std::mutex g_dataMutex;                        // 保护共享状态的并发访问
static int g_nextId = 1; 

// ★ 倍速改成**全局一个原子量**：任意时刻所有在响的流必须用同一个倍速
//   （两首歌的墙钟拍周期必须相同），所以它天生是"全局共享"而不是"每会话私有"。
static std::atomic<double> g_speed{1.0};
static std::atomic<long long> g_lastCallbackMs;       // 当前活动会话的最后一次回调时间
bool g_isPlaybackFinished = false;

// ─── 步频管线（"模拟演示"源）────────────────────────────────────────────
//   g_stepPipeline 是纯逻辑（可在宿主机单独验证）；
//   线程、NAPI、以及"把倍速塞回播放链路"这几件事留在本文件。
static steprun::StepPipeline g_stepPipeline;
static std::mutex           g_stepMutex;          // 保护 g_stepPipeline（JS 线程读、步频线程写）
static std::atomic<bool>    g_stepRunning{false};
static std::thread          g_stepThread;
// 当前正在播的播放器（由 WorkerThread 用 RAII 注册/注销），供管线读歌曲位置做回填
static std::atomic<LiveStretchPlayer*> g_livePlayer{nullptr};
static std::atomic<int>     g_liveSampleRate{48000};
// ─── 真实传感器源（S3）─────────────────────────────────────────────────
//   与模拟线程互斥：g_sensorRunning 为真时由 ArkTS 订阅加速度计、攒批调
//   stepSensorPush() 被动喂样，native 不起线程。
static std::atomic<bool>    g_sensorRunning{false};
static double               g_sensorT0Sec = 0.0;   // 真实源的墙钟起点（steady_clock 秒）
static double               g_sensorLastX = 0.0;   // 最近一次样点（调试/日志用）
static double               g_sensorLastY = 0.0;
static double               g_sensorLastZ = 0.0;
static double               g_sensorLastHz = 0.0;

// ─── 原生播放状态（ArkTS 用 musicGetStatus() 查询）─────────────────────
//   解决三件事：
//     ① 解码+建缓冲要好几秒，页面以前只能干等（现在能显示"加载中…"）
//     ② 解码失败以前是**静默**的（页面显示"播放中"却没声），现在能报原因
//     ③ 页面以前自己积分歌曲位置 ⇒ 与真实播放位置漂开，光效相位对不上；
//        现在能把 getInputPosition() 的真实位置回填回去
static const int kPlayIdle    = 0;
static const int kPlayLoading = 1;
static const int kPlayReady   = 2;
static const int kPlayFailed  = 3;
static const int kPlayPrepared = 4;   // S2：已解码建好，但还没起播

// ★ 播放状态（state / frames / rate / error）已经搬进 TsfnContext，
//   musicGetStatus(id) 按 id 查 —— 这样"B 在后台准备"不会覆盖 A 的状态。
//   这里只留一份"最近一次失败"的兜底：失败会话会被 clear() 销毁，
//   不留档的话页面只能看到 "gone"，真正的原因就被吃掉了。
static std::mutex             g_lastFailMx;
static int                    g_lastFailId = -1;
static std::string            g_lastFailErr;
// seek 进行中：此刻引擎被停、回调也停，播放循环的两把"结束判定"尺子都不准，要跳过
static std::atomic<bool>      g_seeking{false};

// ─── 编译优化自检 ─────────────────────────────────────────────────────
//   -O0 下 signalsmith-stretch 达不到实时（生产线程跟不上声卡 ⇒ underrun 掉音）。
//   __OPTIMIZE__ 是编译器**只在 -O1 及以上**才定义的宏，所以这一行能从
//   "跑在设备上的这个 .so 里"直接证明优化有没有开 —— 不用去猜构建配置，
//   也不会被"改了 CMakeLists 但没重新编"骗到。
//   ⚠️ 必须定义在 musicPlay / Init 之前（它们都要调）。
static void logBuildOptimization() {
#if defined(__OPTIMIZE__)
    OH_LOG_INFO(LOG_APP, "[build] 优化已开启 (__OPTIMIZE__ 已定义)：音频 DSP 可实时");
#else
    OH_LOG_WARN(LOG_APP,
        "[build] 未开优化(-O0)：音频 DSP 跟不上，会 underrun 掉音。"
        "请在 CMakeLists 给 target 加 -O2");
#endif
}



//自定义音频加载函数
static OH_AudioData_Callback_Result OnWriteData_New(
    OH_AudioRenderer* renderer,
    void* userData,
    void* buffer,
    int32_t bufferLen){
        // ★ userData 就是本会话的 TsfnContext（见 AudioRendererInit）——
        //   每个会话读自己的环形缓冲，互不干扰。
        TsfnContext* ctx = static_cast<TsfnContext*>(userData);
        if (ctx == nullptr) {
            std::memset(buffer, 0, static_cast<size_t>(bufferLen));
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        size_t floatCount = static_cast<size_t>(bufferLen) / sizeof(float);
        size_t floatsRead = ctx->ring.read(static_cast<float*>(buffer), floatCount);
        


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
static void AudioRendererInit(OH_AudioStreamBuilder*& builder, void* userData){
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
    OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, OnInterruptCb, userData);
    OH_AudioRenderer_OnErrorCallback OnErrorCb = OnError_New;
    OH_AudioStreamBuilder_SetRendererErrorCallback(builder, OnErrorCb, userData);
    OH_AudioRenderer_OnWriteDataCallback writeDataCb = OnWriteData_New;
    // ★ userData = 本会话 ctx：让写数据回调能读到**自己**那份环形缓冲
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, writeDataCb, userData);
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

/** 文件名（含扩展名） */
static std::string baseNameOf(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

/** 去掉扩展名的完整路径 */
static std::string stripExtOf(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    const size_t start = (slash == std::string::npos) ? 0 : slash + 1;
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || dot <= start) return path;
    return path.substr(0, dot);
}

/** 文件所在目录（不含末尾斜杠）；没有斜杠返回空串 */
static std::string dirNameOf(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return (slash == std::string::npos) ? std::string() : path.substr(0, slash);
}

/** 秒 → "M:SS"；超过 1 小时 → "H:MM:SS"。与 ArkTS 侧 formatDuration 格式一致 */
static std::string formatDuration(int totalSec) {
    if (totalSec < 0) totalSec = 0;
    const int h = totalSec / 3600;
    const int m = (totalSec % 3600) / 60;
    const int s = totalSec % 60;
    char buf[32];
    if (h > 0) {
        std::snprintf(buf, sizeof(buf), "%d:%02d:%02d", h, m, s);
    } else {
        std::snprintf(buf, sizeof(buf), "%d:%02d", m, s);
    }
    return std::string(buf);
}

/** 往对象上挂 string 属性 */
static void setStrProp(napi_env env, napi_value obj, const char* key, const std::string& val) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, val.c_str(), val.size(), &v);
    napi_set_named_property(env, obj, key, v);
}

/** 往对象上挂 number 属性 */
static void setNumProp(napi_env env, napi_value obj, const char* key, double val) {
    napi_value v = nullptr;
    napi_create_double(env, val, &v);
    napi_set_named_property(env, obj, key, v);
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
        // 成功：第一个参数 = 歌曲信息对象 { name, author, time, BPM }
        // 字段名刻意与 PlayListStore 的 SongJSON 对齐，上层可直接落库
        napi_value obj = nullptr;
        napi_create_object(env, &obj);
        setStrProp(env, obj, "name",   result->songTitle);
        setStrProp(env, obj, "author", result->songArtist);
        setStrProp(env, obj, "time",   result->songTime);
        setNumProp(env, obj, "BPM",    result->bpm);
        argv[0] = obj;
        argc = 1;
        OH_LOG_INFO(LOG_APP,
                    "[analyse] ok: name=\"%{public}s\" author=\"%{public}s\" "
                    "time=%{public}s BPM=%{public}.3f ticks=%{public}u",
                    result->songTitle.c_str(), result->songArtist.c_str(),
                    result->songTime.c_str(), result->bpm,
                    static_cast<unsigned int>(result->ticks.size()));
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

            // ★ 歌曲信息必须在 `*result = eb::detect(...)` **之后**填：
            //   detect() 返回的是一个新的 BeatResult，会把上面赋的值整体覆盖掉。
            //   顺序写反过一次，表现为 title/artist 恒为空。
            if (dec.title.empty()) {
                // 容器里没有 title 标签时退回文件名（去扩展名）
                result->songTitle = stripExtOf(baseNameOf(task->audioPath));
            } else {
                result->songTitle = dec.title;
            }
            result->songArtist = dec.artist;
            const int totalSec = static_cast<int>(dec.samples.size() / (size_t)dec.sampleRate);
            result->songTime = formatDuration(totalSec);
            OH_LOG_INFO(LOG_APP,
                        "[analyse] 歌曲信息: name=\"%{public}s\" author=\"%{public}s\" time=%{public}s",
                        result->songTitle.c_str(), result->songArtist.c_str(),
                        result->songTime.c_str());

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

        // 兜底补齐歌曲信息：走回退路径时 dec 是失败的、没有元数据，
        // 但仍可用文件名 + 结果样本数给出一份可用的默认值，
        // 保证回调对象里 name/time 永远不是空串。
        if (result->ok) {
            if (result->songTitle.empty()) {
                result->songTitle = stripExtOf(baseNameOf(task->audioPath));
            }
            if (result->songTime.empty()) {
                int totalSec = 0;
                if (dec.ok && dec.sampleRate > 0) {
                    totalSec = static_cast<int>(dec.samples.size() / (size_t)dec.sampleRate);
                } else if (result->sample_count > 0) {
                    // Essentia 的 sample_count 是按 44100 计的单声道样本数
                    totalSec = static_cast<int>(result->sample_count / 44100u);
                }
                result->songTime = formatDuration(totalSec);
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



// ════════════════════════════════════════════════════════════════════════
//  analyzeSongSegments(path) —— CppDataAnalyzer 链路：节拍表 CSV → BPM 段落
//
//  为什么需要它：analyzeMusicAsync 回传的 BPM 是 Essentia 的**全局**估计值；
//  这里用 CppDataAnalyzer 对同一份节拍表再做一次抗混叠归一化 + 回归，得到更规整的 BPM。
//  它读的正是 analyzeMusicAsync 刚写下的 <同名>_beats.csv，
//  所以**不用重新解码/检测**，只是把同一份节拍表再拟合一次（毫秒级）。
//
//  ⚠️ 当前是**单段模式**（Options::multi_segment = false）：整首歌只输出一个平均 BPM。
//     多段模式（每段独立 bpm_start + bpm_trend）留作后续升级。
//
//  ⚠️ 必须在 analyzeMusicAsync 成功之后调用 —— CSV 才会存在。
//
//  返回 JSON 字符串（ArkTS 侧 JSON.parse）：
//    成功 {"ok":true,"filename":"x.wav","filedir":".../Media",
//          "segments":[{"start":0.5,"end":162.15,"bpm":113.996}, ...]}
//    失败 {"ok":false,"filename":...,"filedir":...,"segments":[],"error":"..."}
//  segments 只留 start/end/bpm 三个字段（trend/r2/rmse 是拟合中间量，不落盘）。
//  ⚠️ 不再输出 firstbeat：段落的 start 就是该段第一拍，两者数值相同，属于重复字段。
//     RunDemoEngine 已改为读 start（并对旧文件里的 firstbeat 兜底），Player 按 filename 找歌。
// ════════════════════════════════════════════════════════════════════════
static napi_value analyzeSongSegments(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string filename;
    std::string filedir;
    cda::Result r;

    if (argc < 1 || args[0] == nullptr) {
        r.error = "缺少音频路径参数";
    } else {
        size_t strLen = 0;
        if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen) != napi_ok) {
            r.error = "第一个参数不是字符串";
        } else {
            std::string path(strLen, '\0');
            napi_get_value_string_utf8(env, args[0], &path[0], strLen + 1, &strLen);
            path.resize(strLen);
            filename = baseNameOf(path);
            filedir  = dirNameOf(path);
            // analyzeMusicAsync 写 CSV 的路径规则：去掉扩展名 + "_beats.csv"（同名目录）
            const std::string csv = stripExtOf(path) + "_beats.csv";
            // ★ 当前用**单段模式**：整首歌只输出一个平均 BPM（抗混叠归一化照做）。
            //   多段模式（每段独立 bpm_start + bpm_trend）是后续升级项 ——
            //   把 multi_segment 置 true 即可，上层 JSON/落盘格式不用改。
            cda::Options opt;
            opt.multi_segment = false;
            r = cda::analyze_file(csv, opt);
        }
    }

    std::ostringstream os;
    os << "{\"ok\":" << (r.ok ? "true" : "false")
       << ",\"filename\":\"" << jsonEscape(filename) << "\""
       << ",\"filedir\":\"" << jsonEscape(filedir) << "\""
       << ",\"segments\":[";
    if (r.ok) {
        for (size_t i = 0; i < r.paragraphs.size(); ++i) {
            if (i > 0) os << ',';
            const cda::Paragraph& p = r.paragraphs[i];
            // 只写 start/end/bpm：段落的 start 就是该段第一拍，firstbeat 与它等价，已废弃
            os << "{\"start\":" << p.start
               << ",\"end\":" << p.end
               << ",\"bpm\":" << p.bpm_start << "}";
        }
    }
    os << "]";
    if (!r.ok) {
        os << ",\"error\":\"" << jsonEscape(r.error) << "\"";
    }
    os << "}";

    const std::string s = os.str();
    OH_LOG_INFO(LOG_APP, "[segments] %{public}s -> %{public}u 段 (%{public}s)",
                filename.c_str(), static_cast<unsigned int>(r.paragraphs.size()),
                r.ok ? "ok" : r.error.c_str());

    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
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
    // ★ 倍速现在只是一个全局原子量，不存在"对象还没建好"的问题 ——
    //   原来这里写的是 dataClip->accelerate，dataClip 是播放线程里才 new 的，
    //   起播后上层立刻调过来就会 nullptr 解引用（SIGSEGV@0x8）。
    g_speed.store(speed, std::memory_order_relaxed);
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

/**
 * 发"起播"信号给某个会话 —— native 侧唯一的起播入口。
 * 三件事必须一起做，少一件都会出问题：
 *   ① 置位 startRequested（准备线程的谓词）
 *   ② 复位 firstAudioMs 并记下 startSignalMs（本次起播重新计时）
 *   ③ notify（如果线程还没进 wait，谓词已为真，不会漏）
 * @return 找不到会话时 false
 */
static bool signalStartById(int id) {
    TsfnContext* c = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_downloadMap.find(id);
        if (it != g_downloadMap.end()) {
            c = it->second;
        }
    }
    if (c == nullptr) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lk(c->startMx);
        c->startRequested = true;
        c->firstAudioMs.store(0, std::memory_order_relaxed);
        c->startSignalMs.store(nowMs(), std::memory_order_relaxed);
    }
    c->startCv.notify_all();
    return true;
}



static void WorkerThread(TsfnContext *ctx, char filePath[]){
    bool finished = false;
    bool quit = false;
    //============分析音频=============
    napi_acquire_threadsafe_function(ctx->tsfn);
    //work
    audio_processor audio_processor;
    audio_processor.load_audio(filePath);            //音频位置

    // ★ 解码失败必须在这里掉头：以前无论成败都继续往下走，把垃圾的
    //   total_frame / sample_rate 拿去建环形缓冲和音频流，直接闪退。
    if (audio_processor.total_frame <= 0 || audio_processor.sample_rate <= 0) {
        OH_LOG_ERROR(LOG_APP, "[play] 解码失败，放弃播放: frames=%{public}d rate=%{public}d",
                     audio_processor.total_frame, audio_processor.sample_rate);
        {
            std::lock_guard<std::mutex> lk(ctx->errMx);
            ctx->error = "解码失败（frames=" + std::to_string(audio_processor.total_frame)
                       + ", rate=" + std::to_string(audio_processor.sample_rate)
                       + "）：文件可能是空的/损坏，或该编码没编进 .so";
        }
        ctx->playState.store(kPlayFailed, std::memory_order_release);
        // clear(ctx) 之后这个会话就没了，失败原因留一份到全局兜底
        {
            std::lock_guard<std::mutex> lk(g_lastFailMx);
            g_lastFailId = ctx->playerId;
            g_lastFailErr = ctx->error;
        }
        clear(ctx);
        return;
    }

    // 解码成功：先把真实结果回报出去（音乐页据此判断"能播"）
    ctx->playFrames.store(audio_processor.total_frame, std::memory_order_relaxed);
    ctx->playRate.store(audio_processor.sample_rate, std::memory_order_relaxed);

    AudioRendererInit(ctx->builder, ctx);            //初始化（只建 builder；ctx 作为回调 userData）

    
    // 渲染器/构建器保存在 ctx 里，不再往全局数组里塞
    
    
    
    
    // 使用源音频采样率覆盖 builder（源文件 vs 硬编码 48kHz）
    OH_AudioStreamBuilder_SetSamplingRate(ctx->builder, audio_processor.sample_rate);
    OH_AudioStreamBuilder_GenerateRenderer(ctx->builder, &ctx->renderer);   
    
    //===========LiveStretchPlayer==============
    // 块大小 512 → 1024：唤醒次数减半，对调度抖动更耐受（代价是输出延迟 11ms → 21ms）
    LiveStretchPlayer player(2, audio_processor.sample_rate, audio_processor.total_frame, 1.0, 1024);

    // ★ 把音频生产线程提到交互级。否则它和 UI/JS/管线线程抢 CPU 时会被压后，
    //   声卡回调就取不到数据（日志里的 "underrun: need N, got 0"）。
    // seek 时清掉输出环形缓冲里 seek 之前的残留（最多 6 秒旧位置音频）。
    // 这个回调在 seekTo() 内部 stop() 之后被调用 —— 那一刻生产线程已停，
    // 而 musicSeek() 也把声卡 Pause 了，两端都停着，满足 reset() 的前置条件。
    player.setSeekResetCallback([ctx]() { ctx->ring.reset(); });

    player.setThreadStartCallback([]() {
        // QoS 分级尝试：QOS_USER_INTERACTIVE 在非"驻留应用"上可能被拒（实测 ret=-1），
        // 依次降级，用第一个成功的。全失败也只是少一层保险（-O2 + 6 秒缓冲才是主力）。
        static const QoS_Level kLevels[3] = {
            QOS_USER_INTERACTIVE, QOS_DEADLINE_REQUEST, QOS_USER_INITIATED
        };
        for (int i = 0; i < 3; ++i) {
            const int qr = OH_QoS_SetThreadQoS(kLevels[i]);
            if (qr == 0) {
                OH_LOG_INFO(LOG_APP, "[play] 音频线程 QoS 提升成功: level=%{public}d", static_cast<int>(kLevels[i]));
                return;
            }
        }
        OH_LOG_WARN(LOG_APP, "[play] 音频线程 QoS 各级都被拒，靠 -O2 + 缓冲余量兜底");
    });
    ctx->blockNum = 0;                   // 本会话的音频块计数（原 dataClip->block_num）

    player.setSilenceOnPause(false);      // ★ 暂停期间不产生任何回调数据

    player.setAudioCallback([&ctx](const float* data, int frame, int ch) {
        g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);         //获取当前回调时间
        // ★ 本会话第一块数据回调的时刻（只在起播后第一次记）。
        //   firstAudioMs - startSignalMs = "发信号到真出声"的延迟，页面拿它当硬切提前量。
        if (ctx->firstAudioMs.load(std::memory_order_relaxed) == 0) {
            ctx->firstAudioMs.store(nowMs(), std::memory_order_relaxed);
        }
        
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
            ctx->ring.write(ctx->g_interleavedBuf.data(),
                            static_cast<size_t>(ctx->g_interleavedBuf.size()));
            ctx->blockNum += 1;
        }

    });
    
    player.loadAudio(audio_processor.make_planner_data(), audio_processor.total_frame);
    // ★ 引擎已把数据拷进自己的环形缓冲（loadAudio 文档明确写了"调用后可以释放 data"），
    //   这里把解码缓冲还掉：162s/48k/立体声约 186MB，不还的话峰值内存翻倍 ⇒ 模拟器容易 OOM。
    audio_processor.release_buffers();

    // ═══ S2：准备完毕，等 musicStart(id) 的信号 ═══
    //   解码 + 建引擎这几秒都耗在上面了；一收到信号只做 Start + play()，
    //   所以**起播是瞬时的**（页面按播放不用再等几秒）。
    ctx->playState.store(kPlayPrepared, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "[play] 已就绪，等待 start 信号: id=%{public}d", ctx->playerId);
    {
        std::unique_lock<std::mutex> slk(ctx->startMx);
        ctx->startCv.wait(slk, [ctx]() {
            return ctx->startRequested || ctx->cancelled.load(std::memory_order_relaxed);
        });
        if (ctx->cancelled.load(std::memory_order_relaxed)) {
            OH_LOG_INFO(LOG_APP, "[play] 起播前被取消: id=%{public}d", ctx->playerId);
            slk.unlock();
            clear(ctx);      // 释放渲染器/构建器 + TSFN（播放器还没注册，无需注销）
            return;
        }
    }

    // ★ 起播延迟的计时**起点在这里**，不在"发信号"那一刻。
    //   music_play 是"先建会话、再发信号"，发信号时 worker 往往还在解码；
    //   拿发信号的时间当起点，会把整个解码耗时刻进"起播延迟"里（几秒！），
    //   页面照着这个数提前就完全错了。这里才是"开始起播动作"的那一刻。
    ctx->startSignalMs.store(nowMs(), std::memory_order_relaxed);

    OH_AudioRenderer_Start(ctx->renderer);                  //开始播放

    player.play();                                     //加载音频流
    g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);         //获取当前回调时间
    // ★ 到这里才算"就绪"（渲染器已起、音频线程已跑），页面在此之前显示"加载中…"
    ctx->playState.store(kPlayReady, std::memory_order_release);

    // ★ 把"当前正在播的播放器"暴露给步频管线，供它读歌曲位置（脚步回填用）。
    //   用 RAII：WorkerThread 无论从哪条路径退出（自然结束 / cancel / 异常）
    //   都会清掉这个指针 —— 原来 cancel 那条 continue→退出 的路径没有统一清理点。
    //   析构顺序：liveReg 后声明先析构 ⇒ 指针先清、player 后销毁。
    //   （仍有一个微秒级窗口：管线可能刚取到指针，player 就析构了；
    //     演示阶段可接受，正式版应由会话对象统一持有。）
    struct LivePlayerReg {
        TsfnContext*       ctx_;
        LiveStretchPlayer* p_;      // 自己当初登记进去的那个指针
        explicit LivePlayerReg(TsfnContext* c) : ctx_(c), p_(c->player) {
            g_liveSampleRate.store(c->playRate.load(std::memory_order_relaxed),
                                   std::memory_order_relaxed);
            g_livePlayer.store(c->player, std::memory_order_release);
        }
        ~LivePlayerReg() {
            // ★ 只在"当前登记的确实是自己"时才清空。
            //   接歌硬切时 A、B 会短暂同时活着： B 先 Start、A 过 100ms 才停。
            //   原来无条件置空 ⇒ A 退出时把 B 的登记抹掉，步频管线当场丢了驱动对象，
            //   表现为"刚切完歌倍速就不动了"。
            LiveStretchPlayer* expect = p_;
            g_livePlayer.compare_exchange_strong(expect, nullptr,
                                                 std::memory_order_release);
            if (ctx_ != nullptr) {
                ctx_->player = nullptr;
                // 退出（自然播完 / 取消）后回到 idle，页面据此冻结位置、不再回填
                ctx_->playState.store(kPlayIdle, std::memory_order_release);
            }
        }
    };
    ctx->player = &player;      // 让 musicGetStatus(id) 能读**本会话**的真实位置
    LivePlayerReg liveReg(ctx);

    //播放器循环
    while(!finished && !quit){
        player.setSpeed(g_speed.load(std::memory_order_relaxed));
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
            // ★ 暂停期间也必须刷新"最后一次回调时间"。
            //   暂停时渲染器 Pause + setSilenceOnPause(false) ⇒ 回调完全停止，
            //   这个时间戳会停在暂停前的那一刻。恢复播放后第一次循环里，
            //   下面那段「500ms 没回调就算播完」就会拿暂停前的旧时间戳比较
            //   ⇒ 立刻误判播放结束 ⇒ 停渲染器 ⇒ 全程静音。
            //   症状就是"暂停一会儿再播放，响一下就没了"。
            g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);
            std::this_thread::sleep_for(std::chrono::milliseconds(10));       //停止忙等，释放
        }
        player.resume();
        

        
        
        
        long long last = g_lastCallbackMs.load(std::memory_order_relaxed);

        if(!finished && !quit){
            // ★ 首选判据：引擎数据**真的放完了**（process() 返回 0 才会置 finished_）。
            //   ⚠️ 绝对不能用 isRunning()：seekTo() 内部第一步就是 stop()，
            //   那一瞬间 running_ 变 false，会被误判成"播放结束"，进而
            //   OH_AudioRenderer_Stop + clear(ctx) 把会话和渲染器提前释放掉
            //   —— 那正是"拖进度条就卡死/没声"的成因。
            const bool drained = player.isFinished();
            // 兜底：未暂停但长时间没有回调（正常路径下不再需要）
            const bool silentTooLong = (last > 0) && !ctx->paused.load() && ((nowMs() - last) > 500);
            // ★ seek 期间两把尺子都不准（引擎被停、回调也停），直接跳过这一轮
            if (!g_seeking.load(std::memory_order_relaxed) && (drained || silentTooLong)) {
                OH_LOG_INFO(LOG_APP, "[play] 播放结束 (drained=%{public}d silent=%{public}d)",
                            drained ? 1 : 0, silentTooLong ? 1 : 0);
                finished = true;
                break;
            }
            
            
        }
        // ★ 这里必须让出 CPU。原版是**无 sleep 的忙等**：播放期间这个循环会吃满一个核，
        //   音频生产线程（LiveStretchPlayer::audioLoop）和声卡回调抢不到时间片时，
        //   输出环形缓冲会被读空 —— 听感就是"偶尔空一下"（process() 里那段补零）。
        //   倍速是按"步频"的节奏变的（≤几 Hz），50Hz 轮询绰绰有余。
        std::this_thread::sleep_for(std::chrono::milliseconds(20));

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
    // 进度回调目前未启用（WorkerThread 里那段调用是注释掉的）。
    // dataClip 已删除，这里不再依赖任何全局播放对象。
    if (data == nullptr) {
        return;
    }

    // dataClip 已删除；这个回调的调用点本身是注释掉的（进度回传未启用），
    // 这里回 0，保证再也不碰任何全局播放对象。
    napi_value music_data = nullptr;
    napi_create_int32(env, 0, &music_data);
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
    
    // ★ 恢复播放时把"最后回调时间"刷新到现在：给自然结束检测一个干净的时间基准
    //   （否则它会拿暂停前的旧时间戳来比，暂停超过 0.5 秒就会误判为已播完）
    g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);

    // 最后启动 AudioRenderer（此时环形缓冲区已有数据，避免 underrun）
    if (OH_AudioRenderer* r = rendererForId(id)) {
        OH_AudioRenderer_Start(r);
    }
    
    return nullptr;
}

/**
 * music_seek(id, sec) —— 跳到歌曲的 sec 秒处继续播。
 *   顺序要点：先把声卡 Pause（停消费端），再 seekTo（内部停生产端 → 清环形缓冲
 *   → 从新位置重新喂入），最后 Start 声卡。这样不会先播出 seek 之前残留的那段。
 */
static napi_value musicSeek(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t id = -1;
    double  sec = 0.0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &id);
    if (argc >= 2) napi_get_value_double(env, args[1], &sec);

    LiveStretchPlayer* pl = g_livePlayer.load(std::memory_order_acquire);
    const int sr = g_liveSampleRate.load(std::memory_order_relaxed);
    if (pl == nullptr || sr <= 0 || !(sec >= 0.0)) {
        OH_LOG_WARN(LOG_APP, "[play] seek ignored: hasPlayer=%{public}d sr=%{public}d sec=%{public}.3f",
                    pl != nullptr ? 1 : 0, sr, sec);
        return nullptr;
    }

    OH_AudioRenderer* r = rendererForId(id);
    if (r != nullptr) {
        OH_AudioRenderer_Pause(r);          // 停消费端
    }

    // ★ 告诉播放循环"正在 seek，别做结束判定"：
    //   seekTo() 会 stop() 音频线程（running_ 变 false），回调也随之停止，
    //   两把判据都会误判成"播放结束"并把会话释放掉。
    g_seeking.store(true, std::memory_order_release);
    const long long frame = static_cast<long long>(sec * static_cast<double>(sr));
    const bool ok = pl->seekTo(frame);
    g_seeking.store(false, std::memory_order_release);

    // seek 期间没有回调，刷新时间基准，免得恢复瞬间被 500ms 兜底判据误判
    g_lastCallbackMs.store(nowMs(), std::memory_order_relaxed);

    if (r != nullptr) {
        // ★ 关键：丢掉音频服务里**已经排队**的那一段（约等于一次回调的量，~93ms）。
        //   Pause 只是"停住"，Start 之后服务会先把这段**旧位置**的数据吐出来 ——
        //   听感就是"先响一小段拖动前的音频，才到新位置"。
        //   我们清的是自己那份环形缓冲，管不到服务内部的队列，所以必须 Flush。
        const OH_AudioStream_Result fr = OH_AudioRenderer_Flush(r);
        if (fr != AUDIOSTREAM_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "[play] seek: Flush 返回 %{public}d（非 0 = 旧数据没清掉）",
                        static_cast<int>(fr));
        }
        OH_AudioRenderer_Start(r);          // 重新开始消费
    }

    OH_LOG_INFO(LOG_APP, "[play] seek -> %{public}.3fs (frame=%{public}lld) %{public}s",
                sec, frame, ok ? "OK" : "FAILED");
    return nullptr;
}

/**
 * music_set_speed(id, speed) —— 设置倍速。
 *   倍速是**全局**的：同时出声的所有流必须共用同一个倍速（两首歌的墙钟拍周期
 *   必须相同），所以它天生共享；id 只用来校验会话存在并打日志。
 */
static napi_value musicSetSpeed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    double  speed = 1.0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &id);
    if (argc >= 2) napi_get_value_double(env, args[1], &speed);
    if (!(speed > 0.0)) {
        return nullptr;
    }
    if (rendererForId(id) == nullptr) {
        return nullptr;         // 会话不在，忽略
    }
    g_speed.store(speed, std::memory_order_relaxed);
    return nullptr;
}

/**
 * music_set_volume(id, volume, rampMs) —— 设置本会话的输出音量（可带斜坡）。
 *
 * ★ 这是交叉淡化（S4）的钥匙：每个 OH_AudioRenderer 各自是一条音频流，
 *   系统负责混音 —— 只要给 A、B 各来一条音量斜坡就是淡化，**不用自写 Mixer**。
 *   rampMs > 0 走 SetVolumeWithRamp（平滑过渡），= 0 走 SetVolume（立即）。
 */
static napi_value musicSetVolume(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    double  volume = 1.0;
    int32_t rampMs = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &id);
    if (argc >= 2) napi_get_value_double(env, args[1], &volume);
    if (argc >= 3) napi_get_value_int32(env, args[2], &rampMs);

    OH_AudioRenderer* r = rendererForId(id);
    if (r == nullptr) {
        return nullptr;
    }
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    const OH_AudioStream_Result res = (rampMs > 0)
        ? OH_AudioRenderer_SetVolumeWithRamp(r, static_cast<float>(volume), rampMs)
        : OH_AudioRenderer_SetVolume(r, static_cast<float>(volume));
    OH_LOG_INFO(LOG_APP, "[play] volume id=%{public}d v=%{public}.3f ramp=%{public}dms -> %{public}d",
                id, volume, rampMs, static_cast<int>(res));
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


    TsfnContext* dead = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_downloadMap.find(id);
        if (it != g_downloadMap.end()) {
            it->second->cancelled.store(true);
            it->second->paused.store(false);
            dead = it->second;
            OH_LOG_INFO(LOG_APP, "[NAPI] Download %{public}d cancelled", id);
        }
    }
    // ★ 若这个会话还停在"已就绪、等 start 信号"的等待里，叫醒它让它自己退出
    if (dead != nullptr) {
        dead->startCv.notify_all();
    }

    return nullptr;
}



//音乐调度bridge



// 建会话 + 起准备线程。autoStart=false 时不发 start 信号，停在"已就绪"等 musicStart(id)。
static napi_value playImpl(napi_env env, napi_callback_info info, bool autoStart) {
    OH_LOG_INFO(LOG_APP, "[NAPI] Now loading music play");
    logBuildOptimization();
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

        // 新任务开始：状态复位为"加载中"
        ctx->playFrames.store(0, std::memory_order_relaxed);
        ctx->playRate.store(0, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> elk(ctx->errMx);
            ctx->error.clear();
        }
        ctx->playState.store(kPlayLoading, std::memory_order_release);
        
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
    // （原"在主线程先建 dataClip"已不需要：倍速现在是全局原子量 g_speed，
    //   不存在对象尚未创建的问题。）

    ctx->worker = std::thread(WorkerThread, ctx, buf);
    OH_LOG_INFO(LOG_APP, "Add sub thread");
    ctx->worker.detach();
    
    // ★ S2：music_play 走 autoStart=true，建完会话立刻起播；
    //   music_prepare 走 false，会话停在"已就绪、不出声"，等 musicStart(id)。
    //   这里必然有 ctx，直接置位 + 唤醒（唤醒晚于置位也没关系，谓词已经为真）。
    if (autoStart) {
        signalStartById(ctx->playerId);
        OH_LOG_INFO(LOG_APP, "[play] start 信号 -> id=%{public}d", ctx->playerId);
    }

    napi_value progressId;
    napi_create_int32(env, ctx->playerId, &progressId);
    return progressId;
    
}





//注册函数，告诉系统有一个叫add的函数
// ════════════════════════════════════════════════════════════════════════
//  步频管线（模拟演示源）
//
//    stepPipelineStart(scenario, songBpm, firstBeat)
//        → 起一条 50Hz 线程：GaitSim → StepDetector → TempoFollower
//        → 倍速 → dataClip->accelerate
//    WorkerThread 每轮读 dataClip->accelerate 并 player.setSpeed()，
//    倍速就这样驱动了真实播放。
//
//    「真实传感器」那条路以后只需把"喂样"换成 ArkTS 上报的三轴，
//    管线本身（回填 / 跟随 / 限幅）一行都不用动。
// ════════════════════════════════════════════════════════════════════════

static std::string stepStatusJson() {
    std::lock_guard<std::mutex> lk(g_stepMutex);
    const steprun::Status st = g_stepPipeline.status();
    std::ostringstream os;
    os << "{\"running\":" << ((g_stepRunning.load() || g_sensorRunning.load()) ? "true" : "false")
       << ",\"cadenceSpm\":" << st.cadenceSpm
       << ",\"multiplier\":" << st.multiplier
       << ",\"targetBpm\":" << st.targetBpm
       << ",\"steps\":" << static_cast<unsigned long long>(st.steps)
       << ",\"followState\":" << st.followState
       << ",\"lastStepSec\":" << st.lastStepSec
       << ",\"songSec\":" << st.songSec
       << ",\"mode\":" << st.mode
       << ",\"phaseOffset\":" << st.phaseOffset
       << ",\"delta\":" << st.delta
       << ",\"hasPlayer\":" << (g_livePlayer.load() != nullptr ? "true" : "false")
       << "}";
    return os.str();
}

static void StepWorkerThread() {
    const double dt = 1.0 / 50.0;          // 与 GaitSim 的 sample_rate_hz 一致
    while (g_stepRunning.load(std::memory_order_relaxed)) {
        // 读当前歌曲位置（秒）。没有在播就是 0，跟随器会自然退回纯调速。
        double songPos = 0.0;
        LiveStretchPlayer* pl = g_livePlayer.load(std::memory_order_acquire);
        if (pl != nullptr) {
            const int sr = g_liveSampleRate.load(std::memory_order_relaxed);
            if (sr > 0) {
                songPos = static_cast<double>(pl->getInputPosition()) / static_cast<double>(sr);
            }
        }

        double mult = 1.0;
        {
            std::lock_guard<std::mutex> lk(g_stepMutex);
            g_stepPipeline.tick(dt, songPos);
            mult = g_stepPipeline.status().multiplier;
        }

        // 把倍速塞进现有播放链路：WorkerThread 每轮读 accelerate 并 player.setSpeed()。
        // 把倍速塞进播放链路。现在就是一个全局原子量，不需要任何判空 ——
        // 播放循环每轮读 g_speed 并 player.setSpeed()。
        g_speed.store(mult, std::memory_order_relaxed);

        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

static napi_value stepPipelineStart(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t scenario = 0;
    double  songBpm = 150.0;
    double  firstBeat = 0.0;
    int32_t mode = 0;          // 0 = FOLLOW（动态模式）  1 = PRESET（恒速/曲线）
    double  targetBpm = 0.0;   // PRESET 用：规定目标步频
    if (argc >= 1) napi_get_value_int32(env, args[0], &scenario);
    if (argc >= 2) napi_get_value_double(env, args[1], &songBpm);
    if (argc >= 3) napi_get_value_double(env, args[2], &firstBeat);
    if (argc >= 4) napi_get_value_int32(env, args[3], &mode);
    if (argc >= 5) napi_get_value_double(env, args[4], &targetBpm);

    if (g_stepRunning.load()) {
        OH_LOG_INFO(LOG_APP, "[step] already running, ignore start");
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> lk(g_stepMutex);
        // 顺序要紧：先选控制律（会清掉相位状态）→ 重置 → 设歌 → 设规定步频
        g_stepPipeline.setMode(mode);
        g_stepPipeline.setScenario(scenario);
        g_stepPipeline.reset();
        g_stepPipeline.setSong(songBpm, firstBeat);
        g_stepPipeline.setPresetTargetBpm(targetBpm);
    }
    g_stepRunning.store(true);
    g_stepThread = std::thread(StepWorkerThread);
    OH_LOG_INFO(LOG_APP, "[step] started: mode=%{public}d scenario=%{public}d songBpm=%{public}.1f "
                         "firstBeat=%{public}.2f targetBpm=%{public}.1f",
                mode, scenario, songBpm, firstBeat, targetBpm);
    return nullptr;
}

/** PRESET 模式的规定目标步频（曲线推进 / 恒速滑条改动时调用） */
static napi_value stepPipelineSetTargetBpm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double bpm = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &bpm);
    std::lock_guard<std::mutex> lk(g_stepMutex);
    g_stepPipeline.setPresetTargetBpm(bpm);
    return nullptr;
}

/**
 * stepPipelineSetChaseDelayWindow(sec) —— 动态模式「起步延迟校正」窗口（秒）。
 *   窗口内 CHASE 走 TempoFollower 的 delayChase（不调歌曲速度，只平移 perfect 窗口
 *   去框住脚步，无听感变速）；窗口过后自动回到普通相位调整。0 = 关闭。默认 50 秒。
 */
static napi_value stepPipelineSetChaseDelayWindow(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double sec = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &sec);
    std::lock_guard<std::mutex> lk(g_stepMutex);
    g_stepPipeline.setChaseDelayWindow(sec);
    OH_LOG_INFO(LOG_APP, "[step] chase delay window = %{public}.1fs", sec);
    return nullptr;
}

static napi_value stepPipelineStop(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    g_sensorRunning.store(false);          // 真实源也一起停
    if (g_stepRunning.load()) {
        g_stepRunning.store(false);
        if (g_stepThread.joinable()) {
            g_stepThread.join();
        }
        OH_LOG_INFO(LOG_APP, "[step] stopped");
    }
    return nullptr;
}

static napi_value stepPipelineSetScenario(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t scenario = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &scenario);
    std::lock_guard<std::mutex> lk(g_stepMutex);
    g_stepPipeline.setScenario(scenario);
    return nullptr;
}

static napi_value stepPipelineStatus(napi_env env, napi_callback_info info) {
    (void)info;
    const std::string s = stepStatusJson();
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

// ════════════════════════════════════════════════════════════════════════
//  S3：真实传感器源（被动喂样，native 不起线程）
//    ArkTS 用 @kit.SensorServiceKit 订阅加速度计（m/s²，含重力），攒一批
//    （~100ms）调 stepSensorPush()；这里复用同一条 StepDetector → TempoFollower 链路。
//    ★ 与模拟源互斥；stepSensorStart 会先停掉模拟线程。
// ════════════════════════════════════════════════════════════════════════

/** 单调墙钟（秒）：真实源的时间基准，避免受系统时间调整影响 */
static double steadyNowSec() {
    return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

/**
 * stepSensorStart(songBpm, firstBeatSec, mode, targetBpm)
 *   配置真实源管线并进入"被动喂样"状态；不创建模拟线程。
 */
static napi_value stepSensorStart(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double  songBpm = 150.0;
    double  firstBeat = 0.0;
    int32_t mode = 0;
    double  targetBpm = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &songBpm);
    if (argc >= 2) napi_get_value_double(env, args[1], &firstBeat);
    if (argc >= 3) napi_get_value_int32(env, args[2], &mode);
    if (argc >= 4) napi_get_value_double(env, args[3], &targetBpm);

    // 模拟线程与真实源互斥
    if (g_stepRunning.load()) {
        g_stepRunning.store(false);
        if (g_stepThread.joinable()) {
            g_stepThread.join();
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_stepMutex);
        // 顺序与 stepPipelineStart 一致：先选控制律（会清相位）→ 重置 → 设歌 → 规定步频
        g_stepPipeline.setMode(mode);
        g_stepPipeline.reset();
        g_stepPipeline.setSong(songBpm, firstBeat);
        g_stepPipeline.setPresetTargetBpm(targetBpm);
    }
    g_sensorT0Sec = steadyNowSec();
    g_sensorRunning.store(true);
    OH_LOG_INFO(LOG_APP, "[step] sensor source started: mode=%{public}d songBpm=%{public}.1f "
                         "firstBeat=%{public}.2f targetBpm=%{public}.1f",
                mode, songBpm, firstBeat, targetBpm);
    return nullptr;
}

/**
 * stepSensorPush(samples, n, rateHz)
 *   samples: 一维数组，长度 >= 3n，布局 [x0,y0,z0, x1,y1,z1, ...]，单位 m/s²、含重力。
 *   ★ 刻意用普通 number[] + napi_get_element，而不是 Float32Array：typed array 的
 *     data 指针/长度在这条 ArkTS→NAPI 路上出现过脏值（读出 1e31 级的数据），
 *     普通数组逐个取值不依赖任何指针/内存假设，最稳。
 */
static napi_value stepSensorPush(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3 || !g_sensorRunning.load() || args[0] == nullptr) {
        return nullptr;
    }

    uint32_t len = 0;
    if (napi_get_array_length(env, args[0], &len) != napi_ok) {
        return nullptr;
    }
    int32_t n = 0;
    napi_get_value_int32(env, args[1], &n);
    double rateHz = 50.0;
    napi_get_value_double(env, args[2], &rateHz);
    if (n <= 0 || !(rateHz > 1.0) || static_cast<uint32_t>(n) * 3u > len) {
        return nullptr;
    }

    const double now = steadyNowSec() - g_sensorT0Sec;

    // 歌曲位置：从"当前在播的播放器"读真实输入位置（没有在播就是 0）
    double songSec = 0.0;
    LiveStretchPlayer* pl = g_livePlayer.load(std::memory_order_acquire);
    const int sr = g_liveSampleRate.load(std::memory_order_relaxed);
    if (pl != nullptr && sr > 0) {
        songSec = static_cast<double>(pl->getInputPosition()) / static_cast<double>(sr);
    }

    double magMin = 1e9, magMax = -1e9, magSum = 0.0;
    double lastX = 0.0, lastY = 0.0, lastZ = 0.0;
    steprun::Status st;
    {
        std::lock_guard<std::mutex> lk(g_stepMutex);
        g_stepPipeline.sampleSongClock(now, songSec);
        for (int32_t i = 0; i < n; ++i) {
            double v[3] = {0.0, 0.0, 0.0};
            for (int k = 0; k < 3; ++k) {
                napi_value el = nullptr;
                if (napi_get_element(env, args[0], static_cast<uint32_t>(i * 3 + k), &el) != napi_ok
                    || el == nullptr) {
                    continue;
                }
                napi_get_value_double(env, el, &v[k]);
            }
            const double t = now - static_cast<double>(n - 1 - i) / rateHz;
            g_stepPipeline.pushSample(v[0], v[1], v[2], t);
            const double mag = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
            if (mag < magMin) magMin = mag;
            if (mag > magMax) magMax = mag;
            magSum += mag;
            lastX = v[0]; lastY = v[1]; lastZ = v[2];
        }
        st = g_stepPipeline.status();
        g_speed.store(st.multiplier, std::memory_order_relaxed);
    }

    g_sensorLastX = lastX;
    g_sensorLastY = lastY;
    g_sensorLastZ = lastZ;
    g_sensorLastHz = rateHz;
    static std::atomic<int> pushCount{0};
    if ((pushCount.fetch_add(1) % 25) == 0) {
        OH_LOG_INFO(LOG_APP, "[step] sensor: n=%{public}d last=%{public}.3f/%{public}.3f/%{public}.3f "
                             "|a| min=%{public}.2f mean=%{public}.2f max=%{public}.2f "
                             "cadence=%{public}.1f steps=%{public}llu mult=%{public}.3f",
                    static_cast<int>(n), lastX, lastY, lastZ,
                    magMin, magSum / static_cast<double>(n), magMax,
                    st.cadenceSpm, static_cast<unsigned long long>(st.steps), st.multiplier);
    }
    return nullptr;
}

static napi_value stepSensorStop(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    g_sensorRunning.store(false);
    {
        std::lock_guard<std::mutex> lk(g_stepMutex);
        g_stepPipeline.reset();
    }
    OH_LOG_INFO(LOG_APP, "[step] sensor source stopped");
    return nullptr;
}

// ════════════════════════════════════════════════════════════════════════
//  musicGetStatus(id) —— 原生播放状态查询
//    返回 JSON 字符串：
//      {"ok":bool,"state":"idle|loading|ready|failed|gone",
//       "frames":number,"rate":number,"posSec":number,"error":string}
//    posSec 来自 getInputPosition()，是**真实**的歌曲原始时间轴位置，
//    页面拿它回填，就不会再因为自己积分而把拍相位漂掉。
// ════════════════════════════════════════════════════════════════════════
static napi_value musicGetStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t id = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &id);
    }

    // ★ 按 id 查**本会话**的状态（不是全局）：这样"B 在后台准备"不会覆盖 A。
    TsfnContext* c = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mapMutex);
        auto it = g_downloadMap.find(id);
        if (it != g_downloadMap.end()) {
            c = it->second;
        }
    }

    static const char* kStateNames[5] = {"idle", "loading", "ready", "failed", "prepared"};
    bool      sameTask = (c != nullptr);
    int       state    = kPlayIdle;
    int       rate     = 0;
    long long frames   = 0;
    std::string err;

    if (sameTask) {
        state  = c->playState.load(std::memory_order_acquire);
        rate   = c->playRate.load(std::memory_order_relaxed);
        frames = c->playFrames.load(std::memory_order_relaxed);
        if (state == kPlayFailed) {
            std::lock_guard<std::mutex> lk(c->errMx);
            err = c->error;
        }
    } else {
        // 会话已不在。如果是"解码失败后被 clear 掉的"，从失败档里把原因捞回来，
        // 否则页面只能看到 "gone"，真正的原因就被吃掉了。
        std::lock_guard<std::mutex> lk(g_lastFailMx);
        if (g_lastFailId == id) {
            sameTask = true;
            state    = kPlayFailed;
            err      = g_lastFailErr;
        }
    }
    const std::string stateName = sameTask ? std::string(kStateNames[state % 5]) : std::string("gone");

    double posSec = 0.0;
    if (c != nullptr && c->player != nullptr && rate > 0) {
        posSec = static_cast<double>(c->player->getInputPosition()) / static_cast<double>(rate);
    }

    // ★ 真实音频总长（秒）= 解码帧数 ÷ 采样率。
    //   比 song_data.json 里的 end 可靠 —— 那是分析区间，这是文件真正的结尾。
    //   自动接歌就靠 posSec 和它比："还剩多少"。
    const double durSec = (rate > 0)
        ? (static_cast<double>(frames) / static_cast<double>(rate)) : 0.0;

    // ★ 起播延迟（毫秒）= 发 start 信号 → 第一块真音频回调。
    //   硬切时"提前多久按 start"就填它（-1 = 还没测到 / 还没起播）。
    long long startLatencyMs = -1;
    if (c != nullptr) {
        const long long s0 = c->startSignalMs.load(std::memory_order_relaxed);
        const long long s1 = c->firstAudioMs.load(std::memory_order_relaxed);
        if (s0 > 0 && s1 >= s0) {
            startLatencyMs = s1 - s0;
        }
    }

    std::ostringstream os;
    os << "{\"ok\":" << (sameTask ? "true" : "false")
       << ",\"state\":\"" << stateName << "\""
       << ",\"frames\":" << frames
       << ",\"rate\":" << rate
       << ",\"posSec\":" << posSec
       << ",\"durSec\":" << durSec
       << ",\"startLatencyMs\":" << startLatencyMs
       << ",\"error\":\"" << jsonEscape(err) << "\"}";

    const std::string s = os.str();
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

// ═════════════════════════════════════════════════════════════════════
//   S2：预解码（prepare）与起播（start）分离
//
//   music_play(path, cb)     = prepare + start（旧接口，兼容）
//   music_prepare(path, cb)  = 只解码建引擎，返回 id，不出声
//   music_start(id)          = 对已就绪的会话发信号，瞬时起播
//
//   接歌场景：B 的 prepare 提前发出去耗几秒解码，等播到 A 的交接点
//   只调 music_start(B) —— 那一瞬间只做 Start + play()，就没有 IPC 空档。
// ═════════════════════════════════════════════════════════════════════

static napi_value musicPlay(napi_env env, napi_callback_info info) {
    return playImpl(env, info, true);      // 旧接口：建会话 + 立刻起播
}

static napi_value musicPrepare(napi_env env, napi_callback_info info) {
    // 复用 playImpl 的解析逻辑，只是不发 start 信号（autoStart=false）。
    return playImpl(env, info, false);
}

static napi_value musicStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = -1;
    if (argc >= 1 && args[0] != nullptr) {
        napi_get_value_int32(env, args[0], &id);
    }
    if (!signalStartById(id)) {
        OH_LOG_ERROR(LOG_APP, "[play] music_start: 找不到会话 id=%{public}d", id);
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "[play] music_start 信号 -> id=%{public}d", id);
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "Init called!");
    logBuildOptimization();
    napi_property_descriptor desc[] = {
                // { "add" 是 ArkTS 侧调用时用的名字, Add 是上面的 C++ 函数 }
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr },
        {"squire", nullptr, Squire, nullptr,nullptr,nullptr, napi_default, nullptr},
        {"test_audio", nullptr, test_audio, nullptr, nullptr,nullptr, napi_writable, nullptr},
        {"music_play", nullptr, musicPlay, nullptr, nullptr, nullptr, napi_writable, nullptr},
        {"music_prepare", nullptr, musicPrepare, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_start", nullptr, musicStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_resume", nullptr, musicResume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_cancel", nullptr, musicCancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_seek", nullptr, musicSeek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_set_speed", nullptr, musicSetSpeed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_set_volume", nullptr, musicSetVolume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"music_pause", nullptr, musicPause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"changeSpeed", nullptr, speedChange, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"musicAnalyse", nullptr, analyzeMusic, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ App 请用这个：异步，不阻塞主线程，且会回传 BPM / 失败原因
        {"analyzeMusicAsync", nullptr, analyzeMusicAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ CppDataAnalyzer 链路：读 <同名>_beats.csv 拟合多 BPM 段落，返回 JSON 字符串
        {"analyzeSongSegments", nullptr, analyzeSongSegments, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 轮询分析进度：返回 JSON 字符串 {phase,pct,elapsedMs,running,error}
        {"getAnalyseStatus", nullptr, GetAnalyseStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ 步频管线（模拟演示源）：起 / 停 / 换场景 / 查状态(JSON)
        {"stepPipelineStart", nullptr, stepPipelineStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepPipelineStop", nullptr, stepPipelineStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepPipelineSetScenario", nullptr, stepPipelineSetScenario, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepPipelineStatus", nullptr, stepPipelineStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepPipelineSetTargetBpm", nullptr, stepPipelineSetTargetBpm, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 动态模式起步延迟校正窗口（秒）：窗口内 CHASE 不调速度，只平移 perfect 窗口
        {"stepPipelineSetChaseDelayWindow", nullptr, stepPipelineSetChaseDelayWindow, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ S3：真实传感器源（被动喂样）
        {"stepSensorStart", nullptr, stepSensorStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepSensorPush", nullptr, stepSensorPush, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stepSensorStop", nullptr, stepSensorStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ★ 原生播放状态：加载中/就绪/失败 + 真实歌曲位置
        {"musicGetStatus", nullptr, musicGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr}
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