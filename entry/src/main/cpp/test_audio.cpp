//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "test_audio.h"
#include "LiveStretchPlayer.h"



test_audio::test_audio(int channels, int sampleRate, long long ringBufferSize, double initialSpeed , int blockSize) : player(channels, sampleRate, ringBufferSize, initialSpeed, blockSize){
    
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

void test_audio::player_init(){
    player.setAudioCallback([](const float* data, int frames, int ch) {
        
    });
}

void test_audio::play(){
    while (true){
        
    }
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
}












    



