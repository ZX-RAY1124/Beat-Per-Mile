import {
  HdsNavDestination,
} from '@kit.UIDesignKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { audioRendererInit, changeSpeed, music_cancel, music_pause, music_play, music_resume } from 'libentry.so';
import { fileIo } from '@kit.CoreFileKit';




@Component
struct audio_test {
  @State navPathStack: NavPathStack = new NavPathStack();
  player:number|undefined = undefined;
  speed:number = 1.0;

  aboutToAppear(): void {
    initArguments(this.getUIContext().getHostContext() as common.UIAbilityContext);
    init();
  }

  aboutToDisappear(): void {
    release(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  build() {
      HdsNavDestination(){
        Column({space:20}){
          Button("播放").width(60).height(30).onClick(()=> {if(hadInit){start();}else {initArguments(this.getUIContext().getHostContext() as common.UIAbilityContext);
            init();start();}})
          Button("暂停").width(60).height(30).onClick(()=> {stop();if(this.player) music_pause(this.player);});
          Button("终止").width(60).height(30).onClick(()=> {if(this.player) music_cancel(this.player);this.player = undefined;release(this.getUIContext().getHostContext() as common.UIAbilityContext);})
          Button("初始化Native").width(200).height(40).onClick(()=> {
            audioRendererInit();       //初始化播放器
          });
          Button("从Native播放").width(200).height(40).onClick(()=> {
            copyRawFileToSandbox(getContext(this) as common.UIAbilityContext, "credits.wav").then((audioPath:string) => {
              if(!this.player) {
                this.player = music_play(audioPath, (block: number) => {
                  console.log(block.toString());
                });
              } else {
                music_resume(this.player);
              }
            });



          });
          Button("加速x0.5").width(120).height(30).onClick(() => {
            this.speed += 0.5
            changeSpeed(this.speed);
          });
          Button("减速x0.5").width(120).height(30).onClick(() => {
            this.speed -= 0.5
            changeSpeed(this.speed);
          });
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

let hadInit: boolean = false;

let audioRenderer: audio.AudioRenderer | undefined = undefined;
// 从API版本26.0.0开始，参数samplingRate支持number类型。
// 音频渲染扩展支持8000Hz到384000Hz范围内以10Hz为步长的采样率值。具体设备支持的采样率规格会存在差异。
let audioStreamInfo: audio.AudioStreamInfo = {
  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100, // 采样率。
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


async function copyRawFileToSandbox(context: common.UIAbilityContext, rawfileName: string): Promise<string> {
  const filesDir = context.filesDir;
  const destPath = `${filesDir}/${rawfileName}`;

  // 1. 获取 rawfile 描述符
  const rawFd = context.resourceManager.getRawFdSync(rawfileName);
  console.info(`rawfile: fd=${rawFd.fd}, offset=${rawFd.offset}, length=${rawFd.length}`);

  // 2. 创建目标文件
  const destFile = fileIo.openSync(destPath,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);

  // 3. 分块拷贝（直接基于 fd 读写）
  const bufferSize = 8192;
  let remaining = rawFd.length;
  let currentOffset = rawFd.offset;

  while (remaining > 0) {
    const toRead = Math.min(bufferSize, remaining);
    const buf = new ArrayBuffer(toRead);

    // ✅ 从源 fd 的指定偏移位置读取
    const bytesRead = fileIo.readSync(rawFd.fd, buf, {
      offset: currentOffset,
      length: toRead
    });
    if (bytesRead <= 0) break;

    // ✅ 写入目标 fd
    fileIo.writeSync(destFile.fd, buf.slice(0, bytesRead));

    currentOffset += bytesRead;
    remaining -= bytesRead;
  }

  // 4. 关闭 fd
  fileIo.closeSync(destFile);

  console.info(`✅ 拷贝完成: ${destPath}`);
  return destPath;
}




async function initArguments(context: common.UIAbilityContext) {
  hadInit = true;
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