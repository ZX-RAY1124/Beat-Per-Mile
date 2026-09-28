import { textToSpeech } from '@kit.CoreSpeechKit';

export class TtsManager {
  private ttsEngine?: textToSpeech.TextToSpeechEngine;
  private engineReady = false;

  async initEngine(): Promise<void> {
    const extraParam: Record<string, Object> = {
      'style': 'interaction-broadcast',
      'locate': 'CN',
      'name': 'MyTTS_' + Date.now(), // 使用唯一引擎名称防止冲突
      'isBackStage': true            // 支持后台播报
    };
    const initParams: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: 0,        // 0-聆小珊女声, 1-凌飞哲男声
      online: 1,        // 1-在线, 0-离线
      extraParams: extraParam
    };

    try {
      this.ttsEngine = await textToSpeech.createEngine(initParams);
      this.engineReady = true;
      console.info('TTS 引擎创建成功');
    } catch (err) {
      console.error('引擎创建失败:', err);
    }
  }

  speakText(text: string): void {
    if (!this.engineReady || !this.ttsEngine) {
      console.warn('引擎未就绪');
      return;
    }
    const speakParams: textToSpeech.SpeakParams = {
      requestId: 'req_' + Date.now(),
      extraParams:{
        languageContext: 'zh-CN',
        rate: 1.0,    // 语速 0.5~2.0
        pitch: 1.0,   // 音调
        volume: 1.0   // 音量
      }
    };
    try {
      this.ttsEngine.speak(text, speakParams);
    } catch (e){
      console.error('face error in voice maker', e);
    }
  }

  release(): void {
    if (this.ttsEngine) {
      this.ttsEngine.shutdown();
      this.ttsEngine = undefined;
      this.engineReady = false;
    }
  }
}