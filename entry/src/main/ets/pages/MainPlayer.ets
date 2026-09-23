import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from '../ets_libs/Button';
import { EllipseShape } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { SongListJSON } from '../ets_libs/PlayListStore';


@Component
struct MainPlayer {
  @State colorList: string[] = ["#FF6B6B", "#4ECDC4", "#A78BFA"]
  @State columnList: topColumnMaker[] = [new topColumnMaker('sys.symbol.play_circle_fill','次',0, '次数'),
    new topColumnMaker('sys.symbol.figure_running','km',0, '公里数'),
    new topColumnMaker('sys.symbol.identify_song','BPM',0, '平均BPM')]
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
  @State sport_time: number[] = [0,0,0]   //运动时间（格式:00:00:00）
  @State songTimeLast: number[] = [0,0];     //歌曲剩余时间（格式：00:00）
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


  @Builder
  Column_UP(index:number){
    Column(){
      SymbolGlyph($r(this.columnList[index].icon))
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

  @Builder
  SideButton(text: string, callback:() => void){
    Button(){
      SymbolGlyph($r(text))
        .fontSize(30)

    }
      .borderRadius(5)
      .fontColor(Color.Black)
      .height(55)
      .width(55)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        callback();
      })
  }

  @Builder FloatWidgetBuild(){
    Column(){
      Column({space:10}){
        this.SideButton('sys.symbol.forward_end_fill',() => {})
        this.SideButton('sys.symbol.pause',() => {})
        this.SideButton('sys.symbol.backward_end_fill',() => {})

      }
        .width(60)
        .height(280)
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
          Text("+00:00").fontWeight(FontWeight.Bold).fontSize(25)
          Text("-03:21").fontWeight(FontWeight.Bold).fontSize(25)
        }
      }.width("100%").height("70%")
      Column(){
        Text('Lost Memory').fontWeight(FontWeight.Medium).fontSize(25)
        Text('Sakuzyo').fontWeight(FontWeight.Regular).fontSize(18).fontColor(Color.Gray)

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
            Text('170').fontSize(25).width(120).textAlign(TextAlign.Center).fontWeight(FontWeight.Bold)

          }.height(130)
          .width("20%")
          .justifyContent(FlexAlign.Center)



          Column() {
            SymbolGlyph($r('sys.symbol.figure_running'))
              .fontSize(40)
              .fontColor([this.colorList[0]])
              .padding({ bottom: 10 });
            Text('运动时间').fontSize(15)
            Text('01:30:20').fontSize(25).width(120).textAlign(TextAlign.Center).fontWeight(FontWeight.Bold)

          }.height(130)
          .width("20%")
          .justifyContent(FlexAlign.Center)

          Column(){
            SymbolGlyph(($r('sys.symbol.list_interrupt')))
              .fontSize(40)
              .fontColor([this.colorList[0]])
              .padding({ bottom: 10 });
            Text('平均BPM').fontSize(15)
            Text('149').fontSize(25).width(120).textAlign(TextAlign.Center).fontWeight(FontWeight.Bold)

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
        Column().width(110).height(110).backgroundColor('#4ECDC4').clipShape(new EllipseShape({ width: '100%', height: '100%' }))
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
            angle: 135,
            colors: [['#ffee3939', 0.0], ['#A78BFA', 1.0]]
          })
          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
          .height(240)
          .width(240)
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

  private TimeGoLogic(direction: boolean, Min: number, Sec: number){
    if(Sec === 0){

    }
    Sec -= 1;
  }

  /** 下一首--绑定下一首按钮 */
  private NextSong(): void{

  }
  /** 上一首--绑定上一首按钮*/
  private FormalSong(): void {

  }
  /**暂停 */
  private pause(): void {
    //change button style
  }

  /**摇杆--进度条调整摇杆控制模拟
   * @param distance 摇杆与原点的距离（+则向前调整，-则向后调整）
   * @param MaxLength 摇杆所能到达的最大距离
   * */
  private rockerLogic(distance: number, MaxLength: number): void {

  }

  /** 进度条移动逻辑
   * @param power 设置进度条移动的速率，最小为`0.1s`，最大为`1s`
   * */
  private MoveBar(power: number): void{

  }

}

class topColumnMaker{
  icon:string = '';
  per:string = '';
  statistic:number = 0;
  name:string = '';
  constructor(icon:string, per:string ,statistic: number,name:string) {
    this.icon = icon;
    this.per = per;
    this.statistic = statistic;
    this.name = name;
  }

}


@Builder
export function load(){
  MainPlayer();
}