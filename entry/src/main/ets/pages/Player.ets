import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import {
  CurveStage,
  MODE_CONSTANT,
  MODE_CURVE,
  MODE_DYNAMIC,
  RunDemoEngine,
  RunStatus,
  SongData,
  loadSongData,
  songFilePath
} from '../ets_libs/RunDemoEngine';
import { loadAll as curveLoadAll } from '../ets_libs/CurveStore';
import { NativeAudio } from '../ets_libs/NativeAudio';
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
const MODE_LABELS: string[] = ['动态检测', '恒速', '曲线'];
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
  /** 沙箱 filesDir：调试区显示出来，方便知道文件到底该放哪 */
  @State filesDir: string = '';
  /** song_data.json 指向的音频在沙箱里的完整路径 */
  @State songPath: string = '';

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

    // 歌曲：优先读 song_data.json，读不到就用演示默认值
    this.filesDir = c.filesDir;
    const song: SongData | null = loadSongData(c);
    this.engine.setSong(song);
    if (song !== null) {
      this.songPath = songFilePath(c, song);
    }

    // 曲线：优先用磁盘上第一条曲线，否则用内置演示段
    try {
      const curves = curveLoadAll(c);
      if (curves.length > 0 && curves[0].points.length > 0) {
        const ts: number[] = [];
        const bpms: number[] = [];
        for (let i = 0; i < curves[0].points.length; i++) {
          ts.push(curves[0].points[i].time);
          bpms.push(curves[0].points[i].bpm);
        }
        this.engine.setStagesFromPoints(ts, bpms);
      }
    } catch (e) {
      console.error('读取曲线失败，使用内置演示曲线：' + JSON.stringify(e));
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
            } else if (this.mode === MODE_CONSTANT) {
              this.ConstantPanel()
            } else {
              this.CurvePanel()
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
        .offset({ x: this.mode * (SEG_W + SEG_GAP) })

      Row({ space: SEG_GAP }) {
        ForEach(MODE_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontWeight(this.mode === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mode === index ? ACCENT : TEXT_SECONDARY)
            .width(SEG_W)
            .height(SEG_H)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.switchMode(index);
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
    }
    .width('100%')
  }

  // ==================== 曲线模式面板 ====================

  @Builder
  CurvePanel() {
    Column({ space: 10 }) {
      Row() {
        Text('曲线段（运动时间轴 · 暂停时冻结）')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)
        Text('当前：' + this.stageName + ' ' + this.targetBpm.toFixed(0) + ' BPM')
          .fontSize(12)
          .fontColor(ACCENT)
      }
      .width('100%')

      Row({ space: 8 }) {
        ForEach(this.stages, (st: CurveStage, index: number) => {
          Column({ space: 2 }) {
            Text(st.name)
              .fontSize(12)
              .fontColor(index === this.stageIndex ? Color.White : TEXT_PRIMARY)
            Text(st.bpm.toFixed(0) + ' BPM')
              .fontSize(11)
              .fontColor(index === this.stageIndex ? Color.White : TEXT_SECONDARY)
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(index === this.stageIndex ? ACCENT : FIELD_BG)
          .borderRadius(10)
        }, (st: CurveStage, index: number) => st.name + index.toString())
      }
      .width('100%')

      Text('曲线来自「曲线列表」的第一条；没有曲线时用内置演示段（热身/目标/放松）。')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
        .width('100%')
    }
    .width('100%')
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
        this.DebugRow('歌曲文件', this.songPath.length > 0 ? this.songPath : '未找到 song_data.json')
        this.DebugRow('filesDir', this.filesDir)
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
    if (this.pipelineOn || this.stepSource !== SOURCE_SIM || this.mode !== MODE_DYNAMIC) {
      return;
    }
    try {
      stepPipelineStart(this.stepScenario, this.songBpm, this.firstBeat);
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
    if (this.pipelineState === 2) {
      return 'HOLD 锁定';
    }
    if (this.pipelineState === 1) {
      return 'CHASE 追相位';
    }
    return 'ADJUST 调速';
  }

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
      return '恒速（目标 ' + this.constBpm.toFixed(0) + ' BPM）';
    }
    return '曲线（' + this.stageName + '）';
  }

  /** 总拍数（估算，给调试区用） */
  private totalBeats(): number {
    const period: number = this.songBpm > 0 ? 60.0 / this.songBpm : 0.5;
    return Math.max(0, Math.floor(this.durSec / period));
  }

  private switchMode(index: number): void {
    if (index === this.mode) {
      return;
    }
    // 注意：不要包 animateTo —— pullStatus() 每 33ms 会把 this.mode 同步回来，
    // 动画会被下一帧直接覆盖掉（表现成"没有动画"），不如直接切。
    this.engine.setMode(index);
    // 只有动态模式才由 native 管线驱动倍速；切走就停掉
    if (index === MODE_DYNAMIC) {
      if (this.playing) {
        this.startPipeline();
      }
    } else {
      this.stopPipeline();
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
    }
  }

  private startNative(): void {
    // ★ 优先播 Media 里的真实歌曲（song_data.json 指的那个）；
    //   没有 song_data.json 时才退回内置演示音源，否则会出现
    //   "用 LostMemory 的音频配 Protocol 的 BPM" 这种假数据。
    if (this.songPath.length > 0 && this.native.preparePath(this.songPath)) {
      this.native.play();
      this.native.setSpeed(this.speed);
      this.nativeText = this.native.statusText();
      return;
    }

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
    this.followState = s.followState;
    this.stepCount = s.stepCount;
    this.mode = s.mode;
    this.playing = s.playing;

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

      // 其余状态 + 管线轮询 ~5Hz（6 × 33ms ≈ 200ms）
      this.pollCounter++;
      if (this.pollCounter >= 6) {
        this.pollCounter = 0;
        this.pollPipeline();
        this.pullStatus();
        if (this.nativeOn) {
          // 倍速是慢变量，5Hz 足够；nativeText 也是 @State，别每帧写
          this.native.setSpeed(this.speed);
          this.nativeText = this.native.statusText();
        }
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
