//
// Created on 2026/9/2.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef BEAT_PER_MILE_MUSIC_DATA_H
#define BEAT_PER_MILE_MUSIC_DATA_H

#include "napi/native_api.h"

struct music_data{
    double* data;           
};

#endif //BEAT_PER_MILE_MUSIC_DATA_H
