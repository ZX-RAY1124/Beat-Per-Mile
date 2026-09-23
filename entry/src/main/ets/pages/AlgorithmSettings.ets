import { HdsNavDestination } from '@kit.UIDesignKit';
import { SettingRow } from './Settings';
import {
  CHASE_DELAY_SEC_DEFAULT,
  CHASE_DELAY_SEC_MAX,
  CHASE_DELAY_SEC_MIN,
  SOURCE_SIM,
  STEP_SCENARIOS,
  StepScenario,
  getChaseDelaySec,
  getStepScenario,
  getStepSource,
  setChaseDelaySec,
  setStepScenario,
  setStepSource
} from '../ets_libs/StepSource';

/**
 * 算法参数设置页（设置页 →「算法参数设置」进来）
 *
 * 一屏两块：
 *   1. 大卡片：标签「变速算法选择」占一行，选项另起一行占满卡片宽度
 *   2. 分组卡片里的两条小行：动态同步 / 步数检测的详细参数（跳各自的参数页）
 *
 * 为什么标签和选项不挤在同一行：
 *   360vp 的屏幕上，卡片内可用宽度约 300vp。标签 13fp 就要 78vp，
 *   剩下 212vp 要放「SignalSmith Stretch」+「系统Audio Kit」两段，
 *   字号只能压到 10~11fp（比正文小一圈，很难看清）。
 *   分两行之后选项能吃到整行宽度，14fp 也放得下（放不下就换行，不截断）。
 *
 * 这一页是 push 进来的独立页面（带返回键），不是主页 Tab 里的内容，
 * 所以根节点是 HdsNavDestination，标题栏和返回键都由它提供。
 */

/** 配色（和设置页保持一致） */
const ACCENT: string = '#FF6B6B';
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';
const TEXT_TERTIARY: string = '#C4C8D0';
const PAGE_BG: string = '#F5F6F8';
const CARD_BG: string = '#FFFFFF';
const FIELD_BG: string = '#F2F3F7';
const DIVIDER_COLOR: string = '#F0F0F0';


/** 图标配色 */
const COLOR_TEAL: string = '#4ECDC4';
const COLOR_ORANGE: string = '#FF8E53';
const ICON_BG_TEAL: string = '#EDFCF9';
const ICON_BG_ORANGE: string = '#FFF3E9';

/**
 * 变速算法：数组顺序就是分段控件里的顺序。
 * 以后加算法只要往这里加名字，药丸位置是按下标算的，不用改布局。
 */
const ENGINE_LABELS: string[] = ['SignalSmith Stretch', '系统Audio Kit'];
/** 默认选中项（还没有落盘，以后从 preferences 读） */
const ENGINE_DEFAULT: number = 0;

/** 步数检测源的分段标签（顺序对应 StepSource 的 SOURCE_REAL / SOURCE_SIM） */
const SOURCE_LABELS: string[] = ['真实传感器', '模拟演示'];

/** 分段控件尺寸 */
const SEG_PAD: number = 3;    // 灰色轨道的内边距
const SEG_GAP: number = 4;    // 两段之间的缝隙
const SEG_H: number = 46;     // 段高：够放两行 14fp 文字
const SEG_TEXT_SIZE: number = 14;
const SEG_RADIUS: number = 12;
const PILL_RADIUS: number = 9;

/** 行分割线从文字左边开始（＝行内边距 16 + 图标 32 + 间距 12，和设置页同一套尺寸） */
const DIVIDER_INSET: number = 60;

/**
 * Area.width 的类型是 Length（string | number | Resource），
 * 布局量出来的一定是 number（单位 vp），这里收窄一下，
 * 比直接 as number 稳（ArkTS 对跨类型断言卡得比较严）
 */
function lengthToVp(value: Length): number {
  return typeof value === 'number' ? value : 0;
}

@Component
struct AlgorithmSettings {
  @State navPathStack: NavPathStack = new NavPathStack();
  /** 当前选中的变速算法（ENGINE_LABELS 的下标） */
  @State engineIndex: number = ENGINE_DEFAULT;
  /**
   * 分段控件轨道的实际宽度，onAreaChange 量出来的。
   * 两段的宽度跟着屏幕走、不是固定的，所以药丸的宽度和位移只能等布局量完再算。
   */
  @State trackW: number = 0;

  /** 步数检测源（StepSource.SOURCE_REAL / SOURCE_SIM） */
  @State stepSource: number = SOURCE_SIM;
  /** 模拟场景下标（见 StepSource.STEP_SCENARIOS） */
  @State stepScenario: number = 0;
  /** 动态模式起步延迟校正窗口（秒）；0 = 关闭 */
  @State chaseDelaySec: number = CHASE_DELAY_SEC_DEFAULT;
  /** 步数检测源那个分段控件的轨道宽度（同样要等布局量出来） */
  @State trackWSource: number = 0;

  aboutToAppear(): void {
    this.stepSource = getStepSource();
    this.stepScenario = getStepScenario();
    this.chaseDelaySec = getChaseDelaySec();
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          this.EngineCard()
          this.StepSourceCard()
          this.ParamGroup()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .backgroundColor(PAGE_BG)
      // 标题栏是悬浮在内容之上的，让出它的高度，否则第一张卡片会钻到标题底下
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({ content: { title: { mainTitle: '算法参数设置', mainTitleSize: 20 } } })
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
    .background(PAGE_BG)
  }

  // ==================== 大卡片：变速算法选择 ====================

  @Builder
  EngineCard() {
    Column({ space: 12 }) {
      Text('变速算法选择')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .width('100%')

      this.EngineSwitch()
    }
    .width('100%')
    .padding(16)
    .backgroundColor(CARD_BG)
    .borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
  }

  /**
   * 分段控件：[ SignalSmith Stretch | 系统Audio Kit ]
   *
   * 白色药丸是一个单独的层，靠 offset 平移到选中的那一段
   * （和播放器页的「倍速 / BPM」是同一个做法）。
   * 区别是那边两段宽度写死，这里跟着屏幕走，所以宽度要先量。
   */
  @Builder
  EngineSwitch() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 药丸：先画，文字压在它上面
      Column()
        .width(this.segWidth())
        .height(SEG_H)
        .borderRadius(PILL_RADIUS)
        .backgroundColor(Color.White)
        .shadow({ radius: 6, color: '#14000000', offsetX: 0, offsetY: 1 })
        .offset({ x: this.engineIndex * (this.segWidth() + SEG_GAP) })

      Row({ space: SEG_GAP }) {
        ForEach(ENGINE_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(SEG_TEXT_SIZE)
            .fontWeight(this.engineIndex === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.engineIndex === index ? ACCENT : TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .maxLines(2) // 宽度不够就换行，不截断成省略号
            .width(this.segWidth())
            .height(SEG_H)
            .onClick(() => {
              this.switchEngine(index);
            })
        }, (label: string) => label)
      }
      .width('100%')
    }
    .width('100%')
    .padding(SEG_PAD)
    .backgroundColor(FIELD_BG)
    .borderRadius(SEG_RADIUS)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.trackW = lengthToVp(newArea.width);
    })
  }

  // ==================== 步数检测源 ====================

  /**
   * 步数检测源卡片：真实传感器 / 模拟演示
   *
   * 选「模拟演示」后，播放器页会启动 native 的合成步态管线
   * （GaitSim → StepDetector → TempoFollower → 倍速 → 实际播放），
   * 这样没有真机传感器也能端到端验证"从检测步数到音乐变速"。
   */
  @Builder
  StepSourceCard() {
    Column({ space: 12 }) {
      Text('步数检测源')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .width('100%')

      this.SourceSwitch()

      // 动态模式「起步延迟校正」窗口：前 N 秒的 CHASE 只校正计步延迟，不改歌曲速度
      Row({ space: 8 }) {
        Text('起步校正时长')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
          .width(96)
        Slider({
          value: this.chaseDelaySec,
          min: CHASE_DELAY_SEC_MIN,
          max: CHASE_DELAY_SEC_MAX,
          step: 5,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .trackColor(FIELD_BG)
          .selectedColor(ACCENT)
          .blockColor(Color.White)
          .onChange((value: number) => {
            this.chaseDelaySec = Math.round(value);
            setChaseDelaySec(this.chaseDelaySec);
          })
        Text(this.chaseDelaySec.toFixed(0) + ' 秒')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
          .width(52)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('动态模式下，前 ' + this.chaseDelaySec.toFixed(0)
        + ' 秒的追逐(CHASE)只做计步延迟校正（不改歌曲速度），过后才做正常相位调整。')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
        .width('100%')

      if (this.stepSource === SOURCE_SIM) {
        Text('模拟场景')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
          .width('100%')

        Column() {
          ForEach(STEP_SCENARIOS, (sc: StepScenario, index: number) => {
            this.ScenarioRow(sc, index)
          }, (sc: StepScenario) => sc.name)
        }
        .width('100%')

        Text('模拟源由 native 合成，不读真实传感器；算出的倍速会实际驱动播放。')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
          .width('100%')
      } else {
        Text('真实传感器（加速度计）尚未接线，选它暂时不会有步频数据。')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(CARD_BG)
    .borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
  }

  /** 两段分段控件：[ 真实传感器 | 模拟演示 ]，与上面变速算法同一套做法 */
  @Builder
  SourceSwitch() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(this.sourceSegWidth())
        .height(SEG_H)
        .borderRadius(PILL_RADIUS)
        .backgroundColor(Color.White)
        .shadow({ radius: 6, color: '#14000000', offsetX: 0, offsetY: 1 })
        .offset({ x: this.stepSource * (this.sourceSegWidth() + SEG_GAP) })

      Row({ space: SEG_GAP }) {
        ForEach(SOURCE_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(SEG_TEXT_SIZE)
            .fontWeight(this.stepSource === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.stepSource === index ? ACCENT : TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .width(this.sourceSegWidth())
            .height(SEG_H)
            .onClick(() => {
              this.switchSource(index);
            })
        }, (label: string) => label)
      }
      .width('100%')
    }
    .width('100%')
    .padding(SEG_PAD)
    .backgroundColor(FIELD_BG)
    .borderRadius(SEG_RADIUS)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.trackWSource = lengthToVp(newArea.width);
    })
  }

  /** 一条模拟场景（选中打勾）。图标沿用工程里已验证过的 sys.symbol.* */
  @Builder
  ScenarioRow(sc: StepScenario, index: number) {
    Row({ space: 10 }) {
      SymbolGlyph(this.stepScenario === index
        ? $r('sys.symbol.checkmark_square_fill')
        : $r('sys.symbol.square'))
        .fontSize(18)
        .fontColor([this.stepScenario === index ? ACCENT : TEXT_TERTIARY])

      Column({ space: 2 }) {
        Text(sc.name)
          .fontSize(14)
          .fontColor(TEXT_PRIMARY)
          .width('100%')
        Text(sc.desc)
          .fontSize(11)
          .fontColor(TEXT_SECONDARY)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      this.selectScenario(index);
    })
  }

  /** 步数检测源控件的单段宽度 */
  private sourceSegWidth(): number {
    const inner: number = this.trackWSource - SEG_PAD * 2 - SEG_GAP * (SOURCE_LABELS.length - 1);
    return inner > 0 ? inner / SOURCE_LABELS.length : 0;
  }

  private switchSource(index: number): void {
    if (index === this.stepSource) {
      return;
    }
    setStepSource(index);
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.stepSource = index;
    });
  }

  private selectScenario(index: number): void {
    setStepScenario(index);
    this.stepScenario = index;
  }

  /** 单段宽度：轨道内容宽减去段间距后均分（轨道还没量出来时先返回 0） */
  private segWidth(): number {
    const inner: number = this.trackW - SEG_PAD * 2 - SEG_GAP * (ENGINE_LABELS.length - 1);
    return inner > 0 ? inner / ENGINE_LABELS.length : 0;
  }

  /** 切换变速算法：药丸滑过去（换成另一套算法要重开播放器的话，接后端时加在这里） */
  private switchEngine(index: number): void {
    if (index === this.engineIndex) {
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.engineIndex = index;
    });
  }

  // ==================== 两条小行：详细参数 ====================

  @Builder
  ParamGroup() {
    Column() {
      SettingRow({
        icon: $r('sys.symbol.waveform'),
        iconColor: COLOR_TEAL,
        iconBg: ICON_BG_TEAL,
        label: '动态同步算法详细参数设置',
        onTap: () => {
          this.rowTap('动态同步算法详细参数设置');
        }
      })
      this.RowDivider()
      SettingRow({
        icon: $r('sys.symbol.figure_running'),
        iconColor: COLOR_ORANGE,
        iconBg: ICON_BG_ORANGE,
        label: '步数检测算法详细参数设置',
        onTap: () => {
          this.rowTap('步数检测算法详细参数设置');
        }
      })
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(16)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
    .clip(true) // 让分割线不会溢出圆角
  }

  /** 行之间的淡分割线：从文字左边开始 */
  @Builder
  RowDivider() {
    Divider()
      .strokeWidth(1)
      .color(DIVIDER_COLOR)
      .margin({ left: DIVIDER_INSET })
  }

  /** 参数页还没做，先给个反馈方便确认点到了哪个 */
  private rowTap(name: string): void {
    console.info('算法参数页：' + name);
    this.toast(name + '：功能待接入');
  }

  /** showToast 会抛异常，包一层（不处理的话 ArkTS 会报 "Function may throw exceptions"） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      console.error('showToast 失败：' + JSON.stringify(err));
    }
  }
}

@Builder
export function load() {
  AlgorithmSettings()
}
