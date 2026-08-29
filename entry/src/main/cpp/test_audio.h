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
extern "C" {
    #include <libavutil/samplefmt.h>
    #include <libavcodec/avcodec.h>
    #include <libavformat/avformat.h>
}

struct test_audio {
private:
    std::string name;
    LiveStretchPlayer player;
    FILE *file;
    void process_audio(AVFrame *frame);
    void channel_split(int channel, float data);
    
public:
    test_audio();
    std::vector<float> channel_r;
    std::vector<float> channel_l;
    int sample_rate;
    void make_name(std::string name);
    std::string get_name();
    void init_audio(char file_path[]);
    void audio_play();
    void audio_pause();
};

#endif //BEAT_PER_MILE_TEST_AUDIO_H
