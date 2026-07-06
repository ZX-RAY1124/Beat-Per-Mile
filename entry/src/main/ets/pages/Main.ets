import { HdsNavDestination, HdsNavigation } from '@hms.hds.hdsBaseComponent';
import { curves } from '@kit.ArkUI';
import { EllipseShape } from '@kit.ArkUI';
import {Ellipse_animation} from './Ellipse_animation'

@Preview
@Component
struct Main {

  @State navPathStack: NavPathStack = new NavPathStack();
  @State is_button_animate : boolean = false;
  @State button_y : number = -20;
  @State button_zoom_x: number = 1;
  @State button_zoom_y: number = 1;
  @State anim_ctr : boolean = false;
  @State animator: Ellipse_animation = new Ellipse_animation(960,480);

  build() {
    HdsNavDestination() {
      Column() {
        Text('主屏幕')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .offset({y:-100})


        Column(){
          Column().width(40).height(40).backgroundColor(Color.Orange).id("sc").animation({duration:1200, iterations:-1})
            .offset({x:this.animator.x, y:this.animator.y})
            .onClick(() =>{
              this.anim_ctr = !this.anim_ctr;
              this.anim_ctr ? this.animator.onPlay() : this.animator.onPause();
            })


        }.backgroundColor(Color.Blue)
        .clipShape(new EllipseShape({width:'100%', height:'100%'}))
        .height(240)
        .width(240)
        .scale({x:this.button_zoom_x, y:this.button_zoom_y})
        .offset({y: this.button_y})
        .renderGroup(true)
        .onClick(()=>{
          this.getUIContext()?.animateTo({curve: Curve.EaseInOut, duration:500}, () => {
            this.is_button_animate = !this.is_button_animate;
            this.button_y= this.is_button_animate ? 400 : -20;    //400
            this.button_zoom_x = this.is_button_animate ? 4 : 1
            this.button_zoom_y = this.is_button_animate ? 2 : 1

          })

        })



      }
      .width('100%')
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
