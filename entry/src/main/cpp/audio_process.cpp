//
// Created on 2026/9/1.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "audio_process.h"
#include "hilog/log.h"
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200   // 0x0000 ~ 0xFFFF，自定义业务领域
#define LOG_TAG   "MyTag"   // 标识模块，不能为NULL

audio_processor::audio_processor(){
    avformat_network_init();
}

void audio_processor::load_audio(char file_path[]){
   // ======="ffmpeg"========
    AVFormatContext *formatCtx = nullptr;
    file_path_ = file_path;
    int ret = avformat_open_input(&formatCtx, file_path, nullptr, nullptr);
    
    
    
    if(ret != 0){
        // open fail
        char errBuf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(ret, errBuf, sizeof(errBuf));
        // 打印到控制台或日志
        OH_LOG_ERROR(LOG_APP, "avformat_open_input failed! ret=%{public}d, err=%{public}s", 
                 ret, errBuf);
        delete [] file_path;
        
        quickCheck();
        
        
        openfail = true;
        return;
    }
    if(avformat_find_stream_info(formatCtx, nullptr) < 0) {
        //get fail
        loadfail = true;
        avformat_close_input(&formatCtx);
        return;
    }
    //查找音频流索引
    int audioStreamIdx = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1,-1,NULL,0);
    if (audioStreamIdx < 0){
        //未找到音频流
        avformat_close_input(&formatCtx);
        return;
    }
    delete [] file_path;
    //初始化编码器
    AVCodecParameters *codecParams = formatCtx->streams[audioStreamIdx]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecParams->codec_id);
    if (codec == nullptr) {
        OH_LOG_ERROR(LOG_APP, "avcodec_find_decoder 失败！codec_id=%{public}d（编码器未编进 .so）",
                     static_cast<int>(codecParams->codec_id));
        avformat_close_input(&formatCtx);
        return;
    }
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    if (codecCtx == nullptr) {
        OH_LOG_ERROR(LOG_APP, "avcodec_alloc_context3 失败");
        avformat_close_input(&formatCtx);
        return;
    }
    if (avcodec_parameters_to_context(codecCtx, codecParams) < 0) {
        OH_LOG_ERROR(LOG_APP, "avcodec_parameters_to_context 失败");
        avcodec_free_context(&codecCtx);
        avformat_close_input(&formatCtx);
        return;
    }
    
    //打开编码器
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        OH_LOG_ERROR(LOG_APP, "avcodec_open2 失败！codec=%{public}s", codec->name ? codec->name : "?");
        avcodec_free_context(&codecCtx);
        avformat_close_input(&formatCtx);
        return;
    }
    
    /**读取数据包并解码为帧*/
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    
    while(av_read_frame(formatCtx, packet) >= 0){
        if(packet -> stream_index == audioStreamIdx){
            avcodec_send_packet(codecCtx, packet);
            while(avcodec_receive_frame(codecCtx, frame) == 0){
                //处理数据
                process_audio(frame);
                this->total_frame += frame->nb_samples;
                
            }
        }
        av_packet_unref(packet);
    }
    
    avcodec_send_packet(codecCtx, NULL);
    while(avcodec_receive_frame(codecCtx,frame) == 0){
        process_audio(frame);
        this->total_frame += frame->nb_samples;
    }
    
    
    //释放资源并关闭解码器
    avcodec_close(codecCtx);
    avformat_close_input(&formatCtx);

    OH_LOG_INFO(LOG_APP, "[decode] 完成: frames=%{public}d rate=%{public}d L=%{public}u R=%{public}u",
                total_frame, sample_rate,
                static_cast<unsigned int>(channel_l.size()),
                static_cast<unsigned int>(channel_r.size()));
}

void audio_processor::release_buffers() {
    // ★★ 只能还掉解码时的两个声道缓冲，**res 必须留着** ★★
    //   LiveStretchPlayer::loadAudio() 把 res.data() 记成借用指针 sourceData_，
    //   之后 seekTo() 要靠它把数据从新位置重新喂进引擎。
    //   把 res 也 swap 掉会让 seek 变成 use-after-free（读已释放内存）。
    //   代价：res 那约 62MB 常驻；收益：仍然省下两个声道 ≈ 62MB。
    std::vector<float>().swap(channel_l);
    std::vector<float>().swap(channel_r);
    file_path_ = nullptr;
}

void audio_processor::quickCheck() {
    OH_LOG_INFO(LOG_APP, "========== 快速诊断 ==========");
    
    // 1️⃣ 检查 wav demuxer（这是核心！）
    const AVInputFormat* wavFmt = av_find_input_format("wav");
    if (wavFmt) {
        OH_LOG_INFO(LOG_APP, "[✅] wav demuxer 存在: %{public}s", wavFmt->name);
    } else {
        OH_LOG_ERROR(LOG_APP, "[❌] wav demuxer 不存在！被裁剪了！");
    }
    
    // 2️⃣ 检查所有 demuxer 中是否包含 wav 相关
    void* opaque = nullptr;
    const AVInputFormat* fmt = nullptr;
    bool foundWav = false;
    while ((fmt = av_demuxer_iterate(&opaque))) {
        if (fmt->name && strstr(fmt->name, "wav")) {
            OH_LOG_INFO(LOG_APP, "[✅] 找到 demuxer: %{public}s", fmt->name);
            foundWav = true;
        }
    }
    if (!foundWav) {
        OH_LOG_ERROR(LOG_APP, "[❌] 没有任何 wav 相关的 demuxer！");
    }
    
    OH_LOG_INFO(LOG_APP, "==============================");
}


void audio_processor::process_audio(AVFrame *frame) {
    if (!frame) return;
    enum AVSampleFormat fmt = (enum AVSampleFormat)frame->format;
    int channels = frame->channels;
    int nb_samples = frame->nb_samples;
    int is_planar = av_sample_fmt_is_planar(fmt);

    this->sample_rate = frame->sample_rate;

    if (is_planar) {
        // ── 平面格式：每个声道独立指针 ──
        for (int ch = 0; ch < channels; ch++) {
            if (!frame->extended_data[ch]) continue;
            uint8_t *data_ptr = frame->extended_data[ch];

            for (int i = 0; i < nb_samples; i++) {
                float sample = 0.0f;
                switch (fmt) {
                    case AV_SAMPLE_FMT_FLTP:
                        sample = ((float *)data_ptr)[i];
                        break;
                    case AV_SAMPLE_FMT_S16P:
                        sample = ((int16_t *)data_ptr)[i] / 32768.0f;
                        break;
                    case AV_SAMPLE_FMT_S32P:
                        sample = ((int32_t *)data_ptr)[i] / 2147483648.0f;
                        break;
                    case AV_SAMPLE_FMT_U8P:
                        sample = ((uint8_t *)data_ptr)[i] / 128.0f - 1.0f;
                        break;
                    case AV_SAMPLE_FMT_DBLP:
                        sample = (float)((double *)data_ptr)[i];
                        break;
                    default:
                        sample = 0.0f;
                        break;
                }
                channel_split(ch, sample);
            }
        }
    } else {
        // ── 交错格式：单个缓冲区，声道交错排列 ──
        if (!frame->extended_data[0]) return;
        uint8_t *data_ptr = frame->extended_data[0];

        for (int i = 0; i < nb_samples * channels; i++) {
            float sample = 0.0f;
            switch (fmt) {
                case AV_SAMPLE_FMT_FLT:
                    sample = ((float *)data_ptr)[i];
                    break;
                case AV_SAMPLE_FMT_S16:
                    sample = ((int16_t *)data_ptr)[i] / 32768.0f;
                    break;
                case AV_SAMPLE_FMT_S32:
                    sample = ((int32_t *)data_ptr)[i] / 2147483648.0f;
                    break;
                case AV_SAMPLE_FMT_U8:
                    sample = ((uint8_t *)data_ptr)[i] / 128.0f - 1.0f;
                    break;
                case AV_SAMPLE_FMT_DBL:
                    sample = (float)((double *)data_ptr)[i];
                    break;
                default:
                    sample = 0.0f;
                    break;
            }
            channel_split(i % channels, sample);
        }
    }
}

void audio_processor::channel_split(int channel, float data){
    if(channel == 0)
        this->channel_l.push_back(data);
    if(channel == 1)
        this->channel_r.push_back(data);
    else if (channel > 1){
        return;   
    }
}

float* audio_processor::make_planner_data() {
    res.reserve(this->channel_l.size() + this->channel_r.size());
    res.insert(res.end(), this->channel_l.begin(), this->channel_l.end());
    res.insert(res.end(), this->channel_r.begin(), this->channel_r.end());
    return res.data();
}
