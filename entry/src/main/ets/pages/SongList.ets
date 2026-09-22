import { HdsNavDestination } from '@kit.UIDesignKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongJSON, SongListJSON, selection, saveAt } from '../ets_libs/PlayListStore';
import { common } from '@kit.AbilityKit';
import call from '@ohos.telephony.call';
import { loadAll } from '../ets_libs/CurveStore';
import {analyzeMusicAsync, getAnalyseStatus} from 'libentry.so';

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
  type:selection;

  constructor(title: string, artist: string, bpm: number, duration: string = '') {
    this.title = title;
    this.artist = artist;
    this.bpm = bpm;
    this.duration = duration;
    this.type = selection.OFFLINE;    //要改,测试用
  }
}

/** 演示数据 */
let SONGS: SongData[] = [
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
const CAPSULE_BOTTOM_MARGIN: number = 50;
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
  /** 全局播放Json列表*/
  @State G_Playlist :Array<SongJSON> = [];
  PAGE_BG: string = '#F5F6F8';

  //全局表
  @State SONG_LIST_NAME:string = '';
  COLOR_PLAN = 0;
  G_INDEX = 0;


  build() {
    HdsNavDestination() {
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
    }.backgroundColor(this.PAGE_BG)
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
      const param: SongListJSON = ctx.pathInfo.param as SongListJSON;
      //歌单数据注入
      this.SONG_LIST_NAME = param.name;
      this.COLOR_PLAN = param.colorPlan;
      this.G_INDEX = param.index - 1;

      if(param !== undefined && param !== null){
        this.loadPlayList(param.songList)
      }
    })
    .titleBar({
      content: {
        title: {
          mainTitle: "歌曲列表",
          mainTitleSize: 20
        },
        menu: {
          maxCount: 1,
          value: [{
            content: {
              label: '从本地导入歌曲',
              componentId: "menu_1",
              isEnabled:true,
              action: () => {
                load_from_native(this.getUIContext().getHostContext() as common.UIAbilityContext).then((dir: string) => {
                  if (dir.length === 0) {
                    console.error('未选择音频文件，跳过分析');
                    return;
                  }
                  // 起一个进度定时器：native 侧按阶段/百分比回报，done/failed 自动收尾
                  const progressTimer = startAnalyseProgress();
                  // ★ 异步分析：不阻塞主线程；CSV 生成在 <filesDir>/Media/ 下
                  analyzeMusicAsync(dir, (bpm: number | null, err?: string) => {
                    clearInterval(progressTimer);
                    if (bpm !== null) {
                      console.info(`分析完成: BPM=${bpm}, 已生成 ${dir.replace(/\.[^.]+$/, '')}_beats.csv`);

                    } else {
                      console.error(`分析失败: ${err ?? '未知原因'}`);
                    }
                  });
                })
              }
            }, badge: {}
          },
            {
              content: {
                label: "从服务器导入歌曲",
                componentId: "menu_2",
                action: () => {


                }
              }, badge: {}
            },
            {
              content: {
                label: "切换第三方服务器",
                componentId: "menu_3",
                action: () => {

                }
              }, badge: {}
            }]

        }

      }
    })
    .onBackPressed(() => {
      this.showBackDialog();
      return true;
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

      TextInput({placeholder:"请输入播放列表名称", text:this.SONG_LIST_NAME}).height(40).width("80%").id("enterName").onChange((value:string) => {
        this.SONG_LIST_NAME = value;
      })

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

  private loadPlayList(songList: SongJSON[]){
    songList.forEach((item) => {
      SONGS.forEach((song_item) => {
        if(item.name === song_item.title){
          this.toggle(SONGS.indexOf(song_item));
        }
      })
    })
  }


  private save_playList_plan(plan: number[]): SongListJSON {
    plan.reverse();
    let callback: SongListJSON = {name:this.SONG_LIST_NAME,songList:[],colorPlan:this.COLOR_PLAN, index:0}
    plan.forEach((item) => {
      let SONG_item: SongJSON = {
        name: SONGS[item].title ? SONGS[item].title : '',
        author: SONGS[item].artist ? SONGS[item].artist : '',
        time: SONGS[item].duration ? SONGS[item].duration : '',
        BPM: SONGS[item].bpm ? SONGS[item].bpm : 0,
        type: SONGS[item].type,
      }
      callback.songList.push(SONG_item);
    })

    return callback;
  }

  private showBackDialog(): void {
    this.getUIContext().showAlertDialog({
      title: '确认保存',
      message: `歌单名称:${this.SONG_LIST_NAME},歌曲数:${this.selectedIndexes.length}`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {

          this.getUIContext().showAlertDialog({
            title: '确认退出?',
            message: `您还未保存歌单`,
            autoCancel: true,
            primaryButton: {
              value: '确定',
              action: () => {
                this.navPathStack.pop();
                loadAll(this.getUIContext().getHostContext() as common.UIAbilityContext);
              }
            },
            secondaryButton: {
              value: '取消',
              action: () => {

              }
            }
          })


        }
      },
      secondaryButton: {
        value: '确定',
        action: () => {
          let result: SongListJSON = this.save_playList_plan(this.selectedIndexes)
          saveAt(this.getUIContext().getHostContext() as common.UIAbilityContext,this.G_INDEX,result);
          this.navPathStack.pop();
        }
      }
    })
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

  private add_music(name: string, BPM: number, author: string){

  }




}

@Builder
export function load() {
  SongList()
}

/** getAnalyseStatus() 返回的 JSON 结构 */
interface AnalyseStatus {
  phase: string;
  pct: number;
  elapsedMs: number;
  running: boolean;
  error: string;
}

/** 阶段名 → 人话 */
function phaseText(phase: string): string {
  if (phase === 'decode') {
    return '解码音频';
  }
  if (phase === 'detect') {
    return '节拍分析';
  }
  if (phase === 'write') {
    return '写 CSV';
  }
  if (phase === 'done') {
    return '完成';
  }
  if (phase === 'failed') {
    return '失败';
  }
  return phase;
}

/**
 * 轮询 native 分析进度并打到日志，形成一条可见的时间线。
 *
 * 为什么需要它：分析要跑几秒到几十秒，而"没有任何输出"既可能是还在跑、
 * 也可能是已经卡死 —— 光看开始和结束两条日志分不清。这里每 500ms 打一次
 * 阶段 + 进度 + 已耗时，卡在哪一步一眼可见。
 *
 * 注意：解码阶段若总时长未知（某些 m4a 的 moov 里没写 duration），
 * native 侧会退化为在日志里报"已解码 xxs"，此时 pct 为 -1 ——
 * 这里就不再显示百分比，不再出现无意义的 -1%。
 *
 * ⚠️ 调用方必须在 analyzeMusicAsync 的回调里 clearInterval（见调用处），
 *    否则 done/failed 之后它会一直空转。本函数在检测到终态时也会自行停掉，
 *    属于双保险。
 */
function startAnalyseProgress(): number {
  let lastLine: string = '';
  const timer = setInterval(() => {
    let st: AnalyseStatus;
    try {
      st = JSON.parse(getAnalyseStatus()) as AnalyseStatus;
    } catch (e) {
      return;
    }
    // pct >= 0 才显示百分比；未知时只显示阶段
    const line: string = `[进度] ${phaseText(st.phase)}` +
      (st.pct >= 0 ? ` ${st.pct}%` : '') +
      `  已耗时 ${(st.elapsedMs / 1000).toFixed(1)}s`;
    if (line !== lastLine) {
      lastLine = line;
      console.info(line);
    }
    if (!st.running) {
      clearInterval(timer);
      if (st.phase === 'failed') {
        console.error(`[进度] 分析失败: ${st.error}`);
      } else if (st.phase === 'done') {
        console.info(`[进度] 分析完成，总耗时 ${(st.elapsedMs / 1000).toFixed(1)}s`);
      }
    }
  }, 500);
  return timer;
}

/**
 * 从系统文件选择器导入音频到沙箱，供 native 分析（analyzeMusicAsync）与播放使用。
 *
 * ★ 为什么不用 copyFileSync(fd, path)：
 *   官方签名虽然允许 src/dest 是「路径或文件描述符」，但实测（HarmonyOS 6.0.2）
 *   传 picker 拿到的 URI fd 时它**既不抛异常也不拷贝**，落盘是个 0 字节文件 ——
 *   这正是 FFmpeg 报 "Invalid data found when processing input" 的根因
 *   （日志证据：copied=0、dstSize=0、head 为空，且捕获分支一行都没打）。
 *   改用「手动分块 read/write」——这也是本工程 audio_play_test.ets 一直在用、
 *   并且已被证明有效的导入方式。
 *
 * 拷贝后做三项自检并打日志，避免再出现"静默成功但文件是坏的"。
 * 格式自检只对 m4a/mp4/mov 要求 ftyp 签名；wav/flac/mp3 不适用，不作判定。
 */
const COPY_CHUNK_SIZE: number = 8192;

/** 把错误对象压成一行可读文本（HarmonyOS 的 BusinessError 带 code / message） */
function err2str(e: Object): string {
  return JSON.stringify(e);
}

/** byte[] → "00 01 02" */
function toHex(bytes: Uint8Array, n: number): string {
  const H: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < n; i++) {
    if (i > 0) {
      out += ' ';
    }
    out += H.charAt(bytes[i] >> 4) + H.charAt(bytes[i] & 0x0F);
  }
  return out;
}

/** byte[] → "....ftyp...."（不可打印字符显示为 .） */
function toAscii(bytes: Uint8Array, n: number): string {
  let out: string = '';
  for (let i = 0; i < n; i++) {
    out += (bytes[i] >= 32 && bytes[i] < 127) ? String.fromCharCode(bytes[i]) : '.';
  }
  return out;
}

/**
 * ⚠️⚠️ 这里踩过一个坑，务必别再犯：
 *
 * 早期版本在本函数里为了"探测源文件大小/可读性"，对 probeFile.fd 调了
 * fs.readSync / fs.read 各读 16 字节。这些调用**是有效的读操作**，会把
 * 文件描述符的游标推进 32 字节；随后的拷贝循环复用同一个 fd，于是
 * **从第 32 字节开始拷贝**，目标文件丢掉开头 32 字节。
 *
 * 后果（两个都真实发生过）：
 *   · wav ：丢了 RIFF + fmt 块 ⇒ FFmpeg 算不出总时长（"总长未知"）；
 *   · m4a ：丢了 ftyp box  ⇒ avformat_open_input 直接报
 *            "Invalid data found when processing input"。
 *
 * 结论：**任何一次"只看一眼"的读都会移动游标。拷贝必须用一个全新的 fd。**
 */
async function load_from_native(context: common.Context) : Promise<string>{
  const mPicker = new picker.AudioViewPicker(context);
  const options = new picker.AudioSelectOptions();

  const uris: Array<string> = await mPicker.select(options);
  if (uris === undefined || uris.length === 0) {
    console.warn('[import] 用户没有选择任何音频文件');
    return '';
  }
  const srcUri: string = uris[0];
  console.info(`[import] picker 返回 uri=${srcUri}`);

  const mediaDir = `${context.filesDir}/Media`;
  if (!fs.accessSync(mediaDir)) {
    fs.mkdirSync(mediaDir);
  }

  // ---- 1. 探测源文件：拿到文件名 + 头部字节，看完【立刻关闭】----
  //         绝不让这个 fd 活到拷贝阶段（见函数头注释）
  let fileName: string = 'unknown.bin';
  let srcHead: string = '(未取到)';
  try {
    const probe = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    fileName = probe.name;
    const head = new ArrayBuffer(32);
    const n: number = fs.readSync(probe.fd, head);
    const bytes = new Uint8Array(head);
    srcHead = `${n}B hex=[${toHex(bytes, n)}] ascii=[${toAscii(bytes, n)}]`;
    fs.closeSync(probe);                 // ★ 立刻关闭
  } catch (e) {
    console.error(`[import] 打开/读取源文件失败: ${err2str(e)}`);
    return '';
  }
  const destPath: string = `${mediaDir}/${fileName}`;
  console.info(`[import] 源文件 name=${fileName}`);
  console.info(`[import] 源头部 ${srcHead}`);

  // ---- 2. 清理旧目标（同名目录是早期版本遗留的 bug）----
  if (fs.accessSync(destPath)) {
    if (fs.statSync(destPath).isDirectory()) {
      fs.rmdirSync(destPath);
    } else {
      fs.unlinkSync(destPath);
    }
  }

  // ---- 3. 拷贝：用全新的 fd，从偏移 0 开始 ----
  let srcFile: fs.File | undefined = undefined;
  let dstFile: fs.File | undefined = undefined;
  let copied: number = 0;
  try {
    srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);       // 新 fd，游标在 0
    dstFile = fs.openSync(destPath,
                          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const buf = new ArrayBuffer(COPY_CHUNK_SIZE);              // 复用一块缓冲，不逐块分配
    while (true) {
      const n: number = fs.readSync(srcFile.fd, buf);
      if (n <= 0) {
        break;
      }
      fs.writeSync(dstFile.fd, buf.slice(0, n));
      copied += n;
    }
    fs.fsyncSync(dstFile.fd);
    fs.closeSync(dstFile);
    dstFile = undefined;
  } catch (e) {
    console.error(`[import] 拷贝失败: ${err2str(e)}`);
    return '';
  } finally {
    if (srcFile !== undefined) {
      try {
        fs.closeSync(srcFile);
      } catch (e) {
      }
    }
    if (dstFile !== undefined) {
      try {
        fs.closeSync(dstFile);
      } catch (e) {
      }
    }
  }

  const dstSize: number = fs.statSync(destPath).size;
  console.info(`[import] 拷贝完成: copied=${copied} dstSize=${dstSize}`);

  // ---- 4. 逐字节校验（不再依赖任何"大小看起来对"的间接判断）----
  //   只比前 1MB：字节级偏移错误必然在开头就暴露，
  //   整文件两遍读在几百 MB 的音频上太慢。
  let verdict: string = '';
  let firstDiff: number = -1;
  let dstHead: string = '';
  let headEqual: boolean = false;
  let compared: number = 0;
  try {
    const a = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    const b = fs.openSync(destPath, fs.OpenMode.READ_ONLY);
    // 先各自读头部，用于"源头部 / 目标头部"对照（必须在遍历前读，否则游标已到末尾）
    const ha = new ArrayBuffer(32);
    const hb = new ArrayBuffer(32);
    const na0: number = fs.readSync(a.fd, ha);
    const nb0: number = fs.readSync(b.fd, hb);
    const ba = new Uint8Array(ha);
    const bb = new Uint8Array(hb);
    dstHead = `${nb0}B hex=[${toHex(bb, nb0)}] ascii=[${toAscii(bb, nb0)}]`;
    headEqual = (na0 === nb0);
    if (headEqual) {
      for (let i = 0; i < na0; i++) {
        if (ba[i] !== bb[i]) {
          headEqual = false;
          firstDiff = i;
          break;
        }
      }
    }

    const va = new ArrayBuffer(COPY_CHUNK_SIZE);
    const vb = new ArrayBuffer(COPY_CHUNK_SIZE);
    const ua = new Uint8Array(va);
    const ub = new Uint8Array(vb);
    const kVerifyBytes: number = 1024 * 1024;   // 1MB 足够暴露任何字节级偏移错误
    compared = 0;

    while (compared < kVerifyBytes) {
      const na: number = fs.readSync(a.fd, va);
      const nb: number = fs.readSync(b.fd, vb);
      if (na !== nb) {
        verdict = `长度不一致（src 读 ${na}，dst 读 ${nb}）`;
        break;
      }
      if (na <= 0) {
        break;
      }
      for (let i = 0; i < na; i++) {
        if (ua[i] !== ub[i]) {
          if (firstDiff < 0) {
            firstDiff = compared + i;
          }
          break;
        }
      }
      if (firstDiff >= 0) {
        break;
      }
      compared += na;
    }
    fs.closeSync(a);
    fs.closeSync(b);

    if (verdict.length === 0) {
      verdict = (firstDiff < 0) ? `前 ${compared}B 完全一致` : `首个不同字节在偏移 ${firstDiff}`;
    }
  } catch (e) {
    verdict = `校验本身出错: ${err2str(e)}`;
  }
  console.info(`[import] 目标头部 ${dstHead}`);
  console.info(`[import] 校验结果: ${verdict}（头部一致=${headEqual}）`);

  if (copied === 0 || dstSize === 0) {
    console.error('[import] ❌ 目标文件为 0 字节：拷贝没有写入任何数据');
    return '';
  }
  if (copied !== dstSize) {
    console.error(`[import] ❌ 写入字节数与目标大小不一致（copied=${copied} dst=${dstSize}）`);
    return '';
  }
  if (firstDiff >= 0) {
    console.error(`[import] ❌ 拷贝内容与源不一致（偏移 ${firstDiff}），文件已损坏，放弃分析`);
    return '';
  }

  console.info('[import] ✅ 拷贝校验通过');
  return destPath;
}

