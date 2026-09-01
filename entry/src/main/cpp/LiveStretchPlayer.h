/*
 * LiveStretchPlayer.hpp
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
     * @param ringBufferSize 环形缓冲区大小（帧数），建议设为文件总帧数或足够大（如 65536）
     * @param initialSpeed   初始变速比，默认为 1.0
     * @param blockSize      每次 process() 请求的帧数，默认为 512
     * 
     * @note blockSize 会影响延迟和 CPU 负载，可在 play() 前通过 setBlockSize() 调整。
     */
    LiveStretchPlayer(int channels, int sampleRate, int ringBufferSize, 
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

    // ==================== 数据加载（一次性喂入全部音频） ====================

    /**
     * @brief 加载音频数据，必须为平面（Planar）格式。
     * @param data        指向浮点 PCM 数据，排列方式：
     *                     - 单声道：所有样本连续
     *                     - 立体声：先左声道全部样本，紧接着右声道全部样本
     * @param totalFrames 每个声道的样本数（总帧数）
     * 
     * @note 此函数会停止当前播放并重置引擎。
     *       数据会在内部被复制到环形缓冲区，调用后可以释放 data。
     *       该函数可在任意线程调用，但会阻塞直到停止完成。
     */
    void loadAudio(const float* data, int totalFrames) {
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
        int written = engine_.feedAudio(channelPtrs.data(), totalFrames);
        // 如果容量足够，written 应等于 totalFrames
        engine_.finish(); // 标记输入结束
    }

    // ==================== 播放进度与跳转 ====================

    /**
     * @brief 当前播放位置（输入音频帧数，绝对位置，含跳转偏移）。
     *        精确值来自引擎内部已消耗输入计数。
     */
    int getInputPosition() const {
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
    bool seekTo(int frameOffset) {
        if (!sourceData_ || sourceFrames_ <= 0) return false;
        if (frameOffset < 0 || frameOffset >= sourceFrames_) return false;

        bool wasPlaying = running_.load(std::memory_order_relaxed);
        bool wasPaused  = paused_.load(std::memory_order_relaxed);
        stop(); // 停止并等待后台线程退出

        engine_.reset();
        int remaining = sourceFrames_ - frameOffset;
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
            play();
            if (wasPaused) pause(); // 保持暂停状态
        }
        return true;
    }

    // ==================== 播放控制 ====================

    /** 启动播放（非阻塞，开启后台线程） */
    void play() {
        if (running_) return;
        running_ = true;
        paused_ = false;
        workThread_ = std::thread(&LiveStretchPlayer::audioLoop, this);
    }

    /** 暂停播放（后台线程继续运行，但停止调用 process，输出静音） */
    void pause() {
        paused_ = true;
    }

    /** 恢复播放 */
    void resume() {
        paused_ = false;
    }

    /** 停止播放并等待后台线程退出（阻塞调用线程） */
    void stop() {
        if (!running_) return;
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
    void updateInterval() {
        // 计算每次回调的间隔（毫秒）
        intervalMs_ = static_cast<double>(blockSize_) / sampleRate_ * 1000.0;
    }

    // ---------- 后台线程主循环 ----------
    void audioLoop() {
        // 准备输出指针（平面格式，避免每次循环重新分配）
        std::vector<float*> outputPtrs(channels_);
        // 使用高精度时钟驱动
        auto nextWake = std::chrono::steady_clock::now();
        bool wasPaused = false; // 上次迭代是否处于暂停（恢复时需重置节拍）

        while (running_) {
            // ---- 暂停状态：输出静音，不消耗引擎数据 ----
            if (paused_) {
                wasPaused = true;
                if (audioCallback_) {
                    // 产生静音数据（每实例独立缓冲，多播放器并发/不同块大小均安全）
                    audioCallback_(silenceBuf_.data(), blockSize_, channels_);
                }
                // 短暂睡眠，避免 CPU 空转
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            // ---- 刚从暂停恢复：重置节拍时钟 ----
            // 否则 nextWake 停留在暂停前的旧值，恢复后会"追赶"式爆发输出，
            // 把暂停期间欠下的音频瞬间全部吐出（进度飞跳、再次暂停不生效）。
            if (wasPaused) {
                nextWake = std::chrono::steady_clock::now();
                wasPaused = false;
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
    std::thread workThread_;                ///< 后台工作线程

    std::function<void(const float* data, int frames, int channels)> audioCallback_; ///< 数据回调

    const float* sourceData_ = nullptr;    ///< 源数据借用指针（seek 时重新喂入用）
    int sourceFrames_ = 0;                 ///< 源数据总帧数
    int seekOffset_ = 0;                   ///< 当前跳转偏移（输入帧）
};
