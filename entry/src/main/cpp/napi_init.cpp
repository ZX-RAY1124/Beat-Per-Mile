#include "audio_process.h"
#include "napi/native_api.h"
#include "hilog/log.h"
#include "test_audio.h"
// 暂时不引用 essentia，先验证编译链路没问题
// #include "essentia/essentia.h"

// 自定义上下文结构体
struct TsfnContext {
    napi_ref callbackRef = nullptr; // 强引用 ArkTS 回调
};

enum ParamStatus{
    ONPLAY,
    PAUSE,
    DONE,
};

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
    struct test_audio audio(2, 44100, 65536, 1.0, 512);       //声明构建
    audio.make_name(name); 
    //------------------------
    napi_create_string_utf8(env, audio.get_name().c_str(), audio.get_name().length(), &result);
    return result;
    
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

static void WorkerThread(TsfnContext *ctx, napi_threadsafe_function tsfn){
    
    napi_acquire_threadsafe_function(tsfn);
    //work
    audio_processor audio_processor;
    audio_processor.load_audio("");            //音频位置
    struct test_audio audio_player(2, 44100, 65536, 1.0, 512);       //声明构建
    audio_player.load_audio(audio_processor.make_planner_data(), audio_processor.total_frame);
    auto *dataPack = new music_data();
    while(audio_player._has_stop){
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        audio_player.play(*dataPack);
        napi_status status = napi_call_threadsafe_function(tsfn, dataPack, napi_tsfn_nonblocking);

        if (status == napi_queue_full) {
            OH_LOG_WARN(LOG_APP, "[TSFN] Queue full, dropping progress %.2f",*dataPack->data);
            delete dataPack; // 投递失败要手动释放
        }
    }
    
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);

    
    
    
}

static void CallJSCallback(napi_env env, napi_value jsCallback, void *context, void *data){
    if(data == nullptr)
        return;
    auto *progressData = static_cast<music_data *>(data);

    napi_value music_data = nullptr;
    napi_create_double(env, *(progressData->data), &music_data);
    
    //回调
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 1, &music_data, nullptr);
    
    delete progressData;
}

//音乐调度bridge



static napi_value music_playing(napi_env env, napi_callback_info info){
    size_t argc = 1;
    napi_value jsCallback = nullptr;
    napi_get_cb_info(env, info, &argc, &jsCallback, nullptr, nullptr);
    //创建上下文
    auto *ctx = new TsfnContext;
    // 强引用 ArkTS 回调，防止被 GC 回收
    napi_create_reference(env, jsCallback, 1, &ctx->callbackRef);
     // 创建资源名称（调试用）
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "Music_data", NAPI_AUTO_LENGTH, &resourceName);
    //创建安全进程函数
    
    napi_threadsafe_function tsfn = nullptr;
    napi_create_threadsafe_function(env,
                                    jsCallback,
                                    nullptr,
                                    resourceName,
                                    10,
                                    1,
                                    ctx,
                                    TsfnFinalizeCallback,      //回调销毁（改）
                                    nullptr,
                                    CallJSCallback,       //主线程真正的回调
                                    &tsfn);
    
    std::thread workThread(WorkerThread, ctx, tsfn);
    workThread.detach();
    return nullptr;
    
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
        {"test_audio", nullptr, test_audio, nullptr, nullptr,nullptr, napi_writable, nullptr}
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