import {
  HdsNavDestination,
} from '@kit.UIDesignKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

@Component
struct audio_test {
  @State navPathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    initArguments(this.getUIContext().getHostContext() as common.UIAbilityContext);
    init();
  }

  build() {
      HdsNavDestination(){
        Column(){
          Button("播放").width(60).height(30).onClick(()=> {start();})
          Button("暂停").width(60).height(30).onClick(()=> {stop();})
          Button("终止").width(60).height(30).onClick(()=> {release(this.getUIContext().getHostContext() as common.UIAbilityContext);})
        }.justifyContent(FlexAlign.Center).offset({y : 200});

      }
      .height("100%")
    .width("100%")
  }
}

class Options {
  public offset?: number;
  public length?: number;
}

let audioRenderer: audio.AudioRenderer | undefined = undefined;
// 从API版本26.0.0开始，参数samplingRate支持number类型。
// 音频渲染扩展支持8000Hz到384000Hz范围内以10Hz为步长的采样率值。具体设备支持的采样率规格会存在差异。
let audioStreamInfo: audio.AudioStreamInfo = {
  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000, // 采样率。
  channels: audio.AudioChannel.CHANNEL_2, // 通道。
  sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, // 采样格式。
  encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW // 编码格式。
};
let audioRendererInfo: audio.AudioRendererInfo = {
  usage: audio.StreamUsage.STREAM_USAGE_MUSIC, // 音频流使用类型：音乐。根据业务场景配置，参考StreamUsage。
  rendererFlags: 0 // 音频渲染器标志。
};
let audioRendererOptions: audio.AudioRendererOptions = {
  streamInfo: audioStreamInfo,
  rendererInfo: audioRendererInfo
};
let writeDataCallback: audio.AudioRendererWriteDataCallback;

async function initArguments(context: common.UIAbilityContext) {
  let bufferSize: number = 0;
  let file = await context.resourceManager.getRawFd('credits.wav');
  writeDataCallback = (buffer: ArrayBuffer) => {
    let options: Options = {
      offset: bufferSize + file.offset,
      length: buffer.byteLength
    };
    if (bufferSize > file.length) {
      return audio.AudioDataCallbackResult.INVALID;
    }
    try {
      let bufferLength = fs.readSync(file.fd, buffer, options);
      bufferSize += buffer.byteLength;
      // 系统会判定buffer有效，正常播放。
      if (bufferSize > file.length) {
        let view = new DataView(buffer);
        for (let i = bufferSize - file.length; i < buffer.byteLength; i++) {
          // 空白区域填充静音数据。当使用音频采样格式为SAMPLE_FORMAT_U8时0x80为静音数据，使用其他采样格式时0为静音数据。
          view.setUint8(i, 0);
        }
      }
      // API version 11不支持返回回调结果，从API version 12开始支持返回回调结果。
      // 如果开发者不希望播放某段buffer，返回audio.AudioDataCallbackResult.INVALID即可。
      return audio.AudioDataCallbackResult.VALID;
    } catch (error) {
      console.error(`Failed to read file. Code: ${error.code}, message: ${error.message}`);
      // ...
      // API version 11不支持返回回调结果，从API version 12开始支持返回回调结果。
      return audio.AudioDataCallbackResult.INVALID;
    }
  };
}

async function init() {
  console.log("Now load audio...")
  audio.createAudioRenderer(audioRendererOptions, (err, renderer) => { // 创建AudioRenderer实例。
    if (!err) {
      console.info('Succeeded in creating audio renderer.');
      // ...
      audioRenderer = renderer;
      if (audioRenderer !== undefined) {
        audioRenderer.on('writeData', writeDataCallback);
        // ...
      }
    } else {
      console.error(`Failed to create audio renderer. Code: ${err.code}, message: ${err.message}`);
      // ...
    }
  });
}

async function start() {
  if (audioRenderer !== undefined) {
    let stateGroup = [audio.AudioState.STATE_PREPARED, audio.AudioState.STATE_PAUSED, audio.AudioState.STATE_STOPPED];
    if (stateGroup.indexOf(audioRenderer.state.valueOf()) === -1) { // 当且仅当状态为prepared、paused和stopped之一时才能启动渲染。
      console.error('Audio renderer state is invalid.');
      // ...
      return;
    }
    // 启动渲染。
    audioRenderer.start((err: BusinessError) => {
      if (err) {
        console.error(`Failed to start audio renderer. Code: ${err.code}, message: ${err.message}`);
        // ...
      } else {
        console.info('Succeeded in starting audio renderer.');
        // ...
      }
    });
  }
}
async function pause() {
  // 暂停渲染。
  if (audioRenderer !== undefined) {
    // 只有渲染器状态为running的时候才能暂停。
    if (audioRenderer.state.valueOf() !== audio.AudioState.STATE_RUNNING) {
      console.info('Audio renderer state is not running.');
      // ...
      return;
    }
    // 暂停渲染。
    audioRenderer.pause((err: BusinessError) => {
      if (err) {
        console.error(`Failed to pause audio renderer. Code: ${err.code}, message: ${err.message}`);
        // ...
      } else {
        console.info('Succeeded in pausing audio renderer.');
        // ...
      }
    });
  }
}
async function stop() {
  if (audioRenderer !== undefined) {
    // 只有渲染器状态为running或paused的时候才可以停止。
    if (audioRenderer.state.valueOf() !== audio.AudioState.STATE_RUNNING &&
      audioRenderer.state.valueOf() !== audio.AudioState.STATE_PAUSED) {
      console.info('Audio renderer state is not running or paused.');
      // ...
      return;
    }
    // 停止渲染。
    audioRenderer.stop((err: BusinessError) => {
      if (err) {
        console.error(`Failed to stop audio renderer. Code: ${err.code}, message: ${err.message}`);
        // ...
      } else {
        console.info('Succeeded in stopping audio renderer.');
        // ...
      }
    });
  }
}
async function release(context: common.UIAbilityContext) {
  if (audioRenderer !== undefined) {
    // 渲染器状态不是released状态，才能release。
    if (audioRenderer.state.valueOf() === audio.AudioState.STATE_RELEASED) {
      console.info('Audio renderer state is released.');
      // ...
      return;
    }

    // ...

    // 释放资源。
    audioRenderer.release((err: BusinessError) => {
      if (err) {
        console.error(`Failed to release audio renderer. Code: ${err.code}, message: ${err.message}`);
        // ...
      } else {
        console.info('Succeeded in releasing audio renderer.');
        // ...
      }
    });
    // 关闭沙箱文件。
    await context.resourceManager.closeRawFd('credit.wav');
  }
}


@Builder
export function load(){
  audio_test();
}