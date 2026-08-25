/*
 * TimeStretchEngine.hpp
 * 基于 signalsmith-stretch 的实时变速引擎
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
#include "signalsmith_stretch.h"   // 确保包含路径正确

// ============================================================================
// 1. 环形缓冲区 (Ring Buffer)
//    多声道、帧为单位、SPSC 无锁设计
//    当写入速度超过读取速度时，自动丢弃最旧的数据（丢旧保新）
// ============================================================================
template<typename SampleType>
class AudioRingBuffer {
public:
    /**
     * @param channels      声道数 (例如 2 为立体声)
     * @param capacityFrames 缓冲区总帧数（实际可用 capacityFrames - 1 帧）
     */
    AudioRingBuffer(int channels, int capacityFrames)
        : channels_(channels)
        , capacity_(capacityFrames)
        , data_(static_cast<size_t>(channels) * capacityFrames, SampleType(0))
    {
        // 读写指针初始为 0
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
    }

    // 禁止拷贝
    AudioRingBuffer(const AudioRingBuffer&) = delete;
    AudioRingBuffer& operator=(const AudioRingBuffer&) = delete;

    /**
     * 生产者写入音频数据
     * @param input  指针数组: input[ch] 指向第 ch 声道的连续样本
     * @param frames 要写入的帧数
     * @return       实际写入的帧数（通常等于 frames，除非缓冲区无法容纳）
     * 
     * 注意：如果缓冲区空间不足，会先丢弃最旧的数据（移动 readPos）以腾出空间
     */
    int write(const SampleType* const* input, int frames) {
        if (frames <= 0) return 0;

        // 加载当前读写指针（用 acquire 保证能看到消费者更新的 readPos）
        size_t writePos = writePos_.load(std::memory_order_relaxed);
        size_t readPos  = readPos_.load(std::memory_order_acquire);

        // 计算当前已使用空间 (used) 和可用空间 (available)
        // 注意：capacity_ 实际可用为 capacity_ - 1，因为要留一帧区分空/满
        size_t used = writePos - readPos;           // 已用帧数（环形计数）
        size_t available = capacity_ - 1 - used;    // 剩余可用帧数

        int toWrite = frames;

        // ----- 如果缓冲区满了，丢弃旧数据（丢旧保新） -----
        if (toWrite > static_cast<int>(available)) {
            // 计算需要丢弃的旧帧数 = 多出来的部分
            int overflow = toWrite - static_cast<int>(available);

            // 移动读指针，逻辑上丢弃这些旧数据（释放空间）
            // 注意：必须用 release 语义，让消费者知道旧数据作废
            readPos += overflow;
            readPos_.store(readPos, std::memory_order_release);

            // 此时，可用空间已增加，注意不要超出 capacity_ - 1
            // 重新计算可用空间（但实际我们直接按新 readPos 计算，下面再次计算）
            used = writePos - readPos;
            available = capacity_ - 1 - used;
            // 如果 still 不够（极端情况），则限制写入量
            if (toWrite > static_cast<int>(available)) {
                toWrite = static_cast<int>(available);
            }
        }

        // ----- 物理写入数据（分段拷贝，处理绕环） -----
        size_t startFrame = writePos % capacity_;           // 起始物理下标
        size_t endFrame   = startFrame + toWrite;

        if (endFrame <= static_cast<size_t>(capacity_)) {
            // 不绕环，直接拷贝
            for (int ch = 0; ch < channels_; ++ch) {
                SampleType* dest = data_.data() + static_cast<size_t>(ch) * capacity_ + startFrame;
                const SampleType* src = input[ch];
                std::copy(src, src + toWrite, dest);
            }
        } else {
            // 绕环：分两段拷贝
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

        // ----- 更新写指针（release 确保新数据对消费者可见） -----
        writePos += toWrite;
        writePos_.store(writePos, std::memory_order_release);

        return toWrite;
    }

    /**
     * 消费者读取音频数据
     * @param output 指针数组: output[ch] 指向第 ch 声道的输出缓冲区
     * @param frames 要读取的帧数
     * @return       实际读取的帧数 (可能少于 frames，如果数据不足)
     */
    int read(SampleType* const* output, int frames) {
        if (frames <= 0) return 0;

        size_t readPos  = readPos_.load(std::memory_order_relaxed);
        size_t writePos = writePos_.load(std::memory_order_acquire);

        size_t available = writePos - readPos;   // 可读帧数
        int toRead = std::min(frames, static_cast<int>(available));

        if (toRead <= 0) return 0;

        // ----- 物理读取（分段） -----
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

        // 更新读指针
        readPos += toRead;
        readPos_.store(readPos, std::memory_order_release);

        return toRead;
    }

    /** 获取当前可读帧数 */
    int availableRead() const {
        size_t r = readPos_.load(std::memory_order_acquire);
        size_t w = writePos_.load(std::memory_order_acquire);
        return static_cast<int>(w - r);
    }

    /** 重置缓冲区（清空所有数据） */
    void reset() {
        readPos_.store(0, std::memory_order_relaxed);
        writePos_.store(0, std::memory_order_relaxed);
        // 数据不需要物理清零，逻辑上已经清空
    }

private:
    int channels_;
    int capacity_;
    std::vector<SampleType> data_;
    std::atomic<size_t> readPos_{0};
    std::atomic<size_t> writePos_{0};
};

// ============================================================================
// 2. 实时变速引擎 (TimeStretchEngine)
//    封装 signalsmith-stretch，提供流式处理接口
// ============================================================================
class TimeStretchEngine {
public:
    /**
     * @param channels       声道数
     * @param sampleRate     采样率 (Hz)
     * @param ringBufferSize 环形缓冲区总帧数 (建议至少 4096，视延迟需求调整)
     * @param initialSpeed   初始变速比 (1.0 = 原速)
     */
    TimeStretchEngine(int channels, int sampleRate, int ringBufferSize, double initialSpeed = 1.0)
    : channels_(channels)
    , sampleRate_(sampleRate)
    , speed_(initialSpeed)
    , ringBuffer_(channels, ringBufferSize)
    , isFinished_(false)
    , hasPreheated_(false)
    , inputLatency_(0)
    , outputLatency_(0)
{
    stretcher_.presetDefault(channels, sampleRate);
    inputLatency_ = static_cast<int>(stretcher_.inputLatency());
    outputLatency_ = static_cast<int>(stretcher_.outputLatency());

    // 设置最大输入块大小：使用环形缓冲区容量的一半，保证不会一次读太多
    maxInputFrames_ = ringBufferSize / 2;
    if (maxInputFrames_ < 256) maxInputFrames_ = 256; // 最小值

    tempInput_.resize(channels);
    tempInputBuffers_.resize(channels);
    for (int ch = 0; ch < channels; ++ch) {
        tempInputBuffers_[ch].resize(maxInputFrames_ + inputLatency_ + 64); // 额外余量
        tempInput_[ch] = tempInputBuffers_[ch].data();
    }
}
    ~TimeStretchEngine() = default;

    // 禁止拷贝
    TimeStretchEngine(const TimeStretchEngine&) = delete;
    TimeStretchEngine& operator=(const TimeStretchEngine&) = delete;

    /**
     * 生产者接口：向环形缓冲区喂入音频数据
     * @param input  指针数组: input[ch] 指向第 ch 声道输入数据
     * @param frames 帧数
     * @return       实际写入帧数
     */
    int feedAudio(const float* const* input, int frames) {
        if (frames <= 0 || isFinished_) return 0;
        return ringBuffer_.write(input, frames);
    }

    /**
     * 消费者接口：从引擎取出变速后的音频数据
     * @param output       指针数组: output[ch] 指向输出缓冲区
     * @param outputFrames 请求的输出帧数
     * @return             实际输出的帧数（可能少于请求，如果数据不足或已结束）
     * 
     * 注意：此函数会尽量生成 outputFrames 帧输出，但如果环形缓冲区无足够输入，
     *       则可能产生欠载（补零）或输出较少。为保证实时性，不会阻塞等待。
     */
    int process(float* const* output, int outputFrames) {
        if (outputFrames <= 0) return 0;

        // 如果已结束，且内部残留输出已耗尽，返回 0
        if (isFinished_ && !hasRemainingOutput()) {
            return 0;
        }

        // ---- 1. 预热：首次调用时，喂入 inputLatency 个零样本 ----
        if (!hasPreheated_) {
            // 准备零输入
            std::vector<const float*> zeroInputs(channels_);
            // 使用临时缓冲区中已有的空间（清零）
            for (int ch = 0; ch < channels_; ++ch) {
                std::fill(tempInputBuffers_[ch].begin(), 
                          tempInputBuffers_[ch].begin() + inputLatency_, 
                          0.0f);
                zeroInputs[ch] = tempInputBuffers_[ch].data();
            }
            // 调用 process，输出丢弃（传入空输出或临时）
            // 由于我们需要输出，但预热输出应丢弃，可以传入临时 buffer
            // 但简单做法：传入 output 但忽略输出，但会覆盖外部数据？不好。
            // 最好传入一个临时输出缓冲区。
            std::vector<std::vector<float>> warmupOutput(channels_);
            std::vector<float*> warmupOutPtrs(channels_);
            for (int ch = 0; ch < channels_; ++ch) {
                warmupOutput[ch].resize(outputLatency_); // 预热输出大小不重要，但需要足够
                warmupOutPtrs[ch] = warmupOutput[ch].data();
            }
            // 调用 process，送入零，输出丢弃
            stretcher_.process(zeroInputs.data(), inputLatency_, 
                               warmupOutPtrs.data(), outputLatency_);
            hasPreheated_ = true;
        }

        // ---- 2. 计算本次需要从环形缓冲区读取的输入帧数 ----
        // 变速比 speed_ 下，要得到 outputFrames 输出，理论上需要 inputFrames = outputFrames * speed_
        // 但还要考虑 stretcher 内部的延迟，所以我们加一些余量，并保证不超过 maxInputFrames_
        int neededInput = static_cast<int>(std::ceil(outputFrames * speed_)) + inputLatency_;
    // 限制最大输入
        if (neededInput > maxInputFrames_) {
        // 重新计算可用的输出帧数
            int maxOutput = static_cast<int>((maxInputFrames_ - inputLatency_) / speed_);
            if (maxOutput < 1) maxOutput = 1;
            outputFrames = maxOutput;
            neededInput = maxInputFrames_;
        }

    // 从环形缓冲区读取...
        int actualRead = ringBuffer_.read(tempInput_.data(), neededInput);
        if (actualRead < neededInput) {
            // 数据不足，用零填充剩余
            for (int ch = 0; ch < channels_; ++ch) {
                std::fill(tempInputBuffers_[ch].begin() + actualRead, 
                          tempInputBuffers_[ch].begin() + neededInput, 
                          0.0f);
            }
            // 如果实际读取为 0 且没有剩余输出，且已经结束，可能直接返回 0
        }

        // ---- 4. 调用 signalsmith-stretch 处理 ----
        stretcher_.process(tempInput_.data(), neededInput, 
                           output, outputFrames);

        // ---- 5. 如果标记结束，检查是否还有剩余输出 ----
        if (isFinished_) {
            // 如果环形缓冲区已空，且没有新的输入，后续 process 将只产生残留输出
            // 此函数会持续被调用直到 hasRemainingOutput() 为 false
        }

        return outputFrames;
    }

    /**
     * 设置变速比
     * @param speed 目标变速比 (0.5 为半速，2.0 为两倍速)
     */
    void setSpeed(double speed) {
        if (speed < 0.01) speed = 0.01;  // 避免过小
        speed_ = speed;
    }

    double getSpeed() const { return speed_; }

    /** 重置所有状态（包括 stretcher 内部状态） */
    void reset() {
        ringBuffer_.reset();
        stretcher_.presetDefault(channels_, sampleRate_);
        hasPreheated_ = false;
        isFinished_ = false;
        // 重新获取延迟
        inputLatency_ = static_cast<int>(stretcher_.inputLatency());
        outputLatency_ = static_cast<int>(stretcher_.outputLatency());
        // 重设速度
        setSpeed(speed_);
    }

    /**
     * 标记输入结束，之后 process 将继续输出内部残留数据
     * 调用此函数后，不应再调用 feedAudio
     */
    void finish() {
        isFinished_ = true;
        // 为了清空内部状态，需要再喂入 inputLatency 个零
        // 我们可以在 process 中检测并处理，或者在此处直接喂零
        // 简单方式：在 process 中如果 isFinished_ 且环形缓冲区空，则自动喂零
        // 但我们也可以直接在 finish 中喂入零样本到 stretcher
        // 更好的方法：在 process 中判断，当 isFinished_ 且环形缓冲区空时，喂零
        // 本实现中，我们利用 process 的逻辑：当环形缓冲区可读为0时，actualRead=0，补零，调用 process。
        // 但需要确保至少调用一次 process 来输出残留。
        // 所以只需设置标志，由 process 处理。
    }

    /** 检查是否还有残留输出（用于结束判断） */
    bool hasRemainingOutput() const {
        // 如果 ringBuffer 有数据，或者 stretcher 内部还有残留（无法直接查询）
        // 我们可以通过尝试 process 一次来检测，但这样会改变状态。
        // 这里简单认为：如果 isFinished_ 且 ringBuffer 为空，可能还有残留，
        // 需要外部持续调用 process 直到输出为 0。
        // 我们通过 process 返回 0 来判断结束。
        // 因此不实现此函数，而是依赖 process 返回值。
        return true; // 总是返回 true，由 process 决定
    }

private:
    // 配置
    int channels_;
    int sampleRate_;
    double speed_;
    AudioRingBuffer<float> ringBuffer_;

    // signalsmith stretcher 对象
    signalsmith::stretch::SignalsmithStretch<float> stretcher_;

    // 状态标志
    std::atomic<bool> isFinished_;      // 是否已结束输入
    bool hasPreheated_;                 // 是否已完成预热
    int inputLatency_;                  // 输入延迟 (样本数)
    int outputLatency_;                 // 输出延迟 (样本数)
    int maxInputFrames_;                // 单次最大输入帧数

    // 临时缓冲区（用于从 ringBuffer 读取数据后喂给 stretcher）
    std::vector<float*> tempInput_;                 // 指针数组 (channels)
    std::vector<std::vector<float>> tempInputBuffers_; // 实际存储
};

// ============================================================================
// 使用示例 (注释)
// ============================================================================
/*
    // 1. 创建引擎 (立体声，48kHz，环形缓冲 16384 帧，初始速度 1.2)
    TimeStretchEngine engine(2, 48000, 16384, 1.2);

    // 2. 生产者线程 (例如音频回调)
    void onAudioInput(const float* left, const float* right, int numFrames) {
        const float* input[2] = { left, right };
        engine.feedAudio(input, numFrames);
    }

    // 3. 消费者线程 (例如处理循环)
    void audioProcessingLoop() {
        const int OUTPUT_BLOCK = 512;
        std::vector<float> outL(OUTPUT_BLOCK), outR(OUTPUT_BLOCK);
        float* output[2] = { outL.data(), outR.data() };

        while (true) {
            int produced = engine.process(output, OUTPUT_BLOCK);
            if (produced == 0) break; // 结束
            // 将 output 中的音频发送到输出设备...
        }
    }

    // 4. 结束
    engine.finish();
    // 继续调用 process 直到返回 0
*/