/*
 * test_cli.cpp - 命令行 WAV 变速测试（修复版）
 * 编译：g++ -std=c++11 -O2 teststretch.cpp -o teststretch.exe
 * 运行：./teststretch.exe input.wav output.wav 1.5
 * 功能：将 input.wav 变速为 1.5 倍，输出到 output.wav
 */

#include "TimeStretchEngine.cpp"   // 确保该文件已按下方说明修改
#include <fstream>
#include <iostream>
#include <vector>
#include <cstdint>
#include <cstring>
#include <cmath>

// ==================== 自定义 clamp（兼容 C++11） ====================
template<typename T>
T clamp(T value, T minVal, T maxVal) {
    return std::max(minVal, std::min(value, maxVal));
}

// ==================== 简易 WAV 读写（仅支持 PCM 16bit） ====================
struct WavHeader {
    char     chunkID[4];     // "RIFF"
    uint32_t chunkSize;
    char     format[4];      // "WAVE"
    char     subchunk1ID[4]; // "fmt "
    uint32_t subchunk1Size;
    uint16_t audioFormat;    // 1 = PCM
    uint16_t numChannels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char     subchunk2ID[4]; // "data"
    uint32_t subchunk2Size;
};

bool readWav(const std::string& filename, std::vector<float>& left, std::vector<float>& right, int& sampleRate) {
    std::ifstream file(filename, std::ios::binary);
    if (!file) return false;
    WavHeader header;
    file.read(reinterpret_cast<char*>(&header), sizeof(header));
    if (strncmp(header.chunkID, "RIFF", 4) != 0 || strncmp(header.format, "WAVE", 4) != 0 ||
        header.audioFormat != 1 || header.bitsPerSample != 16) {
        std::cerr << "仅支持 PCM 16bit WAV 文件" << std::endl;
        return false;
    }
    sampleRate = header.sampleRate;
    int channels = header.numChannels;
    int totalSamples = header.subchunk2Size / (channels * 2);

    std::vector<int16_t> buffer(totalSamples * channels);
    file.read(reinterpret_cast<char*>(buffer.data()), header.subchunk2Size);
    file.close();

    left.resize(totalSamples);
    right.resize(totalSamples);
    for (int i = 0; i < totalSamples; ++i) {
        left[i] = buffer[i * channels] / 32768.0f;
        if (channels == 2)
            right[i] = buffer[i * channels + 1] / 32768.0f;
        else
            right[i] = left[i];
    }
    return true;
}

bool writeWav(const std::string& filename, const std::vector<float>& left, const std::vector<float>& right, int sampleRate) {
    int totalFrames = left.size();
    if (right.size() != totalFrames) return false;
    std::ofstream file(filename, std::ios::binary);
    if (!file) return false;

    WavHeader header;
    memcpy(header.chunkID, "RIFF", 4);
    header.audioFormat = 1;
    header.numChannels = 2;
    header.sampleRate = sampleRate;
    header.bitsPerSample = 16;
    header.blockAlign = 4;
    header.byteRate = sampleRate * header.blockAlign;
    int dataSize = totalFrames * header.blockAlign;
    header.subchunk2Size = dataSize;
    header.chunkSize = 36 + dataSize;
    memcpy(header.format, "WAVE", 4);
    memcpy(header.subchunk1ID, "fmt ", 4);
    header.subchunk1Size = 16;
    memcpy(header.subchunk2ID, "data", 4);

    file.write(reinterpret_cast<const char*>(&header), sizeof(header));

    std::vector<int16_t> buffer(totalFrames * 2);
    for (int i = 0; i < totalFrames; ++i) {
        buffer[i * 2] = static_cast<int16_t>(clamp(left[i], -1.0f, 1.0f) * 32767);
        buffer[i * 2 + 1] = static_cast<int16_t>(clamp(right[i], -1.0f, 1.0f) * 32767);
    }
    file.write(reinterpret_cast<const char*>(buffer.data()), buffer.size() * sizeof(int16_t));
    file.close();
    return true;
}

// ==================== 主程序 ====================
int main(int argc, char* argv[]) {
    if (argc < 4) {
        std::cout << "用法: " << argv[0] << " <输入.wav> <输出.wav> <变速比>" << std::endl;
        return 1;
    }
    std::string inputFile = argv[1];
    std::string outputFile = argv[2];
    double speed = std::stod(argv[3]);
    if (speed < 0.1 || speed > 5.0) {
        std::cerr << "变速比应在 0.1 ~ 5.0 之间" << std::endl;
        return 1;
    }

    // ---------- 读取输入 ----------
    std::vector<float> left, right;
    int sampleRate;
    if (!readWav(inputFile, left, right, sampleRate)) {
        std::cerr << "读取 WAV 文件失败" << std::endl;
        return 1;
    }
    int totalFrames = left.size();
    std::cout << "输入: " << totalFrames << " 帧, " << sampleRate << " Hz, 立体声" << std::endl;
    // 打印前几个样本验证
    std::cout << "输入前10个样本 (左): ";
    for (int i = 0; i < 10 && i < totalFrames; ++i) std::cout << left[i] << " ";
    std::cout << std::endl;

    // ---------- 计算输出帧数（多留余量） ----------
    int outputFrames = static_cast<int>(totalFrames / speed) + 4096;
    std::vector<float> outLeft(outputFrames), outRight(outputFrames);

    // ---------- 创建引擎（环形缓冲区大小 = 文件总帧数 + 安全余量） ----------
    const int RING_SIZE = totalFrames + 4096;   // 确保能容纳整个文件
    std::cout << "环形缓冲区容量: " << RING_SIZE << " 帧" << std::endl;
    TimeStretchEngine engine(2, sampleRate, RING_SIZE, speed);

    // ---------- 一次性喂入全部数据（不再分块，避免丢弃） ----------
    const float* input[2] = { left.data(), right.data() };
    int written = engine.feedAudio(input, totalFrames);
    std::cout << "实际写入环形缓冲区: " << written << " / " << totalFrames << " 帧" << std::endl;
    if (written < totalFrames) {
        std::cerr << "警告：未能写入全部数据（可能缓冲区仍不够大）" << std::endl;
    }
    engine.finish();   // 标记输入结束

    // ---------- 逐块处理输出 ----------
    int outPos = 0;
    const int OUT_CHUNK = 512;
    std::vector<float> tempL(OUT_CHUNK), tempR(OUT_CHUNK);
    while (outPos < outputFrames) {
        int remaining = outputFrames - outPos;
        int request = std::min(OUT_CHUNK, remaining);
        float* output[2] = { tempL.data(), tempR.data() };
        int produced = engine.process(output, request);
        if (produced == 0) {
            std::cout << "process 返回 0，已无更多数据" << std::endl;
            break;
        }
        // 检查输出振幅（调试用）
        float maxAmp = 0.0f;
        for (int i = 0; i < produced; ++i) {
            maxAmp = std::max(maxAmp, std::fabs(tempL[i]));
            maxAmp = std::max(maxAmp, std::fabs(tempR[i]));
        }
        if (maxAmp > 0.001f) {
            std::cout << "\r处理进度: " << outPos << "/" << outputFrames
                      << " 当前振幅: " << maxAmp << "   " << std::flush;
        } else {
            std::cout << "\r处理进度: " << outPos << "/" << outputFrames << " (静音块)" << std::flush;
        }

        int copy = std::min(produced, remaining);
        std::copy(tempL.begin(), tempL.begin() + copy, outLeft.begin() + outPos);
        std::copy(tempR.begin(), tempR.begin() + copy, outRight.begin() + outPos);
        outPos += copy;
    }
    std::cout << std::endl;
    std::cout << "实际输出帧数: " << outPos << std::endl;

    // 裁剪到实际输出大小
    outLeft.resize(outPos);
    outRight.resize(outPos);

    // ---------- 写出结果 ----------
    if (!writeWav(outputFile, outLeft, outRight, sampleRate)) {
        std::cerr << "写入输出文件失败" << std::endl;
        return 1;
    }
    std::cout << "变速完成，输出文件: " << outputFile << std::endl;
    return 0;
}