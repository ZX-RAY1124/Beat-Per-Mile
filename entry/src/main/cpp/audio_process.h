//
// Created on 2026/9/1.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".
// use ffmpeg to analyse music

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
    bool openfail = false;
    bool loadfail = false;
    char *file_path_ = nullptr;
    void quickCheck();
public:
    audio_processor();
    std::vector<float> channel_r;
    std::vector<float> channel_l;
    // ★ 必须初始化：这个对象建在栈上，不初始化就是垃圾值。
    //   total_frame 会被当作播放器环形缓冲大小 —— 垃圾值偏大 ⇒ 一次分配几个 GB
    //   ⇒ std::bad_alloc（未捕获）⇒ terminate ⇒ 闪退。
    int total_frame = 0;
    int sample_rate = 0;
    void load_audio(char file_path[]);
    /** 释放解码缓冲。引擎 loadAudio() 已把数据拷走后调用，可省约 186MB 峰值内存 */
    void release_buffers();
    
    float* make_planner_data();
};
