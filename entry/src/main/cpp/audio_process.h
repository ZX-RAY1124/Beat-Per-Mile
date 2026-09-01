//
// Created on 2026/9/1.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef BEAT_PER_MILE_AUDIO_PROCESS_H
#define BEAT_PER_MILE_AUDIO_PROCESS_H

#endif //BEAT_PER_MILE_AUDIO_PROCESS_H
extern "C" {
    #include <libavutil/samplefmt.h>
    #include <libavcodec/avcodec.h>
    #include <libavformat/avformat.h>
}
#include <string>

struct audio_processor{
private:
    std::vector<float> res;
    void process_audio(AVFrame *frame);
    void channel_split(int channel, float data);
public:
    audio_processor();
    std::vector<float> channel_r;
    std::vector<float> channel_l;
    int total_frame;
    int sample_rate;
    void load_audio(char file_path[]);
    
    float* make_planner_data();
};
