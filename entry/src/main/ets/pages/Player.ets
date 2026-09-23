import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import {
  CurveStage,
  MODE_CONSTANT,
  MODE_CURVE,
  MODE_DYNAMIC,
  RunDemoEngine,
  RunStatus,
  SongEntry,
  getCurrentSongKey,
  loadSongDatabase,
  resolvePlaylistEntries,
  setCurrentSongKey,
  songFilePath,
  TempoPoint
} from '../ets_libs/RunDemoEngine';
import { ACTIVE_CURVE_KEY, CurveFile, CurvePointJson, loadAll as curveLoadAll } from '../ets_libs/CurveStore';
import { ACTIVE_PLAYLIST_KEY, SongListJSON, loadAll as songListLoadAll } from '../ets_libs/PlayListStore';
import {
  HARD_CUT_FADE_MS,
  HARD_CUT_LEAD_MS,
  NativeAudio,
  NativePlayStatus
} from '../ets_libs/NativeAudio';
import { stepPipelineStart, stepPipelineStatus, stepPipelineStop } from 'libentry.so';
import { SOURCE_SIM, STEP_SCENARIOS, getStepScenario, getStepSource } from '../ets_libs/StepSource';

/**
 * 跑步电台 · 播放器页（可演示版）
 *
 * 这一版把原来的「预览播放器」改造为**跑步播放器**：三模式 + 进度条 + 拍点光效 + 步频读数。
 *
 * ⚠️ 数据来源：目前是 RunDemoEngine（纯 ArkTS 复刻链路数学），不是 native 真实数据。
 *    原因见 RunDemoEngine.ets 顶部注释。页面只依赖 status() 这一份快照，
 *    将来把它换成 session_get_status() 轮询即可，UI 不需要改。
 *
 * 三种模式：
 *   动态检测  倍速 = 实测步频(当前为模拟) / 歌曲 BPM，闭环跟随
 *   恒速      倍速 = 规定步频 / 歌曲 BPM
 *   曲线      倍速 = 曲线(运动时间) / 歌曲 BPM（运动时间轴在暂停时冻结）
 *
 * 光效：不再是「按 BPM 自由跑的无限动画」，而是**由歌曲位置算出的拍相位**驱动
 *       （phase = frac((pos - firstBeat) / (60/BPM))，每拍亮起后线性衰减）。
 *       这样变速时相位依然锁在拍上 —— 这才是"音乐节拍实时跟踪"。
 */

/**
 * 提前多少秒开始预解码下一首。
 *
 * 这是个**内存换安全**的旋钮：解码完的整首歌都躺在 native 的内存里
 * （162 秒 / 48k / 立体声 ≈ 60MB+），所以预解码开得越早，
 * "两首歌同时在内存里"的窗口就越长。30 秒足够覆盖几秒的解码，
 * 又不会让内存峰值翻倍太久。
 */
const PREPARE_AHEAD_SEC: number = 30.0;

/** 演示音源（rawfile）；真实音频开关打开时用 */
const NATIVE_RAW: string = 'LostMemory.m4a';

/** 绘制 / 刷新 */
const TICK_MS: number = 33;          // ~30fps
const ALBUM_SIZE: number = 148;
const ALBUM_RADIUS: number = 20;
const GLOW_SHADOW_RADIUS: number = 34;
const GLOW_ALPHA: number = 0.92;

/** 配色（与其余页面一致） */
const ACCENT: string = '#FF6B6B';
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';
const TEXT_TERTIARY: string = '#C4C8D0';
const CARD_BG: string = '#FFFFFF';
const FIELD_BG: string = '#F2F3F7';
const TRACK_BG: string = '#E4E6EE';
const PAGE_BG: string = '#FFFFFF';

/** 模式分段控件 */
const MODE_LABELS: string[] = ['动态检测', '预设'];   // 恒速/曲线已合并为「预设」
const SEG_W: number = 74;
const SEG_H: number = 30;
const SEG_GAP: number = 4;

/** 强调色 + 指定透明度 → '#AARRGGBB' */
function accentWithAlpha(alpha: number): string {
  let a: number = Math.round(alpha * 255);
  if (a < 0) {
    a = 0;
  }
  if (a > 255) {
    a = 255;
  }
  let hex: string = a.toString(16);
  if (hex.length < 2) {
    hex = '0' + hex;
  }
  return '#' + hex + 'FF6B6B';
}

/** 秒 → m:ss */
function formatTime(seconds: number): string {
  const total: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return m.toString() + ':' + (s < 10 ? '0' : '') + s.toString();
}

/**
 * stepPipelineStatus() 返回的 JSON。
 * ⚠️ native 侧字段名 `targetBpm` 实际存的是"目标倍速"（TempoFollower 的乘法系数），
 *    命名遗留，本页不使用它，避免误解。
 */
interface StepPipelineStatus {
  running: boolean;
  cadenceSpm: number;
  multiplier: number;
  targetBpm: number;
  steps: number;
  followState: number;
  lastStepSec: number;
  songSec: number;
  /** 0 = FOLLOW（动态）  1 = PRESET（恒速/曲线） */
  mode: number;
  /** PRESET：最近一次实测相位偏置（offset 单位，圆量，0 = 正中拍点） */
  phaseOffset: number;
  /** PRESET：当前 δ（叠在基准倍速上的临时偏差，会收回 0） */
  delta: number;
  hasPlayer: boolean;
}

/** 跟随时长状态机文案 → 徽标颜色 */
function stateColorOf(state: string): string {
  if (state.indexOf('HOLD') === 0) {
    return '#22A06B';
  }
  if (state.indexOf('CHASE') === 0) {
    return '#FF8E53';
  }
  if (state.indexOf('ADJUST') === 0) {
    return '#4ECDC4';
  }
  return '#B0B5BF';
}

@Component
struct Player {
  @State navPathStack: NavPathStack = new NavPathStack();

  /** 数据源：将来整体替换成 native session */
  private engine: RunDemoEngine = new RunDemoEngine();
  private native: NativeAudio = new NativeAudio();
  private ctx: common.UIAbilityContext | null = null;
  private tickId: number = -1;
  private lastTickMs: number = 0;

  // ---- 从 engine.status() 拷进来的快照 ----
  @State mode: number = MODE_DYNAMIC;
  @State playing: boolean = false;
  @State posSec: number = 0;
  @State durSec: number = 198;
  @State speed: number = 1.0;
  @State songBpm: number = 150;
  @State firstBeat: number = 0;
  @State targetBpm: number = 0;
  @State cadenceSpm: number = 0;
  @State beatPhase: number = 0;
  @State beatIndex: number = -1;
  /** 拍点偏移 [-1,1]。★ 不能叫 offset —— 会和 CustomComponent 自带的 offset 属性冲突 */
  @State beatOffset: number = 0;
  @State stageIndex: number = 0;
  @State stageName: string = '';
  @State stages: CurveStage[] = [];
  /** 运动时间（秒）—— 曲线的横轴，画游标用 */
  @State workoutSec: number = 0;

  // ---- 预设模式选中的曲线（来自「曲线列表」的 AppStorage 选择，先选后用）----
  /** 是否选到了有效曲线；false 时预设模式走恒速 */
  @State hasCurve: boolean = false;
  @State curveName: string = '';
  @State curvePoints: CurvePointJson[] = [];
  /** 画曲线用的 BPM 量程 */
  @State curveMinBpm: number = 100;
  @State curveMaxBpm: number = 200;
  private curveCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private curveCanvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.curveCanvasSettings);
  /** 上次重画游标所在的整秒（避免每帧刷 Canvas） */
  private curveDrawnSec: number = -999;
  @State followState: string = '待机';
  @State stepCount: number = 0;
  @State songName: string = '演示歌曲';
  @State artist: string = '真离散工作室';

  // ---- 用户控制量 ----
  @State constBpm: number = 170;
  @State cadenceBase: number = 168;

  // ---- 交互 ----
  @State seeking: boolean = false;
  @State pulseOpacity: number = 0;
  @State glowEnabled: boolean = true;
  @State debugOpen: boolean = false;

  // ---- 真实音频（临时，默认关）----
  @State nativeOn: boolean = false;
  @State nativeText: string = '未启用';
  /** 原生播放状态：idle | loading | ready | failed | gone */
  @State nativeState: string = 'idle';
  /** 解码失败原因（state === 'failed' 时有值） */
  @State nativeError: string = '';
  /** 沙箱 filesDir：调试区显示出来，方便知道文件到底该放哪 */
  @State filesDir: string = '';
  /** song_data.json 指向的音频在沙箱里的完整路径 */
  @State songPath: string = '';
  /** 当前歌曲在曲库里的键 */
  @State songKey: string = '';
  /** 曲库里所有歌的键（调试区用来切歌） */
  @State songKeys: string[] = [];
  /** 曲库全量条目（缓存，接歌时按 key 找下一首）。选了歌单时，这里就是歌单队列 */
  private songDb: SongEntry[] = [];

  // ---- 歌单（调试区选一个 = 按它的顺序播放；index < 0 = 用整库）----
  private playlists: SongListJSON[] = [];
  @State playlistNames: string[] = [];
  @State playlistIndex: number = -1;

  // ---- S2/S3：预解码 + 接歌硬切 ----
  /** 已经预解码好、只等 start 信号的下一首（null = 没备） */
  private pendingNext: NativeAudio | null = null;
  private pendingKey: string = '';
  /** 调试区显示接歌状态 */
  @State cutInfo: string = '';
  /** 自动接歌开关（默认开：播到快完自动切下一首） */
  @State autoNext: boolean = true;
  /** 预解码失败过的键：避免到点后每帧重试、把解码线程打爆 */
  private prepareFailedKey: string = '';
  /** 刚切完的静默期（毫秒时间戳），期间不再触发自动切歌，避免连环切 */
  private cutGuardUntil: number = 0;
  /** native 回报的真实音频总长 / 起播延迟 / 剩余（调试区显示） */
  @State nativeDurSec: number = 0;
  @State startLatencyMs: number = -1;
  @State nativeRemain: number = -1;

  // ---- 步数检测源 / native 步频管线 ----
  @State stepSource: number = SOURCE_SIM;
  @State stepScenario: number = 0;
  @State pipelineOn: boolean = false;
  @State pipelineCadence: number = 0;
  @State pipelineMultiplier: number = 1;
  @State pipelineState: number = 0;
  @State pipelineSteps: number = 0;

  /** 每 6 个 tick 轮询一次 native 状态（约 5Hz） */
  private pollCounter: number = 0;

  aboutToAppear(): void {
    const c = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctx = c;

    // 歌单列表页选中的歌单（AppStorage 里记着）：播放器直接按它组队列
    const ap: number | undefined = AppStorage.get<number>(ACTIVE_PLAYLIST_KEY);
    if (ap !== undefined) {
      this.playlistIndex = ap;
    }

    // 歌曲：从 song_data.json 的曲库里选一首（默认第一首 / 上次选的那首）
    this.filesDir = c.filesDir;
    this.loadSongList(c);

    // 曲线：用「曲线列表」里选中的那条（AppStorage，先选后用）。
    // 没选过 / 选的是「恒定BPM」(下标 0) / 点数不足 → 不做曲线，预设模式走恒速。
    try {
      const ci: number | undefined = AppStorage.get<number>(ACTIVE_CURVE_KEY);
      if (ci !== undefined && ci >= 1) {
        const curves: CurveFile[] = curveLoadAll(c);
        if (ci - 1 < curves.length) {
          const f: CurveFile = curves[ci - 1];
          if (f.points.length >= 2) {
            const pts: TempoPoint[] = [];
            let lo: number = f.points[0].bpm;
            let hi: number = f.points[0].bpm;
            for (let i = 0; i < f.points.length; i++) {
              pts.push({ time: f.points[i].time, bpm: f.points[i].bpm, type: f.points[i].type });
              lo = Math.min(lo, f.points[i].bpm);
              hi = Math.max(hi, f.points[i].bpm);
            }
            this.engine.setCurvePoints(pts);
            this.hasCurve = true;
            this.curveName = f.name;
            this.curvePoints = f.points;
            const pad: number = Math.max(5, (hi - lo) * 0.15);
            this.curveMinBpm = lo - pad;
            this.curveMaxBpm = hi + pad;
            console.info('[player] 曲线「' + f.name + '」: ' + pts.length + ' 个点（线性插值）');
          } else {
            console.warn('[player] 选中的曲线点数不足（' + f.points.length + '），预设模式改用恒速');
          }
        }
      } else {
        console.info('[player] 未选择曲线，预设模式使用恒定 BPM');
      }
    } catch (e) {
      console.error('读取曲线失败，预设模式使用恒定 BPM：' + JSON.stringify(e));
    }

    this.songName = this.engine.getSongName();
    this.artist = this.engine.getArtist();
    this.durSec = this.engine.getDuration();
    this.songBpm = this.engine.getSongBpm();
    this.stages = this.engine.getStages();

    this.syncStepSettings();
    this.pullStatus();
    this.startTick();
  }

  aboutToDisappear(): void {
    this.stopTick();
    this.stopPipeline();
    this.cancelPending();
    this.native.stop();
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          // ================= 封面 + 拍点光晕 =================
          Stack() {
            Column()
              .width(ALBUM_SIZE)
              .height(ALBUM_SIZE)
              .borderRadius(ALBUM_RADIUS)
              .backgroundColor(ACCENT)
              .shadow({
                radius: GLOW_SHADOW_RADIUS,
                color: accentWithAlpha(GLOW_ALPHA),
                offsetX: 0,
                offsetY: 0
              })
              .opacity(this.pulseOpacity)
              .visibility(this.glowEnabled ? Visibility.Visible : Visibility.None)

            Column() {
              SymbolGlyph($r('sys.symbol.opticaldisc'))
                .fontSize(64)
                .fontColor([Color.White])
            }
            .width(ALBUM_SIZE)
            .height(ALBUM_SIZE)
            .borderRadius(ALBUM_RADIUS)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .linearGradient({
              angle: 145,
              colors: [['#FF6B6B', 0.0], ['#A78BFA', 1.0]]
            })
          }
          .width('100%')
          .height(ALBUM_SIZE + 60)
          .alignContent(Alignment.Center)   // Stack 没有 justifyContent，居中用 alignContent

          // ================= 歌名 / 歌手 =================
          Column({ space: 4 }) {
            Text(this.songName)
              .fontSize(21)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.artist + ' · BPM ' + this.songBpm.toFixed(0) + ' · 首拍 ' + this.firstBeat.toFixed(2) + 's')
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 14 })

          // ================= 模式切换 =================
          Row() {
            Text('跑步模式')
              .fontSize(15)
              .fontColor(TEXT_PRIMARY)
            Blank()
            this.ModeSwitch()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 24, right: 24, bottom: 12 })

          // ================= 模式专属面板 =================
          Column() {
            if (this.mode === MODE_DYNAMIC) {
              this.DynamicPanel()
            } else if (this.mode === MODE_CURVE) {
              this.CurvePanel()
            } else {
              this.ConstantPanel()      // 预设 + 没选曲线 = 恒速
            }
          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(CARD_BG)
          .borderRadius(16)
          .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })

          // ================= 状态条 =================
          Row({ space: 8 }) {
            this.StatChip('倍速', 'x' + this.speed.toFixed(2), ACCENT)
            this.StatChip('目标', this.targetBpm.toFixed(0), TEXT_PRIMARY)
            this.StatChip('拍号', this.beatIndex.toString(), TEXT_PRIMARY)
            this.StatChip('步数', this.stepCount.toString(), TEXT_PRIMARY)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14 })

          // 原生播放状态提示：加载中 / 解码失败（这两种以前都是**静默**的）
          if (this.nativeOn && (this.nativeState === 'loading' || this.nativeState === 'failed')) {
            Text(this.nativeState === 'loading'
              ? '正在加载歌曲（解码 + 建缓冲，长曲子要几秒）…'
              : ('解码失败：' + this.nativeError))
              .fontSize(12)
              .fontColor(this.nativeState === 'failed' ? ACCENT : TEXT_SECONDARY)
              .width('100%')
              .padding({ left: 16, right: 16, top: 8 })
          }

          // ================= 进度条 =================
          Column({ space: 2 }) {
            Slider({ value: this.posSec, min: 0, max: this.durSec, step: 0.1, style: SliderStyle.OutSet })
              .width('100%')
              .trackColor(TRACK_BG)
              .selectedColor(TEXT_PRIMARY)
              .blockColor(Color.White)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  // 拖动期间由 UI 接管，别让 tick 把滑块拽回去
                  this.seeking = true;
                  this.posSec = value;
                } else {
                  this.engine.seek(value);
                  if (this.nativeOn) {
                    this.native.seek(value);   // 真正跳原生播放位置
                  }
                  this.seeking = false;
                  this.pullStatus();
                }
              })
            Row() {
              Text(formatTime(this.posSec))
                .fontSize(12)
                .fontColor(TEXT_SECONDARY)
              Blank()
              Text(formatTime(this.durSec))
                .fontSize(12)
                .fontColor(TEXT_SECONDARY)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 6, bottom: 10 })

          // ================= 播放控制 =================
          Row({ space: 44 }) {
            SymbolGlyph($r('sys.symbol.backward_end_fill'))
              .fontSize(34)
              .fontColor([TEXT_PRIMARY])
              .onClick(() => {
                this.engine.seek(0);
                this.pullStatus();
              })

            Stack() {
              SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                .fontSize(30)
                .fontColor([Color.White])
            }
            .width(68)
            .height(68)
            .borderRadius(34)
            .backgroundColor(ACCENT)
            .shadow({ radius: 16, color: '#33FF6B6B', offsetX: 0, offsetY: 6 })
            .onClick(() => {
              this.togglePlay();
            })

            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(34)
              .fontColor([TEXT_PRIMARY])
              .onClick(() => {
                this.engine.seek(this.durSec > 1 ? this.durSec - 1 : 0);
                this.pullStatus();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ bottom: 12 })

          // ================= 调试 / 验证区 =================
          this.DebugPanel()
        }
        .width('100%')
        .padding({ bottom: 28 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .backgroundColor(PAGE_BG)
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({ content: { title: { mainTitle: '跑步电台', mainTitleSize: 20 } } })
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }

  // ==================== 模式分段控件 ====================

  @Builder
  ModeSwitch() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(SEG_W)
        .height(SEG_H)
        .borderRadius(8)
        .backgroundColor(Color.White)
        .shadow({ radius: 6, color: '#14000000', offsetX: 0, offsetY: 1 })
        .offset({ x: this.modeSegment() * (SEG_W + SEG_GAP) })

      Row({ space: SEG_GAP }) {
        ForEach(MODE_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontWeight(this.modeSegment() === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.modeSegment() === index ? ACCENT : TEXT_SECONDARY)
            .width(SEG_W)
            .height(SEG_H)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.selectSegment(index);
            })
        }, (label: string) => label)
      }
    }
    .padding(3)
    .backgroundColor(FIELD_BG)
    .borderRadius(10)
  }

  // ==================== 动态模式面板 ====================

  @Builder
  DynamicPanel() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.cadenceSpm.toFixed(0))
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT)
          Text(this.pipelineOn ? '实测步频 / 步每分（native 管线）' : '实测步频 / 步每分（本页模拟）')
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.followState)
          .fontSize(12)
          .fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(stateColorOf(this.followState))
          .borderRadius(10)
      }
      .width('100%')

      if (this.pipelineOn) {
        Row() {
          Text('模拟场景')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
          Blank()
          Text(this.scenarioName())
            .fontSize(13)
            .fontColor(TEXT_PRIMARY)
        }
        .width('100%')

        Text('倍速由 native 管线算出并实际驱动播放；换场景请去「设置 → 算法参数设置」。')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
          .width('100%')

        if (!this.nativeOn) {
          Text('提示：打开下方「真实音频」，才会真正出声并听到变速。')
            .fontSize(11)
            .fontColor(ACCENT)
            .width('100%')
        }
      } else {
        Row({ space: 8 }) {
          Text('模拟跑步强度')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .width(84)
          Slider({ value: this.cadenceBase, min: 120, max: 200, step: 1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .trackColor(TRACK_BG)
            .selectedColor(ACCENT)
            .blockColor(Color.White)
            .onChange((value: number) => {
              this.cadenceBase = Math.round(value);
              this.engine.setCadenceBase(this.cadenceBase);
            })
          Text(this.cadenceBase.toFixed(0))
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('倍速 = 实测步频 ÷ 歌曲 BPM。真机接入后步频来自加速度计（step_detector）。')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
          .width('100%')
      }
    }
    .width('100%')
  }

  // ==================== 恒速模式面板 ====================

  @Builder
  ConstantPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('目标步频')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
          .width(64)
        Slider({ value: this.constBpm, min: 120, max: 220, step: 1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .trackColor(TRACK_BG)
          .selectedColor(ACCENT)
          .blockColor(Color.White)
          .onChange((value: number) => {
            this.constBpm = Math.round(value);
            this.engine.setConstBpm(this.constBpm);
          })
        Text(this.constBpm.toFixed(0) + ' BPM')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
          .width(58)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('倍速 = 目标步频 ÷ 歌曲 BPM = ' + this.constBpm.toFixed(0) + ' ÷ ' + this.songBpm.toFixed(0)
        + ' = x' + (this.constBpm / this.songBpm).toFixed(2))
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
        .width('100%')

      Text('开环：音乐是节拍基准，不读脚步。想跟脚步请切「动态检测」。')
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
    }
    .width('100%')
  }

  // ==================== 曲线模式面板 ====================

  @Builder
  CurvePanel() {
    Column({ space: 10 }) {
      Row() {
        Text(this.curveName.length > 0 ? ('曲线：' + this.curveName) : '曲线')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)
        Text('目标 ' + this.targetBpm.toFixed(0) + ' BPM')
          .fontSize(12)
          .fontColor(ACCENT)
      }
      .width('100%')

      Canvas(this.curveCanvasCtx)
        .width('100%')
        .height(110)
        .backgroundColor(FIELD_BG)
        .borderRadius(10)
        .onReady(() => {
          this.drawCurve();
        })
        .onAreaChange(() => {
          this.drawCurve();
        })

      Text('按「曲线列表」中选中的曲线走：点之间线性插值，走完保持最后一档。')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
        .width('100%')

      Text('开环：音乐是节拍基准，不读脚步。想跟脚步请切「动态检测」。')
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
    }
    .width('100%')
  }

  /** 画选中的曲线 + 当前运动时间游标 + 当前目标 BPM 点 */
  private drawCurve(): void {
    const w: number = this.curveCanvasCtx.width;
    const h: number = this.curveCanvasCtx.height;
    const n: number = this.curvePoints.length;
    if (w <= 0 || h <= 0 || n < 2) {
      return;
    }
    this.curveCanvasCtx.clearRect(0, 0, w, h);

    const pad: number = 8;
    const t0: number = this.curvePoints[0].time;
    const t1: number = this.curvePoints[n - 1].time;
    const span: number = (t1 - t0) > 0 ? (t1 - t0) : 1;
    const lo: number = this.curveMinBpm;
    const hi: number = this.curveMaxBpm > lo ? this.curveMaxBpm : (lo + 1);
    const xOf = (t: number): number => {
      return pad + (t - t0) / span * (w - pad * 2);
    };
    const yOf = (b: number): number => {
      return pad + (1 - (b - lo) / (hi - lo)) * (h - pad * 2);
    };

    // 折线：linear 插值就是直连，形状一致
    this.curveCanvasCtx.beginPath();
    this.curveCanvasCtx.moveTo(xOf(this.curvePoints[0].time), yOf(this.curvePoints[0].bpm));
    for (let i = 1; i < n; i++) {
      this.curveCanvasCtx.lineTo(xOf(this.curvePoints[i].time), yOf(this.curvePoints[i].bpm));
    }
    this.curveCanvasCtx.strokeStyle = ACCENT;
    this.curveCanvasCtx.lineWidth = 2;
    this.curveCanvasCtx.lineJoin = 'round';
    this.curveCanvasCtx.stroke();

    // 顶点
    this.curveCanvasCtx.fillStyle = ACCENT;
    for (let i = 0; i < n; i++) {
      this.curveCanvasCtx.beginPath();
      this.curveCanvasCtx.arc(xOf(this.curvePoints[i].time), yOf(this.curvePoints[i].bpm),
        2.5, 0, Math.PI * 2);
      this.curveCanvasCtx.fill();
    }

    // 当前运动时间游标（超出范围就钉在两端）
    let tNow: number = this.workoutSec;
    if (tNow < t0) {
      tNow = t0;
    }
    if (tNow > t1) {
      tNow = t1;
    }
    const cx: number = xOf(tNow);
    this.curveCanvasCtx.beginPath();
    this.curveCanvasCtx.moveTo(cx, pad);
    this.curveCanvasCtx.lineTo(cx, h - pad);
    this.curveCanvasCtx.strokeStyle = '#2FB3A8';
    this.curveCanvasCtx.lineWidth = 1.5;
    this.curveCanvasCtx.stroke();

    // 当前目标 BPM 的落点
    this.curveCanvasCtx.beginPath();
    this.curveCanvasCtx.arc(cx, yOf(this.targetBpm), 3.5, 0, Math.PI * 2);
    this.curveCanvasCtx.fillStyle = '#2FB3A8';
    this.curveCanvasCtx.fill();
  }

  // ==================== 小组件 ====================

  @Builder
  StatChip(label: string, value: string, valueColor: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(valueColor)
        .maxLines(1)
      Text(label)
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(FIELD_BG)
    .borderRadius(10)
    .alignItems(HorizontalAlign.Center)
  }

  // ==================== 调试 / 验证区 ====================

  @Builder
  DebugPanel() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.debugOpen ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
          .fontSize(20)
          .fontColor([this.debugOpen ? ACCENT : '#B0B5BF'])
          .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
        Text('链路验证信息')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
        Blank()
        Text(this.playing ? '运行中' : '已暂停')
          .fontSize(12)
          .fontColor(this.playing ? '#22A06B' : TEXT_SECONDARY)
      }
      .width('100%')
      .onClick(() => {
        this.debugOpen = !this.debugOpen;
      })

      if (this.debugOpen) {
        this.DebugRow('拍相位 phase', this.beatPhase.toFixed(3) + '（0 = 正拍）')
        this.DebugRow('拍点偏移', this.beatOffset.toFixed(3) + '（±1 = 半拍）')
        this.DebugRow('速度来源', this.modeName())
        this.DebugRow('步频源', this.stepSource === SOURCE_SIM
          ? ('模拟 · ' + this.scenarioName())
          : '真实传感器（未接线）')
        this.DebugRow('native 管线', this.pipelineOn
          ? ('运行中 · ' + this.pipelineStateText())
          : '未启动')
        this.DebugRow('控制律', this.mode === MODE_DYNAMIC
          ? 'FOLLOW（闭环，倍速跟步频）'
          : 'PRESET（开环 + PhaseTrim 相位对齐）')
        this.DebugRow('原生播放状态', this.nativeOn
          ? (this.nativeState + (this.nativeError.length > 0 ? (' · ' + this.nativeError) : ''))
          : '未启用')
        this.DebugRow('歌曲文件', this.songPath.length > 0 ? this.songPath : '未找到 song_data.json')
        this.DebugRow('filesDir', this.filesDir)
        this.DebugRow('当前歌曲键', this.songKey.length > 0 ? this.songKey : '（曲库为空）')

        // 歌单：点一下 = 按这个歌单播放（拿歌单里的 filename 去 song_data.json 找数据）
        Text('歌单（点一下按歌单播放）')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .width('100%')
        Row({ space: 10 }) {
          SymbolGlyph(this.playlistIndex < 0
            ? $r('sys.symbol.checkmark_square_fill')
            : $r('sys.symbol.square'))
            .fontSize(16)
            .fontColor([this.playlistIndex < 0 ? ACCENT : TEXT_TERTIARY])
          Text('全部歌曲（song_data.json）')
            .fontSize(12)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.selectPlaylist(-1);
        })

        ForEach(this.playlistNames, (nm: string, i: number) => {
          Row({ space: 10 }) {
            SymbolGlyph(i === this.playlistIndex
              ? $r('sys.symbol.checkmark_square_fill')
              : $r('sys.symbol.square'))
              .fontSize(16)
              .fontColor([i === this.playlistIndex ? ACCENT : TEXT_TERTIARY])
            Text(nm)
              .fontSize(12)
              .fontColor(TEXT_PRIMARY)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.selectPlaylist(i);
          })
        }, (nm: string, i: number) => nm + '#' + i.toString())

        // 曲库列表：点一下切歌（调试用；以后由歌曲列表页接管）
        if (this.songKeys.length > 0) {
          Text('曲库（点一下切换）')
            .fontSize(12)
            .fontColor(TEXT_SECONDARY)
            .width('100%')
          ForEach(this.songKeys, (k: string) => {
            Row({ space: 10 }) {
              SymbolGlyph(k === this.songKey
                ? $r('sys.symbol.checkmark_square_fill')
                : $r('sys.symbol.square'))
                .fontSize(16)
                .fontColor([k === this.songKey ? ACCENT : TEXT_TERTIARY])
              Text(k)
                .fontSize(12)
                .fontColor(TEXT_PRIMARY)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.switchSong(k);
            })
          }, (k: string) => k)
        }
        // ---- S2/S3：预解码 + 自动接歌 ----
        Row({ space: 8 }) {
          Text('自动接歌（放到快完切下一首）')
            .fontSize(13)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoNext })
            .selectedColor(ACCENT)
            .onChange((isOn: boolean) => {
              this.autoNext = isOn;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.DebugRow('接歌', this.cutInfo.length > 0 ? this.cutInfo : '（未预解码）')
        this.DebugRow('下一首', this.pendingNext !== null
          ? ('已备好：' + this.pendingKey)
          : (this.prepareFailedKey.length > 0 ? ('预解码失败：' + this.prepareFailedKey) : '未预解码'))
        this.DebugRow('剩余 / 提前量', (this.nativeRemain >= 0 ? this.nativeRemain.toFixed(2) + 's' : '—')
          + ' / ' + (this.cutLeadSec() * 1000).toFixed(0) + 'ms')
        this.DebugRow('起播延迟', this.startLatencyMs > 0
          ? (this.startLatencyMs.toString() + ' ms（实测）')
          : ('未测到，先用常量 ' + HARD_CUT_LEAD_MS.toString() + ' ms'))
        this.DebugRow('native 音频总长', this.nativeDurSec > 0
          ? (formatTime(this.nativeDurSec) + ' · 曲库标的 ' + formatTime(this.durSec))
          : formatTime(this.durSec))
        Row({ space: 8 }) {
          Text('预解码下一首')
            .fontSize(12)
            .fontColor(ACCENT)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
            .onClick(() => {
              this.prepareNextSong();
            })
          Text('硬切到它')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(ACCENT)
            .borderRadius(8)
            .onClick(() => {
              this.doHardCut(false);
            })
          Blank()
        }
        .width('100%')

        this.DebugRow('光效', this.glowEnabled ? '开（拍相位驱动）' : '关')
        this.DebugRow('歌曲时长', formatTime(this.durSec) + ' · 共 ' + this.totalBeats() + ' 拍')

        Row({ space: 8 }) {
          Text('真实音频（实验）')
            .fontSize(13)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
          Text(this.nativeText)
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
          Toggle({ type: ToggleType.Switch, isOn: this.nativeOn })
            .selectedColor(ACCENT)
            .onChange((isOn: boolean) => {
              this.setNative(isOn);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('原生接口目前无进度/seek，勾选后进度条仍是本页估算；native 修好后由 session 接口接管。')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .margin({ left: 16, right: 16, top: 8 })
    .backgroundColor(FIELD_BG)
    .borderRadius(14)
  }

  @Builder
  DebugRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(TEXT_SECONDARY)
        .layoutWeight(1)
      Text(value)
        .fontSize(12)
        .fontColor(TEXT_PRIMARY)
    }
    .width('100%')
  }

  // ==================== 逻辑 ====================

  // ==================== 步数检测源 / native 步频管线 ====================

  // ==================== 曲库 / 切歌 ====================

  /**
   * 读曲库，并按 AppStorage 里记的键选中一首（记的键不在库里就用第一首）。
   *
   * ★ 若选了歌单（playlistIndex >= 0），队列就按**歌单里的 filename 顺序**
   *   从 song_data.json 取条目；否则用整库。
   *   歌单存的是文件名这个稳定 id，详细 BPM 数据仍在 song_data.json。
   */
  private loadSongList(c: common.UIAbilityContext): void {
    // 歌单列表（调试区选择用）
    const pls: SongListJSON[] = songListLoadAll(c);
    this.playlists = pls;
    const names: string[] = [];
    for (let i = 0; i < pls.length; i++) {
      names.push(pls[i].name);
    }
    this.playlistNames = names;
    if (this.playlistIndex >= pls.length) {
      this.playlistIndex = pls.length > 0 ? 0 : -1;
    }

    let db: SongEntry[] = [];
    if (this.playlistIndex >= 0 && this.playlistIndex < pls.length) {
      const pl: SongListJSON = pls[this.playlistIndex];
      // filename 优先，老数据（filename 为空）按歌名兜底 —— 见 resolvePlaylistEntries
      db = resolvePlaylistEntries(c, pl.songList);
      console.info('[player] 歌单「' + pl.name + '」: ' + pl.songList.length
        + ' 首 → song_data.json 命中 ' + db.length + ' 首');
    } else {
      db = loadSongDatabase(c);
    }

    const keys: string[] = [];
    for (let i = 0; i < db.length; i++) {
      keys.push(db[i].key);
    }
    this.songKeys = keys;
    this.songDb = db;

    if (db.length === 0) {
      this.songKey = '';
      this.songPath = '';
      this.engine.setSong(null);      // 退回演示默认值
      return;
    }

    let idx: number = 0;
    const want: string = getCurrentSongKey();
    for (let i = 0; i < db.length; i++) {
      if (db[i].key === want) {
        idx = i;
        break;
      }
    }
    this.songKey = db[idx].key;
    setCurrentSongKey(this.songKey);
    this.engine.setSong(db[idx].song);
    this.songPath = songFilePath(c, db[idx].song);
  }

  /** 切歌（调试用）：停掉播放与管线 → 换歌 → 状态刷新 */
  private switchSong(key: string): void {
    if (key === this.songKey) {
      return;
    }
    const c = this.ctx;
    if (c === null) {
      return;
    }
    this.stopPipeline();
    this.cancelPending();     // 预解码了一半就直接换歌 ⇒ 把那个会话放掉，否则它一直挂着
    this.native.stop();
    this.engine.setPlaying(false);
    setCurrentSongKey(key);
    this.loadSongList(c);
    this.seeking = false;
    this.pullStatus();
  }

  /**
   * 选歌单：停掉播放与管线 → 换队列（按歌单里的 filename 去 song_data.json 找数据）→ 刷新。
   * 传 -1 表示用整库。
   */
  private selectPlaylist(index: number): void {
    if (index === this.playlistIndex) {
      return;
    }
    const c = this.ctx;
    if (c === null) {
      return;
    }
    this.stopPipeline();
    this.cancelPending();
    this.native.stop();
    this.engine.setPlaying(false);
    this.playlistIndex = index;
    // 记到 AppStorage：与歌单列表页的选择保持同步
    AppStorage.setOrCreate<number>(ACTIVE_PLAYLIST_KEY, index);
    this.loadSongList(c);
    this.seeking = false;
    this.pullStatus();
  }

  // ==================== S2/S3：预解码 + 接歌硬切 ====================

  /** 曲库里的下一首（到头回绕）；只有一首 / 库空返回 null */
  private nextSongEntry(): SongEntry | null {
    if (this.songDb.length < 2) {
      return null;
    }
    let idx: number = 0;
    for (let i = 0; i < this.songDb.length; i++) {
      if (this.songDb[i].key === this.songKey) {
        idx = i;
        break;
      }
    }
    return this.songDb[(idx + 1) % this.songDb.length];
  }

  /**
   * 只把下一首**预解码**（几秒级），当前这首照常播。
   * ★ 这就是"不断音"的全部前提：解码那几秒绝不能落在切换的那一瞬间。
   */
  private prepareNextSong(): void {
    const c = this.ctx;
    if (c === null) {
      return;
    }
    if (this.pendingNext !== null) {
      return;                      // 已经备好了（也保证同时只有一个预解码）
    }
    const nx: SongEntry | null = this.nextSongEntry();
    if (nx === null) {
      this.cutInfo = '曲库里没有下一首';
      return;
    }
    if (nx.key === this.prepareFailedKey) {
      return;                      // 这首歌刚失败过，别再重试
    }
    const t: NativeAudio = new NativeAudio();
    if (!t.prepareOnly(songFilePath(c, nx.song))) {
      this.prepareFailedKey = nx.key;
      this.cutInfo = '预解码发起失败：' + nx.key;
      return;
    }
    this.prepareFailedKey = '';
    this.pendingNext = t;
    this.pendingKey = nx.key;
    this.cutInfo = '正在预解码 ' + nx.key + '…';
  }

  /**
   * 预解码的会话是不是**真的**可以接歌了。
   * ★ pendingNext !== null 只说明"会话建起来了"（music_prepare 会立刻返回），
   *   解码还在后台跑；这时候去 start 就是断音。必须看它的状态到 prepared/ready。
   *   解码失败时会话会被清掉 ⇒ 状态变 gone，这里同样是 false。
   */
  private pendingReady(): boolean {
    if (this.pendingNext === null) {
      return false;
    }
    const ps: NativePlayStatus | null = this.pendingNext.status();
    return ps !== null && (ps.state === 'prepared' || ps.state === 'ready');
  }

  /** 放掉已经预解码但还没切的会话（不给起播信号，让它自己退出） */
  private cancelPending(): void {
    if (this.pendingNext !== null) {
      this.pendingNext.stop();
      this.pendingNext = null;
      this.pendingKey = '';
      this.cutInfo = '已撤销预解码';
    }
  }

  /**
   * 硬切的提前量（秒）：即"提前多久按 start(B)"。
   *
   * ★ 优先用 native **实测**的起播延迟 —— B 从收到信号到真出声要跨一次 IPC，
   *   这段时间跟设备/负载有关，写死常数一定会偏。测到了就照着它提前。
   */
  private cutLeadSec(): number {
    if (this.startLatencyMs > 0) {
      return this.startLatencyMs / 1000.0;
    }
    return HARD_CUT_LEAD_MS / 1000.0;
  }

  /**
   * 到点自动接下一首。判据全部来自 native 的真实量：
   *   · 还剩多少（歌曲时间轴）= durSec(解码帧数÷采样率) − posSec(输入位置÷采样率)
   *   · 还剩多少**真实秒**  = 上面那个 ÷ 倍速（posSec 是按倍速走的）
   *   · 提前量              = startLatencyMs（上次实测的"发信号→真出声"）
   *
   * 所以两件事都在这里发生：
   *   还剩 ≤ PREPARE_AHEAD_SEC  → 预解码下一首（解码那几秒现在做掉）
   *   还剩 ≤ 提前量             → 起播 B，让 B 的第一声正好落在 A 的最后一声上
   */
  private autoAdvance(st: NativePlayStatus): void {
    if (!this.autoNext || !this.nativeOn || !this.playing) {
      return;
    }
    if (Date.now() < this.cutGuardUntil) {
      return;                      // 刚切完，等 B 的状态上来，别连环切
    }
    if (st.state === 'ready' && st.durSec > 0) {
      const remainSong: number = st.durSec - st.posSec;
      if (remainSong <= PREPARE_AHEAD_SEC) {
        this.prepareNextSong();
      }
      const sp: number = this.speed > 0.01 ? this.speed : 1.0;
      const remainReal: number = remainSong / sp;
      // ★ 必须 pendingReady 才切：还没解码完就 start，等于把断音换个地方发生
      if (remainReal <= this.cutLeadSec() && this.pendingReady()) {
        this.doHardCut(true);
      }
      return;
    }
    if (st.state === 'gone' || st.state === 'idle') {
      // 已经放完了才轮到我们：预解码没赶上（大文件 / 刚拖过进度条）。
      // 这时候仍然要往下走 —— 现场加载会静音几秒，但总比停在这儿强。
      this.doHardCut(true);
    }
  }

  /**
   * 硬切到已预解码的下一首。两种时序：
   *
   * 自动（auto=true）——按**实测起播延迟**提前按 start，让 B 的第一声正好落在
   *   A 的最后一声上：
   *       t=0            start(B)
   *       t=lat−FADE     A 音量斜坡开始（FADE 后归零）
   *       t=lat          B 出声 ≈ A 自然播完
   *   重叠期被淡出盖住，所以既不会"断"也不会"双声"。
   *
   * 手动（auto=false，调试按钮）——不预判 A 何时结束，索性让 A 多响 LEAD 一段
   *   盖住 B 的启动延迟，再淡出停掉：
   *       t=0            start(B)
   *       t=LEAD         A 音量斜坡开始（FADE 后归零）
   *       t=LEAD+FADE+40 A stop()
   *
   * 恒速/曲线是**完全开环**：这里只保证"不断音"，不做 A/B 拍相位衔接
   * （要让程序去迁就你的脚步，那是动态检测模式的事）。
   */
  private doHardCut(auto: boolean): void {
    const c = this.ctx;
    if (c === null) {
      return;
    }
    // ★ 预解码的会话必须**真的**就绪才能拿来接（见 pendingReady）。
    //   还在解码 / 已经失败的一律丢掉，走下面的兜底。
    if (this.pendingNext !== null && !this.pendingReady()) {
      this.cancelPending();
    }

    // ★ 兜底：没预解码好也得往下走。现场加载会静音几秒（解码+建引擎），
    //   但"停在这儿不出声"比"断一下"更糟 —— 跑步时音乐停了是致命的。
    if (this.pendingNext === null) {
      const nx: SongEntry | null = this.nextSongEntry();
      if (nx === null) {
        this.cutInfo = '没有下一首（曲库里只有一首）';
        return;
      }
      this.prepareFailedKey = '';       // 允许下次重新尝试预解码
      this.cutInfo = '预解码没赶上，现场加载：' + nx.key;
      this.switchSong(nx.key);          // 换歌 + 停旧的 + 刷新页面参数
      this.engine.setPlaying(true);
      this.startNative();               // 现场加载（会显示"加载中…"）
      this.cutGuardUntil = Date.now() + 3000;
      return;
    }

    const t: NativeAudio = this.pendingNext;
    const old: NativeAudio = this.native;
    const nk: string = this.pendingKey;
    this.pendingNext = null;
    this.pendingKey = '';

    t.startPrepared();                  // B 瞬时起播（native 只做 Start + play()）
    this.native = t;                    // 页面从现在起操作 B

    if (auto) {
      // 自动：按实测起播延迟提前，让 A 的音量刚好在 B 出声时归零
      const latMs: number = this.cutLeadSec() * 1000.0;
      const fadeAt: number = latMs - HARD_CUT_FADE_MS;
      setTimeout(() => {
        old.fadeOut(HARD_CUT_FADE_MS);
      }, fadeAt > 0 ? fadeAt : 0);
      setTimeout(() => {
        old.stop();
      }, latMs + 120);
    } else {
      // 手动：不预判 A 何时结束，让 A 多响 LEAD 一段盖住 B 的启动延迟
      setTimeout(() => {
        old.fadeOut(HARD_CUT_FADE_MS);
        setTimeout(() => {
          old.stop();
        }, HARD_CUT_FADE_MS + 40);
      }, HARD_CUT_LEAD_MS);
    }

    // 页面侧跟着换歌：BPM / 首拍 / 时长 / 位置全部按 B 重置
    setCurrentSongKey(nk);
    this.loadSongList(c);
    this.engine.setPlaying(true);
    this.nativeRemain = -1;
    this.cutGuardUntil = Date.now() + 1000;
    this.cutInfo = (auto ? '自动接歌 → ' : '已硬切 → ') + nk;
  }

  /** 从设置页（AppStorage）同步一次 */
  private syncStepSettings(): void {
    this.stepSource = getStepSource();
    this.stepScenario = getStepScenario();
  }

  /**
   * 动态模式下启动 native 步频管线。
   * 管线在 native 跑：GaitSim → StepDetector → TempoFollower → 倍速 → 播放链路；
   * 本页只负责起停、轮询显示，以及让进度/光效按真实倍速走。
   */
  private startPipeline(): void {
    if (this.pipelineOn) {
      return;
    }
    if (this.stepSource !== SOURCE_SIM) {
      return;                      // 真实传感器尚未接线
    }
    if (this.mode !== MODE_DYNAMIC) {
      // ★ 产品决策：恒速/曲线是**完全开环** —— 音乐按规定倍速播，是节拍基准，
      //   不读步频、不做相位对齐，用户自己跟音乐跑。所以只有动态模式才需要管线。
      //   （native 侧保留 PRESET 控制律备用，但当前不从这里启用。）
      return;
    }
    try {
      stepPipelineStart(this.stepScenario, this.songBpm, this.firstBeat, 0, 0.0);
      this.pipelineOn = true;
      this.pipelineCadence = 0;
      this.pipelineMultiplier = 1;
      this.pipelineState = 0;
      this.pipelineSteps = 0;
    } catch (e) {
      console.error('stepPipelineStart 失败：' + JSON.stringify(e));
    }
  }

  private stopPipeline(): void {
    if (!this.pipelineOn) {
      return;
    }
    try {
      stepPipelineStop();
    } catch (e) {
      console.error('stepPipelineStop 失败：' + JSON.stringify(e));
    }
    this.pipelineOn = false;
    this.engine.clearExternalSpeed();
  }

  /** 轮询 native 状态（约 5Hz） */
  private pollPipeline(): void {
    if (!this.pipelineOn) {
      return;
    }
    try {
      const st = JSON.parse(stepPipelineStatus()) as StepPipelineStatus;
      this.pipelineCadence = st.cadenceSpm;
      this.pipelineMultiplier = st.multiplier;
      this.pipelineState = st.followState;
      this.pipelineSteps = st.steps;

      // 让进度条与拍点光效按"真实倍速"前进
      this.engine.setExternalSpeed(st.multiplier);
    } catch (e) {
      console.error('stepPipelineStatus 解析失败：' + JSON.stringify(e));
    }
  }

  /** native followState(0/1/2) → 文案（复用动态面板的徽标配色） */
  private pipelineStateText(): string {
    if (this.mode !== MODE_DYNAMIC) {
      // PRESET：1 = 正在拉相位，2 = 已对齐（δ 已收回 0）
      return this.pipelineState === 2 ? '已对齐' : '正在对齐';
    }
    if (this.pipelineState === 2) {
      return 'HOLD 锁定';
    }
    if (this.pipelineState === 1) {
      return 'CHASE 追相位';
    }
    return 'ADJUST 调速';
  }

  /** 预设模式不再做相位对齐（见 startPipeline 的说明） */

  private scenarioName(): string {
    if (this.stepScenario >= 0 && this.stepScenario < STEP_SCENARIOS.length) {
      return STEP_SCENARIOS[this.stepScenario].name;
    }
    return '未知场景';
  }

  /** 模式 → 名称（给调试区用） */
  private modeName(): string {
    if (this.mode === MODE_DYNAMIC) {
      return '动态检测（步频跟随）';
    }
    if (this.mode === MODE_CONSTANT) {
      return '预设 · 恒速（' + this.constBpm.toFixed(0) + ' BPM）';
    }
    return '预设 · 曲线（' + this.curveName + '）';
  }

  /** 总拍数（估算，给调试区用） */
  private totalBeats(): number {
    const period: number = this.songBpm > 0 ? 60.0 / this.songBpm : 0.5;
    return Math.max(0, Math.floor(this.durSec / period));
  }

  /** 分段控件下标：0 = 动态，1 = 预设（恒速/曲线已合并） */
  private modeSegment(): number {
    return this.mode === MODE_DYNAMIC ? 0 : 1;
  }

  /**
   * 分段控件选择：
   *   0 → 动态检测；
   *   1 → 预设：选到曲线就走曲线，否则走恒速（先选后用，播放中不换）。
   */
  private selectSegment(seg: number): void {
    const target: number = (seg === 0)
      ? MODE_DYNAMIC
      : (this.hasCurve ? MODE_CURVE : MODE_CONSTANT);
    this.switchMode(target);
  }

  private switchMode(index: number): void {
    if (index === this.mode) {
      return;
    }
    // 注意：不要包 animateTo —— pullStatus() 每 33ms 会把 this.mode 同步回来，
    // 动画会被下一帧直接覆盖掉（表现成"没有动画"），不如直接切。
    this.engine.setMode(index);
    this.mode = index;      // 立刻生效：下面 startPipeline() 要读它
    // ★ 控制律变了（FOLLOW ⇄ PRESET），必须重起管线 —— 两个相位所有者不能同时活着
    this.stopPipeline();
    if (this.playing) {
      this.startPipeline();
    }
    this.pullStatus();
  }

  private togglePlay(): void {
    const next: boolean = !this.playing;
    this.engine.setPlaying(next);
    this.syncStepSettings();   // 可能刚在设置页改过源/场景
    if (next) {
      this.startPipeline();
    } else {
      this.stopPipeline();
    }
    if (this.nativeOn) {
      if (next) {
        this.startNative();
      } else {
        this.native.pause();
        this.nativeText = '已暂停';
      }
    }
    this.pullStatus();
  }

  private setNative(isOn: boolean): void {
    this.nativeOn = isOn;
    if (isOn) {
      this.nativeText = this.native.hasTrack() ? '待播放' : '待准备';
      if (this.playing) {
        this.startNative();
      }
    } else {
      this.native.stop();
      this.nativeText = '未启用';
      this.nativeState = 'idle';
      this.nativeError = '';
      this.engine.setAudioReady(true);   // 退回纯演示：位置正常推进
    }
  }

  /**
   * 轮询原生播放状态（~5Hz）。一次解决三件事：
   *   ① 显示「加载中…」—— 解码+建缓冲要好几秒，以前只能干等
   *   ② 显示解码失败原因 —— 以前是静默的（显示"播放中"却没声）
   *   ③ 用**真实**歌曲位置回填 —— 修掉页面自己积分造成的拍相位漂移
   */
  private pollNative(): void {
    const st: NativePlayStatus | null = this.native.status();
    if (st === null) {
      return;
    }
    this.nativeState = st.state;
    this.nativeError = st.error;
    this.nativeText = this.nativeStateText(st);
    this.nativeDurSec = st.durSec;
    this.startLatencyMs = st.startLatencyMs;
    // ★ 会话在 native 侧已经没了 ⇒ 立刻作废 id。这样：
    //   ① 单曲循环时再按播放是重新解码起播，而不是对死会话 resume（点不动）
    //   ② 下面 doHardCut 里的 old.fadeOut()/old.stop() 变成无害的空操作
    if (st.state === 'gone' || st.state === 'idle') {
      this.native.markEnded();
    }
    // 只有真就绪才让页面位置前进（加载期间冻结，避免空走几秒）
    this.engine.setAudioReady(st.state === 'ready');
    if (st.state === 'ready') {
      this.engine.syncPosition(st.posSec);
      this.nativeRemain = st.durSec > 0 ? (st.durSec - st.posSec) : -1;
    }
    // ★ 到点自动接下一首（判据全部是 native 的真实量）
    this.autoAdvance(st);
  }

  private nativeStateText(st: NativePlayStatus): string {
    if (st.state === 'loading') {
      return '加载中…';
    }
    if (st.state === 'failed') {
      return '解码失败';
    }
    if (st.state === 'prepared') {
      return '已就绪待起播';
    }
    if (st.state === 'ready') {
      return '播放中';
    }
    if (st.state === 'gone') {
      return '会话已结束';
    }
    return '待播放';
  }

  private startNative(): void {
    // 一按播放就先把位置冻住：原生在"解码+建缓冲"期间不会出声，
    // 等 status 报到 ready 才解冻并用真实位置回填（否则这几秒会空走）。
    this.engine.setAudioReady(false);

    // ★ 优先播 Media 里的真实歌曲（song_data.json 指的那个）；
    //   没有 song_data.json 时才退回内置演示音源，否则会出现
    //   "用 LostMemory 的音频配 Protocol 的 BPM" 这种假数据。
    if (this.songPath.length > 0 && this.native.preparePath(this.songPath)) {
      this.native.play();
      this.native.setSpeed(this.speed);
      this.nativeText = this.native.statusText();
      return;
    }

    // ★ 区分两种"没歌可放"：songPath 为空 = 歌单没解析到曲目；有路径但不是它 = 文件缺失
    console.warn('[player] 真实音频不可用，退回内置演示音源。songPath="'
      + this.songPath + '"（空 = 歌单没解析到曲目）');

    const c = this.ctx;
    if (c === null) {
      this.nativeText = '无上下文';
      return;
    }
    this.nativeText = '准备中…（退回内置演示音源）';
    this.native.prepare(c, NATIVE_RAW).then((ok: boolean) => {
      if (!ok) {
        this.nativeText = '准备失败';
        return;
      }
      this.native.play();
      this.native.setSpeed(this.speed);
      this.nativeText = this.native.statusText();
    }).catch((err: Error) => {
      this.nativeText = '失败：' + err.message;
    });
  }

  /**
   * 只刷新光效。每帧调用。
   * ★ 它只写 pulseOpacity **一个** @State，所以 ArkUI 只会更新光晕那一层；
   *   如果每帧去写下面 pullStatus() 的那十几个 @State，整页会 30fps 重绘
   *   （滑块、文字、列表全部重建），在模拟器上就是"卡 + 偶尔空一下"。
   */
  private pullGlow(): void {
    if (!this.glowEnabled) {
      if (this.pulseOpacity !== 0) {
        this.pulseOpacity = 0;
      }
      return;
    }
    const s: RunStatus = this.engine.status();
    let a: number = 1 - s.beatPhase;
    if (a < 0) {
      a = 0;
    }
    this.pulseOpacity = Math.pow(a, 1.6);
  }

  /** 把 engine 的快照拷进 @State（较重，~5Hz 调用） */
  private pullStatus(): void {
    const s: RunStatus = this.engine.status();
    if (!this.seeking) {
      this.posSec = s.posSec;
    }
    this.durSec = s.durSec;
    this.speed = s.speed;
    this.songBpm = s.songBpm;
    this.firstBeat = s.firstBeat;
    this.targetBpm = s.targetBpm;
    this.cadenceSpm = s.cadenceSpm;
    this.beatPhase = s.beatPhase;
    this.beatIndex = s.beatIndex;
    this.beatOffset = s.offset;
    this.stageIndex = s.stageIndex;
    this.stageName = s.stageName;
    this.workoutSec = s.workoutSec;
    this.followState = s.followState;
    this.stepCount = s.stepCount;
    this.mode = s.mode;
    this.playing = s.playing;

    // 曲线游标：按整秒重画，避免每帧刷 Canvas
    if (this.mode === MODE_CURVE) {
      const sec: number = Math.floor(this.workoutSec);
      if (sec !== this.curveDrawnSec) {
        this.curveDrawnSec = sec;
        this.drawCurve();
      }
    }

    // ★ 动态模式接上 native 管线后，步频/倍速/状态机以 native 为准
    if (this.pipelineOn) {
      this.cadenceSpm = this.pipelineCadence;
      this.speed = this.pipelineMultiplier;
      this.followState = this.pipelineStateText();
      this.stepCount = this.pipelineSteps;
    }

    // 光效：每拍突然亮起，到下一拍前衰减（相位驱动，变速时仍锁拍）
    if (this.glowEnabled) {
      let a: number = 1 - s.beatPhase;
      if (a < 0) {
        a = 0;
      }
      this.pulseOpacity = Math.pow(a, 1.6);
    } else {
      this.pulseOpacity = 0;
    }
  }

  private startTick(): void {
    this.stopTick();
    this.lastTickMs = Date.now();
    this.tickId = setInterval(() => {
      const now: number = Date.now();
      const dt: number = (now - this.lastTickMs) / 1000;
      this.lastTickMs = now;
      this.engine.tick(dt);

      // 光效每帧更新（唯一需要 ~30Hz 的东西，且只写一个 @State）
      this.pullGlow();

      // 其余状态 + 管线/原生轮询 ~5Hz（6 × 33ms ≈ 200ms）
      this.pollCounter++;
      // ★ 临近歌曲结尾时切成**每帧轮询**（30Hz ≈ 33ms）：
      //   接歌的提前量只有一两百毫秒，5Hz 的 200ms 粒度根本踩不住那个点
      //   （要么一直没到阈值、要么下一帧已经放完了 ⇒ 必然断一下）。
      //   只在最后这几秒提频，对整页重绘的开销可以忽略。
      const remainPage: number = this.durSec - this.posSec;
      const nearEnd: boolean = this.nativeOn
        && this.nativeState === 'ready'
        && this.autoNext
        && this.playing
        && remainPage >= -0.5
        && remainPage < 2.5;
      if (this.pollCounter >= 6 || nearEnd) {
        this.pollCounter = 0;
        if (this.nativeOn) {
          this.pollNative();             // 加载中 / 解码失败 / 真实位置回填
          this.native.setSpeed(this.speed);
        } else {
          // 没走原生音频：本页纯演示，位置照常推进
          this.engine.setAudioReady(true);
        }
        this.pollPipeline();
        this.pullStatus();
      }
    }, TICK_MS);
  }

  private stopTick(): void {
    if (this.tickId !== -1) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
  }
}

@Builder
export function load() {
  Player()
}
