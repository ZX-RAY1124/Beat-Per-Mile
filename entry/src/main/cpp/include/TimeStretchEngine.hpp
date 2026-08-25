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
    AudioRingBuffer(int channels, int capacityFrames)
        : channels_(channels), capacity_(capacityFrames),
          data_(static_cast<size_t>(channels) * capacityFrames, SampleType(0)) {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

    AudioRingBuffer(const AudioRingBuffer&) = delete;
    AudioRingBuffer& operator=(const AudioRingBuffer&) = delete;

    int write(const SampleType* const* input, int frames) {
        if (frames <= 0) return 0;
        size_t writePos = writePos_.load(std::memory_order_relaxed);
        size_t readPos  = readPos_.load(std::memory_order_acquire);
        size_t used = writePos - readPos;
        size_t available = capacity_ - 1 - used;
        int toWrite = frames;
        if (toWrite > static_cast<int>(available)) {
            int overflow = toWrite - static_cast<int>(available);
            readPos += overflow;
            readPos_.store(readPos, std::memory_order_release);
            used = writePos - readPos;
            available = capacity_ - 1 - used;
            if (toWrite > static_cast<int>(available)) {
                toWrite = static_cast<int>(available);
            }
        }
        size_t startFrame = writePos % capacity_;
        size_t endFrame   = startFrame + toWrite;
        if (endFrame <= static_cast<size_t>(capacity_)) {
            for (int ch = 0; ch < channels_; ++ch) {
                SampleType* dest = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                const SampleType* src = input[ch];
                std::copy(src, src + toWrite, dest);
            }
        } else {
            size_t firstPart  = capacity_ - startFrame;
            size_t secondPart = toWrite - firstPart;
            for (int ch = 0; ch < channels_; ++ch) {
                SampleType* dest1 = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                const SampleType* src1 = input[ch];
                std::copy(src1, src1 + firstPart, dest1);
                SampleType* dest2 = data_.data() + static_cast<size_t>(ch) * capacity_;
                const SampleType* src2 = input[ch] + firstPart;
                std::copy(src2, src2 + secondPart, dest2);
            }
        }
        writePos += toWrite;
        writePos_.store(writePos, std::memory_order_release);
        return toWrite;
    }

    int read(SampleType* const* output, int frames) {
        if (frames <= 0) return 0;
        size_t readPos  = readPos_.load(std::memory_order_relaxed);
        size_t writePos = writePos_.load(std::memory_order_acquire);
        size_t available = writePos - readPos;
        int toRead = std::min(frames, static_cast<int>(available));
        if (toRead <= 0) return 0;
        size_t startFrame = readPos % capacity_;
        size_t endFrame   = startFrame + toRead;
        if (endFrame <= static_cast<size_t>(capacity_)) {
            for (int ch = 0; ch < channels_; ++ch) {
                const SampleType* src = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                SampleType* dest = output[ch];
                std::copy(src, src + toRead, dest);
            }
        } else {
            size_t firstPart  = capacity_ - startFrame;
            size_t secondPart = toRead - firstPart;
            for (int ch = 0; ch < channels_; ++ch) {
                const SampleType* src1 = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                SampleType* dest1 = output[ch];
                std::copy(src1, src1 + firstPart, dest1);
                const SampleType* src2 = data_.data() + static_cast<size_t>(ch) * capacity_;
                SampleType* dest2 = output[ch] + firstPart;
                std::copy(src2, src2 + secondPart, dest2);
            }
        }
        readPos += toRead;
        readPos_.store(readPos, std::memory_order_release);
        return toRead;
    }

    int availableRead() const {
        size_t r = readPos_.load(std::memory_order_acquire);
        size_t w = writePos_.load(std::memory_order_acquire);
        return static_cast<int>(w - r);
    }

    void reset() {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

private:
    int channels_;
    int capacity_;
    std::vector<SampleType> data_;
    std::atomic<size_t> readPos_{0};
    std::atomic<size_t> writePos_{0};
};

// ============================================================================
// 2. 实时变速引擎 (TimeStretchEngine) – 修正变速比计算
// ============================================================================
class TimeStretchEngine {
public:
    TimeStretchEngine(int channels, int sampleRate, int ringBufferSize, double initialSpeed = 1.0)
        : channels_(channels), sampleRate_(sampleRate), speed_(initialSpeed),
          ringBuffer_(channels, ringBufferSize),
          isFinished_(false), hasPreheated_(false), drained_(false),
          inputLatency_(0), outputLatency_(0) {
        stretcher_.presetDefault(channels, sampleRate);
        inputLatency_ = static_cast<int>(stretcher_.inputLatency());
        outputLatency_ = static_cast<int>(stretcher_.outputLatency());

        maxInputFrames_ = ringBufferSize / 2;
        if (maxInputFrames_ < 256) maxInputFrames_ = 256;

        tempInput_.resize(channels);
        tempInputBuffers_.resize(channels);
        for (int ch = 0; ch < channels; ++ch) {
            tempInputBuffers_[ch].resize(maxInputFrames_ + inputLatency_ + 64);
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

    int feedAudio(const float* const* input, int frames) {
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
        int neededInput = static_cast<int>(std::ceil(outputFrames * currentSpeed));
        if (neededInput > maxInputFrames_) {
            int maxOutput = static_cast<int>(maxInputFrames_ / speed_);
            if (maxOutput < 1) maxOutput = 1;
            outputFrames = maxOutput;
            neededInput = maxInputFrames_;
        }

        int actualRead = ringBuffer_.read(tempInput_.data(), neededInput);
        if (actualRead < neededInput) {
            for (int ch = 0; ch < channels_; ++ch) {
                std::fill(tempInputBuffers_[ch].begin() + actualRead,
                          tempInputBuffers_[ch].begin() + neededInput, 0.0f);
            }
        }

        stretcher_.process(tempInput_.data(), neededInput, output, outputFrames);
        return outputFrames;
    }

    void setSpeed(double speed) {
        if (speed < 0.01) speed = 0.01;
        speed_.store(speed, std::memory_order_relaxed);
    }

    double getSpeed() const { return speed_.load(std::memory_order_relaxed); }

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
    int maxInputFrames_;

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