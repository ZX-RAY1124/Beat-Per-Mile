import { HdsNavDestination } from '@kit.UIDesignKit';

/**
 * 播放器页（预览用）
 *
 * 只做"听歌"这件事，不涉及运动/步频。按主流播放平台的样子排：
 * 封面 → 歌名/歌手 → 变速开关 → 倍速拉杆 → 进度条 → 播放控制。
 *
 * 倍速拉杆有两个模式（左上角小开关切换）：
 *   模式1 纯倍速：x0.1 ~ x4，**log2 刻度**（所以 x0.5 和 x2 离 x1 一样远）
 *   模式2 BPM：40 ~ 240，线性刻度
 *
 * 封面外面那圈光效跟着"有效 BPM"闪：拍子处突然亮起，然后在下一个拍子前逐渐暗下去。
 * 现在没有音源和真实数据，所以：
 *   - 歌名/歌手/时长是写死的演示数据，进度条是假的（播放时按倍速前进）
 *   - 光效给了一个临时复选框来控制开关，方便单独看效果
 */

/** 演示数据 */
const SONG_TITLE: string = 'Crave Wave';
const SONG_ARTIST: string = 'LandRoot';
const SONG_ALBUM: string = '演示专辑';
const DEMO_DURATION: number = 198; // 秒，3:18
/** 这首歌的原始 BPM，倍速模式和 BPM 模式靠它互相换算 */
const BASE_BPM: number = 150;

/** 倍速范围（模式1）与 BPM 范围（模式2） */
const SPEED_MIN: number = 0.1;
const SPEED_MAX: number = 4;
const BPM_MIN: number = 40;
const BPM_MAX: number = 240;

/** 封面与光晕 */
const ALBUM_SIZE: number = 176;
const ALBUM_RADIUS: number = 22;
/**
 * 光晕用**阴影**做：和封面同形状的一层垫在封面底下，露在外面的就是它投出的那圈光。
 * 阴影本身是原生高斯模糊、自动贴着形状走，所以不用自己叠层就有"灯带"的观感。
 */
/** 光带的默认宽度（阴影半径，vp）：越大越宽、越弥散 */
const GLOW_SHADOW_RADIUS: number = 36;
/** 拍子处最亮时的不透明度。固定值，不跟滑块走（滑块管的是范围，不是亮度） */
const GLOW_ALPHA: number = 0.9;
/** 临时"光效范围"滑块的量程，直接就是阴影半径 */
const GLOW_RADIUS_MIN: number = 0;
const GLOW_RADIUS_MAX: number = 100;

/** 配色 */
const ACCENT: string = '#FF6B6B';
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';
const FIELD_BG: string = '#F2F3F7';
/** 模式切换控件的每段尺寸：写死才能让白色药丸在两段之间平移 */
const SEG_WIDTH: number = 54;
const SEG_HEIGHT: number = 26;
const TRACK_BG: string = '#E4E6EE';
const PAGE_BG: string = '#FFFFFF';

/** 临时：假进度的刷新间隔 */
const TICK_MS: number = 250;

/** 归一化位置 → 倍速（log2 刻度：位置在 log2 上均匀分布） */
function posToSpeed(t: number): number {
  const lo: number = Math.log2(SPEED_MIN);
  const hi: number = Math.log2(SPEED_MAX);
  return Math.pow(2, lo + (hi - lo) * t);
}

/** 倍速 → 归一化位置 */
function speedToPos(speed: number): number {
  const lo: number = Math.log2(SPEED_MIN);
  const hi: number = Math.log2(SPEED_MAX);
  let s: number = speed;
  if (s < SPEED_MIN) {
    s = SPEED_MIN;
  }
  if (s > SPEED_MAX) {
    s = SPEED_MAX;
  }
  return (Math.log2(s) - lo) / (hi - lo);
}

/** 强调色 + 指定透明度 → '#AARRGGBB'（ArkUI 的八位色是 alpha 在前） */
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

@Component
struct Player {
  @State navPathStack: NavPathStack = new NavPathStack();

  // ---- 变速 ----
  /** 变速总开关 */
  @State speedEnabled: boolean = false;
  /** 拉杆模式：false = 纯倍速，true = BPM */
  @State isBpmMode: boolean = false;
  /** 倍速模式下的拉杆位置（0~1）。0.624 刚好是 x1.0 */
  @State speedPos: number = 0.624;
  /** BPM 模式下的目标步频 */
  @State bpmValue: number = BASE_BPM;

  // ---- 假播放 ----
  @State isPlaying: boolean = false;
  @State progress: number = 42; // 秒
  private timerId: number = -1;

  // ---- 心跳光效 ----
  /** 临时开关：方便单独看光效 */
  @State glowEnabled: boolean = true;
  /**
   * 光效拆成两个互不干涉的部分：
   *   强度 → 阴影颜色里的 alpha（静态属性，滑块一改立刻生效）
   *   闪烁 → pulseOpacity（唯一被动画驱动的属性）
   * 这样调强度不需要动动画，也就不会出现"动画被反复重开、叠在一起疯闪"的问题
   */
  @State pulseOpacity: number = 1;
  /** 临时：光效范围＝阴影半径（vp），滑块直接改它，初值就是 GLOW_SHADOW_RADIUS */
  @State glowRadius: number = GLOW_SHADOW_RADIUS;
  /** 上一次用的搏动周期，避免拖拉杆时疯狂重启动画（不参与渲染） */
  private lastBeatMs: number = 0;

  aboutToDisappear(): void {
    this.stopTimer();
  }

  build() {
    HdsNavDestination() {
      Column() {
        // ================= 封面 + 心跳光晕 =================
        Stack() {
          // 光晕层：和封面同形状、同尺寸，被封面完全盖住；
          // 露在外面的只有它投出的阴影 —— 那就是围着封面的一圈灯带
          Column()
            .width(ALBUM_SIZE)
            .height(ALBUM_SIZE)
            .borderRadius(ALBUM_RADIUS)
            .backgroundColor(ACCENT) //只用来"投出"阴影，本身被封面挡住
            .shadow({
              // 范围跟滑块走；两个都是**静态属性**，改完下一帧生效，不经过动画
              radius: this.glowRadius,
              color: accentWithAlpha(GLOW_ALPHA),
              offsetX: 0,
              offsetY: 0
            })
            // 只有透明度参与动画；峰值亮度 = 强度 × 1，然后淡到 0
            .opacity(this.pulseOpacity)
            .visibility(this.glowEnabled ? Visibility.Visible : Visibility.None)

          // 封面（没有真封面，用唱片图标 + 渐变占位）
          Column() {
            SymbolGlyph($r('sys.symbol.opticaldisc'))
              .fontSize(76)
              .fontColor([Color.White])
          }
          .width(ALBUM_SIZE)
          .height(ALBUM_SIZE)
          .borderRadius(ALBUM_RADIUS)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .linearGradient({           //渐变
            angle: 145,
            colors: [[ '#FF6B6B', 0.0 ], [ '#A78BFA', 1.0 ]]
          })
        }
        .width('100%')
        .layoutWeight(1)
        .onAppear(() => {
          this.restartPulse();
        })

        // ================= 歌名 / 歌手 =================
        Column({ space: 6 }) {
          Text(SONG_TITLE)
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(SONG_ARTIST + ' · ' + SONG_ALBUM)
            .fontSize(14)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 8, bottom: 16 })

        // ================= 变速开关 + 模式切换 =================
        Row({ space: 10 }) {
          Text('变速')
            .fontSize(15)
            .fontColor(TEXT_PRIMARY)
          Toggle({ type: ToggleType.Switch, isOn: this.speedEnabled })
            .selectedColor(ACCENT)
            .onChange((isOn: boolean) => {
              this.speedEnabled = isOn;
              this.restartPulse();
            })
          Blank()
          this.ModeSwitch()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 24, right: 24, bottom: 10 })

        // ================= 倍速拉杆（在进度条上方） =================
        Column({ space: 4 }) {
          Row() {
            Text(this.sliderCaption())
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
            Blank()
            Text(this.sliderValueText())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.speedEnabled ? ACCENT : TEXT_SECONDARY)
          }
          .width('100%')

          if (this.isBpmMode) {
            Slider({ value: this.bpmValue, min: BPM_MIN, max: BPM_MAX, step: 1, style: SliderStyle.OutSet })
              .width('100%')
              .enabled(this.speedEnabled)
              .trackColor(TRACK_BG)
              .selectedColor(ACCENT)
              .blockColor(Color.White)
              // 同样只在松手时换节拍：拖动过程中反复重开无限循环动画，
              // 多个循环叠在一起会让光效乱掉
              .onChange((value: number, mode: SliderChangeMode) => {
                this.bpmValue = Math.round(value);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.restartPulse(true);
                }
              })
          } else {
            // ⚠️ step 必须在 [0.01, max-min] 之内，越界会被静默换成默认值 1。
            // 这个滑块区间只有 0~1，写 0.001 就会退化成"只有 0 和 1 两格"
            // （表现为倍速只能在 x0.10 和 x4.00 之间跳）
            Slider({ value: this.speedPos, min: 0, max: 1, step: 0.01, style: SliderStyle.OutSet })
              .width('100%')
              .enabled(this.speedEnabled)
              .trackColor(TRACK_BG)
              .selectedColor(ACCENT)
              .blockColor(Color.White)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.speedPos = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.restartPulse(true);
                }
              })
          }
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 14 })

        // ================= 进度条 =================
        Column({ space: 2 }) {
          Slider({ value: this.progress, min: 0, max: DEMO_DURATION, step: 0.1, style: SliderStyle.OutSet })
            .width('100%')
            .trackColor(TRACK_BG)
            .selectedColor(TEXT_PRIMARY)
            .blockColor(Color.White)
            .onChange((value: number) => {
              this.progress = value;
            })
          Row() {
            Text(formatTime(this.progress))
              .fontSize(12)
              .fontColor(TEXT_SECONDARY)
            Blank()
            Text(formatTime(DEMO_DURATION))
              .fontSize(12)
              .fontColor(TEXT_SECONDARY)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 10 })

        // ================= 播放控制 =================
        Row({ space: 44 }) {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(34)
            .fontColor([TEXT_PRIMARY])
            .onClick(() => {
              this.progress = 0;
            })

          Stack() {
            SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
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
              this.progress = DEMO_DURATION;
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 14 })

        // ================= 临时：光效调试区 =================
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            SymbolGlyph(this.glowEnabled
              ? $r('sys.symbol.checkmark_square_fill')
              : $r('sys.symbol.square'))
              .fontSize(20)
              .fontColor([this.glowEnabled ? ACCENT : '#B0B5BF'])
              .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
            Text('光效演示（临时）')
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
          }
          .onClick(() => {
            this.glowEnabled = !this.glowEnabled;
            this.restartPulse(true);
          })

          // 拖动时定住显示当前强度，松手才恢复闪烁
          Row({ space: 10 }) {
            Text('光效范围')
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
              .width(56)
            Slider({
              value: this.glowRadius,
              min: GLOW_RADIUS_MIN,
              max: GLOW_RADIUS_MAX,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .enabled(this.glowEnabled)
              .trackColor(TRACK_BG)
              .selectedColor(ACCENT)
              .blockColor(Color.White)
              // 只改半径，**不碰动画**。
              // 半径落在阴影这个静态属性上，改完下一帧就生效，
              // 所以拖动时能实时看到光带变宽变窄；闪烁节奏完全不受影响。
              //
              // ⚠️ 这里千万别调 restartPulse()：每来一个事件就新建一个无限循环动画，
              // 多个循环会叠在同一批属性上互相拉扯，表现为"一碰滑块闪烁就疯掉"
              .onChange((value: number) => {
                this.glowRadius = value;
              })
            Text(this.glowRadius.toFixed(0))
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
              .width(34)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(PAGE_BG)
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({ content: { title: { mainTitle: '正在播放', mainTitleSize: 20 } } })
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }

  /**
   * 模式切换：[倍速 | BPM]
   * 白色药丸是一个单独的层，靠 offset 在两段之间平移；切换时用 animateTo 让它滑过去，
   * 比"底色直接闪一下"顺眼得多
   */
  @Builder
  ModeSwitch() {
    Stack({ alignContent: Alignment.Start }) {
      // 药丸（先画，所以文字压在上面）
      Column()
        .width(SEG_WIDTH)
        .height(SEG_HEIGHT)
        .borderRadius(8)
        .backgroundColor(Color.White)
        .shadow({ radius: 6, color: '#14000000', offsetX: 0, offsetY: 1 })
        .offset({ x: this.isBpmMode ? SEG_WIDTH : 0 })

      Row() {
        Text('倍速')
          .fontSize(13)
          .fontWeight(!this.isBpmMode ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(!this.isBpmMode ? TEXT_PRIMARY : TEXT_SECONDARY)
          .width(SEG_WIDTH)
          .height(SEG_HEIGHT)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.switchMode(false);
          })

        Text('BPM')
          .fontSize(13)
          .fontWeight(this.isBpmMode ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.isBpmMode ? TEXT_PRIMARY : TEXT_SECONDARY)
          .width(SEG_WIDTH)
          .height(SEG_HEIGHT)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.switchMode(true);
          })
      }
    }
    .padding(3)
    .backgroundColor(FIELD_BG)
    .borderRadius(10)
  }

  // ==================== 变速 ====================

  /** 当前倍速值（模式1 由拉杆位置换算） */
  private speedValue(): number {
    return posToSpeed(this.speedPos);
  }

  /** 切换模式时把数值换算过去，保证"实际速度"不跳 */
  private switchMode(toBpm: boolean): void {
    if (toBpm === this.isBpmMode) {
      return;
    }
    if (toBpm) {
      let bpm: number = Math.round(BASE_BPM * this.speedValue());
      if (bpm < BPM_MIN) {
        bpm = BPM_MIN;
      }
      if (bpm > BPM_MAX) {
        bpm = BPM_MAX;
      }
      this.bpmValue = bpm;
    } else {
      this.speedPos = speedToPos(this.bpmValue / BASE_BPM);
    }
    // 切换动作走动画：药丸平移 + 文字变色（数值换算放在外面，不参与动画）
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.isBpmMode = toBpm;
    });
    this.restartPulse(true);
  }

  private sliderCaption(): string {
    return this.isBpmMode ? '目标 BPM（线性刻度）' : '播放倍速（log2 刻度）';
  }

  private sliderValueText(): string {
    if (this.isBpmMode) {
      return this.bpmValue + ' BPM';
    }
    return 'x' + this.speedValue().toFixed(2);
  }

  /** 播放速率：变速关掉就是 1.0 */
  private playRate(): number {
    if (!this.speedEnabled) {
      return 1;
    }
    if (this.isBpmMode) {
      return this.bpmValue / BASE_BPM;
    }
    return this.speedValue();
  }

  // ==================== 心跳光效 ====================

  /** 有效 BPM：光效按它搏动 */
  private effectiveBpm(): number {
    let bpm: number = BASE_BPM;
    if (this.speedEnabled) {
      bpm = this.isBpmMode ? this.bpmValue : BASE_BPM * this.speedValue();
    }
    if (bpm < BPM_MIN) {
      bpm = BPM_MIN;
    }
    if (bpm > BPM_MAX) {
      bpm = BPM_MAX;
    }
    return bpm;
  }

  /** 按有效 BPM 启动（或重启）搏动动画 */
  private restartPulse(force: boolean = false): void {
    if (!this.glowEnabled) {
      this.stopPulse();
      return;
    }
    const beatMs: number = Math.max(150, Math.round(60000 / this.effectiveBpm()));
    // 只在"节拍真的变了"或者 force=true 时才重启。
    // ⚠️ 不要在滑条的每个事件里都调它：每次调用都会新建一个 iterations:-1 的动画，
    // 多个无限循环叠在同一批属性上互相拉扯，表现就是"闪烁突然疯掉"
    if (!force && this.lastBeatMs !== 0 && Math.abs(beatMs - this.lastBeatMs) < 8) {
      return;
    }
    this.lastBeatMs = beatMs;

    // 先把光"瞬间"拉到最亮（这一步不带动画），再交给无限循环动画慢慢暗下去。
    // playMode 用 Normal：每一轮都从动画起点重新开始，所以每拍都是"突然亮起 → 渐暗"，
    // 而不是"渐亮 → 渐暗"那种呼吸感。
    this.pulseOpacity = 1;

    this.getUIContext().animateTo({
      duration: beatMs, //一个拍子的时长，暗下去正好接上下一次亮起
      curve: Curve.EaseOut, //先暗得快、尾巴拖得久，更像灯
      iterations: -1, //无限循环
      playMode: PlayMode.Normal
    }, () => {
      this.pulseOpacity = 0;
    });
  }

  private stopPulse(): void {
    this.lastBeatMs = 0;
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
      this.pulseOpacity = 0;
    });
  }

  // ==================== 假播放 ====================

  private togglePlay(): void {
    this.isPlaying = !this.isPlaying;
    if (this.isPlaying) {
      this.startTimer();
    } else {
      this.stopTimer();
    }
  }

  private startTimer(): void {
    this.stopTimer();
    this.timerId = setInterval(() => {
      let next: number = this.progress + TICK_MS / 1000 * this.playRate();
      if (next >= DEMO_DURATION) {
        next = 0; //循环播放
      }
      this.progress = next;
    }, TICK_MS);
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }
}

@Builder
export function load() {
  Player()
}
