import { HdsNavDestination } from '@kit.UIDesignKit';
import { appendSongList, loadAll, SongListJSON, SongListParam } from '../ets_libs/PlayListStore';
import { SongList } from './SongList';
import { common } from '@kit.AbilityKit';

/**
 * 歌单列表页
 *
 * 布局约定（与 CurveList 的卡片样式保持一致）：
 *   - 每个卡片是一个带阴影的圆角矩形，宽度接近屏幕宽度
 *   - 卡片内部一行排开：左侧是歌单封面（第一首歌的封面占位），
 *     中间是标题 + 副标题（显示有几首歌曲），右侧是设置 / 删除图标
 *   - 未选中：带阴影的圆角矩形
 *   - 选中：整体向左上浮起（偏移 + 加重阴影），四周有色描边，左侧描边更粗
 *
 * 当前是演示版：数据写死在 DEMO_PLAYLISTS 里，只做布局和选中效果。
 */

/** 一个歌单 */
class PlaylistData {
  title: string;
  /** 封面占位色（后续接真实封面图后替换） */
  coverColor: string;
  /** 歌曲数量 */
  songCount: number;
  /** 选中时的描边色 */
  accentColor: string;

  constructor(title: string, coverColor: string, songCount: number, accentColor: string) {
    this.title = title;
    this.coverColor = coverColor;
    this.songCount = songCount;
    this.accentColor = accentColor;
  }
}

/** 配色方案：封面占位色 + 选中描边色 */
const COLOR_PLAN: string[][] = [
  ['#FF6B6B', '#FF6B6B'],
  ['#4ECDC4', '#4ECDC4'],
  ['#A78BFA', '#A78BFA']
];

/** 卡片视觉常量（和 CurveList 保持一致） */
const CARD_RADIUS: number = 18;   // 圆角
const CARD_SPACE: number = 18;    // 卡片间距
const CARD_ACCENT: string = '#FF6B6B';
const LIFT: number = 6;           // 选中时向左上浮起的距离

/** 卡片右侧操作图标 */
const ICON_SIZE: number = 22;
const ICON_GAP_DANGER: number = 20;  // 设置 ↔ 删除：拉开距离，防止误触
const ICON_COLOR: string = '#8A8F99';
const ICON_DANGER: string = '#D98C8C';

/**
 * 描边宽度是"恒定"的，选中与否只切换描边的颜色。
 * 原因同 CurveList：未选中写 0、选中写 6，内容区宽度会在选中瞬间变化。
 */
const CARD_BORDER_LEFT: number = 6;    // 左侧描边（选中时可见）
const CARD_BORDER_OTHER: number = 1.5; // 其余三边描边

/** 内容到卡片外边缘的目标留白（＝ 描边宽度 + padding，所以 padding 要减去描边） */
const CARD_INSET_H: number = 16;       // 左右留白
const CARD_INSET_V: number = 14;       // 上下留白

/** 封面占位图尺寸 */
const COVER_SIZE: number = 56;

@Component
struct PlaylistCard {
  // 静态数据
  title: string = '';
  coverColor: string = CARD_ACCENT;
  songCount: number = 0;
  accentColor: string = CARD_ACCENT;
  // 选中状态要跟着父组件刷新，用 @Prop
  @Prop selected: boolean = false;
  // 回调
  onSelect: () => void = () => {
  };
  onSettings: () => void = () => {
  };
  onDelete: () => void = () => {
  };

  /**
   * 卡片右侧的操作图标：设置 / 删除 两个竖排
   * 删除和设置之间留更大的间距，防止误触
   */
  @Builder
  CardActions() {
    Column() {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(ICON_SIZE)
        .fontColor([ICON_COLOR])
        .onClick(() => {
          this.onSettings();
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

  build() {
    Column() {
      Row({ space: 12 }) {
        // 左侧：第一首歌的封面（占位色块 + 音符图标）
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.music_fill'))
            .fontSize(26)
            .fontColor([Color.White])
        }
        .width(COVER_SIZE)
        .height(COVER_SIZE)
        .borderRadius(10)
        .backgroundColor(this.coverColor)

        // 中间：标题 + 副标题（歌曲数量）
        Column({ space: 4 }) {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1B1B2F')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(`${this.songCount} 首歌曲`)
            .fontSize(12)
            .fontColor(ICON_COLOR)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.CardActions()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    // padding 要减掉描边宽度：内容到卡片外边缘的留白始终是 CARD_INSET_*
    .padding({
      left: CARD_INSET_H - CARD_BORDER_LEFT,
      right: CARD_INSET_H - CARD_BORDER_OTHER,
      top: CARD_INSET_V - CARD_BORDER_OTHER,
      bottom: CARD_INSET_V - CARD_BORDER_OTHER
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
export struct Playlist {
  @State navPathStack: NavPathStack = new NavPathStack();
  /** 当前选中的项：0..n 对应 PLAYLISTS 的下标 */
  @State selectedIndex: number = 0;

  PAGE_BG: string = '#F5F6F8';
  /** 歌单列表（演示数据，后续接真实歌单） */
  @State PLAYLISTS: PlaylistData[] = [
    new PlaylistData('跑步歌单', COLOR_PLAN[0][0], 12, COLOR_PLAN[0][1]),
    new PlaylistData('夜跑精选', COLOR_PLAN[1][0], 8, COLOR_PLAN[1][1]),
    new PlaylistData('节奏训练', COLOR_PLAN[2][0], 20, COLOR_PLAN[2][1])
  ];

  /** 切换选中项，用 animateTo 让浮起 / 描边 / 阴影过渡 */
  private select(index: number): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.selectedIndex = index;
    });
  }


  @Link @Watch ('MakePlayListItem') triggerFlag: boolean;

  MakePlayListItem(){
    if(this.triggerFlag){
      let index: number = Math.floor((Math.random()*3))
      this.makeNewSongList();
    }
  }

  build() {
    Scroll() {
      Column({ space: CARD_SPACE }) {
        ForEach(this.PLAYLISTS, (item: PlaylistData, index: number) => {
          PlaylistCard({
            title: item.title,
            coverColor: item.coverColor,
            songCount: item.songCount,
            accentColor: item.accentColor,
            selected: this.selectedIndex === index,
            onSelect: () => {
              this.select(index);
            },
            onSettings: () => {
              // 设置歌单（占位）
              this.EditSongListColumn(index);
            },
            onDelete: () => {
              // 删除歌单（占位）

            }
          })
        }, (item: PlaylistData) => item.title)
        Blank().width("100%").height(60)

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
    // 否则列表第一项会和大标题重叠
    .padding({ top: $r('sys.float.single_line_titlebar_height') })
  }

  private makeNewSongList() : void{
    let newColumn : SongListJSON = {
      name: '新建歌单',
      songList: [],
      colorPlan: this.getRandomInt(0,2)
    }

    appendSongList(this.getUIContext().getHostContext() as common.UIAbilityContext, newColumn)
    this.PLAYLISTS.push(
      new PlaylistData(newColumn.name, COLOR_PLAN[newColumn.colorPlan][0], 0, COLOR_PLAN[newColumn.colorPlan][1])
    )
  }

  private readSongList(): void {
    let SL_JSON: SongListJSON[] = loadAll(this.getUIContext().getHostContext() as common.UIAbilityContext)
    this.PLAYLISTS = []   //清空column
    for(let i = 0; i<= SL_JSON.length; i++){
      this.PLAYLISTS.push(
        new PlaylistData(SL_JSON[i].name, COLOR_PLAN[SL_JSON[i].colorPlan][0], SL_JSON[i].songList.length, COLOR_PLAN[SL_JSON[i].colorPlan][1])
      )
    }
  }


  private EditSongListColumn(index: number) : void {
    const param: SongListParam = {index: index};
    this.navPathStack.pushPathByName('SongList_Page', param, true);
  }


  private getRandomInt(min: number, max: number): number {
  min = Math.ceil(min);
  max = Math.floor(max);
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

}

@Builder
export function load() {

}

