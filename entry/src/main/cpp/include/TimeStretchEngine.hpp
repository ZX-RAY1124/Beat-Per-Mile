/*
 * TimeStretchEngine.hpp
 * 基于 signalsmith-stretch 的实时变速引擎（修复版）
 * 修正了 process 中错误添加 inputLatency 导致变速比失调的问题。
 *
 * 包含：
 *   - 无锁 SPSC 环形缓冲区（多声道，帧为单位）
 *   - 变速处理器（自动处理输入延迟、输出延迟、缓冲区欠载）
 *   - 完整的生产者/消费者接口
 *
 * 用法：
 *   1. 创建引擎：TimeStretchEngine engine(2, 44100, 8192, 1.2);
 *   2. 音频输入线程循环调用 engine.feedAudio(inputPtrs, numFrames);
 *   3. 音频处理线程循环调用 engine.process(outputPtrs, numOutputFrames);
 *   4. 结束时调用 engine.finish() 并继续 process 直到返回 0
 *
 * 依赖：signalsmith-stretch.h (需在编译路径中)
 * 编译选项：至少 -O2，否则性能严重下降
 */

#pragma once

#include <atomic>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "signalsmith_stretch.h"

// ============================================================================
// 1. 环形缓冲区 (AudioRingBuffer)
//    多声道、帧为单位、SPSC 无锁设计
//    当写入速度超过读取速度时，自动丢弃最旧的数据（丢旧保新）
// ============================================================================
template<typename SampleType>
class AudioRingBuffer {
public:
    AudioRingBuffer(int channels, long long capacityFrames)
        : channels_(channels), capacity_(static_cast<size_t>(capacityFrames)),
          data_(static_cast<size_t>(channels) * static_cast<size_t>(capacityFrames), SampleType(0)) {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

    AudioRingBuffer(const AudioRingBuffer&) = delete;
    AudioRingBuffer& operator=(const AudioRingBuffer&) = delete;

    long long write(const SampleType* const* input, long long frames) {
        if (frames <= 0) return 0;
        size_t writePos = writePos_.load(std::memory_order_relaxed);
        size_t readPos  = readPos_.load(std::memory_order_acquire);
        size_t used = writePos - readPos;
        size_t available = capacity_ - 1 - used;
        long long toWrite = frames;
        if (toWrite > static_cast<long long>(available)) {
            long long overflow = toWrite - static_cast<long long>(available);
            readPos += static_cast<size_t>(overflow);
            readPos_.store(readPos, std::memory_order_release);
            used = writePos - readPos;
            available = capacity_ - 1 - used;
            if (toWrite > static_cast<long long>(available)) {
                toWrite = static_cast<long long>(available);
            }
        }
        size_t startFrame = writePos % capacity_;
        size_t endFrame   = startFrame + static_cast<size_t>(toWrite);
        if (endFrame <= static_cast<size_t>(capacity_)) {
            for (int ch = 0; ch < channels_; ++ch) {
                SampleType* dest = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                const SampleType* src = input[ch];
                std::copy(src, src + toWrite, dest);
            }
        } else {
            size_t firstPart  = capacity_ - startFrame;
            size_t secondPart = static_cast<size_t>(toWrite) - firstPart;
            for (int ch = 0; ch < channels_; ++ch) {
                SampleType* dest1 = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                const SampleType* src1 = input[ch];
                std::copy(src1, src1 + firstPart, dest1);
                SampleType* dest2 = data_.data() + static_cast<size_t>(ch) * capacity_;
                const SampleType* src2 = input[ch] + firstPart;
                std::copy(src2, src2 + secondPart, dest2);
            }
        }
        writePos += static_cast<size_t>(toWrite);
        writePos_.store(writePos, std::memory_order_release);
        return toWrite;
    }

    long long read(SampleType* const* output, long long frames) {
        if (frames <= 0) return 0;
        size_t readPos  = readPos_.load(std::memory_order_relaxed);
        size_t writePos = writePos_.load(std::memory_order_acquire);
        size_t available = writePos - readPos;
        long long toRead = std::min(frames, static_cast<long long>(available));
        if (toRead <= 0) return 0;
        size_t startFrame = readPos % capacity_;
        size_t endFrame   = startFrame + static_cast<size_t>(toRead);
        if (endFrame <= static_cast<size_t>(capacity_)) {
            for (int ch = 0; ch < channels_; ++ch) {
                const SampleType* src = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                SampleType* dest = output[ch];
                std::copy(src, src + toRead, dest);
            }
        } else {
            size_t firstPart  = capacity_ - startFrame;
            size_t secondPart = static_cast<size_t>(toRead) - firstPart;
            for (int ch = 0; ch < channels_; ++ch) {
                const SampleType* src1 = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                SampleType* dest1 = output[ch];
                std::copy(src1, src1 + firstPart, dest1);
                const SampleType* src2 = data_.data() + static_cast<size_t>(ch) * capacity_;
                SampleType* dest2 = output[ch] + firstPart;
                std::copy(src2, src2 + secondPart, dest2);
            }
        }
        readPos += static_cast<size_t>(toRead);
        readPos_.store(readPos, std::memory_order_release);
        return toRead;
    }

    long long availableRead() const {
        size_t r = readPos_.load(std::memory_order_acquire);
        size_t w = writePos_.load(std::memory_order_acquire);
        return static_cast<long long>(w - r);
    }

    // 已读出的帧数（读位置），即已被消费的输入帧数
    size_t readPosition() const {
        return readPos_.load(std::memory_order_relaxed);
    }

    void reset() {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

private:
    int channels_;
    size_t capacity_;
    std::vector<SampleType> data_;
    std::atomic<size_t> readPos_{0};
    std::atomic<size_t> writePos_{0};
};

// ============================================================================
// 2. 实时变速引擎 (TimeStretchEngine) – 修正变速比计算
// ============================================================================
class TimeStretchEngine {
public:
    /**
     * @param ringBufferSize 环形缓冲容量（帧）。支持 >2^31 的超长音频（如数小时 384kHz），
     *                       故为 64 位；注意容量会实打实占用内存（每帧 channels 个 float）。
     */
    TimeStretchEngine(int channels, int sampleRate, long long ringBufferSize, double initialSpeed = 1.0)
        : channels_(channels), sampleRate_(sampleRate), speed_(initialSpeed),
          ringBuffer_(channels, ringBufferSize),
          isFinished_(false), hasPreheated_(false), drained_(false),
          inputLatency_(0), outputLatency_(0) {
        stretcher_.presetDefault(channels, sampleRate);
        inputLatency_ = static_cast<int>(stretcher_.inputLatency());
        outputLatency_ = static_cast<int>(stretcher_.outputLatency());

        // 单次 process() 可消耗的输入上限，同时也是临时缓冲大小。
        // 与环形缓冲容量解耦并封顶，否则超长音频（容量达数十亿帧）会让临时缓冲爆内存。
        const long long kChunkCap = 1LL << 20;   // 约 100 万帧
        maxInputFrames_ = ringBufferSize / 2;
        if (maxInputFrames_ > kChunkCap) maxInputFrames_ = kChunkCap;
        if (maxInputFrames_ < 256) maxInputFrames_ = 256;

        tempInput_.resize(channels);
        tempInputBuffers_.resize(channels);
        for (int ch = 0; ch < channels; ++ch) {
            tempInputBuffers_[ch].resize(static_cast<size_t>(maxInputFrames_) + inputLatency_ + 64);
            tempInput_[ch] = tempInputBuffers_[ch].data();
        }

        warmupOutput_.resize(channels);
        warmupOutPtrs_.resize(channels);
        for (int ch = 0; ch < channels; ++ch) {
            warmupOutput_[ch].resize(outputLatency_ + 64);
            warmupOutPtrs_[ch] = warmupOutput_[ch].data();
        }
    }

    ~TimeStretchEngine() = default;

    TimeStretchEngine(const TimeStretchEngine&) = delete;
    TimeStretchEngine& operator=(const TimeStretchEngine&) = delete;

    /** @param frames 本次喂入的帧数（64 位，支持一次性喂入整首长音频）；返回实际写入帧数 */
    long long feedAudio(const float* const* input, long long frames) {
        if (frames <= 0 || isFinished_) return 0;
        return ringBuffer_.write(input, frames);
    }

    /**
     * 处理音频输出。
     * 正常处理：按变速比消耗输入，即 neededInput = ceil(outputFrames * speed_)。
     * 预热：首次调用时喂入 inputLatency_ 个零样本。
     * 冲刷：当 finish() 后且缓冲区空时，调用 stretcher_.flush() 排空残留输出。
     */
    int process(float* const* output, int outputFrames) {
        if (outputFrames <= 0) return 0;
        if (drained_) return 0;

        // ---- 冲刷模式：输入已结束且缓冲区为空 ----
        if (isFinished_ && ringBuffer_.availableRead() == 0) {
            stretcher_.flush(output, outputFrames);
            bool allZero = true;
            for (int i = 0; i < outputFrames; ++i) {
                for (int ch = 0; ch < channels_; ++ch) {
                    if (output[ch][i] != 0.0f) {
                        allZero = false;
                        break;
                    }
                }
                if (!allZero) break;
            }
            if (allZero) {
                drained_ = true;
                return 0;
            }
            return outputFrames;
        }

        // ---- 预热 ----
        if (!hasPreheated_) {
            std::vector<const float*> zeroInputs(channels_);
            for (int ch = 0; ch < channels_; ++ch) {
                std::fill(tempInputBuffers_[ch].begin(),
                          tempInputBuffers_[ch].begin() + inputLatency_, 0.0f);
                zeroInputs[ch] = tempInputBuffers_[ch].data();
            }
            stretcher_.process(zeroInputs.data(), inputLatency_,
                               warmupOutPtrs_.data(), outputLatency_);
            hasPreheated_ = true;
        }

        // ---- 正常处理 ----
        // 关键修复：按比例消耗输入，不再额外加 inputLatency_
        double currentSpeed = speed_.load(std::memory_order_relaxed);
        long long neededInput = static_cast<long long>(std::ceil(outputFrames * currentSpeed));
        if (neededInput > maxInputFrames_) {
            long long maxOutput = static_cast<long long>(maxInputFrames_ / speed_);
            if (maxOutput < 1) maxOutput = 1;
            outputFrames = static_cast<int>(std::min<long long>(maxOutput, outputFrames));
            neededInput = maxInputFrames_;
        }

        long long actualRead = ringBuffer_.read(tempInput_.data(), neededInput);
        if (actualRead < neededInput) {
            for (int ch = 0; ch < channels_; ++ch) {
                std::fill(tempInputBuffers_[ch].begin() + static_cast<size_t>(actualRead),
                          tempInputBuffers_[ch].begin() + static_cast<size_t>(neededInput), 0.0f);
            }
        }

        stretcher_.process(tempInput_.data(), static_cast<int>(neededInput), output, outputFrames);
        return outputFrames;
    }

    void setSpeed(double speed) {
        if (speed < 0.01) speed = 0.01;
        speed_.store(speed, std::memory_order_relaxed);
    }

    double getSpeed() const { return speed_.load(std::memory_order_relaxed); }

    /**
     * @brief 已实际消耗的输入帧数（精确值，非估算）。
     *        等于环形缓冲区的读位置：每次 process() 真实读取了多少输入帧。
     *        用于上层实现播放进度显示。
     */
    long long inputConsumed() const {
        return static_cast<long long>(ringBuffer_.readPosition());
    }

    /**
     * @brief 单次 process() 可消耗输入帧数的上限（= 内部临时缓冲大小）。
     *        与环形缓冲容量解耦并封顶（约 100 万帧），避免超长音频导致临时缓冲爆内存。
     *        仅供诊断/测试使用。
     */
    long long maxInputChunkFrames() const { return maxInputFrames_; }

    void reset() {
        ringBuffer_.reset();
        stretcher_.presetDefault(channels_, sampleRate_);
        hasPreheated_ = false;
        isFinished_ = false;
        drained_ = false;
        inputLatency_ = static_cast<int>(stretcher_.inputLatency());
        outputLatency_ = static_cast<int>(stretcher_.outputLatency());
        setSpeed(speed_);
    }

    void finish() {
        isFinished_ = true;
        drained_ = false;
    }

private:
    int channels_;
    int sampleRate_;
    std::atomic<double> speed_;
    AudioRingBuffer<float> ringBuffer_;

    signalsmith::stretch::SignalsmithStretch<float> stretcher_;

    std::atomic<bool> isFinished_;
    bool hasPreheated_;
    bool drained_;
    int inputLatency_;
    int outputLatency_;
    long long maxInputFrames_;

    std::vector<float*> tempInput_;
    std::vector<std::vector<float>> tempInputBuffers_;
    std::vector<float*> warmupOutPtrs_;
    std::vector<std::vector<float>> warmupOutput_;
};

// ============================================================================
// 使用示例 (注释)
// ============================================================================
/*
    // 1. 创建引擎 (立体声，48kHz，环形缓冲 16384 帧，初始速度 1.2)
    TimeStretchEngine engine(2, 48000, 16384, 1.2);

    // 2. 生产者线程
    void onAudioInput(const float* left, const float* right, int numFrames) {
        const float* input[2] = { left, right };
        engine.feedAudio(input, numFrames);
    }

    // 3. 消费者线程
    void audioProcessingLoop() {
        const int OUTPUT_BLOCK = 512;
        std::vector<float> outL(OUTPUT_BLOCK), outR(OUTPUT_BLOCK);
        float* output[2] = { outL.data(), outR.data() };

        while (true) {
            int produced = engine.process(output, OUTPUT_BLOCK);
            if (produced == 0) break;
            // 将 output 中的音频发送到输出设备...
        }
    }

    // 4. 结束
    engine.finish();
    // 继续调用 process 直到返回 0
*/