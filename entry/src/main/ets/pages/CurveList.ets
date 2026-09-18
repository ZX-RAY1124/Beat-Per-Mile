import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  appendCurve,
  count,
  CurveEditParam,
  CurveFile,
  deleteAt,
  emptyCurve,
  loadAll,
  pointsToPreview,
  secToMin
} from '../ets_libs/CurveStore';

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
  /** 预览折线的 y 值，取值 0~1（0 = 顶部） */
  points: number[];
  /** 每个点的归一化时间位置（0~1），让预览按真实时间铺开 */
  pointX: number[] = [];
  /** 标签指针的归一化时间位置（0~1） */
  tagX: number[] = [];

  constructor(title: string, lineColor: string, fillColor: string, points: number[]) {
    this.title = title;
    this.lineColor = lineColor;
    this.fillColor = fillColor;
    this.points = points;
  }
}

/** 演示数据：三个曲线项（已由磁盘数据取代，保留类型定义） */


const COLOR_PLAN:string[][] = [          //配色方案
  ['#FF6B6B', 'rgba(255,107,107,0.14)'],
  ['#4ECDC4', 'rgba(78,205,196,0.14)'],
  ['#A78BFA', 'rgba(167,139,250,0.14)']
]


/** 卡片视觉常量 */
const CARD_RADIUS: number = 18;   // 圆角
const CARD_SPACE: number = 18;    // 卡片间距
const CARD_ACCENT: string = '#FF6B6B'; // 恒定BPM 用的描边色
/** 卡片缩略图里标签指针的颜色（和标签编辑页保持一致） */
const TAG_MARK_COLOR: string = '#2FB3A8';
const LIFT: number = 6;           // 选中时向左上浮起的距离

/** 卡片右侧三个操作图标 */
const ICON_SIZE: number = 22;
const ICON_GAP: number = 6;          // 设置 ↔ 标签：同一组，挨近一点
const ICON_GAP_DANGER: number = 20;  // 标签 ↔ 删除：拉开距离，防止误触
const ICON_COLOR: string = '#8A8F99';
const ICON_DANGER: string = '#D98C8C';

/**
 * 描边宽度是"恒定"的，选中与否只切换描边的颜色。
 * 原因：ArkUI 的描边占据组件内部空间，如果未选中写 0、选中写 6，
 * 内容区宽度会在选中瞬间变小，曲线预览的右边缘就会猛地往里缩一下
 * （布局变化立刻生效，动画只作用于描边的绘制）。
 */
const CARD_BORDER_LEFT: number = 6;    // 左侧描边（选中时可见）
const CARD_BORDER_OTHER: number = 1.5; // 其余三边描边

/** 内容到卡片外边缘的目标留白（＝ 描边宽度 + padding，所以 padding 要减去描边） */
const CARD_INSET_H: number = 16;       // 有曲线预览时，左右留白
const CARD_INSET_V: number = 14;       // 有曲线预览时，上下留白
const CARD_INSET_V_TEXT: number = 20;  // 只有一行字时，上下留白

/**
 * 曲线预览：网格 + 折线 + 折线下方淡色面积
 * points / lineColor / fillColor 都是静态参数，父组件重建时不需要更新，所以不加装饰器
 */
@Component
struct CurvePreview {
  points: number[] = [];
  /** 每个点在时间轴上的归一化位置（0~1）；给空数组就按等距画 */
  pointX: number[] = [];
  /** 标签指针的归一化位置（0~1）。这里只画竖线，不画序号和文字 —— 预览区太挤 */
  tagX: number[] = [];
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

    // 点的横向位置优先用真实时间比例，这样标签指针和曲线的位置才对得上；
    // 没给时间就退化成等距（老数据）
    const byTime: boolean = this.pointX.length === n;
    const xOf = (i: number): number => {
      return byTime ? pad + this.pointX[i] * innerW : pad + innerW * i / (n - 1);
    };

    // 折线下方的淡色面积
    this.ctx.beginPath();
    this.ctx.moveTo(xOf(0), h);
    for (let i = 0; i < n; i++) {
      this.ctx.lineTo(xOf(i), pad + this.points[i] * innerH);
    }
    this.ctx.lineTo(xOf(n - 1), h);
    this.ctx.closePath();
    this.ctx.fillStyle = this.fillColor;
    this.ctx.fill();

    // 标签指针：一条竖线
    this.ctx.strokeStyle = TAG_MARK_COLOR;
    this.ctx.lineWidth = 1.5;
    for (let i = 0; i < this.tagX.length; i++) {
      const tx: number = pad + this.tagX[i] * innerW;
      this.ctx.beginPath();
      this.ctx.moveTo(tx, pad);
      this.ctx.lineTo(tx, h - pad);
      this.ctx.stroke();
    }

    // 折线本身（画在标签之后，免得被竖线盖住）
    this.ctx.beginPath();
    this.ctx.moveTo(xOf(0), pad + this.points[0] * innerH);
    for (let i = 1; i < n; i++) {
      this.ctx.lineTo(xOf(i), pad + this.points[i] * innerH);
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
  dialogComponentId?: number;
  @State inputValue: string = '';       // 通过 @Link 双向同步到父组件
  @State realBPM: string = '';



  // 静态数据
  title: string = '';
  points: number[] = [];
  pointX: number[] = [];
  tagX: number[] = [];
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
  onTags: () => void = () => {
  };
  onDelete: () => void = () => {
  };


  /**
   * 卡片右侧的操作图标
   *   - 曲线卡片：设置 / 标签 / 删除 三个竖排
   *   - 恒定BPM：只有一个设置图标
   *     （它是单值，既没有曲线可删、也不需要标签，所以那一行保持原来的高度）
   *
   * 删除和上面两个之间留了更大的间距，防止点标签时误触删除
   */
  @Builder
  CardActions() {
    Column() {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(ICON_SIZE)
        .fontColor([ICON_COLOR])
        .onClick(() => {
          if (this.points.length >= 2) {
            this.onSettings();
          } else {
            this.show_BPM_setting(); //恒定BPM 是单值，弹自己的设置框
          }
        })

      if (this.points.length >= 2) {
        SymbolGlyph($r('sys.symbol.bookmark')) //"标签"用书签符号（sys.symbol.tag 不存在）
          .fontSize(ICON_SIZE)
          .fontColor([ICON_COLOR])
          .margin({ top: ICON_GAP })
          .onClick(() => {
            this.onTags();
          })

        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(ICON_SIZE)
          .fontColor([ICON_DANGER])
          .margin({ top: ICON_GAP_DANGER })
          .onClick(() => {
            this.onDelete();
          })
      }
    }
  }

  @Builder
  BPM_setting_builder() {
    Column() {
      Text("设置默认BPM").fontSize($r('sys.float.Title_M'))
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({top:20, bottom: 30})
      Column() {
        TextInput({placeholder:"请输入BPM", text: this.inputValue}).width("80%").height(40).type(InputType.Number).defaultFocus(true).onChange((value: string) => {
          this.inputValue = value.replace(/[^\d]/g, '')
        });
      }.padding({bottom: 20})
      Row({space: 30}) {
        Button("确定").width(100).height(40).onClick(() => {
          /** 这里记得加上设置BPM的函数*/
          this.close_BPM_setting();
          this.realBPM = this.inputValue;
        }).backgroundColor(CARD_ACCENT)
        Button("取消").width(100).height(40).onClick(() => {
          this.close_BPM_setting();
        }).backgroundColor(CARD_ACCENT)
      }.padding({bottom: 30})
    }
  }

  show_BPM_setting(){
    try {
      const promptAction = this.getUIContext().getPromptAction();
      promptAction.openCustomDialog({
        builder: () => {
          this.BPM_setting_builder();
        },
        autoCancel : false,

      }).then((dialogId: number) => {
        this.dialogComponentId = dialogId;
      })
        .catch((error: BusinessError) => {

      });
    } catch (error){

    }
  }

  close_BPM_setting() {
    if(this.dialogComponentId) {
      try{
        this.getUIContext().getPromptAction().closeCustomDialog(this.dialogComponentId);
        this.dialogComponentId = undefined;

      } catch (error){
         //先不处理
      }
    }
  }



  build() {
    Column({ space: 10 }) {
      if (this.points.length >= 2) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B1B2F')
          .width('100%')
          .textAlign(TextAlign.Start)
        Row({ space: 12 }) {
          Column() {
            CurvePreview({         //缩略图
              points: this.points,
              pointX: this.pointX,
              tagX: this.tagX,
              lineColor: this.lineColor,
              fillColor: this.fillColor
            })
          }
          .layoutWeight(1)
          .height(72)

          this.CardActions()                              //设置 / 标签 / 删除
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B1B2F')
          .width('100%')
          .textAlign(TextAlign.Start)
          Row({ space: 12 }) {
            Text("默认BPM:" + this.realBPM)
              // 原来写死 277.14：卡片宽度一变就把右边的图标挤歪，
              // 改成占满剩余空间，图标才会和其它卡片对齐
              .layoutWeight(1)
              .fontSize(12)
              .textAlign(TextAlign.Start)

            this.CardActions()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

      }
    }
    .width('100%')
    // padding 要减掉描边宽度：内容到卡片外边缘的留白始终是 CARD_INSET_*
    .padding({
      left: CARD_INSET_H - CARD_BORDER_LEFT,
      right: CARD_INSET_H - CARD_BORDER_OTHER,
      top: (this.points.length >= 2 ? CARD_INSET_V : CARD_INSET_V_TEXT) - CARD_BORDER_OTHER,
      bottom: (this.points.length >= 2 ? CARD_INSET_V : CARD_INSET_V_TEXT) - CARD_BORDER_OTHER
    })
    .backgroundColor(Color.White)
    .borderRadius(CARD_RADIUS)
    .borderColor(this.selected ? this.accentColor : '#00000000') //未选中＝全透明，宽度仍然占位
    .borderWidth({
      left: CARD_BORDER_LEFT,
      top: CARD_BORDER_OTHER,
      right: CARD_BORDER_OTHER,
      bottom: CARD_BORDER_OTHER
    })
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
export struct CurveList {
  @State navPathStack: NavPathStack = new NavPathStack();
  @Link @Watch ('onColumnAdd') triggerFlag: boolean   //父组件外部触发器

  onColumnAdd(){
    if(this.triggerFlag){
      this.makeContent();
    }
  }

  /** 当前选中的项：0 = 恒定BPM，1..n 对应 CURVES 的下标 + 1 */
  @State selectedIndex: number = 0;
  /**
   * 每次重新读盘就 +1，然后接到 ForEach 的键里。
   *
   * 为什么需要它：卡片上的 points / pointX / tagX 是**普通成员**（只有 selected 是 @Prop），
   * 而普通成员只在组件创建时初始化一次，父组件重建时不会更新。
   * 键不变 → ForEach 复用旧卡片 → 缩略图一直是进编辑页之前的样子。
   * 让键跟着版本号变，卡片整体重建，才能拿到新数据。
   */
  @State listRevision: number = 0;

  /**
   * 曲线数据的全局版本号（CurveStore 里每次写盘都会 +1）。
   *
   * 为什么不用 pushPathByName 的 onPop 回调刷新：实测**标签编辑页返回时那个回调不触发**，
   * 于是 json 改了、列表却不重读，缩略图一直是旧的（曲线编辑页那条路看起来是好的，但不能依赖）。
   * 改成"谁写盘谁通知"，列表页 @Watch 到就重读，跟用户怎么退出编辑页、有没有走回调都无关。
   */
  // 键名是字面量：@StorageLink 的参数必须是字符串字面量。
  // 它和 CurveStore 里的 CURVE_REVISION_KEY 是同一个 key（'curveStoreRevision'）。
  @StorageLink('curveStoreRevision') @Watch('onStoreChanged') storeRevision: number = 0;

  /** 磁盘变了：重读一遍（编辑页保存/删除时由 CurveStore 通知过来） */
  onStoreChanged(): void {
    this.reloadCurves();
  }

  PAGE_BG: string = '#F5F6F8';
  /** 曲线列表：内容来自 <filesDir>/Curve/*.json，顺序就是文件名顺序 */
  @State CURVES: CurveData[] = [];

  aboutToAppear(): void {
    this.reloadCurves();
  }

  /** 从磁盘重新读一遍曲线列表 */
  private reloadCurves(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const files: CurveFile[] = loadAll(ctx);
    const out: CurveData[] = [];
    for (let i = 0; i < files.length; i++) {
      const plan: string[] = COLOR_PLAN[i % COLOR_PLAN.length];
      const card: CurveData = new CurveData(files[i].name, plan[0], plan[1],
        pointsToPreview(files[i].points));
      // 缩略图按真实时间铺开，标签指针才落得准
      const total: number = this.curveTotalMinutes(files[i]);
      const pTimes: number[] = [];
      for (let k = 0; k < files[i].points.length; k++) {
        pTimes.push(files[i].points[k].time);
      }
      card.pointX = this.normalizedX(pTimes, total);
      const tTimes: number[] = [];
      for (let k = 0; k < files[i].tags.length; k++) {
        tTimes.push(files[i].tags[k].time);
      }
      card.tagX = this.normalizedX(tTimes, total);
      out.push(card);
    }
    this.CURVES = out;
    this.listRevision = this.listRevision + 1; //让 ForEach 的键变化，卡片重建
    if (this.selectedIndex > out.length) {
      this.selectedIndex = 0;
    }
  }

  /** 曲线总时长（分钟）：取最后一个点的时间，兜底 1 分钟 */
  private curveTotalMinutes(file: CurveFile): number {
    if (file.points.length === 0) {
      return 1;
    }
    const last: number = secToMin(file.points[file.points.length - 1].time);
    return last > 0 ? last : 1;
  }

  /** 一串"秒"→ 归一化横向位置（0~1） */
  private normalizedX(times: number[], totalMinutes: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < times.length; i++) {
      let v: number = secToMin(times[i]) / totalMinutes;
      if (v < 0) {
        v = 0;
      }
      if (v > 1) {
        v = 1;
      }
      out.push(v);
    }
    return out;
  }



  build() {

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
              //恒定BPM 的齿轮弹的是自己的输入框（见 CurveCard.CardActions），这里走不到
              this.openSettings(-1);
            }
          })

          ForEach(this.CURVES, (item: CurveData, index: number) => {
            CurveCard({
              title: item.title,
              points: item.points,
              pointX: item.pointX,
              tagX: item.tagX,
              lineColor: item.lineColor,
              fillColor: item.fillColor,
              accentColor: item.lineColor,
              selected: this.selectedIndex === index + 1,
              onSelect: () => {
                this.select(index + 1);
              },
              onSettings: () => {
                this.openSettings(index);
              },
              onTags: () => {
                this.openTags(index);
              },
              onDelete: () => {
                this.askDeleteCurve(index);
              }
            })
            //键里带版本号：内容变了必须重建卡片，否则缩略图不刷新（见 listRevision 的注释）
          }, (item: CurveData) => item.title + '#' + this.listRevision.toString())


          Blank().height(80).width("100%");

        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: 16,
          bottom: 32
        })


      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.PAGE_BG)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      // HdsNavDestination 的标题栏是悬浮在内容之上的：这里让出标题栏的高度，
      // 否则列表第一项会和大标题重叠（滚动时内容也会从标题栏底下穿过去）
      .padding({ top: $r('sys.float.single_line_titlebar_height') })


      /*
      .titleBar({ content: { title: { mainTitle: '曲线列表', mainTitleSize: 20 } } })
      .onReady((context: NavDestinationContext) => {
        this.navPathStack = context.pathStack;
      })
      * */


  }

  /** 切换选中项，用 animateTo 让浮起 / 描边 / 阴影过渡 */
  private select(index: number): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.selectedIndex = index;
    });
  }

  /**
   * 设置图标：进曲线编辑页，把这条曲线在列表里的序号带过去
   *
   * 这里**不注册** pushPathByName 的 onPop 回调：刷新的唯一入口是 CurveStore 的写盘通知
   * （见 storeRevision）。两条路都留着的话，保存一次会刷两遍。
   */
  private openSettings(index: number): void {
    if (index < 0 || index >= this.CURVES.length) {
      return;
    }
    const param: CurveEditParam = { index: index };
    this.navPathStack.pushPathByName('CurveEdit_Page', param, true);
  }

  /** 标签图标：进标签编辑页，同样带上序号（标签存在同一个 json 里） */
  private openTags(index: number): void {
    if (index < 0 || index >= this.CURVES.length) {
      return;
    }
    const param: CurveEditParam = { index: index };
    this.navPathStack.pushPathByName('TagEdit_Page', param, true);
  }

  /** 垃圾桶：删曲线之前先确认 */
  private askDeleteCurve(index: number): void {
    if (index < 0 || index >= this.CURVES.length) {
      return;
    }
    const curve: CurveData = this.CURVES[index];
    this.getUIContext().showAlertDialog({
      title: '删除这条曲线？',
      message: '「' + curve.title + '」删除后不能恢复',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.deleteCurve(index);
        }
      }
    });
  }

  /**
   * 删除曲线：删掉对应的 json，并把后面的文件改名上前一位
   * （文件名就是序号，必须靠 deleteAt 里的重排维持这个约定）
   */
  private deleteCurve(index: number): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx !== undefined && ctx !== null) {
      deleteAt(ctx, index);
    }
    if (this.selectedIndex === index + 1) {
      this.selectedIndex = 0; //选中的正好是被删的，退回"恒定BPM"
    } else if (this.selectedIndex > index + 1) {
      this.selectedIndex = this.selectedIndex - 1;
    }
    this.reloadCurves();
  }


  /** 加号：新建一条曲线（写成 (n+1).json），默认 30 分钟、120 BPM 的直线 */
  private makeContent(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const n: number = count(ctx);
    const file: CurveFile = emptyCurve('曲线' + (n + 1).toString(), 30);
    if (appendCurve(ctx, file) >= 0) {
      this.reloadCurves();
    }
  }



}

function getRandomInt(min: number, max: number): number {
  min = Math.ceil(min);
  max = Math.floor(max);
  return Math.floor(Math.random() * (max - min + 1)) + min;
}


@Builder
export function load() {

}
