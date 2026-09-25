export const add: (a: number, b: number) => number;
export const squire:(a: number, b: number ) => number;
export const test_audio:(name:string) => string;
export const music_play: (url:string, callback : (progress: number) => void) => number;
// ★ S2：预解码 / 起播分离。music_prepare 只解码建引擎、不出声，返回会话 id；
//   music_start(id) 对已就绪的会话发信号，瞬时起播（接歌硬切用这个）。
export const music_prepare: (url: string, callback: (progress: number) => void) => number;
export const music_start: (id: number) => void;
export const music_resume:(id: number) => void;
export const music_pause:(id:number) => void;
export const music_cancel:(id: number) => void;
/** 跳到歌曲 sec 秒处继续播（会丢掉 seek 之前残留的输出，不会先播一小段旧位置） */
export const music_seek:(id: number, sec: number) => void;
/** 设置倍速。倍速是全局的：同时出声的流必须共用同一个拍周期 */
export const music_set_speed:(id: number, speed: number) => void;
/** 设置本会话输出音量；rampMs > 0 时用音量斜坡（交叉淡化的基础，系统负责混音） */
export const music_set_volume:(id: number, volume: number, rampMs: number) => void;
export const changeSpeed:(speed: number) => void;
/** ⚠️ 旧接口：同步执行，会阻塞主线程（长音频触发 THREAD_BLOCK_6S），且不回传结果。仅保留兼容，勿在新代码使用 */
export const musicAnalyse:(path: string) => void;
/** 分析返回的歌曲信息（字段名与 PlayListStore 的 SongJSON 对齐） */
export interface SongMeta {
  /** 歌曲名。容器无 title 标签时退回文件名（去扩展名） */
  name: string;
  /** 作者/艺术家。容器无该标签时为空串 */
  author: string;
  /** 总时长，形如 "3:42"；超过 1 小时为 "1:02:03" */
  time: string;
  /** 检测到的 BPM */
  BPM: number;
}

/**
 * 异步分析音频文件，并在**与音频文件相同的目录**下生成 `<同名去扩展名>_beats.csv`。
 * 立即返回，分析在 native 工作线程进行。
 * @param path 沙箱内音频文件的绝对路径
 * @param callback 成功时 meta 为 SongMeta；失败时 meta 为 null 且 err 给出原因
 */
export const analyzeMusicAsync: (path: string,
  callback: (meta: SongMeta | null, err?: string) => void) => void;
/** song_data.json 里的一个速度段落（CppDataAnalyzer 的输出） */
export interface SongSegmentMeta {
  /** 段落起始时间（秒）＝该段第一拍时间（原 firstbeat 已废弃，两者等价） */
  start: number;
  /** 段落结束时间（秒） */
  end: number;
  /** 段落起始 BPM */
  bpm: number;
}
/** analyzeSongSegments() 返回的 JSON 结构 */
export interface SongSegmentsMeta {
  ok: boolean;
  /** 音频文件名（含扩展名），song_data.json 的合并键 */
  filename: string;
  /** 音频所在目录（Media 绝对路径） */
  filedir: string;
  segments: SongSegmentMeta[];
  /** ok=false 时的原因 */
  error?: string;
}
/**
 * CppDataAnalyzer 链路：读 analyzeMusicAsync 生成的 <同名>_beats.csv，
 * 用多 BPM 段落拟合（聚类归一化 + 二次回归 + 递归分裂）算出详细 BPM。
 * 同步、毫秒级；必须在 analyzeMusicAsync 成功之后调用（CSV 才存在）。
 * 返回 JSON 字符串，结构见 SongSegmentsMeta。
 */
export const analyzeSongSegments: (path: string) => string;
/**
 * 轮询分析进度（用于把"还要等多久 / 卡在哪一步"显示出来）。
 * 返回 JSON 字符串：{"phase":"decode|detect|write|done|failed|idle","pct":0~100 或 -1,
 *                    "elapsedMs":number,"running":boolean,"error":string}
 * 建议 setInterval 每 300~500ms 调一次，done/failed 时停掉定时器。
 */
export const getAnalyseStatus: () => string;
/**
 * 步频管线（模拟演示源）：起一条 50Hz 原生线程
 *   GaitSim 合成三轴 → StepDetector 计步 → TempoFollower 算倍速 → 驱动播放
 * @param scenario 模拟场景序号（0 跑步160 / 1 跑步200 / 2 跑步120→200 / 3 跑20s停8s / 4 步行108 / 5 站立不动）
 * @param songBpm 当前歌曲 BPM（倍速 = 步频 / 歌曲BPM）
 * @param firstBeatSec 歌曲第一拍时间（秒）
 * @param mode 控制律：0 = FOLLOW（动态模式，倍速跟实测步频）
 *                        1 = PRESET（恒速/曲线，倍速 = 规定步频/歌曲BPM，再用 PhaseTrim 对齐相位）
 * @param targetBpm PRESET 模式的规定目标步频（FOLLOW 传 0）
 */
export const stepPipelineStart: (scenario: number, songBpm: number, firstBeatSec: number,
  mode: number, targetBpm: number) => void;
export const stepPipelineStop: () => void;
export const stepPipelineSetScenario: (scenario: number) => void;
/** PRESET 模式：曲线推进 / 恒速滑条改动时更新规定目标步频 */
export const stepPipelineSetTargetBpm: (bpm: number) => void;
/**
 * 动态模式「起步延迟校正」窗口（秒）。
 * 窗口内 CHASE 走 TempoFollower 的 delayChase：不调歌曲速度，只把 perfect 窗口
 * 平移去"框住"脚步（无听感变速）；窗口过后自动回到普通相位调整。
 * 0 = 关闭。默认 50 秒。start 前后调用均可（reset 不会清掉它）。
 */
export const stepPipelineSetChaseDelayWindow: (sec: number) => void;
/**
 * 返回 JSON 字符串：
 *   {running,cadenceSpm,multiplier,targetBpm,steps,followState,lastStepSec,songSec,
 *    mode,phaseOffset,delta,hasPlayer}
 * FOLLOW 的 followState: 0=ADJUST 1=CHASE 2=HOLD
 * PRESET 的 followState: 1=正在拉相位 2=已对齐
 */
export const stepPipelineStatus: () => string;
/**
 * S3：真实传感器源（被动喂样）。ArkTS 用 @kit.SensorServiceKit 订阅加速度计
 * （单位 m/s²、含重力），攒一批（~100ms）调 stepSensorPush()。
 *   stepSensorStart(songBpm, firstBeatSec, mode, targetBpm)  与 stepPipelineStart 同参，但不跑模拟线程
 *   stepSensorPush(ax, ay, az, rateHz)  三个等长 Float32Array；时间戳按名义采样率回填
 *   stepSensorStop()
 */
export const stepSensorStart: (songBpm: number, firstBeatSec: number, mode: number, targetBpm: number) => void;
export const stepSensorPush: (samples: number[], n: number, rateHz: number) => void;
export const stepSensorStop: () => void;
/**
 * 查询原生播放状态。返回 JSON 字符串：
 *   {"ok":boolean,"state":"idle|loading|ready|failed|gone","frames":number,
 *    "rate":number,"posSec":number,"error":string}
 * 用途：① 显示「加载中…」而不是干等；② 显示解码失败原因（以前是静默的）；
 *       ③ 用 posSec 回填真实播放位置，修正页面自积分造成的拍相位漂移。
 */
export const musicGetStatus: (id: number) => string;
