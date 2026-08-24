//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef BEAT_PER_MILE_TEST_AUDIO_H
#define BEAT_PER_MILE_TEST_AUDIO_H

#include <string>
struct test_audio {
private:
    std::string name;
public:
    test_audio();
    std::string make_name(std::string name);
    std::string get_name();
};

#endif //BEAT_PER_MILE_TEST_AUDIO_H
