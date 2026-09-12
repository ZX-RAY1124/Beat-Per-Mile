import { HdsNavDestination } from '@kit.UIDesignKit';

/**
 * 曲线列表页
 *
 * 布局约定：
 *   - 第一项永远是"恒定BPM"，只有一行文字
 *   - 其余项：标题在左上角，标题下方是曲线预览（网格 + 折线），预览右侧是设置图标
 *   - 未选中：带阴影的圆角矩形，宽度接近屏幕宽度
 *   - 选中：整体向左上浮起（偏移 + 加重阴影），四周有色描边，左侧描边更粗
 *
 * 当前是演示版：数据写死在 DEMO_CURVES 里，只做布局和选中效果。
 */

/** 列表里的一条曲线（演示用，后续接真实数据） */
class CurveData {
  title: string;
  /** 折线颜色，同时作为选中时的描边色 */
  lineColor: string;
  /** 折线下方面积的填充色 */
  fillColor: string;
  /** 预览折线的 y 值，取值 0~1（0 = 顶部），按 x 均匀铺满整个预览区 */
  points: number[];

  constructor(title: string, lineColor: string, fillColor: string, points: number[]) {
    this.title = title;
    this.lineColor = lineColor;
    this.fillColor = fillColor;
    this.points = points;
  }
}

/** 演示数据：三个曲线项 */
const DEMO_CURVES: CurveData[] = [
  new CurveData('渐进加速', '#FF6B6B', 'rgba(255,107,107,0.14)',
    [0.82, 0.74, 0.66, 0.58, 0.48, 0.40, 0.30, 0.22]),
  new CurveData('波浪起伏', '#4ECDC4', 'rgba(78,205,196,0.14)',
    [0.52, 0.30, 0.58, 0.28, 0.62, 0.34, 0.54, 0.32]),
  new CurveData('阶梯爬升', '#A78BFA', 'rgba(167,139,250,0.14)',
    [0.86, 0.86, 0.64, 0.64, 0.42, 0.42, 0.24, 0.24]),
];

/** 卡片视觉常量 */
const CARD_RADIUS: number = 18;   // 圆角
const CARD_SPACE: number = 18;    // 卡片间距
const CARD_ACCENT: string = '#FF6B6B'; // 恒定BPM 用的描边色
const LIFT: number = 6;           // 选中时向左上浮起的距离

/**
 * 曲线预览：网格 + 折线 + 折线下方淡色面积
 * points / lineColor / fillColor 都是静态参数，父组件重建时不需要更新，所以不加装饰器
 */
@Component
struct CurvePreview {
  points: number[] = [];
  lineColor: string = CARD_ACCENT;
  fillColor: string = 'rgba(255,107,107,0.14)';

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .backgroundColor('#F7F8FB')
      .borderRadius(10)
      .onReady(() => {
        this.drawPreview();
      })
      .onAreaChange(() => {
        this.drawPreview();
      })
  }

  private drawPreview(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    const n: number = this.points.length;
    if (w <= 0 || h <= 0 || n < 2) {
      return;
    }
    this.ctx.clearRect(0, 0, w, h);

    // 网格：3 条竖线 + 2 条横线
    this.ctx.strokeStyle = '#E3E6EE';
    this.ctx.lineWidth = 1;
    for (let i = 1; i <= 3; i++) {
      const x: number = w * i / 4;
      this.ctx.beginPath();
      this.ctx.moveTo(x, 0);
      this.ctx.lineTo(x, h);
      this.ctx.stroke();
    }
    for (let j = 1; j <= 2; j++) {
      const y: number = h * j / 3;
      this.ctx.beginPath();
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(w, y);
      this.ctx.stroke();
    }

    // 折线四周留一点内边距，避免线头被裁掉
    const pad: number = 6;
    const innerW: number = w - pad * 2;
    const innerH: number = h - pad * 2;
    const stepX: number = innerW / (n - 1);

    // 折线下方的淡色面积
    this.ctx.beginPath();
    this.ctx.moveTo(pad, h);
    for (let i = 0; i < n; i++) {
      this.ctx.lineTo(pad + stepX * i, pad + this.points[i] * innerH);
    }
    this.ctx.lineTo(pad + innerW, h);
    this.ctx.closePath();
    this.ctx.fillStyle = this.fillColor;
    this.ctx.fill();

    // 折线本身
    this.ctx.beginPath();
    this.ctx.moveTo(pad, pad + this.points[0] * innerH);
    for (let i = 1; i < n; i++) {
      this.ctx.lineTo(pad + stepX * i, pad + this.points[i] * innerH);
    }
    this.ctx.strokeStyle = this.lineColor;
    this.ctx.lineWidth = 2;
    this.ctx.lineJoin = 'round';
    this.ctx.lineCap = 'round';
    this.ctx.stroke();
  }
}

/**
 * 列表项卡片
 * points 为空时退化成"只有一行字"的形态（恒定BPM）
 */
@Component
struct CurveCard {
  // 静态数据
  title: string = '';
  points: number[] = [];
  lineColor: string = CARD_ACCENT;
  fillColor: string = 'rgba(255,107,107,0.14)';
  accentColor: string = CARD_ACCENT;
  // 选中状态要跟着父组件刷新，用 @Prop
  @Prop selected: boolean = false;
  // 回调
  onSelect: () => void = () => {
  };
  onSettings: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1B1B2F')
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.points.length >= 2) {
        Row({ space: 12 }) {
          Column() {
            CurvePreview({
              points: this.points,
              lineColor: this.lineColor,
              fillColor: this.fillColor
            })
          }
          .layoutWeight(1)
          .height(72)

          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(24)
            .fontColor(['#8A8F99'])
            .onClick(() => {
              this.onSettings();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.points.length >= 2 ? 14 : 20,
      bottom: this.points.length >= 2 ? 14 : 20
    })
    .backgroundColor(Color.White)
    .borderRadius(CARD_RADIUS)
    .borderColor(this.accentColor)
    .borderWidth(this.selected
      ? { left: 6, top: 1.5, right: 1.5, bottom: 1.5 }
      : { left: 0, top: 0, right: 0, bottom: 0 })
    .shadow(this.selected
      ? { radius: 24, color: '#2E000000', offsetX: 6, offsetY: 10 }
      : { radius: 18, color: '#26000000', offsetX: 0, offsetY: 6 })
    .offset({ x: this.selected ? -LIFT : 0, y: this.selected ? -LIFT : 0 })
    .zIndex(this.selected ? 1 : 0)
    .onClick(() => {
      this.onSelect();
    })
  }
}

@Component
struct CurveList {
  @State navPathStack: NavPathStack = new NavPathStack();
  /** 当前选中的项：0 = 恒定BPM，1..n 对应 DEMO_CURVES 的下标 + 1 */
  @State selectedIndex: number = 0;

  build() {
    HdsNavDestination() {
      Scroll() {
        Column({ space: CARD_SPACE }) {
          // 第一项固定是"恒定BPM"，只有一行字
          CurveCard({
            title: '恒定BPM',
            points: [],
            accentColor: CARD_ACCENT,
            selected: this.selectedIndex === 0,
            onSelect: () => {
              this.select(0);
            },
            onSettings: () => {
              this.openSettings('恒定BPM');
            }
          })

          ForEach(DEMO_CURVES, (item: CurveData, index: number) => {
            CurveCard({
              title: item.title,
              points: item.points,
              lineColor: item.lineColor,
              fillColor: item.fillColor,
              accentColor: item.lineColor,
              selected: this.selectedIndex === index + 1,
              onSelect: () => {
                this.select(index + 1);
              },
              onSettings: () => {
                this.openSettings(item.title);
              }
            })
          }, (item: CurveData) => item.title)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      // HdsNavDestination 的标题栏是悬浮在内容之上的：这里让出标题栏的高度，
      // 否则列表第一项会和大标题重叠（滚动时内容也会从标题栏底下穿过去）
      .padding({ top: $r('sys.float.single_line_titlebar_height') })
    }
    .titleBar({ content: { title: { mainTitle: '曲线列表', mainTitleSize: 20 } } })
    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })
  }

  /** 切换选中项，用 animateTo 让浮起 / 描边 / 阴影过渡 */
  private select(index: number): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.selectedIndex = index;
    });
  }

  /** 设置图标：具体页面还没做，先只打日志 */
  private openSettings(title: string): void {
    console.info('打开曲线设置：' + title);
  }
}

@Builder
export function load() {
  CurveList()
}
