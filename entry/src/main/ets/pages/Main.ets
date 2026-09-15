import { Center_Button } from '../ets_libs/Button';
import { curves, EllipseShape, LengthMetrics } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import {
  hdsMaterial,
  HdsTabs,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabsController,
  ScrollEffectType,
} from '@kit.UIDesignKit';

import { HdsNavDestination } from '@hms.hds.hdsBaseComponent';

import lottie, { AnimationItem } from '@ohos/lottie';
import * as entry from 'libentry.so';
import { SongList } from './SongList';
import { CurveList } from './CurveList';

console.log('模块对象='+JSON.stringify(entry));
console.log('模块对象是否为undefined = ' + (entry === undefined));
console.log(entry.test_audio("test_audio"));

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


@Preview
@Component
struct Main {

  @State g_Visibility: boolean = true;                   //全局显示、隐藏
  @State navPathStack: NavPathStack = new NavPathStack();
  @State selected_id: number = 0;
  @State Button_selected_id : number = 0;
  @State windowWidth: number = 0;
  @State windowHeight: number = 0;
  @State gesture_offset: number = 0;
  @State gesture_start: number = 0;
  @State isMenuShow: boolean = false; //页面导航子菜单是否展开
  @State title_name: string = '';
  CARD_BORDER_TOP: number = 6;    // 左侧描边（选中时可见）
  CARD_BORDER_OTHER: number = 1.5; // 其余三边描边

  @State Button_1 : Center_Button = new Center_Button(1)
  @State Button_2 : Center_Button = new Center_Button(2)
  @State pageName: string = "今日统计";

  @State page_name_list : string[] = ["今日统计","歌曲列表","曲线选择","设置"];
  @State colorList: string[] = ["#FF6B6B", "#4ECDC4", "#A78BFA"]
  @State columnList: topColumnMaker[] = [new topColumnMaker('sys.symbol.play_circle_fill','次',0, '次数'),
    new topColumnMaker('sys.symbol.figure_running','km',0, '公里数'),
    new topColumnMaker('sys.symbol.identify_song','BPM',0, '平均BPM')]


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
  tabBarBuilder(resource: string, text: string, tabIndex: number) {
    Column() {
      SymbolGlyph($r(resource))
        .fontSize(20)
        .fontColor([this.selected_id === tabIndex ? Color.Blue : Color.Gray])
        .padding({ bottom: 5 });
      Text(text)
        .fontSize(10)
        .fontColor(this.selected_id === tabIndex ? Color.Blue : Color.Gray)
        .textAlign(TextAlign.Center)
    }
  }

  /**
   * 主页"页面导航"按钮的子菜单
   *
   * 只收录我们自己写的页面（原生自带的测试按钮不放在这里）。
   * 约定：以后每做好一个页面，就在这里加一个 MenuItem，例如：
   *   MenuItem({ content: '歌曲列表' })
   *     .onClick(() => {
   *       this.isMenuShow = false
   *       this.navPathStack.pushPathByName('SongList_Page', null, true)
   *     })
   * 新页面记得同步在 resources/base/profile/router_map.json 里注册。
   *
   * 菜单显隐由 isMenuShow 控制（bindMenu 的受控写法），
   * 所以每个 MenuItem 里都要先把 isMenuShow 置 false 再跳转。
   */
  @Builder
  PageMenu() {
    Column() {
      MenuItem({ content: '曲线列表' })
        .onClick(() => {
          this.isMenuShow = false
          this.navPathStack.pushPathByName('CurveList_Page', null, true)
        })

      MenuItem({ content: '歌曲列表' })
        .onClick(() => {
          this.isMenuShow = false
          this.navPathStack.pushPathByName('SongList_Page', null, true)
        })

      MenuItem({ content: '曲线编辑' })
        .onClick(() => {
          this.isMenuShow = false
          this.navPathStack.pushPathByName('CurveEdit_Page', null, true)
        })

      MenuItem({ content: '播放器' })
        .onClick(() => {
          this.isMenuShow = false
          this.navPathStack.pushPathByName('Player_Page', null, true)
        })
    }
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
      HdsTabs({ index: this.selected_id }) {
        TabContent() {
          RelativeContainer() {

            Row({space:10}) { //标题三栏
              this.Column_UP(0);
              this.Column_UP(1);
              this.Column_UP(2);
            }.alignRules(
              {
                'top': { 'anchor': '__container__', 'align': VerticalAlign.Top },
                'left': { 'anchor': '__container__', 'align': HorizontalAlign.Start},
              }
            )
            .offset({x:13})





            Column() {
              Row() {
                Button("测试Lottie动画").height(40).width(120).onClick(() => { //测试用，记得删掉
                  this.navPathStack.pushPathByName('Animation_test_Page', null, true)
                  console.info('ButtonType.Normal');
                }).offset({ y: -160 })

                Button("测试音频播放").height(40).width(120).onClick(() => { //测试用，记得删掉
                  this.navPathStack.pushPathByName('Audio_test_page', null, true)
                  console.info('ButtonType.Normal');
                }).offset({ y: -160 })
              }

              Text('主屏幕')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .offset({ y: -100 })


              Row() { //按钮模块
                /*

                *    记得开头结尾修改为 (l + d) / 2
                *    以后适配屏幕宽度
                *    两个按钮之间的宽度同理
                *
                 */

                Blank().width((this.windowWidth - 240) / 2)


                Column() { //第一个按钮
                  Column()
                    .width(40)
                    .height(40)
                    .backgroundColor(Color.Orange)
                    .offset({ x: this.Button_1.animator.x, y: -this.Button_1.animator.y })
                    .onClick(() => {
                      console.log(this.windowWidth.toString()) //test
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

                 // this.navPathStack.pushPathByName('Player_Page', null, true);

                  this.getUIContext()?.animateTo({ curve: Curve.EaseInOut, duration: 500 }, () => {
                    this.Button_selected_id = 1;


                    if (this.Button_1.is_select) {
                      this.Button_1.unselect();
                      this.Button_2.unselect();
                    } else {
                      this.Button_1.select();
                      this.Button_2.unselect();
                    }


                  })


                })


                Blank().width((this.windowWidth - 240) / 2)


                Column() { //第二个按钮
                  Column()
                    .width(40)
                    .height(40)
                    .backgroundColor(Color.Orange)
                    .offset({ x: this.Button_2.animator.x, y: -this.Button_2.animator.y })
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
                    this.Button_selected_id = 2;

                    if (this.Button_2.is_select) {
                      this.Button_2.unselect();
                      this.Button_1.unselect();
                    } else {
                      this.Button_2.select();
                      this.Button_1.unselect();

                    }

                  })


                })

                Blank().width((this.windowWidth - 240) / 2)


              }
              .alignSelf(ItemAlign.Baseline)
              .padding({ top: 20 })
              .position({ x: this.gesture_offset, y: "30%" })
              .width(4000)
              .height('32%')
              .backgroundColor(Color.Pink)

              .gesture(PanGesture({ direction: PanDirection.Horizontal })
                .onActionUpdate((event: GestureEvent) => {
                  this.getUIContext()?.animateTo({ duration: 40, curve: Curve.EaseOut }, () => {
                    this.gesture_offset = event.offsetX + this.gesture_start // >0 右滑  <0 左滑
                  })
                })

                .onActionEnd((event: GestureEvent) => {
                  this.getUIContext()?.animateTo({ curve: curves.springMotion(), duration: 400 }, () => {
                    //右滑动
                    if (this.gesture_offset > 50 + this.gesture_start) {
                      this.gesture_offset = 0;
                      this.gesture_start = this.gesture_offset; //调整初始位置

                    } else if (this.gesture_offset < 0) {
                      if (this.gesture_offset < -50 + this.gesture_start) {
                        this.gesture_offset = -(this.windowWidth - (this.windowWidth - 240) / 2)
                        this.gesture_start = this.gesture_offset; //调整初始位置
                      }

                    }
                    if (this.gesture_start !== 0) {
                      this.gesture_offset = -(this.windowWidth - (this.windowWidth - 240) / 2);
                      this.gesture_start = this.gesture_offset; //调整初始位置
                    } else if (this.gesture_start === 0) {
                      this.gesture_offset = 0;
                      this.gesture_start = this.gesture_offset; //调整初始位置
                    }
                  })
                })) //手势滑动

            }.width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            // 页面导航入口：放在大圆下方、底部悬浮 tab 栏上方的空白区，周围没有别的元素。
            // 同时必须是 RelativeContainer 的最后一个子节点（后绘制的在上层），否则会被
            // 上面那个 100%×100% 的 Column 挡住。

            /*
            Button('页面导航') //只负责进入我们自己写的页面，入口都放在 PageMenu() 子菜单里
              .height(40)
              .width(120)
              .onClick(() => {
                console.info('页面导航按钮被点击, 当前 isMenuShow=' + this.isMenuShow)
                this.isMenuShow = !this.isMenuShow
              })
              .bindMenu(this.isMenuShow, this.PageMenu, {
                onDisappear: () => { //点空白处收起菜单时，把状态同步回来
                  this.isMenuShow = false
                }
              })
              .alignRules({
                'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom },
                'middle': { 'anchor': '__container__', 'align': HorizontalAlign.Center },
              })
              .offset({ y: -150 })
              * */
          }.padding({ top: $r('sys.float.single_line_titlebar_height') })
          //避让标题位置
        }.tabBar(this.tabBarBuilder("sys.symbol.play_circle","主屏幕", 0))


        TabContent(){
          SongList();
        }.tabBar(this.tabBarBuilder("sys.symbol.music_fill","歌曲列表", 1))
          CurveList({navPathStack: this.navPathStack});
        TabContent(){
        }.tabBar(this.tabBarBuilder("sys.symbol.indent_right","曲线选择", 2))


        TabContent(){

        }.tabBar(this.tabBarBuilder("sys.symbol.gearshape", "设置", 3))



      }.barPosition(BarPosition.End)
      .width('100%')
      .height('100%')


      .barOverlap(true)     //设置悬浮开关
      .barFloatingStyle(
        {
          adaptToHandedness: true,
          barBottomMargin: $r('sys.float.padding_level16'),
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
          },
        }
      )
      .onChange((index: number) => {
        this.getUIContext().animateTo({
          duration: 200,
          curve:Curve.EaseInOut
        }, () => {
          this.selected_id = index;
          this.pageName = this.page_name_list[index];
        })
      })

    }.width('100%')
    .height('100%')
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
    .backgroundBlurStyle(BlurStyle.NONE)


    .titleBar({content:{title:{mainTitle:this.pageName,mainTitleSize:20}},style : {
      scrollEffectOpts: {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
      blurEffectiveEndOffset: LengthMetrics.vp(64),
    },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    },
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false,})


    .ignoreLayoutSafeArea(
      [LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.BOTTOM]
    )


    .mode(NavDestinationMode.STANDARD)
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
