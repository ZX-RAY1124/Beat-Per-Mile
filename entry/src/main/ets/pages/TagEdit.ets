import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import {
  appendCurve,
  CurveEditParam,
  CurveFile,
  CurvePointJson,
  CurveTagJson,
  emptyCurve,
  loadAll,
  minToSec,
  saveAt,
  secToMin
} from '../ets_libs/CurveStore';

/**
 * 标签编辑页
 *
 * 参照曲线编辑页写的，但目的不同：这里是给曲线"打标签"——
 * 用户跑到某个时间点时，TTS 会读出该标签上的文字。
 *
 * 和曲线编辑页的差别：
 *   - **速度曲线只读**：曲线只是参考背景，点不能拖、不能加、不能删
 *   - 长按空白处 = 加一个标签；长按标签 = 删这个标签（弹窗确认）
 *   - 标签在图上画成一条竖线，竖线顶端是它的序号
 *   - 操作台去掉了"时间总长度"和"BPM 数值"，换成"标签内容"输入框
 *
 * 现在没有外部数据源，所以曲线用默认的两点直线、标签用两条演示数据。
 */

/**
 * 标签不是单独存的：它和曲线在同一个 json 文件里
 *   一个曲线文件 = { name, points[{time(秒), bpm, type}], tags[{time(秒), text}] }
 * 所以这里的保存是"读出原文件 → 换掉 tags → 写回"，绝不能把 points 覆盖掉。
 * ⚠️ 文件里的 time 是秒，界面上的 time 是分钟，转换只走 secToMin / minToSec
 */

/** 曲线上的一个点（本页只读，只用来把速度曲线画出来） */
class EditPoint {
  id: number;
  /** 时间（分钟） */
  time: number;
  /** 目标步频 */
  bpm: number;

  constructor(id: number, time: number, bpm: number) {
    this.id = id;
    this.time = time;
    this.bpm = bpm;
  }
}

/** 一个标签：跑到这个时间点时，读出 text */
class TagPoint {
  /** 稳定 id：标签按时间重排后靠它找回"当前编辑的是哪一个" */
  id: number;
  /** 时间（分钟） */
  time: number;
  /** 要读出来的文字 */
  text: string;

  constructor(id: number, time: number, text: string) {
    this.id = id;
    this.time = time;
    this.text = text;
  }
}

/** 没有数据传入时的参考曲线：只有头尾两点，一条恒定步频的直线 */
const DEFAULT_TOTAL: number = 30;
const DEFAULT_BPM: number = 150;
const DEFAULT_POINTS: EditPoint[] = [
  new EditPoint(0, 0, DEFAULT_BPM),
  new EditPoint(1, DEFAULT_TOTAL, DEFAULT_BPM),
];

/** 演示标签（接真实数据时替换掉） */
const DEFAULT_TAGS: TagPoint[] = [
  new TagPoint(0, 5, '热身结束，开始加速'),
  new TagPoint(1, 20, '还剩 10 分钟，坚持住'),
];

/** 数值范围 */
const NORMAL_WINDOW_MINUTES: number = 5; // 普通模式固定显示的时间长度
const BPM_MIN: number = 80;
const BPM_MAX: number = 240;
const BPM_TICK_STEP: number = 40;
const TIME_STEP: number = 0.5;      // 标签时间滑条的步长（分钟）
const HIT_RADIUS: number = 22;      // 图上命中标签的半径（vp）
const LONG_PRESS_MS: number = 500;  // 长按多久触发加/删

/** 图表里的字号，单位 vp（canvas 的 font 里那个 px 是物理像素，必须过 chartFont） */
const TICK_FONT_VP: number = 13;
const UNIT_FONT_VP: number = 12;
const TAG_FONT_VP: number = 10;      // 竖线顶端序号
const TAG_TEXT_FONT_VP: number = 11; // 竖线上写的标签内容

/** vp 字号 → canvas 的 font 字符串（按屏幕密度换算成物理 px） */
function chartFont(vpSize: number): string {
  return Math.round(vp2px(vpSize)).toString() + 'px sans-serif';
}

/** 图表配色：跟着界面背景走，比背景略深一点、带一点暖黄 */
const CHART_BG: string = '#F8F6EF';
const CHART_GRID: string = '#E9E5D8';
const CHART_AXIS: string = '#D3CDBD';
const CHART_TEXT: string = '#8C8880';
const CHART_LINE: string = '#FF6B6B';
const CHART_POINT: string = '#FF6B6B';
/**
 * 控制台（滑条、按钮）的强调色：和其它页面统一用红色
 * 注意别和下面的 TAG_COLOR 混用 —— 图上标签指针必须保持青色，红色会和曲线撞在一起看不清
 */
const ACCENT: string = '#FF6B6B';

/** 标签竖线／序号的颜色（和曲线的红区分开，故意不用强调色） */
const TAG_COLOR: string = '#2FB3A8';
const TAG_COLOR_DIM: string = '#8FD8D2';
const TAG_LINE_WIDTH: number = 2;
const TAG_LINE_WIDTH_CURRENT: number = 3.5;

/** 绘图区四周留白 */
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

/** 复制一份曲线点，避免直接改到模块常量 */
function copyPoints(src: EditPoint[]): EditPoint[] {
  const out: EditPoint[] = [];
  for (let i = 0; i < src.length; i++) {
    out.push(new EditPoint(src[i].id, src[i].time, src[i].bpm));
  }
  return out;
}

/** 复制一份标签 */
function copyTags(src: TagPoint[]): TagPoint[] {
  const out: TagPoint[] = [];
  for (let i = 0; i < src.length; i++) {
    out.push(new TagPoint(src[i].id, src[i].time, src[i].text));
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

/** 操作台的一行：标签 + [－] 输入框 [＋] */
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

/** 操作台的一行：标签时间滑条 + 右侧输入框 */
@Component
struct SliderRow {
  label: string = '';
  step: number = 1;
  inputType: InputType = InputType.Number;
  @Prop value: number = 0;
  @Prop valueText: string = '';
  @Prop min: number = 0;
  @Prop max: number = 100;
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
          .trackColor(TRACK_BG)
          .selectedColor(ACCENT)
          .blockColor(Color.White)
          .onChange((value: number) => {
            this.onSlide(value);
          })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      TextInput({ text: this.valueText })
        .type(this.inputType)
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
struct TagEdit {
  @State navPathStack: NavPathStack = new NavPathStack();

  // ---- 数据（曲线只读）----
  @State points: EditPoint[] = copyPoints(DEFAULT_POINTS);
  @State totalMinutes: number = DEFAULT_TOTAL;
  /** 标签列表，按时间排序 */
  @State tags: TagPoint[] = copyTags(DEFAULT_TAGS);

  // ---- 当前编辑的标签 ----
  /** 标签序号，1 开始（界面上的"标签n"） */
  @State currentNo: number = 1;
  @State currentText: string = '1';
  @State timeText: string = '5';

  // ---- 视图 ----
  @State isOverview: boolean = false;
  @State viewStartMinute: number = 0;

  /** 是否已经在退出流程里：防止弹窗里调 pop 又被 onBackPressed 拦一次（不参与渲染） */
  private leaving: boolean = false;
  /** 退出弹窗是否已经走过（保存/丢弃都算）。false 说明返回动作绕过了 onBackPressed */
  private exitHandled: boolean = false;
  /** 标签被改过没有：没改过就不用写盘，避免退出时重复保存把列表刷两遍 */
  private dirty: boolean = false;
  /** 正在编辑第几条曲线的标签（0 开始）；-1 表示还没绑定文件，保存时会新建 */
  private curveIndex: number = -1;
  /** 原文件的曲线名和点，保存标签时原样写回去（不能把曲线弄丢）。
   *  curveName 是 @State：标题栏要显示"在给哪条曲线编标签"，
   *  不带 index 从菜单进来时，这是唯一能看出编辑对象的地方。 */
  @State curveName: string = '';
  private savedPoints: CurvePointJson[] = [];
  private viewStartBase: number = 0;

  // ---- 拖标签（不参与渲染）----
  /** 正在被拖的标签 id；-1 表示这次拖动是在拖时间轴 */
  private dragTagId: number = -1;
  private dragStartMinute: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.timeText = formatMinutes(this.currentTime());
    // 数据在 onReady 里按路由参数读（见下面的 onReady）
  }

  /**
   * 兜底保存。
   *
   * HDS 标题栏的返回箭头会绕过 onBackPressed（退出弹窗不弹），只靠弹窗保存的话
   * 标签会静默丢掉。所以页面销毁时补一次，但加两个条件：
   *   dirty        —— 没改过就不写盘
   *   !exitHandled —— 弹窗已经问过了（用户选过保存或丢弃），尊重他的选择
   * 这样"弹窗里点保存 → 退出"只会写一次盘（原来会写两次，列表就跟着刷两遍）。
   */
  aboutToDisappear(): void {
    if (!this.exitHandled && this.dirty) {
      this.saveTagsFile();
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        // ================= 上半屏：图表（曲线只读，标签可编辑） =================
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
              // Exclusive：谁先满足谁生效
              //   轻点一下 = 选中点到的标签（控制台跟着切过去）
              //   按住不动 = 长按（加/删标签）
              //   一按就滑 = 拖动（标签或时间轴）
              GestureGroup(GestureMode.Exclusive,
                TapGesture({ count: 1 })
                  .onAction((event: GestureEvent) => {
                    this.onChartTap(event);
                  }),
                LongPressGesture({ repeat: false, duration: LONG_PRESS_MS })
                  .onAction((event: GestureEvent) => {
                    this.onChartLongPress(event);
                  }),
                PanGesture({ direction: PanDirection.Horizontal })
                  .onActionStart((event: GestureEvent) => {
                    this.beginDrag(event);
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.updateDrag(event);
                  })
                  .onActionEnd(() => {
                    this.dragTagId = -1;
                  })
                  .onActionCancel(() => {
                    this.dragTagId = -1;
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

        // ================= 图表模式切换 =================
        Row() {
          Blank()
          this.ModeToggle()
        }
        .width('100%')
        .padding({ right: 16, top: 10 })

        // ================= 下半屏：操作台 =================
        Column({ space: 14 }) {
          StepperRow({
            label: '当前标签',
            valueText: this.currentText,
            onMinus: () => {
              this.selectTag(this.currentNo - 1);
            },
            onPlus: () => {
              this.selectTag(this.currentNo + 1);
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

          // 标签内容：到点要让 TTS 读出来的文字
          Column({ space: 6 }) {
            Text('标签内容')
              .fontSize(15)
              .fontColor(TEXT_PRIMARY)
              .width('100%')
              .textAlign(TextAlign.Start)

            TextInput({
              text: this.currentTagText(),
              placeholder: '例如：还有 1 公里，加油！'
            })
              .width('100%')
              .height(38)
              .fontSize(15)
              .fontColor(TEXT_PRIMARY)
              .placeholderColor(TEXT_SECONDARY)
              .backgroundColor(FIELD_BG)
              .borderRadius(10)
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.setCurrentTagText(value);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Button('保存')
            .type(ButtonType.Normal) //默认是胶囊形，改成圆角矩形才吃 borderRadius
            .width('100%')
            .height(42)
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor(ACCENT)
            .borderRadius(10)
            .onClick(() => {
              this.askSave();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 20 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({
      content: {
        title: {
          mainTitle: this.curveName.length > 0 ? '标签编辑 · ' + this.curveName : '标签编辑',
          mainTitleSize: 20
        }
      }
    })
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
      // 列表页进来时带了 { index }，按它去磁盘读这条曲线的标签
      const param: CurveEditParam = context.pathInfo.param as CurveEditParam;
      if (param !== undefined && param !== null) {
        this.loadFromCurve(param.index);
      } else {
        // 从"页面导航"菜单直接进来是不带 index 的。
        // 标签只属于某一条曲线，没有 index 时不能凭空新建一条，
        // 否则保存会 append 出一条谁也不认识的曲线，列表上原来那张卡的缩略图永远不变。
        // 这里退化成"编第一条曲线"；列表为空时 loadFromCurve 会直接返回，
        // curveIndex 保持 -1，保存仍然按新建处理。
        this.loadFromCurve(0);
      }
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
    if (plotW <= 20 || plotH <= 20) {
      return;
    }

    const viewMinutes: number = this.isOverview ? this.totalMinutes : NORMAL_WINDOW_MINUTES;
    const startMinute: number = this.isOverview ? 0 : this.viewStartMinute;
    const endMinute: number = startMinute + viewMinutes;

    const toX = (minute: number): number => PAD_L + (minute - startMinute) / viewMinutes * plotW;
    const toY = (bpm: number): number =>
      PAD_T + (1 - (bpm - BPM_MIN) / (BPM_MAX - BPM_MIN)) * plotH;

    ctx.lineWidth = 1;

    // 竖向网格 + 时间刻度
    const stepMin: number = niceTimeStep(viewMinutes);
    ctx.font = chartFont(TICK_FONT_VP);
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

    // 轴单位
    ctx.fillStyle = CHART_TEXT;
    ctx.font = chartFont(UNIT_FONT_VP);
    ctx.textAlign = 'right';
    ctx.textBaseline = 'top';
    ctx.fillText('BPM', PAD_L - 8, 8);
    ctx.fillText('min', PAD_L + plotW, PAD_T + plotH + 21);

    // ---- 以下内容裁剪到绘图区 ----
    ctx.save();
    ctx.beginPath();
    ctx.rect(PAD_L, PAD_T, plotW, plotH);
    ctx.clip();

    const n: number = this.points.length;

    // 曲线下方的渐隐填充
    if (n >= 1) {
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

      // 曲线上的点：只画出来做参考，本页不可编辑，所以画小一点
      for (let i = 0; i < n; i++) {
        ctx.beginPath();
        ctx.arc(toX(this.points[i].time), toY(this.points[i].bpm), 3, 0, Math.PI * 2);
        ctx.fillStyle = CHART_POINT;
        ctx.fill();
        ctx.strokeStyle = '#FFFFFF';
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }
    }

    // ---- 标签：一条竖线，顶端带序号 ----
    for (let i = 0; i < this.tags.length; i++) {
      const tag: TagPoint = this.tags[i];
      const x: number = toX(tag.time);
      const isCurrent: boolean = (i === this.currentNo - 1);

      ctx.beginPath();
      ctx.moveTo(x, PAD_T);
      ctx.lineTo(x, PAD_T + plotH);
      ctx.strokeStyle = isCurrent ? TAG_COLOR : TAG_COLOR_DIM;
      ctx.lineWidth = isCurrent ? TAG_LINE_WIDTH_CURRENT : TAG_LINE_WIDTH;
      ctx.stroke();

      // 顶端的序号圆点
      ctx.beginPath();
      ctx.arc(x, PAD_T + 11, 9, 0, Math.PI * 2);
      ctx.fillStyle = isCurrent ? TAG_COLOR : TAG_COLOR_DIM;
      ctx.fill();

      ctx.fillStyle = '#FFFFFF';
      ctx.font = chartFont(TAG_FONT_VP);
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText((i + 1).toString(), x, PAD_T + 11);

      // 标签内容：沿着竖线竖着写（旋转 90°），长度不够就截断，
      // 这样多个标签挨得近也不会横向撞在一起
      if (tag.text.length > 0) {
        const avail: number = plotH - 32; //序号圆点下方到绘图区底部的可用长度
        if (avail > 14) {
          ctx.save();
          ctx.translate(x, PAD_T + 26);
          ctx.rotate(Math.PI / 2); //旋转后 +x 朝下，文字从上往下排
          ctx.fillStyle = isCurrent ? TAG_COLOR : TAG_COLOR_DIM;
          ctx.font = chartFont(TAG_TEXT_FONT_VP);
          ctx.textAlign = 'left';
          ctx.textBaseline = 'middle';
          // 第二个参数 -6：旋转后屏幕上看是"往右偏 6"，让文字离竖线一点距离
          ctx.fillText(this.fitText(ctx, tag.text, avail), 0, -6);
          ctx.restore();
        }
      }
    }

    ctx.restore();
  }

  // ==================== 交互（只针对标签） ====================

  private curViewMinutes(): number {
    return this.isOverview ? this.totalMinutes : NORMAL_WINDOW_MINUTES;
  }

  private curStartMinute(): number {
    return this.isOverview ? 0 : this.viewStartMinute;
  }

  private tagToX(minute: number): number {
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    return PAD_L + (minute - this.curStartMinute()) / this.curViewMinutes() * plotW;
  }

  /** 画布内的 x → 时间（分钟） */
  private xToMinute(localX: number): number {
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    if (plotW <= 0) {
      return 0;
    }
    return this.curStartMinute() + (localX - PAD_L) / plotW * this.curViewMinutes();
  }

  /** 按下的横坐标命中了哪个标签，返回标签 id；没命中返回 -1
   *  标签是一条竖线，所以只比横向距离 */
  private hitTestTag(localX: number): number {
    let bestId: number = -1;
    let bestDist: number = HIT_RADIUS * HIT_RADIUS;
    for (let i = 0; i < this.tags.length; i++) {
      const dx: number = localX - this.tagToX(this.tags[i].time);
      const d2: number = dx * dx;
      if (d2 <= bestDist) {
        bestDist = d2;
        bestId = this.tags[i].id;
      }
    }
    return bestId;
  }

  private isInsidePlot(localX: number, localY: number): boolean {
    return localX >= PAD_L && localX <= this.ctx.width - PAD_R &&
      localY >= PAD_T && localY <= this.ctx.height - PAD_B;
  }

  private beginDrag(event: GestureEvent): void {
    this.viewStartBase = this.viewStartMinute;
    this.dragTagId = -1;
    if (event.fingerList.length === 0) {
      return;
    }
    const id: number = this.hitTestTag(event.fingerList[0].localX);
    if (id < 0) {
      return;
    }
    this.dragTagId = id;
    this.selectTagById(id);
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i].id === id) {
        this.dragStartMinute = this.tags[i].time;
        break;
      }
    }
  }

  private updateDrag(event: GestureEvent): void {
    // 没按在标签上：拖时间轴
    if (this.dragTagId < 0) {
      this.panBy(event.offsetX);
      return;
    }
    const plotW: number = this.ctx.width - PAD_L - PAD_R;
    if (plotW <= 0) {
      return;
    }
    const dMinute: number = event.offsetX / plotW * this.curViewMinutes();
    this.updateTagById(this.dragTagId, this.dragStartMinute + dMinute);
    this.timeText = formatMinutes(this.currentTime());
  }

  /**
   * 轻点一下：点在哪条标签上就切到哪条
   * （没有这个的话，只有拖动才会切换当前标签，单纯点一下没反应）
   */
  private onChartTap(event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return;
    }
    const id: number = this.hitTestTag(event.fingerList[0].localX);
    if (id >= 0) {
      this.selectTagById(id);
    }
  }

  /** 长按落在标签上＝删（要确认）；落在空白处＝加（不确认） */
  private onChartLongPress(event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return;
    }
    const lx: number = event.fingerList[0].localX;
    const ly: number = event.fingerList[0].localY;

    const id: number = this.hitTestTag(lx);
    if (id >= 0) {
      this.askDeleteTag(id);
      return;
    }
    if (!this.isInsidePlot(lx, ly)) {
      return;
    }
    this.addTagAt(this.xToMinute(lx));
  }

  private askDeleteTag(id: number): void {
    const idx: number = this.indexOfTag(id);
    if (idx < 0) {
      return;
    }
    const tag: TagPoint = this.tags[idx];
    const text: string = tag.text.length > 0 ? tag.text : '（还没填内容）';
    this.getUIContext().showAlertDialog({
      title: '删除这个标签？',
      message: '标签' + (idx + 1) + '：' + formatMinutes(tag.time) + ' 分钟 · ' + text,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.deleteTag(id);
        }
      }
    });
  }

  // ==================== 标签数据 ====================

  private indexOfTag(id: number): number {
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i].id === id) {
        return i;
      }
    }
    return -1;
  }

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

  private clampNo(no: number): number {
    let n: number = Math.round(no);
    if (n < 1) {
      n = 1;
    }
    if (n > this.tags.length) {
      n = this.tags.length;
    }
    return n;
  }

  /** 当前标签在数组里的下标；一个标签都没有时返回 -1 */
  private currentIndex(): number {
    if (this.tags.length === 0) {
      return -1;
    }
    return this.clampNo(this.currentNo) - 1;
  }

  private currentTime(): number {
    const i: number = this.currentIndex();
    return i < 0 ? 0 : this.tags[i].time;
  }

  private currentTagText(): string {
    const i: number = this.currentIndex();
    return i < 0 ? '' : this.tags[i].text;
  }

  private timeRowLabel(): string {
    return this.tags.length === 0 ? '标签时间（分钟）' : '标签' + this.currentNo + ' 时间（分钟）';
  }

  /** 切到第 no 个标签 */
  private selectTag(no: number): void {
    if (this.tags.length === 0) {
      return;
    }
    this.currentNo = this.clampNo(no);
    this.currentText = this.currentNo.toString();
    this.timeText = formatMinutes(this.currentTime());
    this.drawChart();
  }

  private selectTagById(id: number): void {
    const idx: number = this.indexOfTag(id);
    if (idx < 0) {
      return;
    }
    this.selectTag(idx + 1);
  }

  private onCurrentTextChange(value: string): void {
    this.currentText = value;
    const n: number = Number.parseInt(value, 10);
    if (!Number.isNaN(n)) {
      this.selectTag(n);
    }
  }

  /** 改当前标签的时间；跨过别的标签会重排，序号跟着这个标签走 */
  private setCurrentTime(minutes: number): void {
    const i: number = this.currentIndex();
    if (i < 0) {
      return;
    }
    this.updateTagById(this.tags[i].id, minutes);
    this.timeText = formatMinutes(this.currentTime());
  }

  private onTimeTextChange(value: string): void {
    this.timeText = value; //先原样留着，让用户把小数打完整
    const i: number = this.currentIndex();
    if (i < 0) {
      return;
    }
    const n: number = Number.parseFloat(value);
    if (!Number.isNaN(n)) {
      this.updateTagById(this.tags[i].id, n);
    }
  }

  /** 改当前标签的文字 */
  private setCurrentTagText(text: string): void {
    const i: number = this.currentIndex();
    if (i < 0) {
      return;
    }
    const id: number = this.tags[i].id;
    const next: TagPoint[] = [];
    for (let k = 0; k < this.tags.length; k++) {
      const t: TagPoint = this.tags[k];
      if (t.id === id) {
        next.push(new TagPoint(t.id, t.time, text));
      } else {
        next.push(new TagPoint(t.id, t.time, t.text));
      }
    }
    this.tags = next;
    this.dirty = true;
  }

  /** 改某个标签的时间（按 id 找），改完按时间重排，序号跟着它走 */
  private updateTagById(id: number, minute: number): void {
    const t: number = this.clampTime(minute);
    const next: TagPoint[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      const tag: TagPoint = this.tags[i];
      if (tag.id === id) {
        next.push(new TagPoint(tag.id, t, tag.text));
      } else {
        next.push(new TagPoint(tag.id, tag.time, tag.text));
      }
    }
    next.sort((a: TagPoint, b: TagPoint): number => a.time - b.time);
    this.tags = next;
    this.dirty = true;

    for (let i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        this.currentNo = i + 1;
        break;
      }
    }
    this.currentText = this.currentNo.toString();
    // 不在这里回写 timeText：拖动滑条/输入框那条路径自己管，
    // 否则用户输入 "5." 时会被规范成 "5"，小数点被吃掉
    this.drawChart();
  }

  /** 在指定时间加一个标签，加完自动选中它 */
  private addTagAt(minute: number): void {
    let maxId: number = -1;
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i].id > maxId) {
        maxId = this.tags[i].id;
      }
    }
    const newId: number = maxId + 1;
    const t: number = this.clampTime(minute);

    const next: TagPoint[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      const tag: TagPoint = this.tags[i];
      next.push(new TagPoint(tag.id, tag.time, tag.text));
    }
    next.push(new TagPoint(newId, t, ''));
    next.sort((a: TagPoint, b: TagPoint): number => a.time - b.time);
    this.tags = next;
    this.dirty = true;

    for (let i = 0; i < next.length; i++) {
      if (next[i].id === newId) {
        this.currentNo = i + 1;
        break;
      }
    }
    this.currentText = this.currentNo.toString();
    this.timeText = formatMinutes(t);
    this.drawChart();
  }

  private deleteTag(id: number): void {
    const next: TagPoint[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      const tag: TagPoint = this.tags[i];
      if (tag.id !== id) {
        next.push(new TagPoint(tag.id, tag.time, tag.text));
      }
    }
    this.tags = next;
    this.dirty = true;

    if (next.length === 0) {
      // 全删光了：把序号和输入框都归零，避免界面显示"标签1"但一个都没有
      this.currentNo = 1;
      this.currentText = '1';
      this.timeText = '0';
    } else {
      this.currentNo = this.clampNo(this.currentNo);
      this.currentText = this.currentNo.toString();
      this.timeText = formatMinutes(this.currentTime());
    }
    this.drawChart();
  }

  /** 按可用长度把文字截断（用 measureText 精确量，超出加省略号） */
  private fitText(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
    if (ctx.measureText(text).width <= maxWidth) {
      return text;
    }
    let s: string = text;
    while (s.length > 0 && ctx.measureText(s + '…').width > maxWidth) {
      s = s.substring(0, s.length - 1);
    }
    return s + '…';
  }

  // ==================== 保存 ====================

  /**
   * 打包成要落盘的曲线文件：**曲线原样带回**，只换掉 tags
   * （界面上的分钟 → 文件里的秒）
   */
  private buildCurveFile(): CurveFile {
    const tags: CurveTagJson[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      tags.push({ time: minToSec(this.tags[i].time), text: this.tags[i].text });
    }
    // 还没绑定文件时（从主页菜单直接进来），给它一条头尾两点的直线当曲线
    let pts: CurvePointJson[] = this.savedPoints;
    if (pts.length < 2) {
      pts = emptyCurve('x', this.totalMinutes).points;
    }
    const file: CurveFile = {
      name: this.curveName.length > 0 ? this.curveName : '未命名曲线',
      points: pts,
      tags: tags
    };
    return file;
  }

  /** 点"保存"：先弹窗确认 */
  private askSave(): void {
    this.getUIContext().showAlertDialog({
      title: '保存标签？',
      message: '共 ' + this.tags.length + ' 个标签 · 曲线时长 ' + this.totalMinutes + ' 分钟',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '保存',
        action: () => {
          this.saveTags();
        }
      }
    });
  }

  private saveTags(): void {
    const ok: boolean = this.saveTagsFile();
    this.getUIContext().getPromptAction().showToast({ message: ok ? '已保存' : '保存失败' });
  }

  /** 返回时弹：保存还是丢弃 */
  private askSaveOnExit(): void {
    this.getUIContext().showAlertDialog({
      title: '还没保存',
      message: '退出前要保存这些标签吗？',
      autoCancel: true, //点空白处关掉弹窗＝留在本页
      primaryButton: {
        value: '丢弃',
        action: () => {
          this.exitHandled = true;
          this.popEditor();
        }
      },
      secondaryButton: {
        value: '保存',
        action: () => {
          this.exitHandled = true;
          if (this.dirty) {
            this.saveTagsFile(); //刚才已经在控制台存过就不重复写，否则列表会连着刷两遍
          }
          this.popEditor();
        }
      }
    });
  }

  /** 退出编辑页（保存与否由调用方决定，这里只负责关掉） */
  private popEditor(): void {
    this.leaving = true;
    this.navPathStack.pop();
  }

  /**
   * 写盘：已经绑定文件就覆盖那条曲线的 json（曲线部分不动，只换 tags）；
   * 没绑定就新建一条曲线文件
   */
  private saveTagsFile(): boolean {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return false;
    }
    const file: CurveFile = this.buildCurveFile();
    let ok: boolean = false;
    if (this.curveIndex >= 0) {
      ok = saveAt(ctx, this.curveIndex, file);
    } else {
      // 列表为空时才会走到这里：新建一条曲线文件
      const newIndex: number = appendCurve(ctx, file);
      if (newIndex >= 0) {
        this.curveIndex = newIndex; //记住下标，同一次会话里再保存就是覆盖而不是又新建
        ok = true;
      }
    }
    if (ok) {
      this.dirty = false;
    }
    return ok;
  }

  /**
   * 按序号从磁盘读一条曲线：拿它的曲线画背景、拿它的标签来编辑
   * （时间 秒 → 分钟；读不到就保持默认曲线和演示标签）
   */
  private loadFromCurve(index: number): void {
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
    this.curveName = file.name;
    this.savedPoints = file.points;

    // 总长度取最后一个点（文件格式里没有单独的"总时长"字段），要先定下来，
    // 后面 clampTime() 才有一个正确的上限
    if (file.points.length >= 2) {
      const total: number = Math.max(1,
        Math.round(secToMin(file.points[file.points.length - 1].time)));
      this.totalMinutes = total;
    }

    // 背景曲线
    const pts: EditPoint[] = [];
    for (let i = 0; i < file.points.length; i++) {
      let b: number = Math.round(file.points[i].bpm);
      if (b < BPM_MIN) {
        b = BPM_MIN;
      }
      if (b > BPM_MAX) {
        b = BPM_MAX;
      }
      pts.push(new EditPoint(i, secToMin(file.points[i].time), b));
    }
    if (pts.length >= 2) {
      pts.sort((a: EditPoint, c: EditPoint): number => a.time - c.time);
      this.points = pts;
    }

    // 标签
    const list: TagPoint[] = [];
    for (let i = 0; i < file.tags.length; i++) {
      list.push(new TagPoint(i, this.clampTime(secToMin(file.tags[i].time)), file.tags[i].text));
    }
    list.sort((a: TagPoint, b: TagPoint): number => a.time - b.time);
    this.tags = list;

    if (list.length === 0) {
      this.currentNo = 1;
      this.currentText = '1';
      this.timeText = '0';
    } else {
      this.currentNo = 1;
      this.currentText = '1';
      this.timeText = formatMinutes(this.currentTime());
    }
    this.drawChart();
  }

  // ==================== 视图 ====================

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
}

@Builder
export function load() {
  TagEdit()
}
