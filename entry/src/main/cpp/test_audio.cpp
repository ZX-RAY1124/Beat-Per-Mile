//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "test_audio.h"
#include "LiveStretchPlayer.h"
#include "hilog/log.h"



test_audio::test_audio():player(2, 44100, 65536, 1.0, 512) {
   
}

void test_audio::make_name(std::string name) {
    this->name = name;
}

std::string test_audio::get_name() {
    return this->name;
}

void test_audio::init_audio(char file_path[]){
    file = std::fopen(file_path, "r");
    if (file == nullptr){
        OH_LOG_ERROR(LOG_APP, "Open File Error!");
        return;
    }
}

void test_audio::audio_play() {
   
}

void test_audio::audio_pause() {
    
}

