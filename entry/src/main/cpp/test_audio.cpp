//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "test_audio.h"
#include "LiveStretchPlayer.h"
#include "napi/native_api.h"




test_audio::test_audio(int channels, int sampleRate, long long ringBufferSize, double initialSpeed , int blockSize) : player(channels, sampleRate, ringBufferSize, initialSpeed, blockSize){
    _has_stop = false;
}

void test_audio::make_name(std::string name) {
    this->name = name;
}

std::string test_audio::get_name() {
    return this->name;
}

void test_audio::load_audio(const float *data, int totalFrames) {
    player.loadAudio(data, totalFrames);
}


void test_audio::play(music_data Callback_data){
    player.setAudioCallback([this, &Callback_data](const float* data, int frames, int ch) {
        *Callback_data.data = *data;
    });
    //test code
    
}

void test_audio::setSpeed(double speed) {
    player.setSpeed(speed);
}

void test_audio::pause() {
    player.pause();
}

void test_audio::resume() {
    player.resume();
}

void test_audio::stop() {
    player.stop();
    _has_stop = true;
}












    



