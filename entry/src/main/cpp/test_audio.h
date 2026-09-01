//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef BEAT_PER_MILE_TEST_AUDIO_H
#define BEAT_PER_MILE_TEST_AUDIO_H

#include <cstdint>
#include <string>
#include "LiveStretchPlayer.h"


struct test_audio {
private:
    std::string name;
    LiveStretchPlayer player;
    
public:
    void make_name(std::string name);
    std::string get_name();
    test_audio(int channels, int sampleRate, long long ringBufferSize, 
                      double initialSpeed = 1.0, int blockSize = 512);
    
    void load_audio(const float *data, int totalFrames);
    void setSpeed(double speed);
    void pause();
    void resume();
    void stop();
    void play();
    void player_init();
};

#endif //BEAT_PER_MILE_TEST_AUDIO_H
