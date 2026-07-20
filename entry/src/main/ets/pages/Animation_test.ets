import { HdsNavDestination } from '@hms.hds.hdsBaseComponent'
import lottie, { AnimationItem } from '@ohos/lottie';


/**
* # 测试界面
 ***不做引用处理**
 *
 */

@Component
struct Animation_test{
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  animation_Name: string = 'Test_Animation';
  @Provide navPathStack: NavPathStack = new NavPathStack();


  private animItem: AnimationItem | null = null;

  aboutToAppear(): void {
    this.destroy_ani();
  }

   private initAnimation(): void {
    this.context.imageSmoothingEnabled = true;
    this.context.imageSmoothingQuality = 'medium';

    this.animItem = lottie.loadAnimation({
      container: this.context,
      renderer: 'canvas',
      loop: true,
      autoplay: true,
      name: this.animation_Name,
      path: 'common/lottie/test_Animation.json',
      frameRate: 30,
      initialSegment: [0, 0],
      contentMode: 'Contain'
    });

  }

  private destroy_ani(): void {
    this.animItem?.destroy()
    lottie.destroy(this.animation_Name)
  }

  build() {
    HdsNavDestination(){
      Column() {
        Text('animation')
          .fontSize(30)
          .fontWeight(700)
          .width('100%')
          .height('100%')
          .backgroundColor('#FFF0F0F0')
          .textAlign(TextAlign.Center)

        Button('返回')
          .height(40).width(120)
          .onClick(() => {
            this.navPathStack.pushPathByName("MainPage",null,true);
            this.destroy_ani();
          })

      }.justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .height("40%")
      .width("100%")

      Column(){

        Canvas(this.context)
          .width('100%')
          .height('100%')
          .onReady(() => {
            // Canvas 组件就绪后才可加载动画
            this.initAnimation();
          })
          .onDisAppear(() => {
            this.destroy_ani();
          })



      }.height("50%")
      .width("100%")
      .backgroundColor('#ffff00')


    }.onReady((context: NavDestinationContext) => {
      this.navPathStack = context.pathStack;
    })


  }
}


@Builder
export function load(){
  Animation_test()
}
