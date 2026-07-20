import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';
import { Center_Button } from './Button';
import { curves, EllipseShape } from '@kit.ArkUI';
import { window } from '@kit.ArkUI'
import lottie, { AnimationItem } from '@ohos/lottie';

@Preview
@Component
struct Main {

  @State navPathStack: NavPathStack = new NavPathStack();
  @State selected_id: number = 1;
  @State windowWidth: number = 0;
  @State windowHeight: number = 0;
  @State gesture_offset: number = 0;
  @State gesture_start: number = 0;


  @State Button_1 : Center_Button = new Center_Button(1)
  @State Button_2 : Center_Button = new Center_Button(2)

  @Builder
  Column_UP(){
    Column(){}.height(100).width(100).borderRadius(20)
    .shadow({
      radius: 20,
      color: '#1A000000',
      offsetX: 0,
      offsetY: 4})
    .margin(5);
  }

  aboutToAppear(): void {
    try {
      window.getLastWindow(this.getUIContext().getHostContext())        //获取窗口大小
        .then((windowClass: window.Window) => {
          const properties = windowClass.getWindowProperties();
          const rect = properties.windowRect
          this.windowWidth = px2vp(rect.width) //get window's width
          this.windowHeight = px2vp(rect.height) // get window's height
        })

      } catch (exception){
      console.error('出现异常' + JSON.stringify(exception))
    }
  }


  build() {
    HdsNavDestination() {
      Text('今日统计')     //开头



      Row(){    //标题三栏
        this.Column_UP();
        this.Column_UP();
        this.Column_UP();
      }



      Column() {
        Button("测试Lottie动画").height(40).width(120).onClick(() => {        //测试用，记得删掉
          this.navPathStack.pushPathByName('Animation_test_Page', null, true)
          console.info('ButtonType.Normal');
        }).offset({y: -200})
        Text('主屏幕')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .offset({ y: -100 })



          Row() {          //按钮模块
          /*

          *    记得开头结尾修改为 (l + d) / 2
          *    以后适配屏幕宽度
          *    两个按钮之间的宽度同理
          *
           */

            Blank().width((this.windowWidth - 240)/ 2)


              Column() {      //第一个按钮
                Column()
                  .width(40)
                  .height(40)
                  .backgroundColor(Color.Orange)
                  .offset({ x: this.Button_1.animator.x, y: -this.Button_1.animator.y + 50 })
                  .onClick(() => {
                    console.log(this.windowWidth.toString())   //test
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


            Blank().width((this.windowWidth - 240)/ 2)


              Column() {         //第二个按钮
                Column()
                  .width(40)
                  .height(40)
                  .backgroundColor(Color.Orange)
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

            Blank().width((this.windowWidth - 240)/ 2)



          }
          .alignSelf(ItemAlign.Baseline)
          .padding({ top: 20 })
          .position({x:this.gesture_offset, y:"25%"})
          .width(4000)
          .height('50%')

          .gesture(PanGesture({direction: PanDirection.Horizontal})
            .onActionUpdate((event: GestureEvent) => {
              this.getUIContext()?.animateTo({duration: 40, curve: Curve.EaseOut},() => {
                this.gesture_offset = event.offsetX + this.gesture_start     // >0 右滑  <0 左滑

                if(this.gesture_offset > 0){
                  console.log("正在右滑" + this.gesture_offset.toString())
                } else if (this.gesture_offset < 0){
                  console.log("正在左滑" + this.gesture_offset.toString())
                }
              })
            })



            .onActionEnd((event: GestureEvent) => {
              this.getUIContext()?.animateTo({curve: curves.springMotion(), duration: 400},() => {
                //右滑动
                if (this.gesture_offset > 50 + this.gesture_start) {
                  this.gesture_offset = 0;
                  this.gesture_start = this.gesture_offset;         //调整初始位置

                } else if(this.gesture_offset < 0) {
                  if (this.gesture_offset < - 50 + this.gesture_start) {
                    this.gesture_offset = -(this.windowWidth - (this.windowWidth - 240) / 2)
                    this.gesture_start = this.gesture_offset;         //调整初始位置
                  }

                }
                if (this.gesture_start !== 0) {
                  this.gesture_offset = -(this.windowWidth - (this.windowWidth - 240) / 2);
                  this.gesture_start = this.gesture_offset; //调整初始位置
                } else if(this.gesture_start === 0) {
                  this.gesture_offset = 0;
                  this.gesture_start = this.gesture_offset; //调整初始位置
                }
              })
            }))      //手势滑动

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
