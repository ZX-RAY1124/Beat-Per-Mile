// LiveStretchPlayer.cpp
#pragma once

#include <thread>
#include <atomic>
#include <chrono>
#include <vector>
#include <functional>
#include <cmath>
#include "TimeStretchEngine.hpp"

class LiveStretchPlayer {
public:
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
    }

    ~LiveStretchPlayer() {
        stop();
    }

    // ==================== 配置 ====================
    bool setBlockSize(int newBlockSize) {
        if (running_) return false;
        if (newBlockSize < 64 || newBlockSize > 8192) return false;
        blockSize_ = newBlockSize;
        updateInterval();
        outputBuffer_.resize(blockSize_ * channels_);
        return true;
    }

    // ==================== 数据加载 ====================
    // 注意：data 必须是平面格式 (Planar)：先左声道全部，再右声道全部
    void loadAudio(const float* data, int totalFrames) {
        stop(); // 先停止
        
        // 构建指针数组
        std::vector<const float*> channelPtrs(channels_);
        if (channels_ == 2) {
            channelPtrs[0] = data;
            channelPtrs[1] = data + totalFrames;
        } else {
            channelPtrs[0] = data;
        }

        engine_.reset();
        engine_.feedAudio(channelPtrs.data(), totalFrames);
        engine_.finish();
    }

    // ==================== 播放控制 ====================
    void play() {
        if (running_) return;
        running_ = true;
        paused_ = false;
        workThread_ = std::thread(&LiveStretchPlayer::audioLoop, this);
    }

    void pause() {
        paused_ = true;
    }

    void resume() {
        paused_ = false;
    }

    void stop() {
        if (!running_) return;
        running_ = false;
        paused_ = false;
        if (workThread_.joinable()) {
            workThread_.join();
        }
    }

    void setSpeed(double speed) {
        engine_.setSpeed(speed);
    }

    // ==================== 回调注册 ====================
    // 注意：回调运行在 C++ 后台线程，不能直接调 JS，必须用 ThreadSafeFunction
    void setAudioCallback(std::function<void(const float* data, int frames, int channels)> callback) {
        audioCallback_ = callback;
    }

private:
    void updateInterval() {
        intervalMs_ = static_cast<double>(blockSize_) / sampleRate_ * 1000.0;
    }

    void audioLoop() {
        std::vector<float*> outputPtrs(channels_);
        auto nextWake = std::chrono::steady_clock::now();

        while (running_) {
            // 如果暂停，输出静音并等待（不消耗引擎数据）
            if (paused_) {
                if (audioCallback_) {
                    // 传空数据或静音数据给 JS（让 JS 知道还在运行但没声音）
                    static std::vector<float> silence(blockSize_ * channels_, 0.0f);
                    audioCallback_(silence.data(), blockSize_, channels_);
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            // 准备输出指针（平面格式）
            if (channels_ == 2) {
                outputPtrs[0] = outputBuffer_.data();
                outputPtrs[1] = outputBuffer_.data() + blockSize_;
            } else {
                outputPtrs[0] = outputBuffer_.data();
            }

            // 调用引擎处理
            int produced = engine_.process(outputPtrs.data(), blockSize_);

            // 如果引擎返回 0，代表数据耗尽，自动停止
            if (produced == 0) {
                running_ = false;
                break;
            }

            // 回调给 JS（数据指针、实际帧数、声道数）
            if (audioCallback_) {
                audioCallback_(outputBuffer_.data(), produced, channels_);
            }

            // 精准控制节拍
            nextWake += std::chrono::microseconds(
                static_cast<long long>(intervalMs_ * 1000)
            );
            std::this_thread::sleep_until(nextWake);
        }
    }

    TimeStretchEngine engine_;
    int channels_;
    int sampleRate_;
    int blockSize_;
    double intervalMs_;
    std::vector<float> outputBuffer_;

    std::atomic<bool> running_;
    std::atomic<bool> paused_;
    std::thread workThread_;

    std::function<void(const float* data, int frames, int channels)> audioCallback_;
};