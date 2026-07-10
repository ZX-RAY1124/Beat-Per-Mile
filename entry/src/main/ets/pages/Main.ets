import { HdsNavDestination, HdsNavigation } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from './Button';
import { EllipseShape } from '@kit.ArkUI';

@Preview
@Component
struct Main {

  @State navPathStack: NavPathStack = new NavPathStack();
  @State selected_id: number = 1;
  private scroller: Scroller = new Scroller();      //创建Scroller


  @State Button_1 : Center_Button = new Center_Button(1)
  @State Button_2 : Center_Button = new Center_Button(2)


  build() {
    HdsNavDestination() {
      Column() {
        Text('主屏幕')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .offset({ y: -100 })


          List({scroller:this.scroller}) {
          /*

          *    记得开头结尾修改为 (l + d) / 2
          *    以后适配屏幕宽度
          *    两个按钮之间的宽度同理
          *
           */

            ListItem(){
              Row().width(1000)
            }

            ListItem() {
              Column() {
                Column()
                  .width(40)
                  .height(40)
                  .backgroundColor(Color.Orange)
                  .animation({ duration: 1200 })
                  .offset({ x: this.Button_1.animator.x, y: -this.Button_1.animator.y + 50 })
                  .onClick(() => {

                  })


              }
              .backgroundColor(Color.Blue)
              .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
              .height(240)
              .width(240)
              .scale({ x: this.Button_1.button_zoom_x, y: this.Button_1.button_zoom_y })
              .offset({ y: this.Button_1.offset_y })
              .renderGroup(true)
              .onClick(() => {

                this.getUIContext()?.animateTo({ curve: Curve.EaseInOut, duration: 500 }, () => {
                  this.selected_id = 1;



                  if(this.Button_1.is_select) {
                    this.Button_1.unselect();
                    this.Button_2.unselect();
                  } else {
                    this.Button_1.select();
                    this.Button_2.unselect();
                  }


                })


              })
            }.margin({right:20})
            ListItem() {


              Column() {
                Column()
                  .width(40)
                  .height(40)
                  .backgroundColor(Color.Orange)
                  .animation({ duration: 1200 })
                  .offset({ x: this.Button_2.animator.x, y: -this.Button_2.animator.y + 50 })
                  .onClick(() => {

                  })


              }
              .backgroundColor(Color.Green)
              .clipShape(new EllipseShape({ width: '100%', height: '100%' }))
              .height(240)
              .width(240)
              .scale({ x: this.Button_2.button_zoom_x, y: this.Button_2.button_zoom_y })
              .offset({ y: this.Button_2.offset_y })
              .renderGroup(true)
              .onClick(() => {

                this.getUIContext()?.animateTo({ curve: Curve.EaseInOut, duration: 500 }, () => {
                  this.selected_id = 2;

                  if(this.Button_2.is_select) {
                    this.Button_2.unselect();
                    this.Button_1.unselect();
                  } else {
                    this.Button_2.select();
                    this.Button_1.unselect();

                  }

                })


              })
            }
            ListItem(){
              Row().width(1000)
            }

          }.listDirection(Axis.Horizontal)
          .alignSelf(ItemAlign.Baseline)
          .scrollBar(BarState.Off)
          .width(1000)
          .margin({ top: 20 })
        .width('100%')
        .height('50%')

      }.width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }.width('100%')
    .height('100%')
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
    .onReady((context: NavDestinationContext) => {
        this.navPathStack = context.pathStack;
    })
    .hideBackButton(true)
    .onBackPressed(()=>{
      this.getUIContext().getRouter().back();
      return true;
    })

  }

  /*
  pageTransition() {
    PageTransitionEnter({ duration: 400, curve: Curve.EaseInOut })
      .slide(SlideEffect.Right)
      .opacity(0)
    PageTransitionExit({ duration: 400, curve: Curve.EaseInOut })
      .slide(SlideEffect.Left)
      .opacity(0)
  }
  */
}
@Builder
export function load(){
  Main()
}
