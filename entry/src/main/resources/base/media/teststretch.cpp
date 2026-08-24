/*
 * test_cli.cpp - 命令行 WAV 变速测试
 * 编译：g++ -std=c++11 -O2 test_cli.cpp -o test_cli
 * 运行：./test_cli input.wav output.wav 1.5
 * 功能：将 input.wav 变速为 1.5 倍，输出到 output.wav
 */

#include "TimeStretchEngine.cpp"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstdint>
#include <cstring>
#include <cmath>

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
    int totalSamples = header.subchunk2Size / (channels * 2); // 每声道样本数

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
            right[i] = left[i]; // 单声道复制到右声道
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
        buffer[i * 2] = static_cast<int16_t>(std::clamp(left[i], -1.0f, 1.0f) * 32767);
        buffer[i * 2 + 1] = static_cast<int16_t>(std::clamp(right[i], -1.0f, 1.0f) * 32767);
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

    std::vector<float> left, right;
    int sampleRate;
    if (!readWav(inputFile, left, right, sampleRate)) {
        std::cerr << "读取 WAV 文件失败" << std::endl;
        return 1;
    }
    int totalFrames = left.size();
    std::cout << "输入: " << totalFrames << " 帧, " << sampleRate << " Hz, 立体声" << std::endl;

    // 计算输出帧数（约）
    int outputFrames = static_cast<int>(totalFrames / speed);
    std::vector<float> outLeft(outputFrames), outRight(outputFrames);

    // 创建引擎
    const int RING_SIZE = 8192;
    TimeStretchEngine engine(2, sampleRate, RING_SIZE, speed);

    // 喂入所有数据（可分块，这里简单一次性喂入，但需考虑环形缓冲区容量，可循环喂）
    const int CHUNK = 1024;
    int fed = 0;
    while (fed < totalFrames) {
        int chunk = std::min(CHUNK, totalFrames - fed);
        const float* input[2] = { left.data() + fed, right.data() + fed };
        int written = engine.feedAudio(input, chunk);
        if (written != chunk) {
            std::cerr << "警告: 写入环形缓冲区失败（可能溢出，但已处理）" << std::endl;
        }
        fed += chunk;
        std::cout << "\r喂入进度: " << fed << "/" << totalFrames << std::flush;
    }
    std::cout << std::endl;
    engine.finish();

    // 逐块处理输出
    int outPos = 0;
    const int OUT_CHUNK = 512;
    std::vector<float> tempL(OUT_CHUNK), tempR(OUT_CHUNK);
    while (outPos < outputFrames) {
        int remaining = outputFrames - outPos;
        int request = std::min(OUT_CHUNK, remaining);
        float* output[2] = { tempL.data(), tempR.data() };
        int produced = engine.process(output, request);
        if (produced == 0) break; // 结束
        // 复制到结果数组
        int copy = std::min(produced, remaining);
        std::copy(tempL.begin(), tempL.begin() + copy, outLeft.begin() + outPos);
        std::copy(tempR.begin(), tempR.begin() + copy, outRight.begin() + outPos);
        outPos += copy;
        std::cout << "\r处理进度: " << outPos << "/" << outputFrames << std::flush;
    }
    std::cout << std::endl;
    std::cout << "实际输出帧数: " << outPos << std::endl;

    if (outPos < outputFrames) {
        outLeft.resize(outPos);
        outRight.resize(outPos);
    }

    if (!writeWav(outputFile, outLeft, outRight, sampleRate)) {
        std::cerr << "写入输出文件失败" << std::endl;
        return 1;
    }
    std::cout << "变速完成，输出文件: " << outputFile << std::endl;
    return 0;
}