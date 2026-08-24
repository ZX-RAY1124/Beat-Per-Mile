//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "test_audio.h"

test_audio::test_audio() : name("dev") {}

std::string test_audio::make_name(std::string name) {
    this->name = name;
}

std::string test_audio::get_name() {
    return this->name;
}
