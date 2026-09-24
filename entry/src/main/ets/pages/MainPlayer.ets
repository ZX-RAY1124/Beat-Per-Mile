import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from '../ets_libs/Button';
import { EllipseShape, window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  SongJSON,
  SongListJSON,
  ACTIVE_PLAYLIST_KEY,
  loadAll as songListLoadAll
} from '../ets_libs/PlayListStore';
import {
  MODE_CONSTANT,
  MODE_CURVE,
  MODE_DYNAMIC,
  RunDemoEngine,
  RunStatus,
  SongEntry,
  getCurrentSongKey,
  loadSongDatabase,
  resolvePlaylistEntries,
  setCurrentSongKey,
  songFilePath,
  TempoPoint
} from '../ets_libs/RunDemoEngine';
import { ACTIVE_CURVE_KEY, CurveFile, loadAll as curveLoadAll } from '../ets_libs/CurveStore';
import {
  HARD_CUT_FADE_MS,
  HARD_CUT_LEAD_MS,
  NativeAudio,
  NativePlayStatus
} from '../ets_libs/NativeAudio';
import {
  stepPipelineSetChaseDelayWindow,
  stepPipelineStart,
  stepPipelineStatus,
  stepPipelineStop
} from 'libentry.so';
import { SOURCE_SIM, getChaseDelaySec, getStepScenario, getStepSource } from '../ets_libs/StepSource';
import { MainPlayerParam } from '../ets_libs/PlayerRouteParam';

/**
 * MainPlayer.ets —— 正式播放器
 *
 * 这一版把「预览播放器」(Player.ets) 的播放能力搬了进来：
 *   · RunDemoEngine：模式数学（动态 = 步频跟随 / 预设 = 恒速或曲线）
 *   · NativeAudio：真实出声（没有 song_data.json 时退回内置演示音源）
 *   · stepPipeline*：动态模式的 native 步频闭环
 *   · 曲库 / 歌单 / 预解码接歌：直接复用 RunDemoEngine + PlayListStore 的现成函数
 *
 * ★ 模式由入口决定，进页后不切换：红圆 = 动态，绿圆 = 预设（有曲线走曲线，否则恒速）。
 * ★ 进度环沿用原来的「每秒轮询 + Progress 动画」，但角度改用引擎真实歌曲位置求（见文件末尾）。
 */

/** 主循环周期（约 30fps），与预览页一致 */
const TICK_MS: number = 33;

/** 预解码下一首的提前秒数（内存换"不断音"） */
const PREPARE_AHEAD_SEC: number = 30.0;

/** 自动接歌防连环跳：新会话至少真的播这么久，才允许被判定"结束并切下一首"（毫秒） */
const MIN_SESSION_PLAY_MS: number = 2500;

/** 没有 song_data.json 时的内置演示音源（rawfile） */
const NATIVE_RAW: string = 'LostMemory.m4a';

/** 摇杆：最大拖动像素 / 两端对应的进度倍率（上滑快进 8、下滑后退 -6，静止 = (8-6)/2 = 1） */
const ROCKER_MAX_DIST: number = 60;
const ROCKER_RATE_FWD: number = 8;
const ROCKER_RATE_BACK: number = -6;

/** stepPipelineStatus() 返回的 JSON */
interface StepPipelineStatus {
  running: boolean;
  cadenceSpm: number;
  multiplier: number;
  targetBpm: number;
  steps: number;
  followState: number;
  lastStepSec: number;
  songSec: number;
  mode: number;
  phaseOffset: number;
  delta: number;
  hasPlayer: boolean;
}

@Component
struct MainPlayer {
  @State colorList: string[] = ["#FF6B6B", "#4ECDC4", "#A78BFA"]
  @State columnList: topColumnMaker[] = [new topColumnMaker($r('sys.symbol.play_circle_fill'),'次',0, '次数'),
    new topColumnMaker($r('sys.symbol.figure_running'),'km',0, '公里数'),
    new topColumnMaker($r('sys.symbol.identify_song'),'BPM',0, '歌曲倍速')]
  @State navPathStack :NavPathStack = new NavPathStack();

  @State Status: string[] = ["正在运动","暂停","加速中","减速中"]
  @State Button_1 : Center_Button = new Center_Button(1)
  @State outCircle: Center_Button = new Center_Button(2)
  @State WINDOWS_WID : number = 0;
  @Provide transition_type : NavigationSystemTransitionType =
    NavigationSystemTransitionType.EXPLODE;

  private displayInfo: display.Display = display.getDefaultDisplaySync();
  private screenWidth: number = this.displayInfo.width;
  private screenHeight: number = this.displayInfo.height;
  @State private offsetX: number = 0;
  @State private offsetY: number = 200; // 初始纵向位置

  CARD_BORDER_TOP: number = 6;    // 左侧描边（选中时可见）
  CARD_BORDER_OTHER: number = 1.5; // 其余三边描边
  PAGE_BG: string = '#F5F6F8';
  @State offset_bar: number = 0;
  @State gesture_start: number = 0;

  // ==================== 引擎 / 音频 / 主循环 ====================
  private engine: RunDemoEngine = new RunDemoEngine();
  private native: NativeAudio = new NativeAudio();
  private ctx: common.UIAbilityContext | null = null;
  private tickId: number = -1;
  private lastTickMs: number = 0;
  private pollCounter: number = 0;
  private statusAccum: number = 0;
  private lastStatusSpeed: number = 1;

  // ==================== 展示数据（@State 才刷新 UI） ====================
  @State BPM_now : number = 0;              //当前BPM（目标步频）
  @State Speed : number = 1;               //歌曲倍速
  @State sport_time: number[] = [0,0,0];   //运动时间（格式:00:00:00）
  @State songTimeLast: number[] = [0,0];   //歌曲剩余时间（格式：00:00）
  @State songTimePass: number[] = [0,0];   //歌曲已播放时间（格式：00:00）
  @State songName: string = '';            //歌曲名称
  @State Artist: string = '';              //作曲家名称
  @State statusText: string = '正在运动';   //标题状态字
  @State glowOpacity: number = 0;          //进度环边缘发光（拍相位驱动）
  @State playlistProgress: number = 0;     //总歌单播放进度 0~1
  @State isPause: boolean = false;
  @State Pauce_icon: Resource = $r('sys.symbol.pause');
  @State hasStop: boolean = false;     //是否暂停
  @State stop_token : string = ''    //特定向暂停轮询
  private G_token: boolean = true    //全局轮询令牌
  @State nativeState: string = 'idle';

  // ==================== 内部标量 ====================
  private posSecC: number = 0;
  private durSecC: number = 0;
  private speedC: number = 1;
  private songBpmC: number = 150;
  private firstBeatC: number = 0;
  private modeC: number = MODE_DYNAMIC;
  private playingC: boolean = false;
  private startLatencyMs: number = -1;
  private hasCurve: boolean = false;

  @State windowWidth: number = 0;     //窗口宽度 弦长
  @State windowHeight: number = 0;
  // 圆的视觉半径：元素 240 被放大 8 倍（outCircle.select），半径 = 120 × 8 = 960。
  // ★ 原实现写成 240*8（那是直径）→ 算出的半张角只有应有的一半，交界点到不了屏幕左右边缘。
  @State R: number = 240 * 4;         //圆半径
  @State rotate_angle: number = 90;      //用于制作旋转进度条（window 就绪后按真实窗口宽重算）

  // ==================== 曲库 / 歌单 ====================
  private songDb: SongEntry[] = [];
  @State songKey: string = '';
  @State songPath: string = '';
  private playlists: SongListJSON[] = [];
  private playlistIndex: number = -1;
  private playlistTotalSec: number = 0;
  private playlistDoneSec: number = 0;

  // ==================== 预解码接歌 ====================
  private pendingNext: NativeAudio | null = null;
  private pendingKey: string = '';
  private prepareFailedKey: string = '';
  private cutGuardUntil: number = 0;
  private autoNext: boolean = true;
  /**
   * 预解码硬切（不断音）开关。
   * true  = 提前 music_prepare 下一首，到点 music_start 硬切（无缝，但依赖 native 状态可信）。
   * 之前这条路径会连环跳（新会话被误判"已结束"）；现在 autoAdvance 加了两道护栏：
   *   ① sessionReadyOnce + MIN_SESSION_PLAY_MS：新会话必须真就绪、真播过才允许再切；
   *   ② 位置合理性校验：起播没几秒却报"快到头"的 posSec 一律不采信。
   * 如果还跳：把它改回 false 即可立刻退回 music_play 路径（代价是切换有 ~2s 解码静默）。
   */
  private usePreparedCut: boolean = true;
  /** 当前 native 会话是否已经就绪过 / 起算时刻（防自动切歌连环跳） */
  private sessionReadyOnce: boolean = false;
  private sessionStartMs: number = 0;
  /** 位置合理性校验的基线：本会话起播位置 / 最近一次 seek 目标（秒） */
  private posBaselineSec: number = 0;
  /** 诊断用：上一次打印过的 native 状态 */
  private lastLoggedState: string = '';

  // ==================== native 步频管线（仅动态模式） ====================
  @State stepSource: number = SOURCE_SIM;
  @State stepScenario: number = 0;
  @State pipelineOn: boolean = false;
  @State pipelineCadence: number = 0;
  @State pipelineMultiplier: number = 1;
  @State pipelineState: number = 0;
  @State pipelineSteps: number = 0;

  // ==================== 摇杆 ====================
  @State rocker_offset: number = 0;
  @State scrubbing: boolean = false;
  private scrubRate: number = 1;
  private scrubPos: number = 0;
  /** 擦洗发生在音频会话建立之前时，起播后要补的 seek（-1 = 无） */
  private pendingSeekSec: number = -1;

  @State G_COLOR: string = this.colorList[this.getRandomInt(0,2)];

  aboutToAppear(): void {
    const c = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctx = c;
    this.G_token = true;      // 重进页面时重新激活轮询令牌
    this.stop_token = '';

    try {
      window.getLastWindow(this.getUIContext().getHostContext())        //获取窗口大小
        .then((windowClass: window.Window) => {
          const properties = windowClass.getWindowProperties();
          const rect = properties.windowRect;
          this.windowWidth = this.getUIContext().px2vp(rect.width); //get window's width
          this.windowHeight = this.getUIContext().px2vp(rect.height); // get window's height
          if (this.WINDOWS_WID <= 0) {
            this.WINDOWS_WID = this.windowWidth;
          }
          // 进度环初始角：交界点恰好落在屏幕左边缘（原实现公式，见 ringHalfAngle）
          this.rotate_angle = 90 - this.ringHalfAngle();
          // 进度环每秒按引擎真实位置推进（原来那套假时钟已由引擎接管）
          this.startTimeProgressSongRight(1, 'songTimePass');
        })
    } catch (exception) {
      console.error('出现异常' + JSON.stringify(exception));
    }

    // 歌单：与「歌单列表」页共享 AppStorage（先选后用）
    const ap: number | undefined = AppStorage.get<number>(ACTIVE_PLAYLIST_KEY);
    if (ap !== undefined) {
      this.playlistIndex = ap;
    }

    // 曲线：预设模式优先按「曲线列表」里选中的那条走（0 = 恒定 BPM）
    try {
      const ci: number | undefined = AppStorage.get<number>(ACTIVE_CURVE_KEY);
      if (ci !== undefined && ci >= 1) {
        const curves: CurveFile[] = curveLoadAll(c);
        if (ci - 1 < curves.length) {
          const f: CurveFile = curves[ci - 1];
          if (f.points.length >= 2) {
            const pts: TempoPoint[] = [];
            for (let i = 0; i < f.points.length; i++) {
              pts.push({ time: f.points[i].time, bpm: f.points[i].bpm, type: f.points[i].type });
            }
            this.engine.setCurvePoints(pts);
            this.hasCurve = true;
            console.info('[MainPlayer] 预设曲线「' + f.name + '」: ' + pts.length + ' 个点');
          }
        }
      }
    } catch (e) {
      console.error('读取曲线失败，预设模式使用恒定 BPM：' + JSON.stringify(e));
    }

    this.loadSongList(c);
    this.syncStepSettings();
    this.pullStatus();
    this.startTick();
  }

  aboutToDisappear(): void {
    this.onQuit();            // 停掉旧版每秒轮询
    this.stopTick();
    this.stopPipeline();
    this.cancelPending();
    this.native.stop();
  }

  @Builder
  Column_UP( index:number){
    Column(){
      SymbolGlyph(this.columnList[index].icon)
        .fontSize(30)
        .fontColor([this.colorList[index]])
        .padding({ bottom: 10 });
      Row(){
        Text(this.columnList[index].statistic.toString()).fontWeight(FontWeight.Medium).fontSize(25)
        Text(this.columnList[index].per).fontColor('#ff646161').fontSize(10).alignSelf(ItemAlign.Baseline)
      }
      Text(this.columnList[index].name).fontColor('#ff646161').fontSize(10)

    }.height(120).width(100).borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .borderColor(this.colorList[index])
    .backgroundColor(Color.White)
    .borderWidth({
      left:this.CARD_BORDER_OTHER,
      right:this.CARD_BORDER_OTHER,
      top:this.CARD_BORDER_TOP,
      bottom:this.CARD_BORDER_OTHER
    })
    .shadow({ radius: 24, color: "#2E000000", offsetX: 6, offsetY: 10 })
    .margin(5);
  }

  @Builder FloatWidgetBuild(){
    Column(){
      Column({space:10}){
        SideButton({ icon: $r('sys.symbol.forward_end_fill'), onTap: () => { this.nextSong() } });
        SideButton({ icon: this.Pauce_icon, onTap: () => { this.pause() } });
        SideButton({ icon: $r('sys.symbol.backward_end_fill'), onTap: () => { this.prevSong() } });
        this.rocker_Build();
      }
        .width(60)
        .height(400)
        .borderRadius(15)
        .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)

    }.position({right:0, top:this.offset_bar})

    .gesture(PanGesture({direction:PanDirection.Vertical})
      .onActionUpdate((event: GestureEvent) => {
        this.getUIContext()?.animateTo({ duration: 40, curve: Curve.EaseOut }, () => {
          this.offset_bar = event.offsetY + this.gesture_start // >0 上滑  <0 下滑
        })
      })
      .onActionEnd(() => {
        this.gesture_start = this.offset_bar;
      }))


  }

  @Builder Song_Column(){
    Column(){
      Row({space:25}){
        Column() {
          SymbolGlyph($r('sys.symbol.opticaldisc'))
            .fontSize(64)
            .fontColor([Color.White])
        }
        .width(130)
        .height(130)
        .borderRadius(10)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .offset({x: 15})
        .linearGradient({
          angle: 145,
          colors: [['#FF6B6B', 0.0], ['#A78BFA', 1.0]]
        })

        Column({space:10}){
          Text('+' + this.songTimePass[0].toString().padStart(2, '0') + ':' + this.songTimePass[1].toString().padStart(2, '0')).fontWeight(FontWeight.Bold).fontSize(25)
          Text('-' + this.songTimeLast[0].toString().padStart(2,'0') + ':' + this.songTimeLast[1].toString().padStart(2,'0')).fontWeight(FontWeight.Bold).fontSize(25)
        }
      }.width("100%").height("70%")
      Column(){
        // 歌名 / 作者可能很长：用 Marquee 在组件边界内滚动，短文本自然静止
        Marquee({ start: true, step: 4, loop: -1, fromStart: true, src: this.songName })
          .width(210)
          .height(32)
          .fontSize(25)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1B1B2F')
        Marquee({ start: true, step: 4, loop: -1, fromStart: true, src: this.Artist })
          .width(210)
          .height(26)
          .fontSize(18)
          .fontColor(Color.Gray)

      }

    }.width(250)
    .height(250)
    .borderRadius(15)
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
    .position({x:25, y:240})
    .borderColor(this.G_COLOR)
    .borderWidth({
      left:this.CARD_BORDER_OTHER,
      right:this.CARD_BORDER_OTHER,
      top:this.CARD_BORDER_TOP,
      bottom:this.CARD_BORDER_OTHER
    })

  }
/**
 * 摇杆组件：拖动时按倍率"擦洗"进度（音乐静音/暂停），松手才 seek 到目标位置
 * */
  @Builder rocker_Build(){
    Column() {
      // 摇杆主题
      Column(){
        SymbolGlyph($r('sys.symbol.slider_vertical_3'))
          .fontColor(['#FF6B6B'])
          .fontSize(30)
      }.width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.White)
      .borderRadius(10)
      .shadow({ radius: 24, color: "#2E000000", offsetX: 6, offsetY: 10 })
      .offset({y:this.rocker_offset})
      .gesture(PanGesture({direction:PanDirection.Vertical})
        .onActionStart(() => {
          this.rocker_offset = 0;
          this.beginScrub();
        })
        .onActionUpdate((event: GestureEvent) => {
          let off: number = event.offsetY;
          if (off < -ROCKER_MAX_DIST) { off = -ROCKER_MAX_DIST; }
          if (off > ROCKER_MAX_DIST) { off = ROCKER_MAX_DIST; }
          this.getUIContext().animateTo({ duration: 60, curve: Curve.EaseOut} ,() => {
            this.rocker_offset = off;
          })
          if (this.scrubbing) {
            this.scrubRate = this.rockerRate(off);
          }
        })
        .onActionEnd(() => {
          this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut} ,() => {
            this.rocker_offset = 0;
          })
          this.endScrub();
        }))

    }.width(40)
    .height(160)
    .borderWidth(1)
    .borderColor(this.G_COLOR)
    .justifyContent(FlexAlign.Center)
    .shadow({ radius: 24, color: "#2E000000", offsetX: 6, offsetY: 10 })
    .borderRadius(10)
  }


  build(){
    HdsNavDestination(){
      Column(){
        Row({space:40}) {

          Column(){
            SymbolGlyph($r('sys.symbol.identify_song'))
              .fontSize(40)
              .fontColor([this.colorList[0]])
              .padding({ bottom: 10 });
            Text('BPM').fontSize(15)
            Text(this.BPM_now.toString()).fontSize(25).width(120).textAlign(TextAlign.Center).fontWeight(FontWeight.Bold)

          }.height(130)
          .width("20%")
          .justifyContent(FlexAlign.Center)



          Column() {
            SymbolGlyph($r('sys.symbol.figure_running'))
              .fontSize(40)
              .fontColor([this.colorList[0]])
              .padding({ bottom: 10 });
            Text('运动时间').fontSize(15)
            Text(this.sport_time[0].toString().padStart(2, '0') + ':' + this.sport_time[1].toString().padStart(2, '0') + ':' + this.sport_time[2].toString().padStart(2, '0')).fontSize(25).width(120).textAlign(TextAlign.Center)
              .fontWeight(FontWeight.Bold)

          }.height(130)
          .width("20%")
          .justifyContent(FlexAlign.Center)

          Column(){
            SymbolGlyph(($r('sys.symbol.list_interrupt')))
              .fontSize(40)
              .fontColor([this.colorList[0]])
              .padding({ bottom: 10 });
            Text('歌曲倍速').fontSize(15)
            Text(this.Speed.toString() + 'x').fontSize(25).width(120).textAlign(TextAlign.Center).fontWeight(FontWeight.Bold)

          }.height(140)
          .width("20%")
          .justifyContent(FlexAlign.Center)
        }


        Row(){
          Slider({
            value: this.playlistProgress,
            min: 0,
            max: 1,
            step: 0.01,
            style: SliderStyle.NONE
          }).height(20)
            .width("90%")
            .selectedColor(this.G_COLOR)
            .blockColor(Color.White)
            .hitTestBehavior(HitTestMode.None)      // 只展示"总歌单进度"，禁止用户滑动
            .onChange((value: number) => {

            })
        }.width("100%").height("40%").justifyContent(FlexAlign.Center)

      }.height(140).width("90%").borderRadius(20)
      .justifyContent(FlexAlign.Center)
      .borderColor(this.G_COLOR)
      .backgroundColor(Color.White)
      .borderWidth({
        left:this.CARD_BORDER_OTHER,
        right:this.CARD_BORDER_OTHER,
        top:this.CARD_BORDER_OTHER,
        bottom:this.CARD_BORDER_TOP,
      })
      .offset({ top: $r('sys.float.single_line_titlebar_height') })
      .shadow({ radius: 24, color: "#2E000000", offsetX: 6, offsetY: 10 })
      .margin(5);

      Row({space:40}){
        Column(){
         SymbolGlyph(this.Pauce_icon)
           .fontSize(60)
           .fontColor([Color.White])
        }.width(110).height(110).backgroundColor('#4ECDC4')
        .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.pause();
        })
      }.width("100%").justifyContent(FlexAlign.Center).offset({y:500}).zIndex(2)  //调整优先级


      this.Song_Column()




      Column() {

        Stack(){
          Column() {

          }.shadow({
            // 范围跟滑块走；两个都是**静态属性**，改完下一帧生效，不经过动画
            radius: 20,
            color: '#FF6B6B',
            offsetX: 0,
            offsetY: 0
          })
          .opacity(this.glowOpacity)        // 拍点光效：由 beatPhase 驱动，每拍亮→衰减
          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
          .height(240)
          .width(240)
          .scale({ x: this.outCircle.button_zoom_x + 0.05, y: this.outCircle.button_zoom_y + 0.05})
          .offset({ y: this.outCircle.offset_y })
          .onClick(() => {

          })
          .padding({ top: $r('sys.float.single_line_titlebar_height') })
          .borderColor(this.colorList[this.getRandomInt(0, this.colorList.length - 1)])
          .renderGroup(true)


          Column() {

          }
          .linearGradient({
            angle: 0,
            colors: [['#ffee3939', 0.0], ['#ffee3939', 0.5],['#A78BFA', 0.5],['#A78BFA', 1.0]]
          })
          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
          .height(240)
          .width(240)
          .rotate({angle:this.rotate_angle})
          .scale({ x: this.outCircle.button_zoom_x + 0.05, y: this.outCircle.button_zoom_y + 0.05})
          .offset({ y: this.outCircle.offset_y })
          .onClick(() => {

          })
          .renderGroup(true)
        }.position({ x: (this.WINDOWS_WID / 2) - 120, y: "15%" })


        Column() {
          Column() {         //切换器

          }
          .linearGradient({
            angle: 120 ,
            colors: [['#FF6B6B', 0.0],['#A78BFA', 1.0]]
          })          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
          .height(240)
          .width(240)
          .scale({ x: this.Button_1.button_zoom_x, y: this.Button_1.button_zoom_y })
          .offset({ y: this.Button_1.offset_y })
          .onClick(() => {

          })
          .renderGroup(true)



        }.position({ x: (this.WINDOWS_WID / 2) - 120, y: "15%" })


        this.FloatWidgetBuild();



    }.width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)





    }.width("100%")
    .height("100%")
    .systemTransition(this.transition_type)
    .backgroundColor(this.PAGE_BG)
    .onBackPressed(() => {
      this.getUIContext().animateTo({curve: Curve.EaseInOut, duration:500},() => {
        this.Button_1.unselect();
        this.navPathStack.pop({})
      })
      return true;
    })

    .onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
      const raw: Object | undefined = context.pathInfo.param as Object | undefined;
      let requested: number = MODE_DYNAMIC;
      if (raw !== undefined) {
        const p: MainPlayerParam = raw as MainPlayerParam;
        if (p.width > 0) {
          this.WINDOWS_WID = p.width;
        }
        requested = p.mode;
      }
      // 模式由入口决定：红圆 = 动态；绿圆 = 预设（有曲线走曲线，否则恒速）
      this.applyEntryMode(requested);
      this.outCircle.select();

      // 进入即播：两个入口进来都直接开始运动
      this.engine.setPlaying(true);
      this.playingC = true;
      this.isPause = false;
      this.Pauce_icon = $r('sys.symbol.pause');
      this.startPipeline();
      this.startNative();
      this.noteSessionStart();
      this.pullStatus();
    })

    .onActive(() => {
      this.getUIContext().animateTo({curve: Curve.EaseInOut, duration: 500}, () => {
          this.Button_1.select();
      })
    })

    .titleBar({content:{title:{mainTitle:this.statusText,mainTitleSize:20}}})
  }

  // ==================== 基础工具 ====================

  private getRandomInt(min: number, max: number): number {
    min = Math.ceil(min);
    max = Math.floor(max);
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  /** 用于将传递进来的关于 00:00 格式的字符串转换为 number[] 并输出 */
  private TimeTransformMinSec(strTime: string): number[]{
    const spliter = strTime.split(":");
    const Min: number = Number(spliter[0]);
    const Sec: number = Number(spliter[1]);
    return [Min,Sec]
  }

  /** 秒 → [小时,分,秒] */
  private secToHms(sec: number): number[] {
    let t: number = Math.max(0, Math.floor(sec));
    const h: number = Math.floor(t / 3600);
    t = t % 3600;
    const m: number = Math.floor(t / 60);
    const s: number = t % 60;
    return [h, m, s];
  }

  /** 秒 → [分,秒] */
  private secToMs(sec: number): number[] {
    const t: number = Math.max(0, Math.floor(sec));
    return [Math.floor(t / 60), t % 60];
  }

  /**
   * 进度环可见弧的半张角 θ（度）。
   * 圆被放大到半径 R，屏幕里只露顶部一段；屏幕半宽 = R·sin(θ)，
   * 所以 θ = asin(屏幕半宽 / R)。交界点在 90-θ 时正好落在屏幕左边缘、90+θ 落在右边缘。
   */
  private ringHalfAngle(): number {
    if (this.windowWidth <= 0 || this.R <= 0) {
      return 0;
    }
    let s: number = (0.5 * this.windowWidth) / this.R;
    if (s < 0) { s = 0; }
    if (s > 1) { s = 1; }
    return Math.asin(s) * 180 / Math.PI;
  }

  /** 歌曲进度 → 进度环角度：起点 90-θ（屏幕左边缘），终点 90+θ（右边缘），播完回到左边缘 */
  private ringAngleAt(pos: number, dur: number): number {
    const half: number = this.ringHalfAngle();
    let t: number = dur > 0 ? pos / dur : 0;
    if (t < 0) { t = 0; }
    if (t > 1) { t = 1; }
    return (90 - half) + t * (2 * half);
  }

  /** 总歌单进度：0~1 */
  private playlistProgressAt(pos: number): number {
    if (this.playlistTotalSec <= 0) {
      return 0;
    }
    let v: number = (this.playlistDoneSec + pos) / this.playlistTotalSec;
    if (v < 0) { v = 0; }
    if (v > 1) { v = 1; }
    return v;
  }

  // ==================== 模式 ====================

  /** 入口模式 → 引擎模式。绿圆传 MODE_CONSTANT 表示"预设" */
  private applyEntryMode(requested: number): void {
    const m: number = (requested === MODE_DYNAMIC)
      ? MODE_DYNAMIC
      : (this.hasCurve ? MODE_CURVE : MODE_CONSTANT);
    this.modeC = m;
    this.engine.setMode(m);
  }

  // ==================== 曲库 / 歌单 / 切歌 ====================

  /** 一首歌在歌曲原速时间轴上的总长（取所有段落 end 的最大值） */
  private songEnd(entry: SongEntry): number {
    let end: number = 0;
    const segs = entry.song.segments;
    for (let i = 0; i < segs.length; i++) {
      if (segs[i].end > end) {
        end = segs[i].end;
      }
    }
    return end;
  }

  /** 从当前歌单里找这首歌的作者（曲库本身不存作者） */
  private authorFor(key: string): string {
    if (this.playlistIndex < 0 || this.playlistIndex >= this.playlists.length) {
      return '';
    }
    const items: SongJSON[] = this.playlists[this.playlistIndex].songList;
    for (let i = 0; i < items.length; i++) {
      const it: SongJSON = items[i];
      const f: string = it.filename !== undefined ? it.filename : '';
      if (f === key) {
        return it.author;
      }
    }
    return '';
  }

  /** 读曲库/歌单，选中上次那首（不在库里就第一首），并算好总歌单时长 */
  private loadSongList(c: common.UIAbilityContext): void {
    const pls: SongListJSON[] = songListLoadAll(c);
    this.playlists = pls;
    if (this.playlistIndex >= pls.length) {
      this.playlistIndex = pls.length > 0 ? 0 : -1;
    }

    let db: SongEntry[] = [];
    if (this.playlistIndex >= 0 && this.playlistIndex < pls.length) {
      db = resolvePlaylistEntries(c, pls[this.playlistIndex].songList);
    } else {
      db = loadSongDatabase(c);
    }
    this.songDb = db;

    const want: string = getCurrentSongKey();
    let curIdx: number = 0;
    for (let i = 0; i < db.length; i++) {
      if (db[i].key === want) {
        curIdx = i;
        break;
      }
    }

    let total: number = 0;
    let done: number = 0;
    for (let i = 0; i < db.length; i++) {
      const e: number = this.songEnd(db[i]);
      total += e;
      if (i < curIdx) {
        done += e;
      }
    }
    this.playlistTotalSec = total;
    this.playlistDoneSec = done;

    if (db.length === 0) {
      this.songKey = '';
      this.songPath = '';
      this.engine.setSong(null);      // 退回演示默认值
      return;
    }

    this.songKey = db[curIdx].key;
    setCurrentSongKey(this.songKey);
    this.engine.setSong(db[curIdx].song);
    this.songPath = songFilePath(c, db[curIdx].song);
    this.songName = this.engine.getSongName();
    const au: string = this.authorFor(this.songKey);
    this.Artist = au.length > 0 ? au : this.engine.getArtist();
  }

  /** 曲库里的下一首（到头回绕）；只有一首 / 库空返回 null */
  private nextSongEntry(): SongEntry | null {
    if (this.songDb.length < 2) {
      return null;
    }
    let idx: number = 0;
    for (let i = 0; i < this.songDb.length; i++) {
      if (this.songDb[i].key === this.songKey) {
        idx = i;
        break;
      }
    }
    return this.songDb[(idx + 1) % this.songDb.length];
  }

  /** 曲库里的上一首（到头回绕） */
  private prevSongEntry(): SongEntry | null {
    if (this.songDb.length < 2) {
      return null;
    }
    let idx: number = 0;
    for (let i = 0; i < this.songDb.length; i++) {
      if (this.songDb[i].key === this.songKey) {
        idx = i;
        break;
      }
    }
    return this.songDb[(idx - 1 + this.songDb.length) % this.songDb.length];
  }

  /** 切到指定 key：停播放/管线 → 换歌 → 需要的话重新起播 */
  private switchToKey(key: string, keepPlaying: boolean): void {
    const c = this.ctx;
    if (c === null) {
      return;
    }
    if (key === this.songKey) {
      return;
    }
    this.stopPipeline();
    this.cancelPending();
    this.native.stop();
    this.noteSessionStart();
    this.engine.setPlaying(false);
    setCurrentSongKey(key);
    this.loadSongList(c);
    this.engine.seek(0);
    this.pullStatus();
    if (keepPlaying) {
      this.engine.setPlaying(true);
      this.playingC = true;
      this.startNative();
      this.startPipeline();
    }
  }

  /** 下一首 */
  private nextSong(): void {
    const nx: SongEntry | null = this.nextSongEntry();
    if (nx === null) {
      return;
    }
    this.switchToKey(nx.key, this.playingC);
  }

  /** 上一首 */
  private prevSong(): void {
    const pv: SongEntry | null = this.prevSongEntry();
    if (pv === null) {
      return;
    }
    this.switchToKey(pv.key, this.playingC);
  }

  // ==================== 播放控制 ====================

  /** 暂停 / 继续（侧栏与中央按钮共用） */
  private pause(): void {
    const next: boolean = !this.engine.isPlaying();
    this.engine.setPlaying(next);
    this.playingC = next;
    this.isPause = !next;
    this.Pauce_icon = next ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill');
    this.syncStepSettings();
    if (next) {
      this.startPipeline();
      this.startNative();
    } else {
      this.stopPipeline();
      this.native.pause();
      this.statusText = '暂停';
    }
    this.pullStatus();
  }

  private startNative(): void {
    // 一按播放先冻住页面位置：原生解码/建缓冲期间不出声
    this.engine.setAudioReady(false);

    if (this.songPath.length > 0 && this.native.preparePath(this.songPath)) {
      this.native.play();
      this.native.setSpeed(this.speedC);
      this.applyPendingSeek();
      return;
    }

    // 没有 song_data.json 指向的音频 → 退回内置演示音源
    const c = this.ctx;
    if (c === null) {
      return;
    }
    this.native.prepare(c, NATIVE_RAW).then((ok: boolean) => {
      if (!ok) {
        return;
      }
      this.native.play();
      this.native.setSpeed(this.speedC);
      this.applyPendingSeek();
    }).catch((err: Error) => {
      console.error('内置演示音源准备失败：' + err.message);
    });
  }

  /** 擦洗发生在音频会话建立之前时，起播后补一次 seek */
  private applyPendingSeek(): void {
    if (this.pendingSeekSec >= 0) {
      this.native.seek(this.pendingSeekSec);
      this.pendingSeekSec = -1;
    }
  }

  /** 轮询原生播放状态：回填真实位置 / 冻结加载期 / 触发接歌 */
  private pollNative(): void {
    const st: NativePlayStatus | null = this.native.status();
    if (st === null) {
      return;
    }
    this.nativeState = st.state;
    this.startLatencyMs = st.startLatencyMs;
    if (st.state === 'ready') {
      this.sessionReadyOnce = true;
    }
    if (st.state !== this.lastLoggedState) {
      this.lastLoggedState = st.state;
      console.info('[MainPlayer] native ' + st.state + ' pos=' + st.posSec.toFixed(2)
        + 's dur=' + st.durSec.toFixed(2) + 's song=' + this.songKey);
    }
    if (this.scrubbing) {
      return;                     // 擦洗期间不要用旧状态覆盖
    }
    // 会话在 native 侧已经没了 ⇒ 作废 id，之后按播放是重新解码
    if (st.state === 'gone' || st.state === 'idle') {
      this.native.markEnded();
    }
    // 只有真就绪才让页面位置前进（加载期间冻结）
    this.engine.setAudioReady(st.state === 'ready');
    if (st.state === 'ready') {
      this.engine.syncPosition(st.posSec);
    }
    this.autoAdvance(st);
  }

  // ==================== 预解码 + 接歌硬切 ====================

  /** 只把下一首预解码（几秒级），当前这首照常播 */
  private prepareNextSong(): void {
    const c = this.ctx;
    if (c === null) {
      return;
    }
    if (this.pendingNext !== null) {
      return;
    }
    const nx: SongEntry | null = this.nextSongEntry();
    if (nx === null) {
      return;
    }
    if (nx.key === this.prepareFailedKey) {
      return;                     // 这首歌刚失败过，别每帧重试
    }
    const t: NativeAudio = new NativeAudio();
    if (!t.prepareOnly(songFilePath(c, nx.song))) {
      this.prepareFailedKey = nx.key;
      return;
    }
    this.prepareFailedKey = '';
    this.pendingNext = t;
    this.pendingKey = nx.key;
  }

  /** 预解码的会话是不是真的可以接歌了（decode 还在后台跑时 start 就是断音） */
  private pendingReady(): boolean {
    if (this.pendingNext === null) {
      return false;
    }
    const ps: NativePlayStatus | null = this.pendingNext.status();
    return ps !== null && (ps.state === 'prepared' || ps.state === 'ready');
  }

  private cancelPending(): void {
    if (this.pendingNext !== null) {
      this.pendingNext.stop();
      this.pendingNext = null;
      this.pendingKey = '';
    }
  }

  /** 硬切提前量（秒）：优先用 native 实测的起播延迟 */
  private cutLeadSec(): number {
    if (this.startLatencyMs > 0) {
      return this.startLatencyMs / 1000.0;
    }
    return HARD_CUT_LEAD_MS / 1000.0;
  }

  /** 标记"当前 native 会话从这一刻开始"（首次起播 / 切歌时调用） */
  private noteSessionStart(): void {
    this.sessionReadyOnce = false;
    this.sessionStartMs = Date.now();
    this.posBaselineSec = 0;
  }

  /** 到点自动接下一首（判据全部来自 native 真实量） */
  private autoAdvance(st: NativePlayStatus): void {
    if (!this.autoNext || !this.playingC) {
      return;
    }
    if (Date.now() < this.cutGuardUntil) {
      return;                     // 刚切完，等新会话的状态上来
    }
    // ★ 防连环跳：新会话必须"就绪过 + 真的播够 MIN_SESSION_PLAY_MS"才允许再切；
    //   一直没就绪的（解码失败等）给 8 秒兜底，避免卡死在一首上。
    const playedMs: number = Date.now() - this.sessionStartMs;
    const settled: boolean = (this.sessionReadyOnce && playedMs > MIN_SESSION_PLAY_MS)
      || playedMs > 8000;

    if (st.state === 'ready' && st.durSec > 0) {
      // ★ 位置合理性：会话才起播 playedMs，posSec 不可能已经走到 durSec 附近。
      //   超了就说明 native 这次报的位置不可信（切歌瞬间的经典误报），不采信。
      const maxPlausiblePos: number = this.posBaselineSec + (playedMs / 1000.0) * 2.5 + 5.0;
      if (st.posSec > maxPlausiblePos) {
        console.warn('[MainPlayer] 位置不可信，忽略：pos=' + st.posSec.toFixed(2)
          + 's / dur=' + st.durSec.toFixed(2) + 's，实际只播了 '
          + (playedMs / 1000.0).toFixed(1) + 's song=' + this.songKey);
        return;
      }
      const remainSong: number = st.durSec - st.posSec;
      if (this.usePreparedCut && remainSong <= PREPARE_AHEAD_SEC) {
        this.prepareNextSong();
      }
      const sp: number = this.speedC > 0.01 ? this.speedC : 1.0;
      const remainReal: number = remainSong / sp;
      const canCut: boolean = this.usePreparedCut ? this.pendingReady() : true;
      if (settled && remainReal <= this.cutLeadSec() && canCut) {
        this.doHardCut(true);
      }
      return;
    }
    if (st.state === 'gone' || st.state === 'idle') {
      // 预解码没赶上（或会话真结束）也得往下走；先过防连环跳的最小播放时间
      if (settled) {
        this.doHardCut(true);
      } else {
        console.warn('[MainPlayer] 忽略过早的 ' + st.state + '（会话可能刚起播）song=' + this.songKey);
      }
    }
  }

  /** 硬切到已预解码的下一首；没预解码好就现场加载 */
  private doHardCut(auto: boolean): void {
    const c = this.ctx;
    if (c === null) {
      return;
    }
    if (this.pendingNext !== null && !this.pendingReady()) {
      this.cancelPending();
    }

    // 兜底：现场加载
    if (this.pendingNext === null) {
      const nx: SongEntry | null = this.nextSongEntry();
      if (nx === null) {
        return;
      }
      this.prepareFailedKey = '';
      this.switchToKey(nx.key, false);
      this.engine.setPlaying(true);
      this.playingC = true;
      this.startNative();
      this.startPipeline();
      this.cutGuardUntil = Date.now() + 3000;
      return;
    }

    const t: NativeAudio = this.pendingNext;
    const old: NativeAudio = this.native;
    const nk: string = this.pendingKey;
    this.pendingNext = null;
    this.pendingKey = '';

    console.info('[MainPlayer] doHardCut -> ' + nk + '（预解码硬切）');
    t.startPrepared();                  // B 瞬时起播
    this.native = t;                    // 页面从现在起操作 B
    this.noteSessionStart();

    if (auto) {
      const latMs: number = this.cutLeadSec() * 1000.0;
      const fadeAt: number = latMs - HARD_CUT_FADE_MS;
      setTimeout(() => {
        old.fadeOut(HARD_CUT_FADE_MS);
      }, fadeAt > 0 ? fadeAt : 0);
      setTimeout(() => {
        old.stop();
      }, latMs + 120);
    } else {
      setTimeout(() => {
        old.fadeOut(HARD_CUT_FADE_MS);
        setTimeout(() => {
          old.stop();
        }, HARD_CUT_FADE_MS + 40);
      }, HARD_CUT_LEAD_MS);
    }

    setCurrentSongKey(nk);
    this.loadSongList(c);
    this.engine.setPlaying(true);
    this.playingC = true;
    this.cutGuardUntil = Date.now() + 1000;
  }

  // ==================== 摇杆：静音擦洗 + 松手 seek ====================

  /** 摇杆偏移 → 进度倍率（上滑快进、下滑后退，静止 = 1） */
  private rockerRate(off: number): number {
    let d: number = off;
    if (d < -ROCKER_MAX_DIST) { d = -ROCKER_MAX_DIST; }
    if (d > ROCKER_MAX_DIST) { d = ROCKER_MAX_DIST; }
    const base: number = (ROCKER_RATE_FWD + ROCKER_RATE_BACK) / 2.0;
    return base + (ROCKER_RATE_FWD - base) * (-d / ROCKER_MAX_DIST);
  }

  private beginScrub(): void {
    this.scrubbing = true;
    this.scrubRate = 1;
    this.scrubPos = this.posSecC;
    this.engine.setAudioReady(false);      // 冻结引擎自己的位置推进
    if (this.native.isLive()) {
      // 只静音、不暂停：拖动期间原生继续静默跑，松手后再 seek
      this.native.mute(30);
    }
  }

  /** 擦洗期间由主循环每帧调用 */
  private scrubStep(dt: number): void {
    let p: number = this.scrubPos + this.scrubRate * dt;
    if (p > this.durSecC) { p = this.durSecC; }
    if (p < 0) { p = 0; }
    this.scrubPos = p;
    this.engine.seek(p);
    this.posSecC = p;
    this.songTimePass = this.secToMs(p);
    this.songTimeLast = this.secToMs(Math.max(0, this.durSecC - p));
    this.rotate_angle = this.ringAngleAt(p, this.durSecC);
    this.playlistProgress = this.playlistProgressAt(p);
  }

  private endScrub(): void {
    if (!this.scrubbing) {
      return;
    }
    this.scrubbing = false;
    const target: number = this.scrubPos;
    if (target > this.posBaselineSec) {
      this.posBaselineSec = target;       // 跳过去的位置是合法的"大值"，别被合理性校验误杀
    }
    this.engine.seek(target);
    if (this.native.isLive()) {
      // 只要会话还活着就必须 seek：否则"暂停态下拖完再按播放"会 resume 到老位置
      this.native.seek(target);
      if (this.playingC) {
        this.native.unmute(80);
      } else {
        // music_seek 内部会 Start 声卡，这里补一次 pause 把暂停态保住
        this.native.pause();
        this.native.unmute(80);            // 音量先恢复，下次 resume 才有声
      }
    } else {
      // 会话还没建起来（例如刚进页面就拖）：记下来，起播后补 seek
      this.pendingSeekSec = target;
    }
    this.engine.setAudioReady(true);
    this.pullStatus();
  }

  // ==================== native 步频管线（动态模式） ====================

  /** 从算法参数设置页（AppStorage）同步一次 */
  private syncStepSettings(): void {
    this.stepSource = getStepSource();
    this.stepScenario = getStepScenario();
  }

  private startPipeline(): void {
    if (this.pipelineOn) {
      return;
    }
    if (this.stepSource !== SOURCE_SIM) {
      return;                      // 真实传感器尚未接线
    }
    if (this.modeC !== MODE_DYNAMIC) {
      // ★ 预设（恒速/曲线）是**完全开环**：音乐是节拍基准，不读步频、不做相位对齐
      return;
    }
    try {
      stepPipelineSetChaseDelayWindow(getChaseDelaySec());
      stepPipelineStart(this.stepScenario, this.songBpmC, this.firstBeatC, 0, 0.0);
      this.pipelineOn = true;
      this.pipelineCadence = 0;
      this.pipelineMultiplier = 1;
      this.pipelineState = 0;
      this.pipelineSteps = 0;
    } catch (e) {
      console.error('stepPipelineStart 失败：' + JSON.stringify(e));
    }
  }

  private stopPipeline(): void {
    if (!this.pipelineOn) {
      return;
    }
    try {
      stepPipelineStop();
    } catch (e) {
      console.error('stepPipelineStop 失败：' + JSON.stringify(e));
    }
    this.pipelineOn = false;
    this.engine.clearExternalSpeed();
  }

  private pollPipeline(): void {
    if (!this.pipelineOn) {
      return;
    }
    try {
      const st = JSON.parse(stepPipelineStatus()) as StepPipelineStatus;
      this.pipelineCadence = st.cadenceSpm;
      this.pipelineMultiplier = st.multiplier;
      this.pipelineState = st.followState;
      this.pipelineSteps = st.steps;
      this.engine.setExternalSpeed(st.multiplier);
    } catch (e) {
      console.error('stepPipelineStatus 解析失败：' + JSON.stringify(e));
    }
  }

  // ==================== 主循环 / 状态刷新 ====================

  private startTick(): void {
    this.stopTick();
    this.lastTickMs = Date.now();
    this.tickId = setInterval(() => {
      const now: number = Date.now();
      let dt: number = (now - this.lastTickMs) / 1000;
      this.lastTickMs = now;
      if (dt > 0.5) { dt = 0.5; }

      if (this.scrubbing) {
        this.scrubStep(dt);
      } else {
        this.engine.tick(dt);
      }
      this.pullGlow();

      // 标题状态字：每秒判定一次加速/减速/暂停
      this.statusAccum += dt;
      if (this.statusAccum >= 1.0) {
        this.statusAccum = 0;
        this.updateStatusText();
      }

      this.pollCounter++;
      const remainPage: number = this.durSecC - this.posSecC;
      const nearEnd: boolean = this.autoNext && this.playingC
        && remainPage >= -0.5 && remainPage < 2.5;
      if (this.pollCounter >= 6 || nearEnd) {
        this.pollCounter = 0;
        this.pollNative();
        this.native.setSpeed(this.speedC);
        this.pollPipeline();
        this.pullStatus();
      }
    }, TICK_MS);
  }

  private stopTick(): void {
    if (this.tickId !== -1) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
  }

  /** 每帧只写 glowOpacity 一个 @State，避免整页 30fps 重绘 */
  private pullGlow(): void {
    if (!this.playingC) {
      if (this.glowOpacity !== 0) {
        this.glowOpacity = 0;
      }
      return;
    }
    const s: RunStatus = this.engine.status();
    let a: number = 1 - s.beatPhase;
    if (a < 0) { a = 0; }
    this.glowOpacity = Math.pow(a, 1.6);
  }

  /** 把引擎快照拷进 @State（约 5Hz 调用） */
  private pullStatus(): void {
    const s: RunStatus = this.engine.status();
    this.posSecC = s.posSec;
    this.durSecC = s.durSec;
    this.speedC = s.speed;
    this.songBpmC = s.songBpm;
    this.firstBeatC = s.firstBeat;
    this.modeC = s.mode;
    this.playingC = s.playing;

    let bpmShow: number = s.targetBpm;
    if (this.pipelineOn) {
      // 动态模式接上 native 管线后，步频/倍速以 native 为准
      this.speedC = this.pipelineMultiplier;
      bpmShow = this.pipelineCadence;
    }

    this.BPM_now = Math.round(bpmShow);
    this.Speed = Math.round(this.speedC * 100) / 100;
    this.sport_time = this.secToHms(s.workoutSec);
    this.songTimePass = this.secToMs(s.posSec);
    this.songTimeLast = this.secToMs(Math.max(0, s.durSec - s.posSec));
    // 进度环角度由 startTimeProgressSongRight 每秒按引擎位置推进，这里不直接改写
    this.playlistProgress = this.playlistProgressAt(s.posSec);
    if (!s.playing) {
      this.statusText = '暂停';
    }
  }

  private updateStatusText(): void {
    if (!this.playingC) {
      this.statusText = '暂停';
      this.lastStatusSpeed = this.speedC;
      return;
    }
    const d: number = this.speedC - this.lastStatusSpeed;
    this.lastStatusSpeed = this.speedC;
    if (d > 0.005) {
      this.statusText = '加速中';
    } else if (d < -0.005) {
      this.statusText = '减速中';
    } else {
      this.statusText = '正在运动';
    }
  }

  // ==================== 旧版计时器（已恢复启用） ====================
  // TimeGoLogic* / startTimeProgress* / Progress 都是原实现。
  // 现在「运动时间 / 歌曲时间」由引擎驱动，所以 startTimeProgress / startTimeProgressSongLeft 不再启动；
  // 进度环这一路保留每秒轮询（startTimeProgressSongRight），角度改用引擎真实位置求（见该函数）。

  private TimeGoLogic(direction: number, Min: number, Sec: number): number[] {
    if(direction === 0){
    if(Sec === 0){
      Sec = 60;
      Min -= 1;
    }
    Sec -= 1;
    return [Min,Sec]
    } else if (direction === 1){
      if(Sec === 59){
        Sec = 0;
        Min += 1;
      }
      Sec += 1
      return [Min,Sec]

    } else {
      console.error("[TimeGoLogic]direction读取错误")
      return []
    }

  }

  private TimeGoLogicHour(direction: number, Hour: number ,Min: number, Sec: number): number[] {
    if(direction === 0){
      if(Min === 0){
        Hour -= 1;
        Min = 59;
        return [Hour,Min,Sec]

      }

      if(Sec === 0){
        Sec = 59;
        Min -= 1;
        return [Hour,Min,Sec]

      }
      Sec -= 1;
      return [Hour,Min,Sec]
    } else if (direction === 1){

      if(Min === 59){
        Hour += 1;
        Min = 0;
        return [Hour,Min,Sec]

      }
      if(Sec === 59){
        Sec = 0;
        Min += 1;
        return [Hour,Min,Sec]

      }
      Sec += 1
      return [Hour,Min,Sec]


    } else {
      console.error("[TimeGoLogic]direction读取错误")
      return []
    }

  }


  private Progress(PerStep: number): void{
    this.getUIContext().animateTo({duration: 300, curve: Curve.EaseInOut}, () => {
      // console.log(this.rotate_angle.toString());   // 调试期每秒一条，太吵，先注释掉
      this.rotate_angle += PerStep;
    })
  }

  private startTimeProgress(type:number, id_ : string){
    let id : string = id_;
    let intervalID = setInterval(() => {
      if(!this.G_token || id === this.stop_token) {
        this.stop_token = '';    //销毁令牌
        clearInterval(intervalID);
      }
      this.sport_time = this.TimeGoLogicHour(type, this.sport_time[0], this.sport_time[1], this.sport_time[2])

    }, 1000)
  }

  private startTimeProgressSongRight(type:number, id_ : string){
    let id : string = id_;
    let intervalID = setInterval(() => {
      if(!this.G_token || id === this.stop_token) {
        this.stop_token = '';    //销毁令牌
        clearInterval(intervalID);
      }
      if(!this.isPause) {
        // ★ 修复点：原实现用 (90 - rotate_angle)*2 / perStep 每秒自己累加，
        //   而 perStep 取的是 songTimeLast（当时还是占位值 60s，真实曲长 ~198s），必然冲过头。
        //   现在角度直接由引擎的真实歌曲位置算，端点天然落在屏幕左右边缘。
        this.Progress(this.ringAngleAt(this.posSecC, this.durSecC) - this.rotate_angle);
      }

    }, 1000)
  }


  private startTimeProgressSongLeft(type:number, id_ : string){
    let id : string = id_;
    let intervalID = setInterval(() => {
      if(!this.G_token || id === this.stop_token) {
        this.stop_token = '';    //销毁令牌
        clearInterval(intervalID);
      }
      if(!this.isPause) {
        this.songTimeLast = this.TimeGoLogic(type, this.songTimeLast[0], this.songTimeLast[1])
      }

    }, 1000)
  }

  private NextSong(): void{

  }
  private FormalSong(): void {

  }

  private rockerLogic(distance: number, MaxLength: number): void {
    let rate = distance / MaxLength;

  }

  private MoveBar(power: number): void{

  }

  private onQuit(): void {
    this.G_token = false;
  }


}

class topColumnMaker{
  icon: Resource = $r('sys.symbol.play_circle_fill');
  per:string = '';
  statistic:number = 0;
  name:string = '';
  constructor(icon: Resource, per:string ,statistic: number,name:string) {
    this.icon = icon;
    this.per = per;
    this.statistic = statistic;
    this.name = name;
  }

}


@Component
struct SideButton {
  @Prop icon: Resource = $r('sys.symbol.pause');
  onTap: () => void = () => {};

  build() {
    Button() {
      SymbolGlyph(this.icon)
        .fontSize(30)
    }
    .borderRadius(5)
    .fontColor(Color.Black)
    .height(55)
    .width(55)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.onTap();
    })
  }
}

@Builder
export function load(){
  MainPlayer();
}
