/*
 * LiveStretchPlayer.h
 * 基于 TimeStretchEngine 的播放器封装层，提供：
 *   - 独立的后台音频线程，以固定时间间隔驱动 process()
 *   - 支持加载完整音频文件（平面格式）
 *   - 播放、暂停、恢复、停止控制
 *   - 实时调速（线程安全）
 *   - 通过回调函数将 PCM 数据输出给上层（用于 NAPI 或混音）
 *
 * 接入 NAPI 时的关键点：
 *   1. 所有音频数据为平面（Planar）格式：先左声道全部，再右声道全部。
 *   2. setAudioCallback() 传入的回调运行在 C++ 后台线程，
 *      不能直接调用 JS 函数，必须通过 napi_threadsafe_function 转发到 JS 主线。
 *   3. 回调中的数据指针（outputBuffer_）在下一轮循环会被覆写，
 *      上层必须在回调中立即拷贝数据（例如 new Float32Array）。
 *
 * 鸿蒙（OpenHarmony）音频输出建议：
 *   - 使用 OH_AudioRenderer 的写入回调，在回调中从队列取数据，
 *     避免在音频线程中直接阻塞。
 *   - 或者让 JS 侧定时从回调中拿数据并喂给 AudioRenderer。
 */

#pragma once

#include <thread>
#include <atomic>
#include <chrono>
#include <vector>
#include <functional>
#include <cmath>
#include "TimeStretchEngine.hpp"

/**
 * @brief 实时变速播放器，封装引擎和线程管理。
 * 
 * 用法示例（C++ 侧）：
 * @code
 *   LiveStretchPlayer player(2, 44100, 65536, 1.0, 512);
 *   player.setAudioCallback([](const float* data, int frames, int ch) {
 *       // 将 data 交给声卡驱动或 NAPI 回调
 *   });
 *   player.loadAudio(planarData, totalFrames);
 *   player.play();
 *   player.setSpeed(1.5); // 可随时调速
 *   player.pause();       // 暂停
 *   player.resume();      // 恢复
 *   player.stop();        // 停止并释放线程
 * @endcode
 */
class LiveStretchPlayer {
public:
    /**
     * @brief 构造播放器。
     * @param channels       声道数（1 或 2）
     * @param sampleRate     采样率（Hz），用于计算时间间隔
     * @param ringBufferSize 环形缓冲区大小（帧数，64 位），建议设为文件总帧数或足够大（如 65536）；
 *                       超长音频（数小时 384kHz，总帧数 > 2^31）请务必用 64 位值传入
     * @param initialSpeed   初始变速比，默认为 1.0
     * @param blockSize      每次 process() 请求的帧数，默认为 512
     * 
     * @note blockSize 会影响延迟和 CPU 负载，可在 play() 前通过 setBlockSize() 调整。
     */
    LiveStretchPlayer(int channels, int sampleRate, long long ringBufferSize, 
                      double initialSpeed = 1.0, int blockSize = 512)
        : engine_(channels, sampleRate, ringBufferSize, initialSpeed),
          channels_(channels),
          sampleRate_(sampleRate),
          blockSize_(blockSize),
          running_(false),
          paused_(false) {
        updateInterval();
        outputBuffer_.resize(blockSize_ * channels_);
        silenceBuf_.assign(blockSize_ * channels_, 0.0f);
    }

    ~LiveStretchPlayer() {
        stop(); // 确保线程退出
    }

    // ==================== 配置接口（必须在 stop() 后调用） ====================

    /**
     * @brief 调整块大小，影响延迟和性能。
     * @param newBlockSize 新的块大小（建议 64 ~ 8192，且为 2 的幂）
     * @return true 表示设置成功；false 表示正在播放中或参数非法。
     * 
     * @note 必须在 stop() 之后调用，否则返回 false。
     *       调整后，回调数据块大小和音频线程间隔会相应改变。
     */
    bool setBlockSize(int newBlockSize) {
        if (running_) return false;
        if (newBlockSize < 64 || newBlockSize > 8192) return false;
        blockSize_ = newBlockSize;
        updateInterval();
        outputBuffer_.resize(blockSize_ * channels_);
        silenceBuf_.assign(blockSize_ * channels_, 0.0f);
        return true;
    }

    /**
     * @brief 设置「暂停期间是否仍向回调输出静音块」。
     * @param enable true（默认，向后兼容）：暂停时仍回调全零静音块，
     *               适合下游是「持续运行的混音管线」、需要连续数据流的场景；
     *               false：暂停时**完全不回调**（不产生任何数据），
     *               适合「下游声卡已自行 Pause」的场景——此时静音无人消费，
     *               写进下游缓冲只会把它灌满、并在恢复时播出陈旧静音。
     *
     * @note 两种模式下节拍时钟都保持实时推进，恢复时都无"追赶"爆发。
     *       若下游是 OH_AudioRenderer 且暂停时会调用 Pause，请设为 false。
     */
    void setSilenceOnPause(bool enable) {
        silenceOnPause_.store(enable, std::memory_order_relaxed);
    }

    // ==================== 数据加载（一次性喂入全部音频） ====================

    /**
     * @brief 加载音频数据，必须为平面（Planar）格式。
     * @param data        指向浮点 PCM 数据，排列方式：
     *                     - 单声道：所有样本连续
     *                     - 立体声：先左声道全部样本，紧接着右声道全部样本
     * @param totalFrames 每个声道的样本数（总帧数，64 位，支持超长音频）
     * 
     * @note 此函数会停止当前播放并重置引擎。
     *       数据会在内部被复制到环形缓冲区，调用后可以释放 data。
     *       该函数可在任意线程调用，但会阻塞直到停止完成。
     */
    void loadAudio(const float* data, long long totalFrames) {
        stop(); // 先停止播放

        // 保留源数据指针，供 seekTo() 重新喂入使用（借用指针，调用方须保持数据存活）
        sourceData_ = data;
        sourceFrames_ = totalFrames;
        seekOffset_ = 0;

        // 构建指针数组（平面格式）
        std::vector<const float*> channelPtrs(channels_);
        if (channels_ == 2) {
            channelPtrs[0] = data;
            channelPtrs[1] = data + totalFrames;
        } else {
            channelPtrs[0] = data;
        }

        engine_.reset();
        long long written = engine_.feedAudio(channelPtrs.data(), totalFrames);
        // 如果容量足够，written 应等于 totalFrames
        engine_.finish(); // 标记输入结束
    }

    // ==================== 播放进度与跳转 ====================

    /**
     * @brief 当前播放位置（输入音频帧数，绝对位置，含跳转偏移）。
     *        精确值来自引擎内部已消耗输入计数。
     */
    long long getInputPosition() const {
        return seekOffset_ + engine_.inputConsumed();
    }

    /**
     * @brief 跳转到指定输入帧位置。
     * @param frameOffset 目标帧（0 = 文件开头）
     * @return true 表示成功；false 表示参数越界或未加载数据。
     *
     * @note 内部会停止当前播放线程 -> 重置引擎 -> 从偏移处重新喂入数据，
     *      然后按之前的运行/暂停状态恢复。调用方必须保证 loadAudio()
     *      传入的 data 指针仍然有效（本类持有的是借用指针）。
     */
    bool seekTo(long long frameOffset) {
        if (!sourceData_ || sourceFrames_ <= 0) return false;
        if (frameOffset < 0 || frameOffset >= sourceFrames_) return false;

        bool wasPlaying = running_.load(std::memory_order_relaxed);
        bool wasPaused  = paused_.load(std::memory_order_relaxed);
        stop(); // 停止并等待后台线程退出

        engine_.reset();
        long long remaining = sourceFrames_ - frameOffset;
        const float* data = sourceData_ + frameOffset;

        // 构建指针数组（平面格式，从偏移处开始）
        // 注意：平面布局为 [L0..L(n-1) | R0..R(n-1)]，R 声道起点 = 源数据 + 总帧数
        std::vector<const float*> channelPtrs(channels_);
        if (channels_ == 2) {
            channelPtrs[0] = data;                                       // L 从偏移处
            channelPtrs[1] = sourceData_ + sourceFrames_ + frameOffset; // R 从偏移处
        } else {
            channelPtrs[0] = data;
        }

        engine_.feedAudio(channelPtrs.data(), remaining);
        engine_.finish(); // 标记输入结束
        seekOffset_ = frameOffset;

        if (wasPlaying) {
            // 直接以「暂停态」启动线程：避免 play() 后紧接 pause() 期间
            // 音频线程抢先产出一块真实音频（播放中跳转不受影响）
            startThread(wasPaused);
        }
        return true;
    }

    // ==================== 播放控制 ====================

    /** 启动播放（非阻塞，开启后台线程） */
    void play() {
        startThread(false);
    }

    /** 暂停播放（后台线程继续运行，不调用 process；是否输出静音块由 setSilenceOnPause 决定） */
    void pause() {
        paused_ = true;
    }

    /** 恢复播放 */
    void resume() {
        paused_ = false;
    }

    /** 停止播放并等待后台线程退出（阻塞调用线程） */
    void stop() {
        running_ = false;
        paused_ = false;
        if (workThread_.joinable()) {
            workThread_.join();
        }
    }

    // ==================== 参数控制 ====================

    /**
     * @brief 设置变速比（线程安全，实时生效）
     * @param speed 目标变速比（0.1 ~ 5.0 等，引擎内部会限制最小值）
     * 
     * @note 该函数可在任意线程调用，不影响音频线程实时性。
     */
    void setSpeed(double speed) {
        engine_.setSpeed(speed);
    }

    /**
     * @brief 后台音频线程是否还在跑。
     *
     * audioLoop 在 process() 返回 0（数据耗尽）时会自行把 running_ 置 false 并退出。
     * ★ 用它判断"自然播完"比"500ms 没有回调"这类时间启发式可靠得多 ——
     *   后者在暂停/恢复、卡顿、声卡异常时都会误判。
     * 注意：暂停不会把它置 false（暂停时线程仍在循环），所以暂停中它仍是 true。
     */
    bool isRunning() const { return running_.load(std::memory_order_relaxed); }

    /**
     * @brief 注册"音频线程刚启动时"执行的回调（可选）。
     *
     * ★ 用途是**平台相关的线程优先级提升**。本类刻意保持平台无关（不 include 任何
     *   系统头），所以平台调用交给上层：
     *       player.setThreadStartCallback([]{ OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE); });
     *   否则这个生产线程很容易被 UI/JS 线程抢走时间片，输出环形缓冲被声卡读空
     *   ⇒ underrun（掉音）。
     */
    void setThreadStartCallback(std::function<void()> cb) { threadStartCb_ = cb; }

    // ==================== 数据回调注册 ====================

    /**
     * @brief 注册音频数据回调函数。
     * @param callback 回调函数原型：
     *                 void callback(const float* data, int frames, int channels)
     *                 - data：指向一块连续的 PCM 数据，排列为平面格式（先左后右）
     *                 - frames：本次输出的有效帧数（通常等于 blockSize，最后可能小于）
     *                 - channels：声道数
     * 
     * @note 该回调运行在 **C++ 后台音频线程**，因此：
     *       - 绝对不能在回调中调用阻塞操作（如 sleep、锁竞争）
     *       - 绝对不能在回调中直接调用 JS 函数（必须通过 napi_threadsafe_function）
     *       - data 指针在回调返回后会被覆写，上层必须立即拷贝数据。
     * 
     * 在 NAPI 封装中，建议在回调中调用 napi_call_threadsafe_function，
     * 将数据拷贝到 JS 侧（例如 new Float32Array）。
     */
    void setAudioCallback(std::function<void(const float* data, int frames, int channels)> callback) {
        audioCallback_ = callback;
    }

private:
    // ---------- 内部辅助 ----------
    /** 启动后台线程；startPaused 为 true 时线程以暂停态启动（用于暂停中跳转） */
    void startThread(bool startPaused) {
        if (running_) return;
        paused_.store(startPaused, std::memory_order_relaxed);
        running_ = true;
        workThread_ = std::thread(&LiveStretchPlayer::audioLoop, this);
    }

    void updateInterval() {
        // 计算每次回调的间隔（毫秒）
        intervalMs_ = static_cast<double>(blockSize_) / sampleRate_ * 1000.0;
    }

    // ---------- 后台线程主循环 ----------
    void audioLoop() {
        // 先给上层一个提升本线程优先级的机会（平台相关，见 setThreadStartCallback）
        if (threadStartCb_) {
            threadStartCb_();
        }
        // 准备输出指针（平面格式，避免每次循环重新分配）
        std::vector<float*> outputPtrs(channels_);
        // 使用高精度时钟驱动
        auto nextWake = std::chrono::steady_clock::now();

        while (running_) {
            // ---- 暂停状态：输出静音，不消耗引擎数据 ----
            // 注意：静音也按实时节拍输出（与正常处理同频），保证：
            //   1. 下游（混音器/声卡）在暂停期间获得实时的静音流，不饿不溢；
            //   2. nextWake 全程保持同步，恢复时无缝衔接，不会"追赶"爆发。
            //   不要改用固定 sleep_for(1ms)：Windows 定时器精度 ~15.6ms，
            //   会导致静音以 ~33k 帧/s（非实时）输出，暂停时长被"压缩"。
            if (paused_) {
                // silenceOnPause_ 为 false 时完全不回调（见 setSilenceOnPause 说明）
                if (silenceOnPause_.load(std::memory_order_relaxed) && audioCallback_) {
                    // 产生静音数据（每实例独立缓冲，多播放器并发/不同块大小均安全）
                    audioCallback_(silenceBuf_.data(), blockSize_, channels_);
                }
                nextWake += std::chrono::microseconds(
                    static_cast<long long>(intervalMs_ * 1000)
                );
                std::this_thread::sleep_until(nextWake);
                continue;
            }

            // ---- 正常处理 ----
            // 设置输出指针
            if (channels_ == 2) {
                outputPtrs[0] = outputBuffer_.data();                 // 左声道
                outputPtrs[1] = outputBuffer_.data() + blockSize_;   // 右声道
            } else {
                outputPtrs[0] = outputBuffer_.data();
            }

            // 调用引擎处理，返回实际产生的帧数
            int produced = engine_.process(outputPtrs.data(), blockSize_);

            // 如果返回 0，表示所有数据已耗尽，自动停止线程
            if (produced == 0) {
                running_ = false;
                break;
            }

            // 如果有回调，将数据传递给上层（注意数据所有权）
            if (audioCallback_) {
                audioCallback_(outputBuffer_.data(), produced, channels_);
            }

            // ---- 精准定时，保持固定的时间间隔 ----
            nextWake += std::chrono::microseconds(
                static_cast<long long>(intervalMs_ * 1000)
            );
            std::this_thread::sleep_until(nextWake);
        }
    }

    // ---------- 成员变量 ----------
    TimeStretchEngine engine_;               ///< 核心变速引擎
    int channels_;                          ///< 声道数
    int sampleRate_;                        ///< 采样率
    int blockSize_;                         ///< 每次处理的帧数
    double intervalMs_;                     ///< 时间间隔（毫秒）
    std::vector<float> outputBuffer_;       ///< 输出缓冲区（平面格式）
    std::vector<float> silenceBuf_;         ///< 暂停时的静音输出缓冲（每实例独立）

    std::atomic<bool> running_;             ///< 线程是否运行
    std::atomic<bool> paused_;              ///< 是否暂停
    std::atomic<bool> silenceOnPause_{true}; ///< 暂停时是否仍输出静音块（默认 true 保持兼容）
    std::thread workThread_;                ///< 后台工作线程

    std::function<void(const float* data, int frames, int channels)> audioCallback_; ///< 数据回调
    std::function<void()> threadStartCb_;   ///< 音频线程启动钩子（平台优先级提升用）

    const float* sourceData_ = nullptr;    ///< 源数据借用指针（seek 时重新喂入用）
    long long sourceFrames_ = 0;           ///< 源数据总帧数（64 位）
    long long seekOffset_ = 0;             ///< 当前跳转偏移（输入帧，64 位）
};
