import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import {
  appendCurve,
  CurveEditParam,
  CurveFile,
  CurvePointJson,
  CurveTagJson,
  loadAll,
  minToSec,
  POINT_TYPE_LINEAR,
  saveAt,
  secToMin
} from '../ets_libs/CurveStore';

/**
 * 曲线编辑页
 *
 * 布局参考耳机调音/EQ 界面：上半屏是图表，下半屏是操作台。
 *
 * 图表两种显示方式：
 *   - 普通模式：时间轴固定只显示 5 分钟，可以左右拖动
 *   - 全景模式：时间轴缩放成整条时间轴，一屏看全
 *   - 右下角按钮切换：亮（实心底色）＝全景，暗（透明底色）＝普通
 *
 * 操作台四项：时间总长度、当前编辑点、当前编辑点的时间、当前编辑点的 BPM。
 *
 * 纵轴固定 80~240 BPM（人走路到快跑的步频范围），不跟着数据缩放。
 *
 * 图上四组操作：
 *   - 拖点：按住某个点滑动 —— 上下改 BPM，左右改时间（首尾点的时间锁住，只能改 BPM）
 *   - 拖时间轴：在空白处按住滑动（仅普通模式，全景模式本来就看得全）
 *   - 长按点：删除这个点（弹窗确认；首尾点不能删）
 *   - 长按空白处：在这里加一个点（不确认）
 * 长按和拖动用 GestureGroup(Exclusive) 分开：按住不动＝长按，一按就滑＝拖动。
 *
 * 曲线点以"时间"为锚点存（单位分钟）：改"时间总长度"时，除了最后一个点跟着挪到新的终点，
 * 其余点的时间都保持不变。
 * 因此"时间总长度"的下限不是固定值，而是【倒数第二个点的时间】——
 * 否则最后一个点会被挤到它前面去，曲线就没有尾了。
 * 第 1 个点固定在 0 分钟、最后一个点固定在总长度，它们的时间滑条是锁住的。
 * 拖动某个点的时间如果跨过了相邻点，会按时间重新排序，序号跟着这个点走。
 */

/**
 * 落盘用的数据结构统一放在 ets_libs/CurveStore.ets：
 *   一个曲线文件 = { name, points[{time(秒), bpm, type}], tags[{time(秒), text}] }
 * ⚠️ 文件里的 time 是秒，界面上的 time 是分钟，转换只走 secToMin / minToSec
 *
 * 注意：json 格式里没有"循环"这个字段（isLoop），所以它只存在于本次编辑，
 * 存不进文件 —— 要持久化的话得在格式里加一个字段。
 */

/** 曲线上的一个编辑点 */
class EditPoint {
  /** 稳定 id：点按时间重新排序后靠它找回"当前编辑的是哪一个" */
  id: number;
  /** 时间（分钟）。第 1 个固定 0，最后一个固定等于"时间总长度" */
  time: number;
  /** 目标步频 */
  bpm: number;

  constructor(id: number, time: number, bpm: number) {
    this.id = id;
    this.time = time;
    this.bpm = bpm;
  }
}

/**
 * 没有数据传入时的初始曲线：只有头、尾两个点，也就是一条恒定步频的直线。
 * 用户进来后在空白处长按加点、拖点，就能把它捏成想要的形状。
 */
const DEFAULT_TOTAL: number = 30;
const DEFAULT_BPM: number = 150;
const DEFAULT_POINTS: EditPoint[] = [
  new EditPoint(0, 0, DEFAULT_BPM),
  new EditPoint(1, DEFAULT_TOTAL, DEFAULT_BPM),
];

/** 数值范围 */
const NORMAL_WINDOW_MINUTES: number = 5; // 普通模式固定显示的时间长度
const TOTAL_MIN: number = 5; // 只是保底；实际下限见 minTotalMinutes()
const TOTAL_MAX: number = 180;
/** 步频范围：走路到快跑 */
const BPM_MIN: number = 80;
const BPM_MAX: number = 240;
const BPM_TICK_STEP: number = 40;
/** 点的时间滑条步长（分钟） */
const TIME_STEP: number = 0.5;
/** 图上拖点时的命中半径（vp） */
const HIT_RADIUS: number = 22;
/** 图上长按多久触发"空白处加点 / 点上删点"（毫秒） */
const LONG_PRESS_MS: number = 500;

/**
 * 图表里的字号，单位是 vp
 *
 * ⚠️ 坑：CanvasRenderingContext2D 的 font 里那个 "px" 是**物理像素**，
 * 而画布坐标系是 vp，两者差一个屏幕密度（手机上大约 3 倍）。
 * 直接写 '13px' 实际只画出 4vp 出头的字，小到看不清，所以必须过一遍 chartFont()。
 */
const TICK_FONT_VP: number = 13;          // 横纵轴刻度数字
const UNIT_FONT_VP: number = 12;          // 轴单位 BPM / min
const POINT_FONT_VP: number = 12;         // 数据点序号
const POINT_FONT_CURRENT_VP: number = 14; // 当前编辑点的序号

// vp 字号 → canvas font 字符串的换算放在组件里的 chartFont() 方法上
// （全局的 vp2px 已标记废弃，要用 UIContext 上的那个）

/** 图表配色：跟着界面背景走，比背景略深一点、带一点暖黄 */
const CHART_BG: string = '#F8F6EF';
const CHART_GRID: string = '#E9E5D8';
const CHART_AXIS: string = '#D3CDBD';
const CHART_TEXT: string = '#8C8880';
const CHART_LINE: string = '#FF6B6B';
const CHART_POINT: string = '#FF6B6B';
const CHART_POINT_DIM: string = '#FFAFAF';

/**
 * 绘图区四周留白
 * 左/下要放得下 13px 的刻度数字，上边还要放纵轴单位 "BPM"
 */
const PAD_L: number = 50;
const PAD_R: number = 18;
const PAD_T: number = 34;
const PAD_B: number = 42;

/** 操作台配色 */
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';
const FIELD_BG: string = '#F2F3F7';
const TRACK_BG: string = '#E4E6EE';
const TOGGLE_IDLE_TEXT: string = '#8C8880';
const CHECKBOX_IDLE: string = '#B0B5BF';  // "循环"复选框未选中时的颜色

/** 复制一份曲线点，避免直接改到模块常量 */
function copyPoints(src: EditPoint[]): EditPoint[] {
  const out: EditPoint[] = [];
  for (let i = 0; i < src.length; i++) {
    out.push(new EditPoint(src[i].id, src[i].time, src[i].bpm));
  }
  return out;
}

/** 分钟数显示：整数不带小数点，否则保留一位 */
function formatMinutes(minutes: number): string {
  const rounded: number = Math.round(minutes * 10) / 10;
  if (Math.abs(rounded - Math.round(rounded)) < 0.05) {
    return Math.round(rounded).toString();
  }
  return rounded.toFixed(1);
}

/** 时间轴按窗口长度挑一个"好看"的刻度间隔，控制在 6 条以内 */
function niceTimeStep(viewMinutes: number): number {
  const candidates: number[] = [1, 2, 5, 10, 15, 30, 60];
  for (let i = 0; i < candidates.length; i++) {
    if (viewMinutes / candidates[i] <= 6) {
      return candidates[i];
    }
  }
  return 60;
}

/**
 * 操作台的一行：标签 + [－] 输入框 [＋]（可选后缀）
 * 用 @Component 而不是 @Builder：@Builder 多参数是按值传递，输入框的文本不会随状态刷新
 */
@Component
struct StepperRow {
  label: string = '';
  suffix: string = '';
  @Prop valueText: string = '';
  onMinus: () => void = () => {
  };
  onPlus: () => void = () => {
  };
  onTextChange: (value: string) => void = () => {
  };
  onEditEnd: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor(TEXT_PRIMARY)
        .width(84)
        .textAlign(TextAlign.Start)

      this.StepButton($r('sys.symbol.minus'), () => {
        this.onMinus();
      })

      TextInput({ text: this.valueText })
        .type(InputType.Number)
        .width(64)
        .height(38)
        .fontSize(15)
        .fontColor(TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .backgroundColor(FIELD_BG)
        .borderRadius(10)
        .padding({ left: 2, right: 2 })
        .onChange((value: string) => {
          this.onTextChange(value);
        })
        .onEditChange((isEditing: boolean) => {
          if (!isEditing) {
            this.onEditEnd();
          }
        })

      this.StepButton($r('sys.symbol.plus'), () => {
        this.onPlus();
      })

      if (this.suffix.length > 0) {
        Text(this.suffix)
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
      }
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StepButton(icon: Resource, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(15)
        .fontColor([TEXT_PRIMARY])
    }
    .width(38)
    .height(38)
    .borderRadius(10)
    .backgroundColor(FIELD_BG)
    .onClick(() => {
      action();
    })
  }
}

/**
 * 操作台的一行：滑条 + 右侧输入框（不带加减按钮）
 * 时间和 BPM 两行共用
 */
@Component
struct SliderRow {
  label: string = '';
  step: number = 1;
  inputType: InputType = InputType.Number;
  @Prop value: number = 0;
  @Prop valueText: string = '';
  @Prop min: number = 0;
  @Prop max: number = 100;
  /**
   * 关掉滑条和输入框（首尾点的时间不让改）
   * 注意：不能叫 enabled —— 那是 CommonMethod 的通用属性方法名，成员同名会编译报错
   */
  @Prop fieldEnabled: boolean = true;
  onSlide: (value: number) => void = () => {
  };
  onTextChange: (value: string) => void = () => {
  };
  onEditEnd: () => void = () => {
  };

  build() {
    Row({ space: 14 }) {
      Column({ space: 6 }) {
        Text(this.label)
          .fontSize(15)
          .fontColor(TEXT_PRIMARY)
          .width('100%')
          .textAlign(TextAlign.Start)

        Slider({
          value: this.value,
          min: this.min,
          max: this.max,
          step: this.step,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .enabled(this.fieldEnabled)
          .trackColor(TRACK_BG)
          .selectedColor(CHART_LINE)
          .blockColor(Color.White)
          .onChange((value: number) => {
            this.onSlide(value);
          })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      TextInput({ text: this.valueText })
        .type(this.inputType)
        .enabled(this.fieldEnabled)
        .width(72)
        .height(38)
        .fontSize(15)
        .fontColor(TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .backgroundColor(FIELD_BG)
        .borderRadius(10)
        .padding({ left: 2, right: 2 })
        .onChange((value: string) => {
          this.onTextChange(value);
        })
        .onEditChange((isEditing: boolean) => {
          if (!isEditing) {
            this.onEditEnd();
          }
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }
}

@Component
struct CurveEdit {
  @State navPathStack: NavPathStack = new NavPathStack();

  // ---- 数据 ----
  /** 曲线名称：列表跳过来时带 { index }，读盘后填进来（见 loadCurve） */
  @State curveTitle: string = '';
  /** 跑完一趟是否循环整条曲线 */
  @State isLoop: boolean = true;
  /** 时间总长度（分钟） */
  @State totalMinutes: number = DEFAULT_TOTAL;
  @State totalText: string = DEFAULT_TOTAL.toString();
  /** 当前编辑点，1 开始（界面上的序号从 1 数） */
  @State currentNo: number = 1;
  @State currentText: string = '1';
  /** 曲线点 */
  @State points: EditPoint[] = copyPoints(DEFAULT_POINTS);
  /** 当前编辑点的时间（分钟）与 BPM，跟着 currentNo 变 */
  @State timeText: string = '0';
  @State bpmText: string = '150';

  // ---- 视图 ----
  /** 是否全景模式 */
  @State isOverview: boolean = false;
  /** 普通模式下，时间轴左端落在第几分钟 */
  @State viewStartMinute: number = 0;
  /** 一次拖动开始时的 viewStartMinute（不参与渲染） */
  private viewStartBase: number = 0;
  /** 是否已经在退出流程里：防止弹窗里调 pop 又被 onBackPressed 拦一次（不参与渲染） */
  private leaving: boolean = false;
  /** 正在编辑第几条曲线（0 开始）；-1 表示还没绑定文件，保存时会新建一个 */
  private curveIndex: number = -1;
  /**
   * 原文件里的标签，保存时原样写回去
   * ⚠️ 曲线和标签在同一个 json 里，保存曲线时如果不带上它，标签就被抹掉了
   */
  private savedTags: CurveTagJson[] = [];

  // ---- 拖点状态（不参与渲染）----
  /** 正在被拖的点的 id；-1 表示这次拖动是在拖时间轴 */
  private dragPointId: number = -1;
  private dragStartMinute: number = 0;
  private dragStartBpm: number = 0;
  /** 被拖的是不是首尾点：是的话只让改 BPM，时间保持不动 */
  private dragLockTime: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
    // 数据在 onReady 里按路由参数读（见下面的 onReady）
  }

  build() {
    HdsNavDestination() {
      Column() {
        // ================= 曲线名称 =================
        // 不加标签：占位文字"未命名曲线"一眼就知道是名字，标签省下的宽度全给输入框
        Row({ space: 10 }) {
          TextInput({ text: this.curveTitle, placeholder: '未命名曲线' })
            .layoutWeight(1)
            .height(38)
            .fontSize(15)
            .fontColor(TEXT_PRIMARY)
            .placeholderColor(TEXT_SECONDARY)
            .backgroundColor(FIELD_BG)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.curveTitle = value;
            })

          this.SaveButton()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 12 })

        // ================= 上半屏：图表 =================
        Stack() {
          Canvas(this.ctx)
            .width('100%')
            .height('100%')
            .onReady(() => {
              this.drawChart();
            })
            .onAreaChange(() => {
              this.drawChart();
            })
            .gesture(
              // Exclusive：谁先满足谁生效 —— 按住不动是长按（加点/删点），
              // 一按就滑是拖动（点在点上拖点，点在空白处拖时间轴）
              GestureGroup(GestureMode.Exclusive,
                LongPressGesture({ repeat: false, duration: LONG_PRESS_MS })
                  .onAction((event: GestureEvent) => {
                    this.onChartLongPress(event);
                  }),
                PanGesture({ direction: PanDirection.All })
                  .onActionStart((event: GestureEvent) => {
                    this.beginDrag(event);
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.updateDrag(event);
                  })
                  .onActionEnd(() => {
                    this.dragPointId = -1;
                  })
                  .onActionCancel(() => {
                    this.dragPointId = -1;
                  })
              )
            )
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ left: 16, right: 16, top: 12 })
        .backgroundColor(CHART_BG)
        .borderRadius(18)
        .clip(true)

        // 这一行放在图表外面：按钮放图里右下角会和横轴刻度文字叠在一起
        Row({ space: 10 }) {
          this.LoopCheckbox()
          Blank()
          this.ModeToggle()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 10 })

        // ================= 下半屏：操作台 =================
        Column({ space: 14 }) {
          StepperRow({
            label: '时间总长度',
            suffix: '分钟',
            valueText: this.totalText,
            onMinus: () => {
              this.setTotalMinutes(this.totalMinutes - 1);
            },
            onPlus: () => {
              this.setTotalMinutes(this.totalMinutes + 1);
            },
            onTextChange: (value: string) => {
              this.onTotalTextChange(value);
            },
            onEditEnd: () => {
              this.totalText = this.totalMinutes.toString();
            }
          })

          StepperRow({
            label: '当前编辑点',
            valueText: this.currentText,
            onMinus: () => {
              this.selectPoint(this.currentNo - 1);
            },
            onPlus: () => {
              this.selectPoint(this.currentNo + 1);
            },
            onTextChange: (value: string) => {
              this.onCurrentTextChange(value);
            },
            onEditEnd: () => {
              this.currentText = this.currentNo.toString();
            }
          })

          SliderRow({
            label: this.timeRowLabel(),
            value: this.currentTime(),
            valueText: this.timeText,
            min: 0,
            max: this.totalMinutes,
            step: TIME_STEP,
            inputType: InputType.NUMBER_DECIMAL,
            fieldEnabled: !this.isTimeLocked(),
            onSlide: (value: number) => {
              this.setCurrentTime(value);
            },
            onTextChange: (value: string) => {
              this.onTimeTextChange(value);
            },
            onEditEnd: () => {
              this.timeText = formatMinutes(this.currentTime());
            }
          })

          SliderRow({
            label: '点' + this.currentNo + ' BPM 数值',
            value: this.currentBpm(),
            valueText: this.bpmText,
            min: BPM_MIN,
            max: BPM_MAX,
            step: 1,
            inputType: InputType.Number,
            onSlide: (value: number) => {
              this.setCurrentBpm(value);
            },
            onTextChange: (value: string) => {
              this.onBpmTextChange(value);
            },
            onEditEnd: () => {
              this.bpmText = this.currentBpm().toString();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 20 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({ content: { title: { mainTitle: '曲线编辑', mainTitleSize: 20 } } })
    // 返回时先问一句"保存还是丢弃"；return true 表示这次返回被拦下，等弹窗结果
    .onBackPressed(() => {
      if (this.leaving) {
        return false; //已经在退出流程里了，放行
      }
      this.askSaveOnExit();
      return true;
    })
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
      // 列表页进来时带了 { index }，按它去磁盘读这条曲线
      const param: CurveEditParam = context.pathInfo.param as CurveEditParam;
      if (param !== undefined && param !== null) {
        this.loadCurve(param.index);
      }
    })
  }

  /**
   * 保存按钮
   * 注意：不要写死宽度 —— Button 自带左右内边距，宽度给小了文案会被截成省略号
   */
  @Builder
  SaveButton() {
    Button('保存')
      .type(ButtonType.Normal) //默认是胶囊形，改成圆角矩形才吃 borderRadius
      .height(38)
      .fontSize(15)
      .fontColor(Color.White)
      .backgroundColor(CHART_LINE)
      .borderRadius(10)
      .padding({ left: 16, right: 16 }) //宽度 = 文案 + 内边距，自动撑开
      .onClick(() => {
        this.askSave();
      })
  }

  /**
   * "循环"复选框：方框 → 实心对勾方框，带替换动效
   * （和歌曲列表页行尾那个复选框同一套写法）
   */
  @Builder
  LoopCheckbox() {
    Row({ space: 8 }) {
      SymbolGlyph(this.isLoop
        ? $r('sys.symbol.checkmark_square_fill')
        : $r('sys.symbol.square'))
        .fontSize(20)
        .fontColor([this.isLoop ? CHART_LINE : CHECKBOX_IDLE])
        .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
      Text('循环')
        .fontSize(14)
        .fontColor(this.isLoop ? TEXT_PRIMARY : TEXT_SECONDARY)
    }
    .height(30)
    .onClick(() => {
      this.isLoop = !this.isLoop;
    })
  }

  /** 图表模式切换：实心底色＝全景，透明底色＝普通 */
  @Builder
  ModeToggle() {
    Row({ space: 6 }) {
      SymbolGlyph(this.isOverview
        ? $r('sys.symbol.arrow_up_left_and_arrow_down_right')
        : $r('sys.symbol.arrow_down_right_and_arrow_up_left'))
        .fontSize(15)
        .fontColor([this.isOverview ? Color.White : TOGGLE_IDLE_TEXT])
      Text(this.isOverview ? '全景' : '普通')
        .fontSize(13)
        .fontColor(this.isOverview ? Color.White : TOGGLE_IDLE_TEXT)
    }
    .height(30)
    .padding({ left: 12, right: 14 })
    .backgroundColor(this.isOverview ? CHART_LINE : '#00000000')
    .borderRadius(15)
    .borderWidth(1)
    .borderColor(this.isOverview ? CHART_LINE : CHART_AXIS)
    .onClick(() => {
      this.toggleOverview();
    })
  }

  // ==================== 绘图 ====================

  /**
   * vp 字号 → canvas 的 font 字符串
   * canvas 的 font 里那个 "px" 是物理像素，而画布坐标是 vp，所以要按屏幕密度换算
   * （用 UIContext 上的换算方法；全局的 vp2px 已经标记废弃了）
   */
  private chartFont(vpSize: number): string {
    return Math.round(this.getUIContext().vp2px(vpSize)).toString() + 'px sans-serif';
  }

  private drawChart(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = CHART_BG;
    ctx.fillRect(0, 0, w, h);

    const plotW: number = w - PAD_L - PAD_R;
    const plotH: number = h - PAD_T - PAD_B;
    if (plotW <= 20 || plotH <= 20 || this.points.length === 0) {
      return;
    }

    // 当前时间窗口
    const viewMinutes: number = this.isOverview ? this.totalMinutes : NORMAL_WINDOW_MINUTES;
    const startMinute: number = this.isOverview ? 0 : this.viewStartMinute;
    const endMinute: number = startMinute + viewMinutes;

    // 纵轴固定 80~240 BPM
    const toX = (minute: number): number => PAD_L + (minute - startMinute) / viewMinutes * plotW;
    const toY = (bpm: number): number =>
      PAD_T + (1 - (bpm - BPM_MIN) / (BPM_MAX - BPM_MIN)) * plotH;

    ctx.lineWidth = 1;

    // 竖向网格 + 时间刻度
    const stepMin: number = niceTimeStep(viewMinutes);
    ctx.font = this.chartFont(TICK_FONT_VP); //横纵轴的刻度数字都用这个字号
    for (let t = Math.ceil(startMinute / stepMin) * stepMin; t <= endMinute + 0.001; t += stepMin) {
      const x: number = toX(t);
      ctx.strokeStyle = CHART_GRID;
      ctx.beginPath();
      ctx.moveTo(x, PAD_T);
      ctx.lineTo(x, PAD_T + plotH);
      ctx.stroke();

      ctx.fillStyle = CHART_TEXT;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      ctx.fillText(Math.round(t).toString(), x, PAD_T + plotH + 6);
    }

    // 横向网格 + BPM 刻度
    for (let v = BPM_MIN; v <= BPM_MAX + 0.001; v += BPM_TICK_STEP) {
      const y: number = toY(v);
      ctx.strokeStyle = CHART_GRID;
      ctx.beginPath();
      ctx.moveTo(PAD_L, y);
      ctx.lineTo(PAD_L + plotW, y);
      ctx.stroke();

      ctx.fillStyle = CHART_TEXT;
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      ctx.fillText(Math.round(v).toString(), PAD_L - 8, y);
    }

    // 坐标轴
    ctx.strokeStyle = CHART_AXIS;
    ctx.beginPath();
    ctx.moveTo(PAD_L, PAD_T);
    ctx.lineTo(PAD_L, PAD_T + plotH);
    ctx.lineTo(PAD_L + plotW, PAD_T + plotH);
    ctx.stroke();

    // 轴单位：纵轴 BPM（左上角外侧），横轴 min（右下角下方）
    ctx.fillStyle = CHART_TEXT;
    ctx.font = this.chartFont(UNIT_FONT_VP);
    ctx.textAlign = 'right';
    ctx.textBaseline = 'top';
    //"BPM" 放在最上沿：贴着最上面那条刻度（240）会撞在一起
    ctx.fillText('BPM', PAD_L - 8, 8);
    ctx.fillText('min', PAD_L + plotW, PAD_T + plotH + 21);

    // ---- 曲线（裁剪到绘图区，超出窗口的部分自动被切掉）----
    ctx.save();
    ctx.beginPath();
    ctx.rect(PAD_L, PAD_T, plotW, plotH);
    ctx.clip();

    const n: number = this.points.length;

    // 曲线下方的渐隐填充
    const grad: CanvasGradient = ctx.createLinearGradient(0, PAD_T, 0, PAD_T + plotH);
    grad.addColorStop(0, 'rgba(255,107,107,0.28)');
    grad.addColorStop(1, 'rgba(255,107,107,0.02)');
    ctx.beginPath();
    ctx.moveTo(toX(this.points[0].time), PAD_T + plotH);
    for (let i = 0; i < n; i++) {
      ctx.lineTo(toX(this.points[i].time), toY(this.points[i].bpm));
    }
    ctx.lineTo(toX(this.points[n - 1].time), PAD_T + plotH);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // 折线
    if (n >= 2) {
      ctx.beginPath();
      for (let i = 0; i < n; i++) {
        const x: number = toX(this.points[i].time);
        const y: number = toY(this.points[i].bpm);
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.strokeStyle = CHART_LINE;
      ctx.lineWidth = 2.5;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.stroke();
    }

    // 数据点 + 序号
    const labelXMin: number = PAD_L + 8;
    const labelXMax: number = PAD_L + plotW - 8;
    for (let i = 0; i < n; i++) {
      const x: number = toX(this.points[i].time);
      const y: number = toY(this.points[i].bpm);
      const isCurrent: boolean = (i === this.currentNo - 1);

      if (isCurrent) {
        ctx.beginPath();
        ctx.arc(x, y, 10, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(255,107,107,0.22)';
        ctx.fill();
      }

      // 白描边让点在浅色底上也看得清
      ctx.beginPath();
      ctx.arc(x, y, isCurrent ? 5 : 3.5, 0, Math.PI * 2);
      ctx.fillStyle = isCurrent ? CHART_POINT : CHART_POINT_DIM;
      ctx.fill();
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 2;
      ctx.stroke();

      // 序号贴着点上方，靠边时往回收一点，避免被裁掉
      let tx: number = x;
      if (tx < labelXMin) {
        tx = labelXMin;
      }
      if (tx > labelXMax) {
        tx = labelXMax;
      }
      ctx.fillStyle = isCurrent ? CHART_LINE : CHART_TEXT;
      ctx.font = this.chartFont(isCurrent ? POINT_FONT_CURRENT_VP : POINT_FONT_VP);
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      ctx.fillText((i + 1).toString(), tx, y - (isCurrent ? 17 : 11));
    }

    ctx.restore();
  }

  // ==================== 交互 ====================

  /** 普通模式下左右拖动时间轴 */
  private panBy(offsetX: number): void {
    if (this.isOverview) {
      return;
    }
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    if (plotW <= 0) {
      return;
    }
    const minutesPerVp: number = NORMAL_WINDOW_MINUTES / plotW;
    this.viewStartMinute = this.clampViewStart(this.viewStartBase - offsetX * minutesPerVp);
    this.drawChart();
  }

  /** 时间轴左端最多能拖到哪 */
  private clampViewStart(minute: number): number {
    const maxStart: number = Math.max(0, this.totalMinutes - NORMAL_WINDOW_MINUTES);
    if (minute < 0) {
      return 0;
    }
    if (minute > maxStart) {
      return maxStart;
    }
    return minute;
  }

  private toggleOverview(): void {
    this.isOverview = !this.isOverview;
    this.viewStartMinute = this.clampViewStart(this.viewStartMinute);
    this.drawChart();
  }

  /**
   * 应用时间总长度（不碰输入框文本）
   * 点以时间为锚点：除了最后一个点跟着挪到新的终点，其余点的时间一点都不动
   */
  private applyTotalMinutes(minutes: number): void {
    let n: number = Math.round(minutes);
    const floor: number = this.minTotalMinutes();
    if (n < floor) {
      n = floor;
    }
    if (n > TOTAL_MAX) {
      n = TOTAL_MAX;
    }
    this.totalMinutes = n;

    const lastIdx: number = this.points.length - 1;
    const next: EditPoint[] = [];
    for (let i = 0; i < this.points.length; i++) {
      const p: EditPoint = this.points[i];
      if (i === lastIdx) {
        next.push(new EditPoint(p.id, n, p.bpm));
      } else {
        next.push(new EditPoint(p.id, p.time, p.bpm));
      }
    }
    this.points = next;

    this.viewStartMinute = this.clampViewStart(this.viewStartMinute);
    this.timeText = formatMinutes(this.currentTime());
    this.drawChart();
  }

  /** 加减按钮：连输入框文本一起更新 */
  private setTotalMinutes(minutes: number): void {
    this.applyTotalMinutes(minutes);
    this.totalText = this.totalMinutes.toString();
  }

  /** 输入框里直接敲：文本先原样留着，只把能解析出来的数字同步进去 */
  private onTotalTextChange(value: string): void {
    this.totalText = value;
    const n: number = Number.parseInt(value, 10);
    if (!Number.isNaN(n)) {
      this.applyTotalMinutes(n);
    }
  }

  private clampNo(no: number): number {
    let n: number = Math.round(no);
    if (n < 1) {
      n = 1;
    }
    if (n > this.points.length) {
      n = this.points.length;
    }
    return n;
  }

  private currentTime(): number {
    return this.points[this.clampNo(this.currentNo) - 1].time;
  }

  private currentBpm(): number {
    return this.points[this.clampNo(this.currentNo) - 1].bpm;
  }

  /** 首尾点的时间锁住（曲线必须有头有尾），只有它们不能改时间 */
  private isTimeLocked(): boolean {
    return this.currentNo === 1 || this.currentNo === this.points.length;
  }

  private timeRowLabel(): string {
    return '点' + this.currentNo + ' 时间（分钟）' + (this.isTimeLocked() ? '（首尾固定）' : '');
  }

  /** 切到第 no 个编辑点（不碰输入框文本，输入框自己管） */
  private applyPointNo(no: number): void {
    const n: number = this.clampNo(no);
    this.currentNo = n;
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
    this.drawChart();
  }

  /** 加减按钮：连输入框文本一起更新 */
  private selectPoint(no: number): void {
    this.applyPointNo(no);
    this.currentText = this.currentNo.toString();
  }

  private onCurrentTextChange(value: string): void {
    this.currentText = value;
    const n: number = Number.parseInt(value, 10);
    if (!Number.isNaN(n)) {
      this.applyPointNo(n); //先把序号同步过去，文本等编辑结束再规范
    }
  }

  /**
   * 更新某个点（按 id 找，不按序号 —— 序号会因为重新排序而变）
   * lockTime=true 时保持它原来的时间位置，只改 BPM
   * 不碰输入框文本，调用方自己决定要不要回写
   */
  private updatePointById(id: number, minute: number, bpm: number, lockTime: boolean): void {
    let n: number = Math.round(bpm);
    if (n < BPM_MIN) {
      n = BPM_MIN;
    }
    if (n > BPM_MAX) {
      n = BPM_MAX;
    }

    const next: EditPoint[] = [];
    for (let i = 0; i < this.points.length; i++) {
      const p: EditPoint = this.points[i];
      if (p.id === id) {
        const t: number = lockTime ? p.time : this.clampTime(minute);
        next.push(new EditPoint(p.id, t, n));
      } else {
        next.push(new EditPoint(p.id, p.time, p.bpm));
      }
    }
    next.sort((a: EditPoint, b: EditPoint): number => a.time - b.time);
    this.points = next;

    // 位置变了可能跨过别的点，序号跟着这个点走
    for (let i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        this.currentNo = i + 1;
        break;
      }
    }
    this.currentText = this.currentNo.toString();
    this.drawChart();
  }

  /** 把时间夹在时间轴范围内（分钟） */
  private clampTime(minute: number): number {
    let m: number = minute;
    if (m < 0) {
      m = 0;
    }
    if (m > this.totalMinutes) {
      m = this.totalMinutes;
    }
    return m;
  }

  /**
   * "时间总长度"的下限 = 倒数第二个点的时间
   * 最后一个点是跟着总长度走的，总长度要是比它前面的点还小，最后一个点就被挤到前面去了
   */
  private minTotalMinutes(): number {
    if (this.points.length < 2) {
      return TOTAL_MIN;
    }
    const secondLast: number = this.points[this.points.length - 2].time;
    const need: number = Math.ceil(secondLast);
    return need > TOTAL_MIN ? need : TOTAL_MIN;
  }

  /** 改当前编辑点的时间；首尾点锁住不让改 */
  private setCurrentTime(minutes: number): void {
    if (this.isTimeLocked()) {
      return;
    }
    const p: EditPoint = this.points[this.clampNo(this.currentNo) - 1];
    this.updatePointById(p.id, minutes, p.bpm, false);
    this.timeText = formatMinutes(this.currentTime());
  }

  private onTimeTextChange(value: string): void {
    this.timeText = value; //先原样留着，让用户把小数打完整
    if (this.isTimeLocked()) {
      return;
    }
    const n: number = Number.parseFloat(value);
    if (!Number.isNaN(n)) {
      const p: EditPoint = this.points[this.clampNo(this.currentNo) - 1];
      this.updatePointById(p.id, n, p.bpm, false);
    }
  }

  /** 改当前编辑点的 BPM */
  private setCurrentBpm(bpm: number): void {
    const p: EditPoint = this.points[this.clampNo(this.currentNo) - 1];
    this.updatePointById(p.id, p.time, bpm, true); //只改 BPM，时间不动
    this.bpmText = this.currentBpm().toString();
  }

  private onBpmTextChange(value: string): void {
    this.bpmText = value; //同上：文本先留着
    const n: number = Number.parseInt(value, 10);
    if (!Number.isNaN(n)) {
      const p: EditPoint = this.points[this.clampNo(this.currentNo) - 1];
      this.updatePointById(p.id, p.time, n, true);
    }
  }

  // ==================== 图上拖点 ====================

  private curViewMinutes(): number {
    return this.isOverview ? this.totalMinutes : NORMAL_WINDOW_MINUTES;
  }

  private curStartMinute(): number {
    return this.isOverview ? 0 : this.viewStartMinute;
  }

  private pointToX(minute: number): number {
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    return PAD_L + (minute - this.curStartMinute()) / this.curViewMinutes() * plotW;
  }

  private bpmToY(bpm: number): number {
    const plotH: number = this.ctx.height - PAD_T - PAD_B;
    return PAD_T + (1 - (bpm - BPM_MIN) / (BPM_MAX - BPM_MIN)) * plotH;
  }

  /** 按下时判断落在哪个点上，返回点的 id；没命中返回 -1 */
  private hitTestPoint(localX: number, localY: number): number {
    let bestId: number = -1;
    let bestDist: number = HIT_RADIUS * HIT_RADIUS;
    for (let i = 0; i < this.points.length; i++) {
      const dx: number = localX - this.pointToX(this.points[i].time);
      const dy: number = localY - this.bpmToY(this.points[i].bpm);
      const d2: number = dx * dx + dy * dy;
      if (d2 <= bestDist) {
        bestDist = d2;
        bestId = this.points[i].id;
      }
    }
    return bestId;
  }

  /** 按下：命中某个点就拖这个点，否则这一轮是在拖时间轴 */
  private beginDrag(event: GestureEvent): void {
    this.viewStartBase = this.viewStartMinute;
    this.dragPointId = -1;
    if (event.fingerList.length === 0) {
      return;
    }
    const id: number = this.hitTestPoint(event.fingerList[0].localX, event.fingerList[0].localY);
    if (id < 0) {
      return;
    }
    this.dragPointId = id;
    for (let i = 0; i < this.points.length; i++) {
      if (this.points[i].id === id) {
        this.dragStartMinute = this.points[i].time;
        this.dragStartBpm = this.points[i].bpm;
        // 首尾点：时间锁住，只让上下拖 BPM
        this.dragLockTime = (i === 0 || i === this.points.length - 1);
        break;
      }
    }
  }

  private updateDrag(event: GestureEvent): void {
    if (this.dragPointId < 0) {
      this.panBy(event.offsetX); //没按在点上，拖时间轴
      return;
    }
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    const plotH: number = this.ctx.height - PAD_T - PAD_B;
    if (plotW <= 0 || plotH <= 0) {
      return;
    }
    const dMinute: number = event.offsetX / plotW * this.curViewMinutes();
    const dBpm: number = -event.offsetY / plotH * (BPM_MAX - BPM_MIN);
    this.updatePointById(this.dragPointId, this.dragStartMinute + dMinute,
      this.dragStartBpm + dBpm, this.dragLockTime);
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
  }

  // ==================== 图上长按：加点 / 删点 ====================

  /** 长按落在点上＝删这个点（要确认）；落在空白处＝在这里加一个点（不确认） */
  private onChartLongPress(event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return;
    }
    const lx: number = event.fingerList[0].localX;
    const ly: number = event.fingerList[0].localY;

    const id: number = this.hitTestPoint(lx, ly);
    if (id >= 0) {
      const idx: number = this.indexOfId(id);
      if (idx === 0 || idx === this.points.length - 1) {
        // 首尾点是曲线的头和尾，删了曲线就断了
        this.getUIContext().getPromptAction().showToast({ message: '首尾点是曲线的头尾，不能删除' });
        return;
      }
      this.askDeletePoint(id);
      return;
    }

    // 空白处才加点，而且要落在绘图区内（轴外侧的留白点了没意义）
    if (!this.isInsidePlot(lx, ly)) {
      return;
    }
    this.addPointAt(this.xToMinute(lx), this.yToBpm(ly));
  }

  /** 删点前确认 */
  private askDeletePoint(id: number): void {
    const idx: number = this.indexOfId(id);
    if (idx < 0) {
      return;
    }
    const p: EditPoint = this.points[idx];
    this.getUIContext().showAlertDialog({
      title: '删除这个点？',
      message: '点' + (idx + 1) + '：' + formatMinutes(p.time) + ' 分钟 · ' + p.bpm + ' BPM',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.deletePoint(id);
        }
      }
    });
  }

  private deletePoint(id: number): void {
    const next: EditPoint[] = [];
    for (let i = 0; i < this.points.length; i++) {
      const p: EditPoint = this.points[i];
      if (p.id !== id) {
        next.push(new EditPoint(p.id, p.time, p.bpm));
      }
    }
    this.points = next;
    this.currentNo = this.clampNo(this.currentNo);
    this.currentText = this.currentNo.toString();
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
    this.drawChart();
  }

  /** 在指定时间/步频处加一个点，加完自动选中它 */
  private addPointAt(minute: number, bpm: number): void {
    let maxId: number = -1;
    for (let i = 0; i < this.points.length; i++) {
      if (this.points[i].id > maxId) {
        maxId = this.points[i].id;
      }
    }
    const newId: number = maxId + 1;
    const t: number = this.clampTime(minute);
    let b: number = Math.round(bpm);
    if (b < BPM_MIN) {
      b = BPM_MIN;
    }
    if (b > BPM_MAX) {
      b = BPM_MAX;
    }

    const next: EditPoint[] = [];
    for (let i = 0; i < this.points.length; i++) {
      const p: EditPoint = this.points[i];
      next.push(new EditPoint(p.id, p.time, p.bpm));
    }
    next.push(new EditPoint(newId, t, b));
    next.sort((a: EditPoint, c: EditPoint): number => a.time - c.time);
    this.points = next;

    for (let i = 0; i < next.length; i++) {
      if (next[i].id === newId) {
        this.currentNo = i + 1;
        break;
      }
    }
    this.currentText = this.currentNo.toString();
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
    this.drawChart();
  }

  private indexOfId(id: number): number {
    for (let i = 0; i < this.points.length; i++) {
      if (this.points[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  /** 画布内的 x 坐标 → 时间（分钟） */
  private xToMinute(localX: number): number {
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    if (plotW <= 0) {
      return 0;
    }
    return this.curStartMinute() + (localX - PAD_L) / plotW * this.curViewMinutes();
  }

  /** 画布内的 y 坐标 → BPM */
  private yToBpm(localY: number): number {
    const plotH: number = this.ctx.height - PAD_T - PAD_B;
    if (plotH <= 0) {
      return BPM_MIN;
    }
    return BPM_MIN + (1 - (localY - PAD_T) / plotH) * (BPM_MAX - BPM_MIN);
  }

  /** 是不是落在绘图区里（坐标轴外侧的留白不算） */
  private isInsidePlot(localX: number, localY: number): boolean {
    return localX >= PAD_L && localX <= this.ctx.width - PAD_R &&
      localY >= PAD_T && localY <= this.ctx.height - PAD_B;
  }

  // ==================== 保存 / 退出 ====================

  /** 名称兜底：没填就用占位文案 */
  private curveTitleText(): string {
    return this.curveTitle.length > 0 ? this.curveTitle : '未命名曲线';
  }

  /** 打包成要落盘的曲线文件（界面上的分钟 → 文件里的秒） */
  private buildCurveFile(): CurveFile {
    const pts: CurvePointJson[] = [];
    for (let i = 0; i < this.points.length; i++) {
      pts.push({
        time: minToSec(this.points[i].time),
        bpm: this.points[i].bpm,
        type: POINT_TYPE_LINEAR
      });
    }
    const file: CurveFile = {
      name: this.curveTitleText(),
      points: pts,
      //标签原样带回去：曲线和标签在同一个 json 里，不带上就把标签抹掉了
      tags: this.savedTags
    };
    return file;
  }

  /** 点"保存"按钮：先弹窗确认 */
  private askSave(): void {
    this.getUIContext().showAlertDialog({
      title: '保存曲线？',
      message: '「' + this.curveTitleText() + '」 · ' + this.totalMinutes + ' 分钟 · ' +
        this.points.length + ' 个点',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '保存',
        action: () => {
          this.saveCurve();
        }
      }
    });
  }

  /** 返回时弹：保存还是丢弃 */
  private askSaveOnExit(): void {
    this.getUIContext().showAlertDialog({
      title: '还没保存',
      message: '退出前要保存这条曲线吗？',
      autoCancel: true, //点空白处关掉弹窗＝留在本页
      primaryButton: {
        value: '丢弃',
        action: () => {
          this.popEditor();
        }
      },
      secondaryButton: {
        value: '保存',
        action: () => {
          this.saveAndExit();
        }
      }
    });
  }

  /** 保存（留在本页），存完给个提示 */
  private saveCurve(): void {
    const ok: boolean = this.saveCurveFile();
    this.getUIContext().getPromptAction().showToast({ message: ok ? '已保存' : '保存失败' });
  }

  /** 保存再退出 */
  private saveAndExit(): void {
    this.saveCurveFile();
    this.popEditor();
  }

  /**
   * 写盘：已经绑定文件就覆盖，否则新建一条（成为 n+1.json）并记住新的下标
   * 这样从主页菜单直接进来（没有传参）也能保存
   */
  private saveCurveFile(): boolean {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return false;
    }
    const file: CurveFile = this.buildCurveFile();
    if (this.curveIndex >= 0) {
      return saveAt(ctx, this.curveIndex, file);
    }
    const newIndex: number = appendCurve(ctx, file);
    if (newIndex < 0) {
      return false;
    }
    this.curveIndex = newIndex;
    return true;
  }

  /**
   * 退出编辑页。
   *
   * 这里只 pop、不回传结果：列表的刷新走 CurveStore 的写盘通知（storeRevision），
   * 不依赖 pushPathByName 的 onPop 回调（那个回调在标签编辑页上实测不触发）。
   */
  private popEditor(): void {
    this.leaving = true;
    this.navPathStack.pop();
  }

  /** 按序号从磁盘读一条曲线装进编辑器；读不到就保持默认曲线 */
  private loadCurve(index: number): void {
    if (index < 0) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const files: CurveFile[] = loadAll(ctx);
    if (index >= files.length) {
      console.error('曲线不存在：' + index);
      return;
    }
    const file: CurveFile = files[index];
    this.curveIndex = index;
    this.curveTitle = file.name;
    this.savedTags = file.tags;
    this.applyCurveFile(file);
  }

  /**
   * 把文件内容装进编辑器：秒 → 分钟，并把三条不变量修一遍
   * 总长度取最后一个点的时间（文件格式里没有单独的"总时长"字段）
   */
  private applyCurveFile(file: CurveFile): void {
    if (file.points.length < 2) {
      return; //数据不完整，保持默认曲线
    }
    let total: number = Math.round(secToMin(file.points[file.points.length - 1].time));
    if (total < TOTAL_MIN) {
      total = TOTAL_MIN;
    }
    if (total > TOTAL_MAX) {
      total = TOTAL_MAX;
    }
    this.totalMinutes = total;
    this.totalText = total.toString();

    const list: EditPoint[] = [];
    for (let i = 0; i < file.points.length; i++) {
      let t: number = secToMin(file.points[i].time);
      if (t < 0) {
        t = 0;
      }
      if (t > total) {
        t = total;
      }
      let b: number = Math.round(file.points[i].bpm);
      if (b < BPM_MIN) {
        b = BPM_MIN;
      }
      if (b > BPM_MAX) {
        b = BPM_MAX;
      }
      list.push(new EditPoint(i, t, b));
    }
    list.sort((a: EditPoint, c: EditPoint): number => a.time - c.time);
    list[0].time = 0; //不变量 1：头在 0
    list[list.length - 1].time = total; //不变量 2：尾在总长度
    this.points = list;

    this.currentNo = 1;
    this.currentText = '1';
    this.timeText = formatMinutes(this.currentTime());
    this.bpmText = this.currentBpm().toString();
    this.drawChart();
  }
}

@Builder
export function load() {
  CurveEdit()
}
