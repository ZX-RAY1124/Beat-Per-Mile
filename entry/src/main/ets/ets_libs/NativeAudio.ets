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
import { changeSpeed, music_cancel, music_pause, music_play, music_prepare, music_resume, music_seek, music_set_volume, music_start, musicGetStatus } from 'libentry.so';

/**
 * 接歌硬切的两段时间（毫秒）—— 都需要在真机上量，这里给一组保守的起步值。
 *
 *   LEAD_MS：music_start(B) 之后**多久才轮到 A 停**。
 *     体系结构上 B 的 OH_AudioRenderer_Start 到音频真正从扬声器出来要跨一次 IPC，
 *     这段延迟里必须让 A 继续响，否则就是"断了 ~100ms 再接上"。
 *     ⇔ 太短 = 听得见的空隙；太长 = A、B 有可听的重叠（音量叠加）。
 *   FADE_MS：A 淡出的时长。SetVolumeWithRamp 是系统给的平滑音量斜坡，
 *     几十毫秒就足以把"咔"的一下换成听不太出来的交叠。
 */
export const HARD_CUT_LEAD_MS: number = 120;
export const HARD_CUT_FADE_MS: number = 80;

/** musicGetStatus() 返回的 JSON */
export interface NativePlayStatus {
  ok: boolean;
  /** idle | loading | prepared（已解码待起播）| ready | failed | gone */
  state: string;
  frames: number;
  rate: number;
  /** 真实歌曲位置（秒，歌曲原速时间轴） */
  posSec: number;
  /** 真实音频总长（秒）= 解码帧数 ÷ 采样率；0 = 还不知道 */
  durSec: number;
  /** 起播延迟（毫秒）= 发 start 信号 → 第一块真音频回调；-1 = 还没测到 */
  startLatencyMs: number;
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

  /**
   * 跳到歌曲 sec 秒处继续播。
   * native 侧会先 Pause 声卡、清掉 seek 前残留的输出、从新位置重新喂入，再 Start。
   */
  seek(sec: number): void {
    if (this.id < 0) {
      return;
    }
    try {
      music_seek(this.id, sec);
    } catch (e) {
      console.error('NativeAudio.seek 失败：' + JSON.stringify(e));
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

  // ==================== S2：预解码 / 起播分离 ====================

  /**
   * 只准备，不出声：解码 + 建引擎 + 把数据喂进环形缓冲（几秒级），
   * 然后停在 native 那边等 music_start。
   * ★ 这是接歌不断音的关键 —— 那几秒的解码放在**上一首还在播**的时候做掉。
   * @return 是否成功（失败时 this.id 仍是 -1，调用方照旧走"现场加载"那条路）
   */
  prepareOnly(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      this.path = path;
      this.id = music_prepare(path, (block: number) => {
        // 与 music_play 一样：native 的进度回调暂未启用，占位
      });
      this.lastSpeed = -999;
      return this.id >= 0;
    } catch (e) {
      console.error('NativeAudio.prepareOnly 失败：' + JSON.stringify(e));
      this.id = -1;
      return false;
    }
  }

  /**
   * 会话在 native 侧已经结束了（自然播完 / 被清掉）。
   * ★ 必须把 id 作废：否则之后再按播放只会对着一具"已经不存在的会话" resume，
   *   而 music_resume 找不到会话就静静返回 —— 症状是"播放键点了没反应、也没报错"。
   */
  markEnded(): void {
    this.id = -1;
  }

  /** 对已经 prepareOnly 过的会话发"起播"信号（native 那边只做 Start + play()，瞬时） */
  startPrepared(): void {
    if (this.id < 0) {
      return;
    }
    try {
      music_start(this.id);
    } catch (e) {
      console.error('NativeAudio.startPrepared 失败：' + JSON.stringify(e));
    }
  }

  /**
   * 淡出（不停止）。接歌硬切用：给 A 一条 fadeMs 的音量斜坡，
   * 调用方隔一小会儿再 stop() 才不会有"咔"。
   */
  fadeOut(fadeMs: number): void {
    if (this.id < 0) {
      return;
    }
    try {
      music_set_volume(this.id, 0, fadeMs);
    } catch (e) {
      console.error('NativeAudio.fadeOut 失败：' + JSON.stringify(e));
    }
  }

  /** 静音（音量斜坡到 0）：摇杆擦洗进度时用，避免快速换位置时的杂音 */
  mute(fadeMs: number): void {
    if (this.id < 0) {
      return;
    }
    try {
      music_set_volume(this.id, 0, fadeMs);
    } catch (e) {
      console.error('NativeAudio.mute 失败：' + JSON.stringify(e));
    }
  }

  /** 恢复满音量 */
  unmute(fadeMs: number): void {
    if (this.id < 0) {
      return;
    }
    try {
      music_set_volume(this.id, 1, fadeMs);
    } catch (e) {
      console.error('NativeAudio.unmute 失败：' + JSON.stringify(e));
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
