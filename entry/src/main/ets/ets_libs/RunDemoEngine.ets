/**
 * RunDemoEngine.ets —— 跑步播放器的“演示引擎”（临时，native session 的占位）
 *
 * 为什么需要它：
 *   现在 native 侧还没有“会话”接口（没有进度、没有 seek、没有按 id 调速、没有拍网格），
 *   而播放器页要能**先演示**三模式 / 进度条 / 拍点光效 / 步频跟随。
 *   所以这里用纯 ArkTS 复刻同一条链路的**数学**，把 UI 先跑通：
 *
 *       恒速模式:  目标步频 = 规定值            ┐
 *       曲线模式:  目标步频 = 曲线(运动时间)     ├─► 倍速 = 目标步频 ÷ 歌曲BPM ──► 进度按倍速前进
 *       动态模式:  目标步频 = 实测步频(模拟)     ┘
 *       拍相位 = frac((歌曲位置 - 首拍) / (60/BPM)) ──► 光效
 *
 *   ★ 接真机时只换数据源，页面不用改：
 *       engine.tick()/status()  ←→  session_get_status(id) 轮询
 *       engine.setPlaying()     ←→  session_play/pause
 *       engine.seek()           ←→  session_seek
 *       engine.setMode()        ←→  session_set_mode
 *     原型函数 startTick() 里那个 33ms 定时器，将来就是 status 轮询 + 拍相位插值。
 *
 * song_data.json（放在 ctx.filesDir + '/Media/'）由协作者的 Essentia 管线产出：
 *   { "filename":"xxx.wav", "filedir":"...Media",
 *     "segments":[ { "start":0, "end":10, "bpm":120 } ] }
 *   （旧版段里有 "firstbeat"，与 start 等价，读取时仍兼容）
 * v1 只用 segments[0]；segments 是给以后“一首歌多段落变速”留的。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { SongJSON } from './PlayListStore';

/** 播放模式 */
export const MODE_DYNAMIC: number = 0;   // 动态检测：倍速 = 实测步频 / 歌曲 BPM
export const MODE_CONSTANT: number = 1;  // 恒速：倍速 = 规定步频 / 歌曲 BPM
export const MODE_CURVE: number = 2;     // 曲线：倍速 = 曲线(运动时间) / 歌曲 BPM

export const MEDIA_DIR: string = 'Media';
export const SONG_DATA_NAME: string = 'song_data.json';

/** 倍速上下限（与 TempoFollower 默认一致） */
const MULT_MIN: number = 0.50;
const MULT_MAX: number = 2.00;
/**
 * 倍速平滑时间常数（秒），**按模式取**。
 *
 * 动态模式沿用 TempoFollower.tau = 2.0：步频本身是抖的，倍速必须平滑，
 * 否则每个脚步都会让音乐一顿一顿。（而且动态模式接上 native 管线后，
 * 倍速其实由管线直接覆盖，这个常数基本不参与。）
 *
 * ★ 恒速/曲线的目标是**规定值**（你拖的滑条 / 你画的曲线），没有任何需要滤掉的抖动。
 *   再套 2 秒就只是拖沓 —— 指数逼近要 ~6 秒才到 99%，手感就是"半天才变过去"。
 *   所以这两个模式用很小的时间常数：恒速 0.25s（≈0.75s 到 95%，1 秒内到位），
 *   曲线 0.4s（段切换留一点点过渡，避免速度硬阶跃）。
 */
const TAU_SPEED_DYNAMIC: number = 2.0;
const TAU_SPEED_CONSTANT: number = 0.25;
const TAU_SPEED_CURVE: number = 0.4;

function speedTau(mode: number): number {
  if (mode === MODE_CONSTANT) {
    return TAU_SPEED_CONSTANT;
  }
  if (mode === MODE_CURVE) {
    return TAU_SPEED_CURVE;
  }
  return TAU_SPEED_DYNAMIC;
}
/** 步频模拟的起停包络时间常数（秒） */
const TAU_CADENCE: number = 1.2;
/** 低于这个步频认为“没在跑”，动态模式保持上一档，不让音乐掉速 */
const RUNNING_MIN_SPM: number = 40.0;

export interface SongSegment {
  /** 段落起始时间（秒）＝该段第一拍时间（原 firstbeat 与它等价） */
  start: number;
  end: number;
  bpm: number;
  /**
   * @deprecated 与 start 等价（都是段落第一拍）。新数据不再写这个字段，
   * 保留仅为兼容协作者 / 旧版 song_data.json，读取时作兜底。
   */
  firstbeat?: number;
}

export interface SongData {
  filename: string;
  filedir: string;
  segments: SongSegment[];
}

/** JSON 可能缺字段，解析时先过这一层 */
interface SongDataRaw {
  filename?: string;
  filedir?: string;
  segments?: SongSegment[];
}

/** 曲库里的一个条目。key 是它在 json 里的键（约定用文件名） */
export interface SongEntry {
  key: string;
  song: SongData;
}

/**
 * 多曲库的宽松根类型：
 *   · 新格式：顶层就是一个以"标识"为键的**字典**  { "a.wav": {filename,segments}, … }
 *   · 旧格式：顶层直接是单曲 {filename, filedir, segments}（保留兼容）
 * ⚠️ 刻意**不做** "songs": { … } 那种"可能是数组也可能是字典"的联合类型 ——
 *    ArkTS 对联合类型 + 动态键不友好，容易编不过。
 */
interface SongRootRaw {
  songs?: SongDataRaw[];
  filename?: string;
  filedir?: string;
  segments?: SongSegment[];
}

/** 「当前歌曲」记在 AppStorage 里（跨页面/重进页面都记得） */
export const SONG_KEY_STORAGE: string = 'currentSongKey';

export function getCurrentSongKey(): string {
  const v: string | undefined = AppStorage.get<string>(SONG_KEY_STORAGE);
  return v === undefined ? '' : v;
}

export function setCurrentSongKey(k: string): void {
  AppStorage.setOrCreate<string>(SONG_KEY_STORAGE, k);
}

/** 把宽松的 JSON 单曲归一化成 SongData；没有有效 segments 就返回 null */
function normalizeSong(raw: SongDataRaw): SongData | null {
  const segs: SongSegment[] = (raw.segments !== undefined && raw.segments.length > 0) ? raw.segments : [];
  if (segs.length === 0) {
    return null;
  }
  const song: SongData = {
    filename: raw.filename !== undefined ? raw.filename : '',
    filedir: raw.filedir !== undefined ? raw.filedir : '',
    segments: segs
  };
  return song;
}

/** 曲线一段：运动时间（秒）→ 目标步频 */
export interface CurveStage {
  atSec: number;
  bpm: number;
  name: string;
}

/** 一帧状态快照（页面把它拷进 @State 触发刷新） */
export interface RunStatus {
  mode: number;
  playing: boolean;
  posSec: number;        // 歌曲原速时间轴上的位置（秒）
  durSec: number;
  speed: number;         // 当前播放倍速
  songBpm: number;
  firstBeat: number;
  targetBpm: number;     // 目标步频
  cadenceSpm: number;    // 实测步频（当前为模拟）
  beatPhase: number;     // 0~1，0 = 正好在拍点上
  beatIndex: number;     // 第几拍（可为负）
  offset: number;        // [-1,1]，0 = 正中拍点，与 tempo::beatOffset 同约定
  stageIndex: number;    // 曲线模式下当前段
  stageName: string;
  followState: string;   // 演示用的状态机文案
  stepCount: number;
}

function clampNum(v: number, lo: number, hi: number): number {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/** Media 目录（与 SongList.ets / 协作者约定一致） */
export function mediaDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + MEDIA_DIR;
}

/** 把一组单曲塞进曲库。key 用文件名；没有文件名就用序号 */
function pushSongs(out: SongEntry[], list: SongDataRaw[]): void {
  for (let i = 0; i < list.length; i++) {
    const one: SongData | null = normalizeSong(list[i]);
    if (one === null) {
      continue;
    }
    const key: string = one.filename.length > 0 ? one.filename : ('song#' + i.toString());
    out.push({ key: key, song: one });
  }
}

/**
 * 读 song_data.json —— **整库**。
 *
 * 约定格式（一层列表，顶层直接是数组）：
 *   [ { "filename":"a.wav", "filedir":"…", "segments":[ … ] }, { … } ]
 *
 * 另外两种也认，省得上层写法变来变去：
 *   ·  { "songs": [ … ] }                    —— 外面多包一层
 *   ·  { "filename":…, "segments":[ … ] }    —— 旧的单曲平铺格式
 *
 * 读不到 / 解析失败返回空数组（页面用演示数据兜底）。
 * ⚠️ 文件里若带尾逗号（"firstbeat":0,），标准 JSON.parse 会直接抛，
 *    所以先把「逗号紧跟 } 或 ]」的尾逗号去掉再解析。
 */
export function loadSongDatabase(ctx: common.UIAbilityContext): SongEntry[] {
  const dir: string = mediaDir(ctx);
  // 顺手确保 Media 目录存在：设备文件管理器/后续的歌曲导入都需要它有地方放文件，
  // 也让调试区显示的 filesDir 与实际可用路径一致。
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  } catch (e) {
    console.error('创建 Media 目录失败：' + JSON.stringify(e));
  }

  const path: string = dir + '/' + SONG_DATA_NAME;
  const out: SongEntry[] = [];
  try {
    if (!fileIo.accessSync(path)) {
      return out;
    }
    let text: string = fileIo.readTextSync(path);
    text = text.replace(new RegExp(',\\s*([}\\]])', 'g'), '$1');

    // ---- 形式 A：顶层直接是列表（约定格式）----
    //   静态类型写成数组，但**是不是数组只有运行期知道**，所以必须 Array.isArray 判一下。
    const asList: SongDataRaw[] = JSON.parse(text) as SongDataRaw[];
    if (Array.isArray(asList)) {
      pushSongs(out, asList);
      return out;
    }

    // ---- 形式 B / C：顶层是对象 ----
    const asObj: SongRootRaw = JSON.parse(text) as SongRootRaw;
    if (asObj.songs !== undefined && Array.isArray(asObj.songs)) {
      pushSongs(out, asObj.songs);
      return out;
    }
    if (asObj.segments !== undefined) {
      const single: SongDataRaw = {
        filename: asObj.filename,
        filedir: asObj.filedir,
        segments: asObj.segments
      };
      const one: SongData | null = normalizeSong(single);
      if (one !== null) {
        out.push({ key: one.filename.length > 0 ? one.filename : 'song', song: one });
      }
    }
  } catch (e) {
    console.error('读取 song_data.json 失败：' + JSON.stringify(e));
  }
  return out;
}

/** 兼容旧调用：取曲库第一首；空库返回 null */
export function loadSongData(ctx: common.UIAbilityContext): SongData | null {
  const db: SongEntry[] = loadSongDatabase(ctx);
  return db.length > 0 ? db[0].song : null;
}

/** song_data.json 指向的音频，在沙箱里的完整路径 */
export function songFilePath(ctx: common.UIAbilityContext, song: SongData): string {
  return mediaDir(ctx) + '/' + song.filename;
}

/** "xxx.wav" → "xxx"（按歌名兜底匹配时用） */
function stripExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/**
 * 把歌单里的歌，按顺序翻译成播放器要的 SongEntry。
 *
 * 匹配规则（两级兜底）：
 *   ① 优先用 filename（稳定 id）精确匹配 song_data.json 的 key；
 *   ② filename 为空/对不上时，退回按**歌名**匹配"文件名去扩展名"——
 *      早期 Songs.json / 歌单没有 filename，靠这个也能播。
 * 找不到的条目跳过并打日志：一首歌缺失不该让整个歌单播不了。
 * （预览播放器在用；正式播放器以后直接复用这个函数即可。）
 */
export function resolvePlaylistEntries(ctx: common.UIAbilityContext,
                                       items: SongJSON[]): SongEntry[] {
  const db: SongEntry[] = loadSongDatabase(ctx);
  const out: SongEntry[] = [];
  for (let i = 0; i < items.length; i++) {
    const it: SongJSON = items[i];
    const f: string = it.filename !== undefined ? it.filename : '';

    let hit: SongEntry | null = null;
    // ① filename 精确匹配
    if (f.length > 0) {
      for (let j = 0; j < db.length; j++) {
        if (db[j].key === f) { hit = db[j]; break; }
      }
    }
    // ② 歌名兜底：playlist.name == 文件名去扩展名
    if (hit === null && it.name.length > 0) {
      for (let j = 0; j < db.length; j++) {
        if (stripExtension(db[j].key) === it.name) { hit = db[j]; break; }
      }
    }

    if (hit !== null) {
      out.push(hit);
    } else {
      console.warn('[playlist] song_data.json 里找不到 "' + it.name
        + '"（filename="' + f + '"），跳过');
    }
  }
  return out;
}

/**
 * 演示引擎。所有“音乐侧”的量都从 tick() 推进、由 status() 读出。
 * 注意：这里不做任何 IO / 播放，是纯逻辑，方便以后整体换成 native 会话。
 */
export class RunDemoEngine {
  // ---- 歌曲 ----
  private songBpmV: number = 150;
  private firstBeatV: number = 0;
  private durSecV: number = 198;
  private songNameV: string = '演示歌曲（未找到 song_data.json）';
  private artistV: string = '真离散工作室';

  // ---- 运行状态 ----
  private modeV: number = MODE_DYNAMIC;
  private playingV: boolean = false;
  private posSecV: number = 0;
  private workoutSecV: number = 0;

  // ---- 用户控制量 ----
  private constBpmV: number = 170;
  private cadenceBaseV: number = 168;

  // ---- 内部派生量 ----
  private stagesV: CurveStage[] = [];
  private cadenceSpmV: number = 0;
  private cadenceRamp: number = 0;
  private speedV: number = 1.0;
  private targetBpmV: number = 0;
  private stepAcc: number = 0;
  private stepCountV: number = 0;
  private beatIndexV: number = -1;
  private beatPhaseV: number = 0;
  private followStateV: string = '待机';
  private holdSec: number = 0;
  /** 外部倍速（<0 = 不用）。动态模式接上 native 步频管线后，倍速由管线给，
   *  这里只是让进度条/光效按真实倍速前进。 */
  private externalSpeedV: number = -1;
  /** 原生音频就绪标志；false 时冻结位置推进（见 setAudioReady） */
  private audioReadyV: boolean = true;

  constructor() {
    // 内置演示曲线：热身 → 目标 → 放松（运动时间轴，秒）
    this.stagesV = [
      { atSec: 0, bpm: 150, name: '热身' },
      { atSec: 300, bpm: 170, name: '目标' },
      { atSec: 1200, bpm: 160, name: '放松' }
    ];
  }

  // ==================== 配置 ====================

  /** 用 song_data.json 覆盖歌曲参数；传 null 保持演示默认值 */
  setSong(song: SongData | null): void {
    if (song === null || song.segments.length === 0) {
      return;
    }
    const s0: SongSegment = song.segments[0];
    if (s0.bpm > 0) {
      this.songBpmV = s0.bpm;
    }
    // ★ firstbeat 已废弃：段落的 start 本来就是该段第一拍，两者数值相同。
    //   新数据只写 start；旧文件/协作者文件可能只有 firstbeat，所以兜底读一下。
    this.firstBeatV = (s0.start !== undefined)
      ? s0.start
      : ((s0.firstbeat !== undefined) ? s0.firstbeat : 0);
    let end: number = s0.end;
    for (let i = 0; i < song.segments.length; i++) {
      if (song.segments[i].end > end) {
        end = song.segments[i].end;
      }
    }
    if (end > 0) {
      this.durSecV = end;
    }
    const name: string = song.filename;
    if (name.length > 0) {
      const dot: number = name.lastIndexOf('.');
      this.songNameV = dot > 0 ? name.substring(0, dot) : name;
    }
    this.posSecV = 0;
    this.workoutSecV = 0;
    this.beatIndexV = -1;
    this.stepAcc = 0;
    this.stepCountV = 0;
  }

  /** 用磁盘上的曲线（CurveStore 的 points）覆盖演示曲线；空则忽略 */
  setStagesFromPoints(times: number[], bpms: number[]): void {
    if (times.length === 0 || times.length !== bpms.length) {
      return;
    }
    const st: CurveStage[] = [];
    for (let i = 0; i < times.length; i++) {
      st.push({ atSec: times[i], bpm: bpms[i], name: '第' + (i + 1).toString() + '段' });
    }
    this.stagesV = st;
  }

  /** 交给 native 管线的倍速驱动（动态模式用） */
  setExternalSpeed(m: number): void {
    this.externalSpeedV = m;
  }

  /** 取消外部倍速，回到本引擎自己算 */
  clearExternalSpeed(): void {
    this.externalSpeedV = -1;
  }

  /** 曲线模式当前段的目标步频（给 native 的 PRESET 控制律用） */
  currentCurveBpm(): number {
    return this.curveBpmAt(this.workoutSecV);
  }

  /**
   * 原生音频是否已就绪。
   * ★ false 时**冻结**歌曲位置与运动时钟 —— 否则起播后那几秒"解码+建缓冲"里，
   *   页面位置会自己空走好几秒，等真出声时相位早就对不上了。
   */
  setAudioReady(b: boolean): void {
    this.audioReadyV = b;
  }

  /**
   * 用原生回报的**真实**歌曲位置把估算值拉回来。
   * 这是修"页面拍相位 vs 真实歌曲相位漂移"的关键一步：
   * 页面不再纯靠 dt×倍速 积分，而是周期性以真实位置为准。
   */
  syncPosition(sec: number): void {
    if (!(sec >= 0)) {
      return;
    }
    let p: number = sec;
    if (this.durSecV > 0) {
      p = p % this.durSecV;
    }
    this.posSecV = p;
    this.beatIndexV = -1;
  }

  getMode(): number { return this.modeV; }

  setMode(m: number): void {
    this.modeV = m;
    this.holdSec = 0;
    if (m === MODE_CONSTANT) {
      this.targetBpmV = this.constBpmV;
    }
  }

  isPlaying(): boolean { return this.playingV; }
  setPlaying(b: boolean): void { this.playingV = b; }
  getConstBpm(): number { return this.constBpmV; }
  setConstBpm(v: number): void { this.constBpmV = v; }
  getCadenceBase(): number { return this.cadenceBaseV; }
  setCadenceBase(v: number): void { this.cadenceBaseV = v; }
  getSongBpm(): number { return this.songBpmV; }
  getDuration(): number { return this.durSecV; }
  getSongName(): string { return this.songNameV; }
  getArtist(): string { return this.artistV; }
  getStages(): CurveStage[] { return this.stagesV; }

  /** 进度条拖动 / 回到开头。真机上对应 session_seek */
  seek(sec: number): void {
    this.posSecV = clampNum(sec, 0, this.durSecV);
    this.beatIndexV = -1;
  }

  // ==================== 曲线取值 ====================

  private curveBpmAt(t: number): number {
    let bpm: number = this.stagesV.length > 0 ? this.stagesV[0].bpm : this.songBpmV;
    for (let i = 0; i < this.stagesV.length; i++) {
      if (t >= this.stagesV[i].atSec) {
        bpm = this.stagesV[i].bpm;
      } else {
        break;
      }
    }
    return bpm;
  }

  private stageIndexAt(t: number): number {
    let idx: number = 0;
    for (let i = 0; i < this.stagesV.length; i++) {
      if (t >= this.stagesV[i].atSec) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  // ==================== 推进 ====================

  /**
   * 推进一步。dtSec 为距上次的墙钟秒数（页面按 33ms 调）。
   * ★ 这一步就是将来 native 侧要做的全部事情，只是数据来源换成真实传感器。
   */
  tick(dtSec: number): void {
    if (!(dtSec > 0)) {
      return;
    }
    if (dtSec > 0.5) {
      dtSec = 0.5;   // 息屏/卡顿保护，和 TempoFollower.maxDtSec 一个意思
    }

    // ---- 1) 进度：歌曲位置按倍速前进（歌曲原速时间轴）----
    //   ★ 必须等原生音频就绪，否则加载那几秒会空走
    if (this.playingV && this.audioReadyV) {
      this.posSecV += dtSec * this.speedV;
      if (this.durSecV > 0) {
        while (this.posSecV >= this.durSecV) {
          this.posSecV -= this.durSecV;   // 演示用循环播放
        }
        if (this.posSecV < 0) {
          this.posSecV = 0;
        }
      }
      this.workoutSecV += dtSec;
    }

    // ---- 2) 模拟实测步频（临时；真机是 step_detector 的输出）----
    const rampA: number = 1 - Math.exp(-dtSec / TAU_CADENCE);
    const rampTarget: number = (this.playingV && this.audioReadyV) ? 1 : 0;
    this.cadenceRamp += rampA * (rampTarget - this.cadenceRamp);
    // 确定性生理抖动：同一段演示每次重放都一样，方便比对
    const wob: number = Math.sin(this.workoutSecV * 0.9) * 3.0 + Math.sin(this.workoutSecV * 2.7) * 1.5;
    let cad: number = (this.cadenceBaseV + wob) * this.cadenceRamp;
    if (cad < 0) {
      cad = 0;
    }
    this.cadenceSpmV = cad;

    // ---- 3) 步数累计（近似：步频积分）----
    this.stepAcc += (cad / 60.0) * dtSec;
    this.stepCountV = Math.floor(this.stepAcc);

    // ---- 4) 目标步频：三种模式的唯一分岔点 ----
    if (this.modeV === MODE_DYNAMIC) {
      // 没在跑就保持上一档：对应验收「停下来音乐保持最后一档速度不抽风」
      if (cad >= RUNNING_MIN_SPM) {
        this.targetBpmV = cad;
      }
    } else if (this.modeV === MODE_CONSTANT) {
      this.targetBpmV = this.constBpmV;
    } else {
      this.targetBpmV = this.curveBpmAt(this.workoutSecV);
    }

    // ---- 5) 倍速 = 目标步频 ÷ 歌曲 BPM（平滑，对应 TempoFollower.tau）----
    if (this.targetBpmV > 0 && this.songBpmV > 0) {
      const raw: number = clampNum(this.targetBpmV / this.songBpmV, MULT_MIN, MULT_MAX);
      if (this.playingV) {
        const spA: number = 1 - Math.exp(-dtSec / speedTau(this.modeV));
        this.speedV += spA * (raw - this.speedV);
      }
      this.speedV = clampNum(this.speedV, MULT_MIN, MULT_MAX);

      // ★ 外部倍速优先：接上 native 管线时，倍速以管线为准（进度/光效跟着走）
      if (this.externalSpeedV >= 0) {
        this.speedV = clampNum(this.externalSpeedV, MULT_MIN, MULT_MAX);
      }

      // ---- 6) 状态机文案（演示：真机是 TempoFollower 的 ADJUST/CHASE/HOLD）----
      const err: number = Math.abs(this.speedV - raw);
      if (this.playingV && cad >= RUNNING_MIN_SPM) {
        if (err < 0.01) {
          this.holdSec += dtSec;
        } else {
          this.holdSec = 0;
        }
        this.followStateV = this.holdSec > 1.0 ? 'HOLD 锁定' : (err > 0.03 ? 'CHASE 追相位' : 'ADJUST 调速');
      } else {
        this.holdSec = 0;
        this.followStateV = '待机';
      }
    }

    // ---- 7) 拍相位（对应 beatgrid::Grid.phase01 / tempo::beatOffset）----
    const period: number = 60.0 / this.songBpmV;
    let rel: number = (this.posSecV - this.firstBeatV) % period;
    if (rel < 0) {
      rel += period;
    }
    this.beatPhaseV = rel / period;
    this.beatIndexV = Math.floor((this.posSecV - this.firstBeatV) / period);
  }

  /** 取一帧状态快照 */
  status(): RunStatus {
    const period: number = this.songBpmV > 0 ? 60.0 / this.songBpmV : 0.5;
    let rel: number = (this.posSecV - this.firstBeatV) % period;
    if (rel < 0) {
      rel += period;
    }
    const phase: number = rel / period;
    // 与 tempo::beatOffset 同约定：0 = 正中拍点，±1 = 半拍
    const off: number = phase < 0.5 ? phase * 2.0 : (phase - 1.0) * 2.0;
    const st: RunStatus = {
      mode: this.modeV,
      playing: this.playingV,
      posSec: this.posSecV,
      durSec: this.durSecV,
      speed: this.speedV,
      songBpm: this.songBpmV,
      firstBeat: this.firstBeatV,
      targetBpm: this.targetBpmV,
      cadenceSpm: this.cadenceSpmV,
      beatPhase: phase,
      beatIndex: this.beatIndexV,
      offset: off,
      stageIndex: this.stageIndexAt(this.workoutSecV),
      stageName: this.stagesV.length > 0 ? this.stagesV[this.stageIndexAt(this.workoutSecV)].name : '',
      followState: this.followStateV,
      stepCount: this.stepCountV
    };
    return st;
  }
}
