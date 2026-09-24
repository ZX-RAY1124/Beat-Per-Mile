import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from '../ets_libs/Button';
import { EllipseShape, window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { SongListJSON } from '../ets_libs/PlayListStore';




@Component
struct MainPlayer {
  @State colorList: string[] = ["#FF6B6B", "#4ECDC4", "#A78BFA"]
  @State columnList: topColumnMaker[] = [new topColumnMaker($r('sys.symbol.play_circle_fill'),'次',0, '次数'),
    new topColumnMaker($r('sys.symbol.figure_running'),'km',0, '公里数'),
    new topColumnMaker($r('sys.symbol.identify_song'),'BPM',0, '歌曲倍速')]
  @State navPathStack :NavPathStack = new NavPathStack();

  @Prop value: number = 0;
  @Prop valueText: string = '';
  @Prop min: number = 0;
  @Prop max: number = 100;
  step: number = 1;

  @State Status:string[] = ["正在运动","暂停","加速中","减速中"]
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


  @State BPM_now : number = 0;     //当前BPM
  @State BPM_Average: number = 0;    //目前平均BPM
  @State Speed : number = 0;    //歌曲倍速
  @State sport_time: number[] = [0,0,0]   //运动时间（格式:00:00:00）
  @State songTimeLast: number[] = [1,0];     //歌曲剩余时间（格式：00:00）
  @State songTimePass: number[] = [0,0];    //歌曲已播放时间（格式：00:00）
  @State songName: string = '';     //歌曲名称
  @State Artist: string = '';      //作曲家名称
  @State hasStop: boolean = false;     //是否暂停
  @State playList : SongListJSON = {    //歌单列表
    index: 0,
    name: 'index',
    songList: [],
    colorPlan: 0
  }

  @State isPause: boolean = false;
  @State Pauce_icon: Resource = $r('sys.symbol.pause')
  @State stop_token : string = ''    //特定向暂停轮询
  private G_token: boolean = true    //全局轮询令牌

  @State windowWidth: number = 0;     //窗口宽度 弦长
  @State windowHeight: number = 0;
  @State R: number = 240*8;         //圆半径
  @State rotate_angle: number = 0;      //用于制作旋转进度条

  aboutToAppear(): void {
    try {
      window.getLastWindow(this.getUIContext().getHostContext())        //获取窗口大小
        .then((windowClass: window.Window) => {
          const properties = windowClass.getWindowProperties();
          const rect = properties.windowRect
          this.windowWidth = this.getUIContext().px2vp(rect.width) //get window's width
          this.windowHeight = this.getUIContext().px2vp(rect.height) // get window's height
          this.rotate_angle = 90 - ((Math.asin(0.5 * this.windowWidth / this.R)) * 180 / Math.PI);
          console.log((Math.asin(0.5*this.windowWidth/this.R)* 180 / Math.PI).toString());
          this.startTimeProgressSongRight(1, 'songTimePass')
          this.startTimeProgressSongLeft(0, 'songTimeLast')
        })

    } catch (exception){
      console.error('出现异常' + JSON.stringify(exception))
    }
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
        SideButton({ icon: $r('sys.symbol.forward_end_fill'), onTap: () => {} });
        SideButton({ icon: this.Pauce_icon, onTap: () => { this.pause() } });
        SideButton({ icon: $r('sys.symbol.backward_end_fill'), onTap: () => {} });
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
  @State G_COLOR:string = this.colorList[this.getRandomInt(0,2)];

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
          Text(`+${this.songTimePass[0].toString().padStart(2, '0')}:${this.songTimePass[1].toString().padStart(2, '0')}`).fontWeight(FontWeight.Bold).fontSize(25)
          Text(`-${this.songTimeLast[0].toString().padStart(2,'0')}:${this.songTimeLast[1].toString().padStart(2,'0')}`).fontWeight(FontWeight.Bold).fontSize(25)
        }
      }.width("100%").height("70%")
      Column(){
        Text(this.songName).fontWeight(FontWeight.Medium).fontSize(25)
        Text(this.Artist).fontWeight(FontWeight.Regular).fontSize(18).fontColor(Color.Gray)

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
 * 摇杆组件*/
  @State rocker_offset: number = 0;
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
        })
        .onActionUpdate((event: GestureEvent) => {
          this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut} ,() => {
            if(event.offsetY <= 60 && event.offsetY >= -60){
              this.rocker_offset = event.offsetY;
              console.log(this.rocker_offset.toString())
            }
          })
        })
        .onActionEnd(() => {
          this.getUIContext().animateTo({ duration: 400, curve: Curve.EaseOut} ,() => {
            this.rocker_offset = 0;
          })
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
            Text(`${this.sport_time[0].toString().padStart(2, '0')}:${this.sport_time[1].toString().padStart(2, '0')}:${this.sport_time[2].toString().padStart(2, '0')}`).fontSize(25).width(120).textAlign(TextAlign.Center)
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
            value: this.value,
            min: this.min,
            max: this.max,
            step: this.step,
            style: SliderStyle.NONE
          }).height(20)
            .width("90%")
            .selectedColor(this.G_COLOR)
            .blockColor(Color.White)
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
         SymbolGlyph($r('sys.symbol.pause'))
           .fontSize(60)
           .fontColor([Color.White])
        }.width(110).height(110).backgroundColor('#4ECDC4')
        .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
        .justifyContent(FlexAlign.Center)
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
          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
          .height(240)
          .width(240)
          .scale({ x: this.outCircle.button_zoom_x + 0.05, y: this.outCircle.button_zoom_y + 0.05})
          .offset({ y: this.outCircle.offset_y })
          .onClick(() => {

          })
          .padding({ top: $r('sys.float.single_line_titlebar_height') })
          .borderColor(this.colorList[this.getRandomInt(0,3)])
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
      this.WINDOWS_WID = context.pathInfo.param as number;
      this.outCircle.select();
      this.startTimeProgress(1, 'global_time');



    })

    .onActive(() => {
      this.getUIContext().animateTo({curve: Curve.EaseInOut, duration: 500}, () => {
          this.Button_1.select();
      })
    })

    .titleBar({content:{title:{mainTitle:this.Status[0],mainTitleSize:20}}})
  }


  private getRandomInt(min: number, max: number): number {
    min = Math.ceil(min);
    max = Math.floor(max);
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }
  /** 用于将传递进来的关于`00:00`格式的字符串转换为`number[]`并输出
   * @param strTime 传入的字符串格式时间`00:00`
   * @returns [Min,Sec]
   * */
  private TimeTransformMinSec(strTime: string): number[]{
    const spliter = strTime.split(":");
    const Min: number = Number(spliter[0]);
    const Sec: number = Number(spliter[1]);
    return [Min,Sec]
  }
/** 轮询计时器逻辑
 * @param direction: 正负计时 (`1`正`0`负）
 * @param Min: 分钟
 * @param Sec: 秒
 * @returns [Min,Sec]
 * */
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
    //test 77-101
    this.getUIContext().animateTo({duration: 300, curve: Curve.EaseInOut}, () => {
      console.log(this.rotate_angle.toString());
      this.rotate_angle += PerStep;
    })
  }

  /**
   * 开启计时器
   * @param type 正倒计时
   */

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
    const way : number = (90 - this.rotate_angle) * 2
    let perStep = this.songTimeLast[0] * 60 + this.songTimeLast[1]
    let id : string = id_;
    let intervalID = setInterval(() => {
      if(!this.G_token || id === this.stop_token) {
        this.stop_token = '';    //销毁令牌
        clearInterval(intervalID);
      }
      if(!this.isPause) {
        this.songTimePass = this.TimeGoLogic(type, this.songTimePass[0], this.songTimePass[1])
        this.Progress(way/perStep);

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

  /** 下一首--绑定下一首按钮 */
  private NextSong(): void{

  }
  /** 上一首--绑定上一首按钮*/
  private FormalSong(): void {

  }
  /**暂停 */
  private pause(): void {
    this.isPause = !this.isPause;
    if(this.isPause){
      this.Pauce_icon = $r('sys.symbol.play_fill')
    } else {
      this.Pauce_icon = $r('sys.symbol.pause')
    }
  }



  /**摇杆--进度条调整摇杆控制模拟
   * @param distance 摇杆与原点的距离（+则向前调整，-则向后调整）
   * @param MaxLength 摇杆所能到达的最大距离
   * */
  private rockerLogic(distance: number, MaxLength: number): void {
    let rate = distance / MaxLength;

  }

  /** 进度条移动逻辑
   * @param power 设置进度条移动的速率，最小为`0.1s`，最大为`1s`
   * */
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