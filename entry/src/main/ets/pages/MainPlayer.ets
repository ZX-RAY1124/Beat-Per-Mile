import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from '../ets_libs/Button';
import { EllipseShape } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';


@Component
struct MainPlayer {
  @State colorList: string[] = ["#FF6B6B", "#4ECDC4", "#A78BFA"]
  @State columnList: topColumnMaker[] = [new topColumnMaker('sys.symbol.play_circle_fill','次',0, '次数'),
    new topColumnMaker('sys.symbol.figure_running','km',0, '公里数'),
    new topColumnMaker('sys.symbol.identify_song','BPM',0, '平均BPM')]
  @State navPathStack :NavPathStack = new NavPathStack();

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



  @Builder FloatWidgetBuild(){
    Column(){
      Column()
        .width(45)
        .height(45)
        .borderRadius(5)
        .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
    }.position({right:0, top:50})
  }




  build(){
    HdsNavDestination(){
      Column(){

      }

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
          .renderGroup(true)


          Column() {

          }
          .backgroundColor(Color.Orange)
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
          Column() {

          }
          .backgroundColor(Color.Blue)
          .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
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