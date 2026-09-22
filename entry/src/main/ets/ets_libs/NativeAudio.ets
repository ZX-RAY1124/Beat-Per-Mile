/**
 * NativeAudio.ets —— 现有 native 播放接口的薄封装（临时过渡件）
 *
 * 现状（重要）：native 侧还是「全局单例 + 全局倍速」，而且：
 *   · music_play 的进度回调是**被注释掉的**，实际不会回调；
 *   · changeSpeed() 写的是全局 dataClip->accelerate，只能有一路播放；
 *   · 没有 seek、没有按 id 调速、没有位置查询。
 *
 * 所以这里只做最小封装：能出声、能暂停/恢复/停止、能改倍速。
 * 进度条由上层 RunDemoEngine 估算（不是 native 真实位置）。
 *
 * ★ P1 会话接口（session_open / session_get_status / session_seek / session_set_speed）
 *   就绪后，**整个文件删掉换实现即可**，页面不用动 —— 这是它单独成文件的原因。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { changeSpeed, music_cancel, music_pause, music_play, music_resume, musicGetStatus } from 'libentry.so';

/** musicGetStatus() 返回的 JSON */
export interface NativePlayStatus {
  ok: boolean;
  /** idle | loading | ready | failed | gone */
  state: string;
  frames: number;
  rate: number;
  /** 真实歌曲位置（秒，歌曲原速时间轴） */
  posSec: number;
  error: string;
}

export class NativeAudio {
  private id: number = -1;
  private path: string = '';
  private lastSpeed: number = -999;

  /** 已经准备好一条音轨（沙箱路径已就绪） */
  hasTrack(): boolean {
    return this.path.length > 0;
  }

  /** 是否已经真正在播（拿到了 playerId） */
  isLive(): boolean {
    return this.id >= 0;
  }

  /**
   * 把 rawfile 拷到沙箱（只做一次），返回是否成功。
   * 分块拷贝的写法与 audio_play_test.ets 保持一致。
   */
  async prepare(ctx: common.UIAbilityContext, rawName: string): Promise<boolean> {
    if (this.path.length > 0) {
      return true;
    }
    try {
      const dest: string = ctx.filesDir + '/' + rawName;
      if (!fileIo.accessSync(dest)) {
        const rawFd = ctx.resourceManager.getRawFdSync(rawName);
        const f = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        const bufSize: number = 8192;
        let remaining: number = rawFd.length;
        let off: number = rawFd.offset;
        while (remaining > 0) {
          const toRead: number = Math.min(bufSize, remaining);
          const buf: ArrayBuffer = new ArrayBuffer(toRead);
          const n: number = fileIo.readSync(rawFd.fd, buf, { offset: off, length: toRead });
          if (n <= 0) {
            break;
          }
          fileIo.writeSync(f.fd, buf.slice(0, n));
          off += n;
          remaining -= n;
        }
        fileIo.closeSync(f);
      }
      this.path = dest;
      return true;
    } catch (e) {
      console.error('NativeAudio.prepare 失败：' + JSON.stringify(e));
      return false;
    }
  }

  /**
   * 直接用沙箱里**已经存在**的音频文件（不拷 rawfile）。
   * 这是正式/测试路径：歌放在 filesDir/Media 里，json 指过去。
   * @return 文件不存在或不可读时返回 false，调用方可退回内置演示音源。
   */
  preparePath(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      if (!fileIo.accessSync(path)) {
        return false;
      }
      this.path = path;
      return true;
    } catch (e) {
      console.error('NativeAudio.preparePath 失败：' + JSON.stringify(e));
      return false;
    }
  }

  /** 开始播放（已在播则恢复） */
  play(): void {
    if (this.path.length === 0) {
      return;
    }
    if (this.id >= 0) {
      this.resume();
      return;
    }
    try {
      this.id = music_play(this.path, (block: number) => {
        // 进度回调目前不会触发（native 里那段被注释了），留着占位
      });
      this.lastSpeed = -999;
      // native 侧现在会在 music_play 返回前就把 dataClip 建好，且 speedChange 有判空，
      // 所以这里不用再靠"等一会儿"躲空指针了。
    } catch (e) {
      console.error('NativeAudio.play 失败：' + JSON.stringify(e));
    }
  }

  pause(): void {
    if (this.id >= 0) {
      try {
        music_pause(this.id);
      } catch (e) {
        console.error('NativeAudio.pause 失败：' + JSON.stringify(e));
      }
    }
  }

  resume(): void {
    if (this.id >= 0) {
      try {
        music_resume(this.id);
      } catch (e) {
        console.error('NativeAudio.resume 失败：' + JSON.stringify(e));
      }
    }
  }

  stop(): void {
    if (this.id >= 0) {
      try {
        music_cancel(this.id);
      } catch (e) {
        console.error('NativeAudio.stop 失败：' + JSON.stringify(e));
      }
      this.id = -1;
    }
  }

  /** 倍速（全局）。变化小于 0.01 不发，避免每帧都调 native */
  setSpeed(s: number): void {
    if (this.id < 0) {
      return;
    }
    if (Math.abs(s - this.lastSpeed) < 0.01) {
      return;
    }
    this.lastSpeed = s;
    try {
      changeSpeed(s);
    } catch (e) {
      console.error('NativeAudio.setSpeed 失败：' + JSON.stringify(e));
    }
  }

  /**
   * 查询原生播放状态。
   * 没有在播（id < 0）返回 null；解析失败也返回 null。
   */
  status(): NativePlayStatus | null {
    if (this.id < 0) {
      return null;
    }
    try {
      return JSON.parse(musicGetStatus(this.id)) as NativePlayStatus;
    } catch (e) {
      console.error('NativeAudio.status 解析失败：' + JSON.stringify(e));
      return null;
    }
  }

  statusText(): string {
    if (this.id < 0) {
      return this.hasTrack() ? '待播放' : '未准备';
    }
    return '播放中 #' + this.id.toString();
  }
}
