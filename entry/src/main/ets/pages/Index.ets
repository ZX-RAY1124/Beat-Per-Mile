import { HdsNavigation } from '@hms.hds.hdsBaseComponent';

@Entry
@Component

@Preview
struct Index {

  @Provide NavPathStack: NavPathStack = new NavPathStack();


  aboutToAppear(): void {
    setTimeout(() => {
      this.NavPathStack.replacePathByName("MainPage",null,true)
    }, 1000);
  }




  build() {
    HdsNavigation(this.NavPathStack) {
      RelativeContainer() {
        Image($r('app.media.sports_icon')/*$r('app.media.sports_icon')*/)
          .id('sports_icon')
          .width(200)
          .height(200)
          .alignRules({
            center: { anchor: '__container__', align: VerticalAlign.Center },
            middle: { anchor: '__container__', align: HorizontalAlign.Center }
          })
          .offset({ y: -50 })
        Text('真离散工作室')
          .id('studio_text')
          .fontSize(20)
          .fontColor('#999999')
          .alignRules({
            bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
            middle: { anchor: '__container__', align: HorizontalAlign.Center }
          })
          .margin({ bottom: 40 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .hideToolBar(true)
    .hideBackButton(true)
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
