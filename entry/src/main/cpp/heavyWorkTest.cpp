#include "napi/native_api.h"
#include "hilog/log.h"
#include <thread>
#include <atomic>
#include <string>
#include <chrono>
#include <unordered_map>
#include <mutex>

// ─── 下载任务上下文 ───
struct DownloadContext {
    napi_threadsafe_function tsfn = nullptr;
    napi_ref callbackRef = nullptr;

    // ★ 控制标志位（原子变量，线程安全）
    std::atomic<bool> paused{false};
    std::atomic<bool> cancelled{false};
    std::atomic<int> progress{0};

    int downloadId;     // 任务ID
    std::string url;    // 下载地址
    std::thread worker; // 工作线程
};

// ─── 全局任务管理器（用于按ID查找上下文） ───
static std::unordered_map<int, DownloadContext *> g_downloadMap;
static std::mutex g_mapMutex;
static int g_nextId = 1;

// ★ CallJsCallback：主线程执行，将进度回调给 ArkTS
void CallJsCallback(napi_env env, napi_value jsCallback, void *context, void *data) {
    int *progressData = static_cast<int *>(data);

    napi_value jsProgress;
    napi_create_int32(env, *progressData, &jsProgress);

    napi_value global;
    napi_get_global(env, &global);

    napi_call_function(env, global, jsCallback, 1, &jsProgress, nullptr);

    delete progressData;
}

// ★ TsfnFinalizeCallback：TSFN 销毁时释放资源
void TsfnFinalizeCallback(napi_env env, void *finalizeData, void *hint) {
    auto *ctx = static_cast<DownloadContext *>(finalizeData);
    if (ctx->callbackRef) {
        napi_delete_reference(env, ctx->callbackRef);
    }
    // 注意：不要在这里 delete ctx，因为 worker 线程可能还在用
    // 在 worker 线程结束后统一清理
}

// ★ 工作线程：模拟下载
void DownloadWorker(DownloadContext *ctx) {
    OH_LOG_INFO(LOG_APP, "[Worker] Download started: %s", ctx->url.c_str());

    // 模拟下载 100 个块
    for (int i = 1; i <= 100; i++) {
        // ① 检查是否被取消
        if (ctx->cancelled.load()) {
            OH_LOG_INFO(LOG_APP, "[Worker] Download cancelled");
            goto cleanup;
        }

        // ② 检查是否暂停 → 忙等待
        while (ctx->paused.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            // 在暂停期间也要检查是否被取消
            if (ctx->cancelled.load()) {
                OH_LOG_INFO(LOG_APP, "[Worker] Cancelled while paused");
                goto cleanup;
            }
        }

        // ③ 模拟下载一个块（耗时操作）
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        // ④ 更新进度
        ctx->progress.store(i);
        int *progressData = new int(i);

        napi_call_threadsafe_function(ctx->tsfn, progressData, napi_tsfn_nonblocking);
    }

cleanup:
    // ★ 释放 TSFN 引用
    napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);

    // ★ 从全局映射中移除并清理
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        g_downloadMap.erase(ctx->downloadId);
    }

    // 等待 TSFN 完全销毁后再删除上下文
    // 实际项目中可以用回调通知主线程来清理
    delete ctx;

    OH_LOG_INFO(LOG_APP, "[Worker] Thread finished");
}

// ─────────────────────────────────────────────
// ★ NAPI 接口 1：开始下载
// ArkTS: nativeModule.startDownload(url, callback) => number
// ─────────────────────────────────────────────
napi_value StartDownload(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 解析 url
    size_t strLen;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
    char *urlBuf = new char[strLen + 1];
    napi_get_value_string_utf8(env, args[0], urlBuf, strLen + 1, &strLen);
    std::string url(urlBuf);
    delete[] urlBuf;

    // 创建上下文
    auto *ctx = new DownloadContext();
    ctx->url = url;
    napi_create_reference(env, args[1], 1, &ctx->callbackRef);

    // 分配 ID
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        ctx->downloadId = g_nextId++;
        g_downloadMap[ctx->downloadId] = ctx;
    }

    // 创建 TSFN
    napi_value resourceName;
    napi_create_string_utf8(env, "DownloadTSFN", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_threadsafe_function(env, args[1], nullptr, resourceName,
                                    0,                    // 队列无限制
                                    1,                    // 初始引用计数 = 1
                                    ctx,                  // context
                                    TsfnFinalizeCallback, // finalize_cb
                                    nullptr,              // finalize_hint
                                    CallJsCallback,       // call_js_cb
                                    &ctx->tsfn);

    // 启动子线程
    ctx->worker = std::thread(DownloadWorker, ctx);
    ctx->worker.detach();

    // 返回任务 ID 给 ArkTS
    napi_value result;
    napi_create_int32(env, ctx->downloadId, &result);
    return result;
}

// ─────────────────────────────────────────────
// ★ NAPI 接口 2：暂停下载
// ArkTS: nativeModule.pauseDownload(downloadId)
// ─────────────────────────────────────────────
napi_value PauseDownload(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int id;
    napi_get_value_int32(env, args[0], &id);

    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->paused.store(true);
        OH_LOG_INFO(LOG_APP, "[NAPI] Download %d paused", id);
    }
    return nullptr;

}

// ─────────────────────────────────────────────
// ★ NAPI 接口 3：恢复下载
// ArkTS: nativeModule.resumeDownload(downloadId)
// ─────────────────────────────────────────────
napi_value ResumeDownload(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int id;
    napi_get_value_int32(env, args[0], &id);

    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->paused.store(false);
        OH_LOG_INFO(LOG_APP, "[NAPI] Download %d resumed", id);
    }

    return nullptr;
}

// ─────────────────────────────────────────────
// ★ NAPI 接口 4：取消下载
// ArkTS: nativeModule.cancelDownload(downloadId)
// ─────────────────────────────────────────────
napi_value CancelDownload(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int id;
    napi_get_value_int32(env, args[0], &id);

    std::lock_guard<std::mutex> lock(g_mapMutex);
    auto it = g_downloadMap.find(id);
    if (it != g_downloadMap.end()) {
        it->second->cancelled.store(true);
        it->second->paused.store(false); // 如果暂停中，也要唤醒
        OH_LOG_INFO(LOG_APP, "[NAPI] Download %d cancelled", id);
    }

    return nullptr;
}

// ─────────────────────────────────────────────
// ★ NAPI 接口 5：查询下载状态
// ArkTS: nativeModule.getProgress(downloadId) => number
// ─────────────────────────────────────────────
napi_value GetProgress(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int id;
    napi_get_value_int32(env, args[0], &id);

    int progress = 0;
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_downloadMap.find(id);
        if (it != g_downloadMap.end()) {
            progress = it->second->progress.load();
        }
    }

    napi_value result;
    napi_create_int32(env, progress, &result);
    return result;
}

// ─── 模块注册 ───
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startDownload", nullptr, StartDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pauseDownload", nullptr, PauseDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resumeDownload", nullptr, ResumeDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelDownload", nullptr, CancelDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProgress", nullptr, GetProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule(void) { napi_module_register(&demoModule); }