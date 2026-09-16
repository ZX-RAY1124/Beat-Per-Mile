import { HdsNavDestination } from '@kit.UIDesignKit';

/**
 * 歌曲列表（音乐库）
 *
 * 设计方案（方案 A）：
 *   - 主体是音乐库这个"源列表"，行的样式不因为"已加入"而变化，
 *     只在行尾换一个图标（方框 → 实心对勾方框，带 ReplaceSymbolEffect 动效）
 *   - 底部常驻悬浮胶囊，汇总当前播放列表（现在是单个列表，多列表切换放到另一个页面）
 *   - 点胶囊上拉半屏面板，在那里查看 / 移除 / 长按拖动排序
 *
 * 详情行固定切成三栏：作者（可伸缩、超长省略）｜ 时长 ｜ BPM，
 * 这样作者再长也只会自己截断，不会把后面的时长和 BPM 顶出去。
 *
 * 时长数据暂时没有：所有时长位先显示占位符，等 SongData.duration 有值就自动生效
 * （胶囊和面板头部的"总时长"也是同一条路径算出来的）。
 */

/** 一首歌（演示数据，后续接真实音乐库） */
class SongData {
  title: string;
  artist: string;
  bpm: number;
  /** 时长，形如 '3:42'；暂时没有这个数据，留空时显示占位符 */
  duration: string;

  constructor(title: string, artist: string, bpm: number, duration: string = '') {
    this.title = title;
    this.artist = artist;
    this.bpm = bpm;
    this.duration = duration;
  }
}

/** 演示数据 */
const SONGS: SongData[] = [
  new SongData('Crave Wave', 'LandRoot', 150),
  new SongData('The Chariot ~REVIIVAL~', 'Attoclef', 190),
  new SongData('Luminescence', '米虾Fomiki & 初云CLoudie', 184),
  new SongData('Retribution', 'nm-y & Kry.exe', 190),
  new SongData('DESTRUCTION 3,2,1', 'Normal1zer vs. Broken Nerdz', 321),
  new SongData('Distorted Fate', 'Sakuzyo', 150),
  new SongData('Clock Paradox', 'WyvernP', 140),
  new SongData('Chronologika', 'Hundotte', 180),
  new SongData('Nick of Time', 'P4koo', 175),
  new SongData('Chronomia', 'Lime', 227),
  new SongData('Chronos Collapse - La Campanella', 'SunsetRay', 180),
  new SongData("Rrhar'il", 'Team Grimoire', 190),
];

/** 行的尺寸与配色 */
const ROW_PADDING_H: number = 16;        // 行左右内边距
const ROW_PADDING_V: number = 10;        // 行上下内边距
const COLUMN_GAP: number = 12;           // 详情行三栏之间的间距
const DURATION_WIDTH: number = 46;       // 时长栏宽度（固定，保证各行对齐）
const BPM_WIDTH: number = 62;            // BPM 栏宽度（固定，"321 BPM" 也放得下）
const DIVIDER_COLOR: string = '#F0F0F0'; // 分割线颜色（淡）
const ICON_IDLE: string = '#B0B5BF';     // 未加入时的图标颜色
const SELECT_ACCENT: string = '#FF6B6B'; // 已加入时的强调色
const DURATION_PLACEHOLDER: string = '--:--'; // 还没有时长数据时的占位
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';

/** 悬浮胶囊 */
const CAPSULE_BG: string = '#1B1B2F';
const CAPSULE_HEIGHT: number = 44;
const CAPSULE_BOTTOM_MARGIN: number = 100;
/** 给胶囊留出的列表底部空间，保证最后一首歌能滚到胶囊上方 */
const CAPSULE_RESERVE: number = CAPSULE_HEIGHT + CAPSULE_BOTTOM_MARGIN + 20;

/** 把 '3:42' 解析成秒；解析不出来返回 -1 */
function parseDuration(text: string): number {
  if (text.length === 0) {
    return -1;
  }
  const parts: string[] = text.split(':');
  if (parts.length !== 2) {
    return -1;
  }
  const minutes: number = Number.parseInt(parts[0], 10);
  const secs: number = Number.parseInt(parts[1], 10);
  if (Number.isNaN(minutes) || Number.isNaN(secs)) {
    return -1;
  }
  return minutes * 60 + secs;
}

/** 把秒数格式化成 '12:34' */
function formatDuration(totalSeconds: number): string {
  const minutes: number = Math.floor(totalSeconds / 60);
  const secs: number = totalSeconds % 60;
  return minutes.toString() + ':' + (secs < 10 ? '0' : '') + secs.toString();
}

@Component
struct SongRow {
  // 静态数据
  title: string = '';
  artist: string = '';
  bpm: number = 0;
  duration: string = '';
  // 已加入状态要跟着父组件刷新
  @Prop selected: boolean = false;
  // 点击整行切换
  onToggle: () => void = () => {
  };

  build() {
    Row({ space: COLUMN_GAP }) {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontColor(TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Row({ space: COLUMN_GAP }) {
          // 第一栏：作者（可伸缩，超长自己省略，不挤别人）
          Text(this.artist)
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          // 第二栏：时长（固定宽度、右对齐，各行竖着对齐）
          Text(this.duration.length > 0 ? this.duration : DURATION_PLACEHOLDER)
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .width(DURATION_WIDTH)
            .textAlign(TextAlign.End)

          // 第三栏：BPM（固定宽度、右对齐）
          Text(this.bpm + ' BPM')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .width(BPM_WIDTH)
            .textAlign(TextAlign.End)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 行尾复选框：方框 → 实心对勾方框，用 ReplaceSymbolEffect 做切换动画
      SymbolGlyph(this.selected
        ? $r('sys.symbol.checkmark_square_fill')
        : $r('sys.symbol.square'))
        .fontSize(24)
        .fontColor([this.selected ? SELECT_ACCENT : ICON_IDLE])
        .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
    }
    .width('100%')
    .padding({
      left: ROW_PADDING_H,
      right: ROW_PADDING_H,
      top: ROW_PADDING_V,
      bottom: ROW_PADDING_V
    })
    .onClick(() => {
      this.onToggle();
    })
  }
}

@Component
export struct SongList {
  @State navPathStack: NavPathStack = new NavPathStack();
  /** 当前播放列表：存的是 SONGS 里的下标，数组顺序＝播放顺序（最后加入的排最前） */
  @State selectedIndexes: number[] = [];
  /** 上拉面板是否展开 */
  @State isSheetShow: boolean = false;
  PAGE_BG: string = '#F5F6F8';


  build() {
      Stack({ alignContent: Alignment.Bottom }) {
        List() {
          ForEach(SONGS, (song: SongData, index: number) => {
            ListItem() {
              SongRow({
                title: song.title,
                artist: song.artist,
                bpm: song.bpm,
                duration: song.duration,
                selected: this.isSelected(index),
                onToggle: () => {
                  this.toggle(index);
                }
              })
            }
          }, (song: SongData) => song.title)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        // 淡分割线：与文字左右对齐
        .divider({
          strokeWidth: 1,
          color: DIVIDER_COLOR,
          startMargin: ROW_PADDING_H,
          endMargin: ROW_PADDING_H
        })
        // HdsNavDestination 的标题栏悬浮在内容之上，这里让出它的高度
        .padding({ top: $r('sys.float.single_line_titlebar_height') })
        // 底部给悬浮胶囊留位置
        .contentEndOffset(CAPSULE_RESERVE)

        if (this.selectedIndexes.length > 0) {
          this.PlaylistCapsule()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.PAGE_BG)

      .bindSheet(this.isSheetShow, this.PlaylistSheet, {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE], //半屏起，可以往上拉成全屏
        dragBar: true,
        showClose: false, //关掉系统自带的关闭按钮，用面板头部自己的"完成"
        onDisappear: () => { //下拉、点遮罩关掉时把状态同步回来
          this.isSheetShow = false;
        }
      })


  }

  /** 底部悬浮胶囊：汇总当前播放列表（首数 + 总时长），点它上拉面板 */
  @Builder
  PlaylistCapsule() {
    Row({ space: 8 }) {
      Text('已选 ' + this.selectedIndexes.length + ' 首 · ' + this.totalDurationText())
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
      SymbolGlyph($r('sys.symbol.chevron_up'))
        .fontSize(16)
        .fontColor([Color.White])
    }
    .height(CAPSULE_HEIGHT)
    .padding({ left: 20, right: 16 })
    .backgroundColor(CAPSULE_BG)
    .borderRadius(CAPSULE_HEIGHT / 2)
    .shadow({ radius: 18, color: '#33000000', offsetX: 0, offsetY: 6 })
    .margin({ bottom: CAPSULE_BOTTOM_MARGIN })
    .onClick(() => {
      this.isSheetShow = true;
    })
  }

  /** 上拉面板：当前播放列表，长按某一行可以拖动排序 */
  @Builder
  PlaylistSheet() {
    Column() {
      // 头部：首数 + 总时长
      Row({ space: 10 }) {
        Text('播放列表')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_PRIMARY)
        Text(this.selectedIndexes.length + ' 首 · ' + this.totalDurationText())
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
        Blank()
        Text('完成')
          .fontSize(16)
          .fontColor(SELECT_ACCENT)
          .onClick(() => {
            this.isSheetShow = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 12 })

      List() {
        // 用 Repeat 而不是 ForEach：Repeat 自带 onMove，长按拖动排序走的是系统拖拽
        Repeat<number>(this.selectedIndexes)
          .each((ri: RepeatItem<number>) => {
            ListItem() {
              Row({ space: COLUMN_GAP }) {
                // 播放顺序
                Text((ri.index + 1).toString())
                  .fontSize(14)
                  .fontColor(ICON_IDLE)
                  .width(22)
                  .textAlign(TextAlign.Start)

                Column({ space: 4 }) {
                  Text(SONGS[ri.item].title)
                    .fontSize(16)
                    .fontColor(TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  // 作者 · 时长 · BPM
                  Text(this.sheetSubtitle(SONGS[ri.item]))
                    .fontSize(13)
                    .fontColor(TEXT_SECONDARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 移出播放列表
                SymbolGlyph($r('sys.symbol.minus_circle'))
                  .fontSize(22)
                  .fontColor(['#C4C8D0'])
                  .onClick(() => {
                    this.toggle(ri.item);
                  })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: ROW_PADDING_V, bottom: ROW_PADDING_V })
            }
          })
          .key((songIndex: number) => 'playlist_' + songIndex.toString())
          .onMove((from: number, to: number) => {
            this.moveInPlaylist(from, to);
          })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 1,
        color: DIVIDER_COLOR,
        startMargin: 20,
        endMargin: 20
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 面板里一行的副标题：作者 · 时长 · BPM */
  private sheetSubtitle(song: SongData): string {
    const parts: string[] = [song.artist];
    parts.push(song.duration.length > 0 ? song.duration : DURATION_PLACEHOLDER);
    parts.push(song.bpm + ' BPM');
    return parts.join(' · ');
  }

  /** 播放列表总时长；一首时长都没有时返回占位符 */
  private totalDurationText(): string {
    let seconds: number = 0;
    let known: number = 0;
    for (let i = 0; i < this.selectedIndexes.length; i++) {
      const sec: number = parseDuration(SONGS[this.selectedIndexes[i]].duration);
      if (sec >= 0) {
        seconds += sec;
        known++;
      }
    }
    if (known === 0) {
      return DURATION_PLACEHOLDER;
    }
    return formatDuration(seconds);
  }

  private isSelected(index: number): boolean {
    return this.selectedIndexes.indexOf(index) >= 0;
  }

  /** 加入 / 移出某一首；新加入的放在最前面 */
  private toggle(index: number): void {
    const next: number[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.selectedIndexes.length; i++) {
      const cur: number = this.selectedIndexes[i];
      if (cur === index) {
        hit = true;
      } else {
        next.push(cur);
      }
    }
    if (!hit) {
      next.unshift(index); //新勾选的默认放在歌单顶部
    }
    this.selectedIndexes = next;
    if (next.length === 0) { //列表被清空时顺手收起面板
      this.isSheetShow = false;
    }
  }

  /** 拖拽排序：把 from 位置的歌移到 to 位置 */
  private moveInPlaylist(from: number, to: number): void {
    const arr: number[] = [];
    for (let i = 0; i < this.selectedIndexes.length; i++) {
      arr.push(this.selectedIndexes[i]);
    }
    if (from === to || from < 0 || from >= arr.length || to < 0 || to >= arr.length) {
      return;
    }
    const moved: number[] = arr.splice(from, 1);
    arr.splice(to, 0, moved[0]);
    this.selectedIndexes = arr;
  }
}

@Builder
export function load() {
  SongList()
}
