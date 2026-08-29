//
// Created on 2026/8/24.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "test_audio.h"
#include "LiveStretchPlayer.h"
#include "hilog/log.h"
#include <cstdint>


test_audio::test_audio():player(2, 44100, 65536, 1.0, 512) {
    avformat_network_init();
    
    
}

void test_audio::make_name(std::string name) {
    this->name = name;
}

std::string test_audio::get_name() {
    return this->name;
}

void test_audio::init_audio(char file_path[]){
   // ======="ffmpeg"========
    AVFormatContext *formatCtx = avformat_alloc_context();
    if(avformat_open_input(&formatCtx, file_path, NULL, NULL) != 0){
        // open fail
        return;
    }
    if(avformat_find_stream_info(formatCtx, NULL) < 0) {
        //get fail
        return;
    }
    //查找音频流索引
    int audioStreamIdx = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1,-1,NULL,0);
    if (audioStreamIdx < 0){
        //未找到音频流
        return;
    }
    //初始化编码器
    AVCodecParameters *codecParams = formatCtx->streams[audioStreamIdx]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecParams->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codecCtx, codecParams);
    
    //打开编码器
    avcodec_open2(codecCtx,codec,NULL);
    
    /**读取数据包并解码为帧*/
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    
    while(av_read_frame(formatCtx, packet) >= 0){
        if(packet -> stream_index == audioStreamIdx){
            avcodec_send_packet(codecCtx, packet);
            while(avcodec_receive_frame(codecCtx, frame) == 0){
                //处理数据
                process_audio(frame);
            }
        }
        av_packet_unref(packet);
    }
    
    avcodec_send_packet(codecCtx, NULL);
    while(avcodec_receive_frame(codecCtx,frame) == 0){
        
    }
    
    
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

void test_audio::process_audio(AVFrame *frame) {
    if (!frame) return;
    enum AVSampleFormat fmt = (enum AVSampleFormat)frame->format;
    int channels = frame->channels;
    int nb_samples = frame->nb_samples;
    int is_planer = av_sample_fmt_is_planar(fmt);
    
    int bps = av_get_bytes_per_sample(fmt);
    if (bps <= 0) return;  // 安全保护
    this->sample_rate = frame->sample_rate;
    
    if(is_planer){
        //遍历每一个声道
        for(int ch = 0; ch < channels; ch ++) {
            if(!frame->extended_data[ch]) continue;
            int valid_bytes = frame->linesize[0];
            int valid_samples = valid_bytes / bps;
            // 实际有效样本数不能超过 nb_samples
            int samples_to_process = FFMIN(nb_samples, valid_samples);
            
            // 获取该声道指针
            uint8_t *data_ptr = frame->extended_data[ch];
            // 根据格式转为 int16_t* 或 float* 等
            float *samples = (float*)data_ptr;  // 假设是 FLTP
            for (int i = 0; i < samples_to_process; i++) {
                // 处理 samples[i] （第 ch 声道，第 i 个样本）
                channel_split(ch, samples[i]);
            }
            
        }
    } else {
        if (!frame->extended_data[0]) return;
        int total_samples = channels * nb_samples;
        int valid_bytes = frame->linesize[0];
        int valid_samples = valid_bytes / bps;
        int samples_to_process = FFMIN(total_samples, valid_samples);
        uint8_t *data_ptr = frame->extended_data[0];
        float *samples = (float*)data_ptr;  // 假设是 FLT
        for (int i = 0; i < samples_to_process; i++) {
            channel_split(i % channels, samples[i]);
        }
        
    }
}

void test_audio::channel_split(int channel, float data){
    if(channel == 0)
        this->channel_l = data;
    if(channel == 1)
        this->channel_r = data;
    else if (channel > 1){
        return;   
    }
}
