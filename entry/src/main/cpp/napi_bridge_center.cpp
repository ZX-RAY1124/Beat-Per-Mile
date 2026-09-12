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
// 暂时不引用 essentia，先验证编译链路没问题

// ─── 播放用环形缓冲区：实现真正的流式生产者-消费者 ───
class PlaybackRingBuffer {
public:
    PlaybackRingBuffer(size_t capacity) : buffer_(capacity + 1), capacity_(capacity + 1) {}    //留一格区分满和空

    /** 生产者写入数据，返回实际写入的 float 个数 */
    size_t write(const float* data, size_t count) {
        size_t space = capacity_ - fill_;
        size_t toWrite = std::min(count, space);
        for (size_t i = 0; i < toWrite; i++) {
            buffer_[writePos_] = data[i];
            writePos_ = (writePos_ + 1) % capacity_;
        }
        fill_ += toWrite;
        return toWrite;
    }

    /** 消费者读取数据，返回实际读取的 float 个数 */
    size_t read(float* out, size_t count) {
        size_t toRead = std::min(count, fill_);
        for (size_t i = 0; i < toRead; i++) {
            out[i] = buffer_[readPos_];
            readPos_ = (readPos_ + 1) % capacity_;
        }
        fill_ -= toRead;
        return toRead;
    }

    size_t available() const { return fill_; }
    size_t capacity() const { return capacity_; }
    bool empty() const { return fill_ == 0; }
    bool full() const { return fill_ == capacity_; }

    void reset() {
        readPos_ = 0;
        writePos_ = 0;
        fill_ = 0;
    }

private:
    std::vector<float> buffer_;
    size_t capacity_;
    size_t readPos_ = 0;
    size_t writePos_ = 0;
    size_t fill_ = 0;
};

// ════════════════════════════════════════════

static OH_AudioRenderer* audioRenderer;
static OH_AudioStreamBuilder* builder;                   //音频流构建器

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

static napi_value AudioRendererInit(napi_env env, napi_callback_info info){
    OH_LOG_INFO(LOG_APP, "Now Add AudioRenderer");
    if (audioRenderer){            //事先清理
        OH_AudioRenderer_Release(audioRenderer);
        OH_AudioStreamBuilder_Destroy(builder);
        
        audioRenderer = nullptr;
        builder = nullptr;
    }
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
    return nullptr;
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

static long long nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
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
    napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        g_downloadMap.erase(ctx->playerId);
    }
}



static void WorkerThread(TsfnContext *ctx, char filePath[]){
    bool finished = false;
    bool quit = false;
    //============分析音频=============
    napi_acquire_threadsafe_function(ctx->tsfn);
    //work
    audio_processor audio_processor;
    audio_processor.load_audio(filePath);            //音频位置
    
    // 使用源音频采样率覆盖 builder（源文件 vs 硬编码 48kHz）
    OH_AudioStreamBuilder_SetSamplingRate(builder, audio_processor.sample_rate);
    OH_AudioStreamBuilder_GenerateRenderer(builder, &audioRenderer);   
    
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
    
    player.play();                                     //加载音频流
    OH_AudioRenderer_Start(audioRenderer);            //开始播放
    //播放器循环
    while(!finished && !quit){
        player.setSpeed(dataClip->accelerate);
        if(ctx->cancelled.load()){
            quit = true;
            OH_AudioRenderer_Stop(audioRenderer);
            clear(ctx);
            continue;

        }
        
        while (ctx->paused.load()) {
            if(ctx->cancelled.load()){
                quit = true;
                OH_AudioRenderer_Stop(audioRenderer);
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
        OH_AudioRenderer_Stop(audioRenderer);
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
    
    OH_AudioRenderer_Pause(audioRenderer);           //暂停音频
    
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
    OH_AudioRenderer_Start(audioRenderer);
    
    return nullptr;
}

static napi_value musicCancel(napi_env env, napi_callback_info info) {             // 先Release audio Render 再 musicCancel
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int id;
    OH_AudioRenderer_Stop(audioRenderer);         //结束播放
 
    napi_get_value_int32(env, args[0], &id);

    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->cancelled.store(true);
        it->second->paused.store(false); 
        OH_LOG_INFO(LOG_APP, "[NAPI] Download %{public}d cancelled", id);
    }

    return nullptr;
}

static napi_value AudioRendererRelease(napi_env env, napi_callback_info info){
    if(audioRenderer){
        OH_AudioRenderer_Release(audioRenderer);
        OH_AudioStreamBuilder_Destroy(builder);
        audioRenderer = nullptr;
        builder = nullptr;
    }
    //这里释放文件进程
    
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
        {"audioRendererInit", nullptr, AudioRendererInit, nullptr, nullptr, nullptr, napi_writable, nullptr},
        {"audioRendererRelease", nullptr, AudioRendererRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"changeSpeed", nullptr, speedChange, nullptr, nullptr, nullptr, napi_default, nullptr}
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