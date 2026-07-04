import { HdsNavDestination, HdsNavigation } from '@hms.hds.hdsBaseComponent';

@Preview
@Component
struct Main {

  @State navPathStack: NavPathStack = new NavPathStack();

  build() {
    HdsNavDestination() {
      Column() {
        Text('主屏幕')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }.width('100%')
    .height('100%')
    .onReady((context: NavDestinationContext) => {
        this.navPathStack = context.pathStack;
    })
    .hideBackButton(true)
    .onBackPressed(()=>{
      this.getUIContext().getRouter().back();
      return true;
    })

  }

  pageTransition() {
    PageTransitionEnter({ duration: 400, curve: Curve.EaseInOut })
      .slide(SlideEffect.Right)
      .opacity(0)
    PageTransitionExit({ duration: 400, curve: Curve.EaseInOut })
      .slide(SlideEffect.Left)
      .opacity(0)
  }
}
@Builder
export function load(){
  Main()
}
