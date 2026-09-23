import { HdsNavDestination } from '@kit.UIDesignKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongJSON, SongListJSON, selection, saveAt, totalSongList, SongJSON_ROW, bumpRevision,
         removeSongFromAllPlaylists } from '../ets_libs/PlayListStore';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import call from '@ohos.telephony.call';
import { loadAll } from '../ets_libs/CurveStore';
import {analyzeMusicAsync, getAnalyseStatus, analyzeSongSegments, SongMeta} from 'libentry.so';

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
  /**
   * 音频文件名（含扩展名），Media 目录内的实际文件名。
   * ★ 删除歌曲时要靠它定位「音频本体 + <同名>_beats.csv」。
   *   不能拿 title 反推：重名导入会存成 xxx-1.wav，而 title 是容器标签。
   *   旧数据可能没有，故为空串时删除会跳过文件清理（但 json 记录照删）。
   */
  filename: string;

  constructor(title: string, artist: string, bpm: number, duration: string = '',
              type_: selection = selection.OFFLINE, filename: string = '') {
    this.title = title;
    this.artist = artist;
    this.bpm = bpm;
    this.duration = duration;
    this.type = type_;    //要改,测试用
    this.filename = filename;
  }
}

/** 演示数据 */
let SONGS: SongData[] = [
  /*
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
  * */
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

  /** 导入/分析进行中：true 时挡住返回，并显示不可取消的进度弹窗 */
  @State importing: boolean = false;
  /** 进度弹窗文案（"正在分析 2/5：xxx" / "解码音频 40%"） */
  @State importText: string = '';
  /** openCustomDialog 返回的弹窗 id，用于关闭；undefined = 当前没有弹窗 */
  private importDialogId: number | undefined = undefined;
  /** openCustomDialog 的 Promise 本体：它异步给出 id，关闭前要等它就绪，避免竞态 */
  private importDialogOpening: Promise<number> | undefined = undefined;

  @State listVision:number = 0;


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
            }.swipeAction({
              // ★ end = 从右往左滑（左滑）露出的操作区
              //   点「删除」→ 二次确认 → 清 song_data.json / 音频+beats csv / Songs.json
              end: {
                builder: () => {
                  this.DeleteActionBuilder(index);
                }
              }
            })
          }, (song: SongData) => song.title+ '#' + this.listVision.toString())
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
      this.reload_SongList();

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
                this.runImportFlow();
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
        // 文件名必须一起带走，否则存进歌单后删歌就找不到文件了
        filename: SONGS[item].filename,
      }
      callback.songList.push(SONG_item);
    })

    return callback;
  }

  private showBackDialog(): void {
    // ★ 导入/分析进行中：绝对不允许离开本页。
    //   此时正确做法是"什么都不做"—— 弹窗本身不可取消，也不该再叠一个退出确认框。
    if (this.importing) {
      console.info('[import] 正在导入/分析，暂时不能离开本页');
      this.getUIContext().getPromptAction().showToast({
        message: '正在导入歌曲，请稍候…',
        duration: 1500
      });
      return;
    }
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

  // ────────────────────────────────────────────────────────────────
  //  导入进度弹窗（不可取消）
  //
  //  需求：从本地导入后，在落库全部完成之前不允许用户离开 SongList 页。
  //  三道锁：
  //    ① 弹窗 autoCancel = false  —— 点遮罩不关
  //    ② onBackPressed 里判 importing —— 系统返回键/侧滑退不出去
  //    ③ 弹窗里【没有】任何取消按钮 —— 没有可点的关闭入口
  //  分析跑完由代码调 closeImportDialog() 关闭，然后 importing 立刻转 false。
  //
  //  沿用工程既有写法（CurveList.ets 的 show_BPM_setting / close_BPM_setting）：
  //  promptAction.openCustomDialog 拿 dialogId，closeCustomDialog(id) 关闭。
  // ────────────────────────────────────────────────────────────────

  /**
   * 导入主流程。用 async/await 而不是 then 链，是为了让 finally 明确地
   * 覆盖"取消 / 异常 / 正常完成"三种出口 —— 否则一旦漏掉某条路径，
   * 弹窗不关 + importing 不复位，用户就被永久困在本页了。
   *
   * ★ 弹窗必须在 picker **返回之后**才打开，不能提前到 picker 之前：
   *   提前打开时，系统 picker 是被拉起的另一个窗口，会把刚创建的 dialog
   *   顶掉/抢占焦点，用户从头到尾都看不到它。
   *   （实测现象：返回键和侧滑都被挡住了 —— 说明 importing 确实生效了 ——
   *     但界面上一直没有弹窗。）
   *   所以顺序是：先上锁 importing（此时返回已被拦）→ 选文件 → 再弹窗 → 分析。
   */
  private async runImportFlow(): Promise<void> {
    // ★ 先上锁：从拉起 picker 之前就防住"半路退出"。
    //   这段时间界面没有弹窗（用户正在系统选择器里选文件），
    //   但 importing 已经为 true，返回键/侧滑同样被拦。
    this.importing = true;
    this.importText = '正在导入歌曲…';

    let done: number = 0;
    try {
      const paths: string[] = await importFromPicker(
        this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (paths.length === 0) {
        console.error('[import] 未导入任何文件，跳过分析');
        return;                       // finally 会负责解锁
      }

      // ── 选完文件、开始分析前才弹窗：此时不会有别的窗口来抢焦点 ──
      console.info(`[import] 导入 ${paths.length} 首，开始逐首分析…`);
      this.importText = `已导入 ${paths.length} 首，准备分析…`;
      this.openImportDialog();

      // 逐首串行分析：native 的进度状态是单例，并行会互相覆盖
      await analyzeSequentially(paths,
        (meta: SongMeta, path: string) => {
          // ★ 从沙箱路径取出音频文件名，随 songs.json 一起落库 —— 删除时靠它定位文件
          const audioName: string = path.substring(path.lastIndexOf('/') + 1);
          // ① songs.json：歌曲列表展示要的元数据（BPM 是 Essentia 的全局值）
          this.add_music(meta.name, meta.BPM, meta.author, meta.time, selection.OFFLINE, audioName);
          // ② song_data.json：CppDataAnalyzer 的详细多段 BPM（预览播放器用）
          //    必须在 analyzeMusicAsync 成功之后 —— native 要读刚写下的 _beats.csv
          this.add_song_data(path);
          done++;
        },
        (idx: number, total: number, name: string, phase: string) => {
          this.importText = (phase.length > 0)
            ? `正在分析 ${idx}/${total}：${name}\n${phase}`
            : `正在分析 ${idx}/${total}：${name}`;
        });

      // 全部落库完成后再重读一次，保证界面看到完整列表
      this.reload_SongList();
      this.importText = `已完成 ${done} 首，即将刷新列表…`;
    } catch (e) {
      console.error(`[import] 导入流程异常: ${err2str(e)}`);
    } finally {
      // 无论成功、失败、还是用户取消，都必须走到这里
      await this.closeImportDialog(done);
    }
  }

  /**
   * 进度弹窗内容。
   * ⚠️ 颜色一律用字面量，不要用 $r('sys.color.xxx')：
   *    工程里验证过能用的只有 font_primary；font_secondary / font_tertiary /
   *    background_primary 这几个我没能核实到，写错会静默失效（不报错、但不显示）。
   */
  @Builder
  ImportProgressBuilder() {
    Column() {
      Text('正在导入歌曲')
        .fontSize($r('sys.float.Title_M'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .padding({ top: 24, bottom: 14 })

      LoadingProgress()
        .width(48)
        .height(48)
        .color('#FF6B6B')

      Text(this.importText.length > 0 ? this.importText : '准备中…')
        .fontSize(14)
        .fontColor('#666666')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 10 })
        .width('86%')

      Text('分析期间请勿退出本页面')
        .fontSize(12)
        .fontColor('#999999')
        .padding({ bottom: 24 })
    }
    .width('80%')
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }

  private openImportDialog(): void {
    try {
      this.importDialogOpening = this.getUIContext().getPromptAction().openCustomDialog({
        builder: () => {
          this.ImportProgressBuilder();
        },
        autoCancel: false          // ★ 点遮罩不关
      });
      this.importDialogOpening.then((dialogId: number) => {
        this.importDialogId = dialogId;
        console.info(`[import] 进度弹窗已打开 id=${dialogId}`);
      }).catch((error: BusinessError) => {
        console.error(`[import] 打开进度弹窗失败: ${JSON.stringify(error)}`);
      });
    } catch (error) {
      console.error(`[import] openCustomDialog 异常: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 关闭进度弹窗并解锁。
   *
   * 这里 await 打开时存下的 promise：openCustomDialog 是异步返回 id 的，
   * 如果分析很快结束（或用户很快取消），关闭调用可能**早于** id 赋值，
   * 那样 importDialogId 还是 undefined，弹窗就永远关不掉、人被困住。
   *
   * @param done 成功落库的歌曲数；> 0 时再弹一个完成提示
   */
  private async closeImportDialog(done: number): Promise<void> {
    if (this.importDialogOpening !== undefined) {
      let dialogId: number | undefined = this.importDialogId;
      if (dialogId === undefined) {
        try {
          dialogId = await this.importDialogOpening;   // 等 id 就绪
        } catch (e) {
          console.error(`[import] 等待弹窗 id 失败: ${err2str(e)}`);
        }
      }
      if (dialogId !== undefined) {
        try {
          this.getUIContext().getPromptAction().closeCustomDialog(dialogId);
        } catch (error) {
          console.error(`[import] 关闭进度弹窗失败: ${JSON.stringify(error)}`);
        }
      }
      this.importDialogId = undefined;
      this.importDialogOpening = undefined;
    }
    // ★ 顺序要紧：先真正关掉弹窗，最后才解锁 importing。
    //   反过来的话（先解锁）会出现"弹窗还在、但返回已经不拦"的窗口期。
    this.importing = false;

    if (done > 0) {
      this.getUIContext().showAlertDialog({
        title: '导入完成',
        message: `已成功导入 ${done} 首歌曲`,
        autoCancel: true,
        confirm: {
          value: '知道了',
          action: () => {
          }
        }
      });
    }
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



  private add_music(name_: string, BPM_: number, author_: string, time_:string,type_: selection,
                    filename_: string = ''){
    let rawData : SongJSON_ROW = {
      name: name_,
      BPM: BPM_,
      author: author_,
      time: time_,
      type: type_,
      filename: filename_
    }

    const formalData : SongJSON = {
      name: rawData.name ? name_ : "Unknow Name",
      BPM: rawData.BPM ? BPM_ : NaN,
      author: rawData.author ? author_ : "Unkown Artist",
      time: rawData.time ? time_ : "00:00",
      type: type_,
      // ★ 存下真实文件名，删除时才找得到「音频 + 同名 _beats.csv」
      filename: filename_
    }

    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const path: string = ctx.filesDir + '/Media/Songs.json';
    try {
      let fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      let file = fs.readTextSync(path);
      let songList : totalSongList = {songList:[]};
      if(file) {
        songList = JSON.parse(file) as totalSongList;
      }
      songList.songList.push(formalData);
      const text: string = JSON.stringify(songList);
      // ⚠️ writeSync 不截断：新内容比旧内容短时，旧文件尾部会残留，
      //    读出的是 "……}]}旧尾巴"，JSON.parse 直接抛错。
      //    必须先 truncate 到新长度（或先清空），否则第二次写入就坏。
      fs.truncateSync(path, 0);
      fs.writeSync(fd.fd, text);
      fs.closeSync(fd);
      // 通知监听方（Playlist.ets 的 @StorageLink('songListStoreRevision')）重读
      bumpRevision();
    } catch (e){
      console.error(`Face Error in load music List: ${e}`)
    }



  }

  private reload_SongList(){
    try {
      SONGS = [];   //全局歌单清零
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path: string = ctx.filesDir + '/Media/Songs.json';
      let fd = fs.openSync(path, fs.OpenMode.READ_WRITE| fs.OpenMode.CREATE)
      let file = fs.readTextSync(path);
      let songList : totalSongList = {songList:[]};
      if(file) {
        songList = JSON.parse(file) as totalSongList;
      }
      songList.songList.forEach((item: SongJSON) => {
        // 旧数据可能没有 filename 字段（undefined），这里统一成空串
        const fn: string = (item.filename !== undefined && item.filename !== null)
          ? item.filename : '';
        SONGS.push(
          new SongData(item.name, item.author, item.BPM, item.time, item.type, fn),
        )
        this.listVision += 1;
      })
    } catch (e){
      console.error(`Face Error in load music List: ${e}`)
    }
  }

  /**
   * 删除一首歌的全部痕迹。四步都要做，缺一不可：
   *   ① song_data.json 里 filename 匹配的那条（预览播放器读的那份）
   *   ② Media 目录下的音频本体 + 同名 <stem>_beats.csv
   *   ③ Songs.json 里的展示记录（曲库）
   *   ④ 所有已保存歌单（SongList/*.json）里的副本
   *
   * ★ 匹配统一以 **filename 为稳定 id**（①③④ 都是 filename 优先、name 兜底），
   *   只有 early 数据缺 filename 时才退回按 name —— 三处用同一把尺子，
   *   避免"某个文件删掉了、另一个还留着"的割裂状态。
   *
   * 顺序说明：先删外部文件、最后删 Songs.json 主记录 —— 万一中间失败，
   * 列表里那首歌还在，用户能重试；反过来先删主记录就会出现"列表没了、
   * 文件还占着空间"的孤儿文件。
   *
   * @param filename 音频文件名（含扩展名）；为空时跳过 ②（旧数据没这个字段）
   * @param name     展示名，仅在 filename 缺失时作为兜底键
   * @return ①③ 是否都成功
   */
  private removeSong(filename: string, name: string): boolean {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    const mediaDir: string = ctx.filesDir + '/Media';

    // ── ① song_data.json ──
    const sdRemoved: boolean = removeSongData(ctx, filename, name);

    // ── ② 音频本体 + 同名 _beats.csv ──
    //   用 unlinkSync 而不是 removeSync：后者在 @ohos.file.fs 的文档里我没能核实到，
    //   而 unlinkSync 是本工程 PlayListStore/CurveStore 已在用的接口（见 deleteAt）。
    //   注意 unlinkSync 在目标不存在时会抛，所以必须先 accessSync 判存在。
    if (filename.length > 0) {
      const audioPath: string = mediaDir + '/' + filename;
      safeUnlink(audioPath, '音频');
      // beats csv 的命名规则与 native 一致：<音频去扩展名>_beats.csv
      const dot: number = filename.lastIndexOf('.');
      const stem: string = (dot > 0) ? filename.substring(0, dot) : filename;
      safeUnlink(mediaDir + '/' + stem + '_beats.csv', '拍点表');
    } else {
      // 旧数据没有 filename：拿 title 配上常见扩展名试着找找，找不到就算了（不报错）
      console.info('[delete] 无 filename（旧数据），尝试按标题匹配音频文件');
      const exts: string[] = ['.wav', '.m4a', '.mp3', '.flac', '.aac', '.ogg'];
      for (let i = 0; i < exts.length; i++) {
        const cand: string = mediaDir + '/' + name + exts[i];
        if (fs.accessSync(cand)) {
          safeUnlink(cand, '音频(按标题匹配)');
          safeUnlink(mediaDir + '/' + name + '_beats.csv', '拍点表(按标题匹配)');
          break;
        }
      }
    }

    // ── ③ Songs.json（曲库展示记录）──
    //   与 ①② 用同一把尺子：filename 优先，老数据才退回按 name
    const songsRemoved: boolean = removeFromSongsJson(ctx, filename, name);

    // ── ④ 所有已保存的歌单里也要剔除这首歌 ──
    //   歌单 json 各自存了 songList 副本，不清理就会残留一条指向已删文件的
    //   filename —— 播放器按 filename 去 song_data.json / Media 找必然落空。
    const plTouched: number = removeSongFromAllPlaylists(ctx, filename, name);
    if (plTouched > 0) {
      console.info(`[delete] 已从 ${plTouched} 个歌单中移除该曲目`);
    }

    if (songsRemoved || plTouched > 0) {
      bumpRevision();   // 通知监听方重读
    }
    return sdRemoved && songsRemoved;
  }

  /** 侧滑露出的删除按钮 */
  @Builder
  DeleteActionBuilder(index: number) {
    Button('删除')
      .type(ButtonType.Normal)
      .width(72)
      .height('100%')
      .fontSize(15)
      .fontColor(Color.White)
      .backgroundColor('#E84026')
      .borderRadius(0)
      .onClick(() => {
        this.confirmDelete(index);
      })
  }

  /** 删除前确认（破坏性操作，必须二次确认） */
  private confirmDelete(index: number): void {
    if (index < 0 || index >= SONGS.length) {
      console.error(`[delete] 下标越界: ${index}`);
      return;
    }
    const song: SongData = SONGS[index];
    this.getUIContext().showAlertDialog({
      title: '删除歌曲',
      message: `确定删除「${song.title}」吗？\n音频文件与拍点数据都会一并删除，且不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.doDelete(index);
        }
      }
    });
  }

  private doDelete(index: number): void {
    if (index < 0 || index >= SONGS.length) {
      console.error(`[delete] 下标越界: ${index}`);
      return;
    }
    const song: SongData = SONGS[index];
    const ok: boolean = this.removeSong(song.filename, song.title);

    // 播放列表里选中的是 SONGS 的下标；删掉一项后，比它大的下标都要前移一位，
    // 否则 selectedIndexes 会指向隔壁那首歌（甚至越界）。
    const next: number[] = [];
    for (let i = 0; i < this.selectedIndexes.length; i++) {
      const s: number = this.selectedIndexes[i];
      if (s < index) {
        next.push(s);
      } else if (s > index) {
        next.push(s - 1);
      }
      // s === index 的那项直接丢掉
    }
    this.selectedIndexes = next;

    this.reload_SongList();
    this.getUIContext().getPromptAction().showToast({
      message: ok ? `已删除「${song.title}」` : `「${song.title}」删除可能不完整，请检查日志`,
      duration: 2000
    });
  }


  /**
   * 详细 BPM 落库：调 native 的 CppDataAnalyzer 链路，把多段 BPM 并入 song_data.json。
   *
   * 调用时机：analyzeMusicAsync 成功之后（native 要读刚写下的 <同名>_beats.csv）。
   * 失败只记日志、不抛出 —— songs.json 已经写好，不能因为"详细数据"失败让整次导入失败。
   */
  private add_song_data(audioPath: string): void {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;

    let raw: string = '';
    try {
      raw = analyzeSongSegments(audioPath);
    } catch (e) {
      console.error(`[song_data] analyzeSongSegments 调用失败: ${err2str(e)}`);
      return;
    }

    let parsed: SongSegmentsResult;
    try {
      parsed = JSON.parse(raw) as SongSegmentsResult;
    } catch (e) {
      console.error(`[song_data] 返回的 JSON 解析失败: ${raw}`);
      return;
    }
    if (!parsed.ok || parsed.segments === undefined || parsed.segments.length === 0) {
      const why: string = parsed.error !== undefined ? parsed.error : '未知原因';
      console.error(`[song_data] 段落分析未产出: ${why}`);
      return;
    }

    const entry: SongDataEntry = {
      filename: parsed.filename,
      filedir: parsed.filedir,
      segments: parsed.segments
    };
    if (mergeSongData(ctx, entry)) {
      console.info(`[song_data] ✅ ${parsed.filename}: ${parsed.segments.length} 段`);
    }
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
 *
 * @param onPhase 可选：阶段文案变化时回调一次（"解码音频 40%"、"节拍分析"…），
 *                用于刷新进度弹窗。不传就只打日志。
 */
function startAnalyseProgress(onPhase?: (phase: string) => void): number {
  let lastLine: string = '';
  const timer = setInterval(() => {
    let st: AnalyseStatus;
    try {
      st = JSON.parse(getAnalyseStatus()) as AnalyseStatus;
    } catch (e) {
      return;
    }
    // pct >= 0 才显示百分比；未知时只显示阶段
    const head: string = phaseText(st.phase) + (st.pct >= 0 ? ` ${st.pct}%` : '');
    const line: string = `[进度] ${head}  已耗时 ${(st.elapsedMs / 1000).toFixed(1)}s`;
    if (line !== lastLine) {
      lastLine = line;
      console.info(line);
      if (onPhase !== undefined && st.running) {
        onPhase(head);       // 只在变化时回调，避免每 500ms 都 setState
      }
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

/** picker 里最多允许选择的文件数（AudioSelectOptions.maxSelectNumber，API 12+） */
const MAX_SELECT_NUMBER: number = 50;

/**
 * ⚠️⚠️ 这里踩过一个坑，务必别再犯：
 *
 * 早期版本在拷贝**之前**为了"探测源文件大小/可读性"，对同一个 fd 调了
 * fs.readSync / fs.read 各读 16 字节。这些调用**是有效的读操作**，会把
 * 文件描述符的游标推进 32 字节；随后复用同一个 fd 的拷贝循环于是
 * **从第 32 字节开始拷贝**，目标文件稳定丢掉开头 32 字节。
 *
 * 后果（两个都真实发生过）：
 *   · wav ：丢了 RIFF + fmt 块 ⇒ FFmpeg 算不出总时长（"总长未知"）；
 *   · m4a ：丢了 ftyp box  ⇒ avformat_open_input 直接报
 *            "Invalid data found when processing input"。
 *
 * 而且它**极其隐蔽**：丢的是固定 32 字节，copied 与 dstSize 依然完全相等，
 * "大小一致就算成功"这种校验永远查不出来。
 *
 * 结论：**任何一次"只看一眼"的读都会移动游标。探测用的 fd 必须即用即关，
 *       拷贝必须用一个全新的 fd。**
 */

/** 把一个源 uri 拷贝到沙箱 Media 目录。成功返回目标路径，失败返回 '' */
async function copyUriToSandbox(context: common.Context, srcUri: string): Promise<string> {
  const mediaDir = `${context.filesDir}/Media`;
  if (!fs.accessSync(mediaDir)) {
    fs.mkdirSync(mediaDir);
  }

  // ---- 1. 探测源文件：拿到文件名 + 头部字节，看完【立刻关闭】----
  //         绝不让这个 fd 活到拷贝阶段（见下方注释）
  let fileName: string = 'unknown.bin';
  let srcHead: string = '';
  try {
    const probe = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    fileName = probe.name;
    const head = new ArrayBuffer(32);
    const n: number = fs.readSync(probe.fd, head);
    const bytes = new Uint8Array(head);
    srcHead = `${n}B hex=[${toHex(bytes, n)}] ascii=[${toAscii(bytes, n)}]`;
    fs.closeSync(probe);                 // ★ 立刻关闭，别让游标状态流到拷贝环节
  } catch (e) {
    console.error(`[import] 打开/读取源文件失败 uri=${srcUri}: ${err2str(e)}`);
    return '';
  }
  console.info(`[import] 源 ${fileName}  头部 ${srcHead}`);

  // ---- 2. 解决重名：同名文件已存在时加 -1 / -2 后缀，不覆盖已有导入 ----
  let destPath: string = `${mediaDir}/${fileName}`;
  if (fs.accessSync(destPath)) {
    if (fs.statSync(destPath).isDirectory()) {
      // 早期版本在同名路径上遗留过目录
      fs.rmdirSync(destPath);
    } else {
      const dot: number = fileName.lastIndexOf('.');
      const stem: string = (dot > 0) ? fileName.substring(0, dot) : fileName;
      const ext: string = (dot > 0) ? fileName.substring(dot) : '';
      let k: number = 1;
      while (k < 1000) {
        const cand: string = `${mediaDir}/${stem}-${k}${ext}`;
        if (!fs.accessSync(cand)) {
          destPath = cand;
          break;
        }
        k++;
      }
      console.info(`[import] 同名文件已存在，改存为 ${destPath}`);
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
    console.error(`[import] 拷贝失败 ${fileName}: ${err2str(e)}`);
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
  console.info(`[import] 拷贝完成 ${fileName}: copied=${copied} dstSize=${dstSize}`);

  // ---- 4. 逐字节校验（不再依赖任何"大小看起来对"的间接判断）----
  //   只比前 1MB：字节级偏移错误必然在开头就暴露，整文件两遍读太慢。
  let firstDiff: number = -1;
  try {
    const a = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    const b = fs.openSync(destPath, fs.OpenMode.READ_ONLY);
    const va = new ArrayBuffer(COPY_CHUNK_SIZE);
    const vb = new ArrayBuffer(COPY_CHUNK_SIZE);
    const ua = new Uint8Array(va);
    const ub = new Uint8Array(vb);
    const kVerifyBytes: number = 1024 * 1024;
    let compared: number = 0;
    while (compared < kVerifyBytes) {
      const na: number = fs.readSync(a.fd, va);
      const nb: number = fs.readSync(b.fd, vb);
      if (na !== nb) {
        firstDiff = compared;
        break;
      }
      if (na <= 0) {
        break;
      }
      for (let i = 0; i < na; i++) {
        if (ua[i] !== ub[i]) {
          firstDiff = compared + i;
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
  } catch (e) {
    console.error(`[import] 校验出错 ${fileName}: ${err2str(e)}`);
    return '';
  }

  if (copied === 0 || dstSize === 0) {
    console.error(`[import] ❌ ${fileName} 目标文件为 0 字节，放弃`);
    return '';
  }
  if (copied !== dstSize) {
    console.error(`[import] ❌ ${fileName} 写入字节数与目标大小不一致（${copied} vs ${dstSize}）`);
    return '';
  }
  if (firstDiff >= 0) {
    console.error(`[import] ❌ ${fileName} 拷贝内容与源不一致（偏移 ${firstDiff}），放弃`);
    return '';
  }

  console.info(`[import] ✅ ${fileName} 拷贝校验通过`);
  return destPath;
}

/**
 * 导入入口：拉起 picker（支持多选），把选中的文件**全部**拷进沙箱。
 * 返回成功拷贝的沙箱路径数组；用户取消或全部失败时返回空数组。
 *
 * 注意：这里只负责"拷贝"，不做分析 —— 分析放回组件里串行触发，
 *       这样进度提示能按"第 i / N 首"显示。
 */
async function importFromPicker(context: common.Context): Promise<string[]> {
  const mPicker = new picker.AudioViewPicker(context);
  const options = new picker.AudioSelectOptions();
  // ★ 默认值是 1，不设就只能选一首（AudioSelectOptions.maxSelectNumber，API 12+）
  options.maxSelectNumber = MAX_SELECT_NUMBER;

  let uris: Array<string> = [];
  try {
    uris = await mPicker.select(options);
  } catch (e) {
    console.error(`[import] 拉起选择器失败: ${err2str(e)}`);
    return [];
  }
  if (uris === undefined || uris.length === 0) {
    console.warn('[import] 用户没有选择任何音频文件');
    return [];
  }
  console.info(`[import] picker 返回 ${uris.length} 个文件`);

  const paths: string[] = [];
  for (let i = 0; i < uris.length; i++) {
    const out: string = await copyUriToSandbox(context, uris[i]);
    if (out.length > 0) {
      paths.push(out);
    }
  }
  console.info(`[import] 导入结束: 成功 ${paths.length} / 共 ${uris.length}`);
  return paths;
}

/**
 * 逐首串行分析。
 *
 * 为什么必须串行：native 侧的分析进度是**一份全局状态**
 * （getAnalyseStatus 的 phase/pct），并发跑多首会互相覆盖；
 * 而且 Essentia 的 multifeature 本身很吃 CPU，并发只会更慢。
 *
 * @param onResult   每首分析完成（成功才回调 meta）时通知上层，用于落库
 * @param onProgress 进度回调（第 idx 首 / 共 total 首 / 文件名 / 阶段文案）。
 *                   阶段文案为空串表示"刚开始这一首"。
 */
async function analyzeSequentially(paths: string[],
                                   onResult: (meta: SongMeta, path: string) => void,
                                   onProgress: (idx: number, total: number,
                                                name: string, phase: string) => void): Promise<void> {
  const total: number = paths.length;
  for (let i = 0; i < total; i++) {
    const p: string = paths[i];
    const name: string = p.substring(p.lastIndexOf('/') + 1);
    if (total > 1) {
      console.info(`[import] —— 分析 ${i + 1}/${total}: ${name} ——`);
    }
    onProgress(i + 1, total, name, '');
    const progressTimer: number = startAnalyseProgress((phase: string) => {
      // 把 native 的阶段（解码 40% / 节拍分析 …）透传给弹窗
      onProgress(i + 1, total, name, phase);
    });
    await new Promise<void>((resolve: () => void) => {
      analyzeMusicAsync(p, (meta: SongMeta | null, err?: string) => {
        clearInterval(progressTimer);
        if (meta !== null) {
          console.info(`[import] ✅ ${i + 1}/${total} ${meta.name} · ${meta.author} · ${meta.time} ${meta.BPM} BPM`);
          onResult(meta, p);   // 把沙箱路径一起给上层，song_data.json 要用它找 _beats.csv
        } else {
          console.error(`[import] ❌ ${i + 1}/${total} ${name} 分析失败: ${err ?? '未知原因'}`);
        }
        resolve();   // 无论成败都继续下一首
      });
    });
  }
  if (total > 0) {
    console.info(`[import] 全部结束，共处理 ${total} 个文件`);
  }
}

// ════════════════════════════════════════════════════════════════════════
//  song_data.json —— CppDataAnalyzer 的详细 BPM 段落（预览播放器读的那份）
//
//  两套 json 暂时并存（临近截止先不合并）：
//    · Songs.json      —— 歌曲列表展示用（name/author/time/BPM/type），在 add_music 里写
//    · song_data.json  —— 详细 BPM 段落，Player/RunDemoEngine 跟步频用，在这里写
//  合并键用 filename：RunDemoEngine 的 SongEntry.key 就是它，Player 也按它找歌。
// ════════════════════════════════════════════════════════════════════════

/** song_data.json 里的一段速度（与 index.d.ts 的 SongSegmentMeta 对齐） */
interface SongDataSegment {
  start: number;   // 段落起始＝该段第一拍
  end: number;
  bpm: number;
}

/** song_data.json 数组里的一个元素：一首歌 */
interface SongDataEntry {
  filename: string;
  filedir: string;
  segments: SongDataSegment[];
}

/**
 * native analyzeSongSegments() 返回的 JSON。
 * 这里刻意用**本文件自己的类型**（而不是从 libentry.so import 一份），
 * 免得在两个命名不同的接口之间做结构赋值 —— ArkTS 对这类赋值比 TS 严。
 */
interface SongSegmentsResult {
  ok: boolean;
  filename: string;
  filedir: string;
  segments: SongDataSegment[];
  error?: string;
}

/** song_data.json 的绝对路径（与 RunDemoEngine.mediaDir 的约定一致） */
function songDataFilePath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/Media/song_data.json';
}

/**
 * 把一首歌的详细 BPM 段落并入 song_data.json。
 *
 * 为什么是"合并"而不是覆盖：曲库里的歌可能来自协作者的离线 Essentia 管线
 * （他们先把 song_data.json 放进 Media），我们导入时不能把已有条目冲掉。
 * 同一首（filename 相同）则替换它那一条，避免重复导入堆出多份。
 *
 * ⚠️ 落盘必须先截断：writeSync 不截断，新内容比旧内容短时旧文件尾部会残留，
 *    读出来就是 "……}]}旧尾巴"，JSON.parse 直接抛（Songs.json 踩过同样的坑）。
 */
function mergeSongData(ctx: common.UIAbilityContext, entry: SongDataEntry): boolean {
  const path: string = songDataFilePath(ctx);
  let list: SongDataEntry[] = [];
  if (fs.accessSync(path)) {
    try {
      const text: string = fs.readTextSync(path);
      if (text.length > 0) {
        // 约定格式：顶层是数组。静态类型写成数组，但**是不是数组只有运行期知道**，
        // 所以必须 Array.isArray 判一下（与 RunDemoEngine.loadSongDatabase 同样的写法）。
        const asList: SongDataEntry[] = JSON.parse(text) as SongDataEntry[];
        if (Array.isArray(asList)) {
          list = asList;
        } else {
          // 兼容旧的"单曲平铺"格式：{ filename, filedir, segments }
          const asObj: SongDataEntry = JSON.parse(text) as SongDataEntry;
          if (asObj !== undefined && asObj !== null) {
            list = [asObj];
          }
        }
      }
    } catch (e) {
      console.error(`[song_data] 解析失败，按空库重建: ${err2str(e)}`);
      list = [];
    }
  }

  // 同名（filename）替换；没有同名就追加到末尾
  const next: SongDataEntry[] = [];
  let hit: boolean = false;
  for (let i = 0; i < list.length; i++) {
    const cur: SongDataEntry = list[i];
    if (cur !== undefined && cur !== null && cur.filename === entry.filename) {
      next.push(entry);
      hit = true;
    } else {
      next.push(cur);
    }
  }
  if (!hit) {
    next.push(entry);
  }

  try {
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.truncateSync(path, 0);            // 见函数头注释：必须先截断
    fs.writeSync(f.fd, JSON.stringify(next));
    fs.closeSync(f);
    return true;
  } catch (e) {
    console.error(`[song_data] 写入失败: ${err2str(e)}`);
    return false;
  }
}

/**
 * 删除一个文件；不存在就静默跳过。
 *
 * ⚠️ 必须自己先 accessSync 判存在：unlinkSync 对不存在的路径会抛异常，
 *    而"拍点表本来就没生成过"是完全正常的情况（分析失败/素材太短），
 *    不该因此让整个删除流程报错。
 *
 * @param what 日志里的称呼（"音频" / "拍点表"）
 */
function safeUnlink(path: string, what: string): void {
  if (!fs.accessSync(path)) {
    console.info(`[delete] ${what}不存在，跳过: ${path}`);
    return;
  }
  try {
    fs.unlinkSync(path);
    console.info(`[delete] 已删除${what}: ${path}`);
  } catch (e) {
    console.error(`[delete] 删除${what}失败 ${path}: ${err2str(e)}`);
  }
}

/**
 * 从 song_data.json 里删掉一首歌。
 *
 * 优先按 filename 精确匹配（这是该文件的既有主键）；
 * filename 为空（旧数据）时退回**基名相等**匹配：把条目的 filename 去扩展名，
 * 和展示名比 —— 能覆盖"导入时用文件名当标题"的常见情形。
 *
 * @return true = 确实删掉了一条；false = 没找到或写回失败（都不该阻断后续删除）
 */
function removeSongData(ctx: common.UIAbilityContext, filename: string, name: string): boolean {
  const path: string = songDataFilePath(ctx);
  if (!fs.accessSync(path)) {
    return false;         // 还没有这份文件，视为"无数据可删"
  }

  let list: SongDataEntry[] = [];
  try {
    const text: string = fs.readTextSync(path);
    if (text.length > 0) {
      const asList: SongDataEntry[] = JSON.parse(text) as SongDataEntry[];
      if (Array.isArray(asList)) {
        list = asList;
      } else {
        const asObj: SongDataEntry = JSON.parse(text) as SongDataEntry;
        if (asObj !== undefined && asObj !== null) {
          list = [asObj];
        }
      }
    }
  } catch (e) {
    console.error(`[delete] song_data.json 解析失败，跳过: ${err2str(e)}`);
    return false;
  }

  const next: SongDataEntry[] = [];
  let removed: boolean = false;
  for (let i = 0; i < list.length; i++) {
    const cur: SongDataEntry = list[i];
    if (cur === undefined || cur === null) {
      continue;
    }
    let match: boolean = false;
    if (filename.length > 0 && cur.filename === filename) {
      match = true;
    } else if (filename.length === 0 && name.length > 0 && cur.filename !== undefined) {
      const dot: number = cur.filename.lastIndexOf('.');
      const stem: string = (dot > 0) ? cur.filename.substring(0, dot) : cur.filename;
      match = (stem === name);
    }
    if (match) {
      removed = true;
      continue;            // 丢掉这一条
    }
    next.push(cur);
  }

  if (!removed) {
    console.info(`[delete] song_data.json 中没有匹配项: filename=${filename} name=${name}`);
    return false;
  }

  try {
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.truncateSync(path, 0);              // writeSync 不截断，必须先清空
    fs.writeSync(f.fd, JSON.stringify(next));
    fs.closeSync(f);
    console.info(`[delete] song_data.json 已移除 1 条，剩余 ${next.length} 条`);
    return true;
  } catch (e) {
    console.error(`[delete] song_data.json 写回失败: ${err2str(e)}`);
    return false;
  }
}

/**
 * 从 Media/Songs.json（歌曲列表的展示记录）里删掉一首歌。
 *
 * 匹配规则与另外两处（song_data.json / 各歌单 json）**完全一致**：
 *   ① filename 非空 → 按 filename 精确匹配（稳定 id）
 *   ② filename 为空（早期数据没写这个字段）→ 退回按 name 匹配
 *
 * 为什么改成 filename 优先：filename 才是真正唯一的键。
 * 按 name 删会把**所有同名歌曲**一起删掉（同一首歌可能以
 * LostMemory.m4a / LostMemory-1.m4a 存在两份，name 却相同），
 * 而按 filename 只删点中的那一条。
 *
 * @param filename 音频文件名（含扩展名），可为空串
 * @param name     展示名，作为 filename 缺失时的兜底
 * @return true = 确实删掉了一条
 */
function removeFromSongsJson(ctx: common.UIAbilityContext, filename: string,
                             name: string): boolean {
  const path: string = ctx.filesDir + '/Media/Songs.json';
  if (!fs.accessSync(path)) {
    return false;
  }

  let list: SongJSON[] = [];
  try {
    const text: string = fs.readTextSync(path);
    if (text.length > 0) {
      const parsed: totalSongList = JSON.parse(text) as totalSongList;
      if (parsed !== undefined && parsed !== null && parsed.songList !== undefined) {
        list = parsed.songList;
      }
    }
  } catch (e) {
    console.error(`[delete] Songs.json 解析失败，跳过: ${err2str(e)}`);
    return false;
  }

  const next: SongJSON[] = [];
  let removed: boolean = false;
  for (let i = 0; i < list.length; i++) {
    const cur: SongJSON = list[i];
    if (cur === undefined || cur === null) {
      continue;
    }
    const curFn: string = (cur.filename !== undefined && cur.filename !== null)
      ? cur.filename : '';
    let match: boolean = false;
    if (filename.length > 0) {
      match = (curFn === filename);          // ① 精确：只删点中的那一条
    } else {
      match = (cur.name === name);           // ② 兜底：老数据没有 filename
    }
    if (match) {
      removed = true;
      continue;                              // 丢掉这一条
    }
    next.push(cur);
  }
  if (!removed) {
    console.info(`[delete] Songs.json 中没有匹配项: filename=${filename} name=${name}`);
    return false;
  }

  try {
    const body: totalSongList = { songList: next };
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.truncateSync(path, 0);              // 同上：必须先截断
    fs.writeSync(f.fd, JSON.stringify(body));
    fs.closeSync(f);
    console.info(`[delete] Songs.json 已移除 1 条，剩余 ${next.length} 条`);
    return true;
  } catch (e) {
    console.error(`[delete] Songs.json 写回失败: ${err2str(e)}`);
    return false;
  }
}


