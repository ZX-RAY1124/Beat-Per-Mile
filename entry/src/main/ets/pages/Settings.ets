/**
 * 设置页 —— 主页底部 Tab 里的「设置」
 *
 * 注意：这里是**纯内容组件**，不带 HdsNavDestination / 标题栏。
 * 标题由主页那个 HdsNavDestination 统一显示（页面名跟着 Tab 切换），
 * 所以本组件直接从 Scroll 开始，顶部只留出悬浮标题栏的高度。
 *
 * 编排按设计稿（resources/base/media/ui_setting.html）：用户资料卡 → 「通用」分组 → 「同步」分组。
 * 视觉是 APP 现在这套：浅灰底 + 白色圆角卡片 + 分组小标题，
 * 图标用系统符号（sys.symbol.*）而不是设计稿里的 SVG。
 *
 * 目前所有条目都是占位：点一下弹个提示，还没有对应的子页面。
 * 开关状态也只存在内存里，没有落盘。
 */

/** 配色（和其它页面一致） */
const ACCENT: string = '#FF6B6B';
const TEXT_PRIMARY: string = '#1B1B2F';
const TEXT_SECONDARY: string = '#8A8F99';
const TEXT_TERTIARY: string = '#C4C8D0';
const PAGE_BG: string = '#F5F6F8';
const CARD_BG: string = '#FFFFFF';
const DIVIDER_COLOR: string = '#F0F0F0';

/** 图标底色（取自设计稿，做了一点收敛） */
const ICON_BG_PURPLE: string = '#F5F0FF';
const ICON_BG_TEAL: string = '#EDFCF9';
const ICON_BG_ORANGE: string = '#FFF3E9';
const ICON_BG_RED: string = '#FFF0ED';

const COLOR_PURPLE: string = '#A78BFA';
const COLOR_TEAL: string = '#4ECDC4';
const COLOR_ORANGE: string = '#FF8E53';
const COLOR_RED: string = '#FF6B6B';

/** 行的尺寸 */
const ROW_HEIGHT: number = 56;
const ROW_PADDING_H: number = 16;
const ICON_BOX: number = 32;
const ICON_BOX_RADIUS: number = 9;
const ICON_GAP: number = 12;
/** 分割线从文字左边开始（＝左右内边距 + 图标 + 间距） */
const DIVIDER_INSET: number = ROW_PADDING_H + ICON_BOX + ICON_GAP;

/** 底部悬浮 tab 栏会盖住内容，给列表留出空间 */
const BOTTOM_RESERVE: number = 100;

/** 演示用的用户信息 */
const USER_NAME: string = '运动达人';
const USER_ID: string = 'ID: runner_2024';

/**
 * 一条"跳转型"设置项：图标 + 文字 + 右箭头
 * 图标和文案都是静态的，所以不加装饰器
 *
 * 导出给算法参数设置页复用，保证两页的行长得一模一样
 */
@Component
export struct SettingRow {
  icon: Resource = $r('sys.symbol.gearshape');
  iconColor: string = COLOR_PURPLE;
  iconBg: string = ICON_BG_PURPLE;
  label: string = '';
  /** 危险操作（退出登录）用红色文字 */
  labelColor: string = TEXT_PRIMARY;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: ICON_GAP }) {
      this.IconBox(this.icon, this.iconColor, this.iconBg)

      Text(this.label)
        .fontSize(15)
        .fontColor(this.labelColor)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([TEXT_TERTIARY])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: ROW_PADDING_H, right: ROW_PADDING_H })
    .onClick(() => {
      this.onTap();
    })
  }

  @Builder
  IconBox(icon: Resource, color: string, bg: string) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([color])
    }
    .width(ICON_BOX)
    .height(ICON_BOX)
    .borderRadius(ICON_BOX_RADIUS)
    .backgroundColor(bg)
  }
}

/**
 * 一条"开关型"设置项：图标 + 文字 + 右侧开关
 */
@Component
struct SettingToggleRow {
  icon: Resource = $r('sys.symbol.gearshape');
  iconColor: string = COLOR_TEAL;
  iconBg: string = ICON_BG_TEAL;
  label: string = '';
  /** 开关状态要跟着页面刷新，用 @Prop */
  @Prop isOn: boolean = false;
  onChange: (value: boolean) => void = () => {
  };

  build() {
    Row({ space: ICON_GAP }) {
      Stack() {
        SymbolGlyph(this.icon)
          .fontSize(18)
          .fontColor([this.iconColor])
      }
      .width(ICON_BOX)
      .height(ICON_BOX)
      .borderRadius(ICON_BOX_RADIUS)
      .backgroundColor(this.iconBg)

      Text(this.label)
        .fontSize(15)
        .fontColor(TEXT_PRIMARY)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(ACCENT)
        .onChange((value: boolean) => {
          this.onChange(value);
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: ROW_PADDING_H, right: ROW_PADDING_H })
  }
}

/** 设置页内容：由主页的「设置」Tab 承载 */
@Component
export struct Settings {
  /** 主页传进来，方便以后从设置里跳子页面 */
  @State navPathStack: NavPathStack = new NavPathStack();

  /** 开关状态（还没有落盘，退出应用就丢） */
  @State syncToCloud: boolean = true;
  @State oneHandMode: boolean = false;

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // ================= 用户资料 =================
        Row({ space: 14 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.person_fill'))
              .fontSize(30)
              .fontColor([ACCENT])
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(ICON_BG_RED)

          Column({ space: 4 }) {
            Text(USER_NAME)
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_PRIMARY)
            Text(USER_ID)
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([TEXT_TERTIARY])
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD_BG)
        .borderRadius(18)
        .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
        .onClick(() => {
          this.rowTap('账号');
        })

        // ================= 通用 =================
        Column({ space: 8 }) {
          Text('通用')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .width('100%')
            .padding({ left: 4 })

          Column() {
            SettingRow({
              icon: $r('sys.symbol.paintpalette'),
              iconColor: COLOR_PURPLE,
              iconBg: ICON_BG_PURPLE,
              label: '应用主题设置',
              onTap: () => {
                this.rowTap('应用主题设置');
              }
            })
            this.RowDivider()
            SettingRow({
              icon: $r('sys.symbol.waveform'),
              iconColor: COLOR_TEAL,
              iconBg: ICON_BG_TEAL,
              label: '算法参数设置',
              onTap: () => {
                // 算法参数是独立页面（有返回键），push 进去而不是在设置页里展开
                this.navPathStack.pushPathByName('Algorithm_Settings_Page', null, true);
              }
            })
            this.RowDivider()
            SettingRow({
              icon: $r('sys.symbol.info_circle'),
              iconColor: COLOR_ORANGE,
              iconBg: ICON_BG_ORANGE,
              label: '关于应用',
              onTap: () => {
                this.rowTap('关于应用');
              }
            })
            this.RowDivider()
            SettingRow({
              icon: $r('sys.symbol.arrow_right_up_and_square'),
              iconColor: COLOR_RED,
              iconBg: ICON_BG_RED,
              label: '退出登录',
              labelColor: COLOR_RED,
              onTap: () => {
                this.askLogout();
              }
            })
          }
          .width('100%')
          .backgroundColor(CARD_BG)
          .borderRadius(16)
          .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
          .clip(true) //让分割线不会溢出圆角
        }
        .width('100%')

        // ================= 同步 =================
        Column({ space: 8 }) {
          Text('同步')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .width('100%')
            .padding({ left: 4 })

          Column() {
            SettingToggleRow({
              icon: $r('sys.symbol.icloud'),
              iconColor: COLOR_TEAL,
              iconBg: ICON_BG_TEAL,
              label: '同步数据到云端',
              isOn: this.syncToCloud,
              onChange: (value: boolean) => {
                this.syncToCloud = value;
              }
            })
            this.RowDivider()
            SettingToggleRow({
              icon: $r('sys.symbol.onehand'),
              iconColor: COLOR_ORANGE,
              iconBg: ICON_BG_ORANGE,
              label: '启动单手模式',
              isOn: this.oneHandMode,
              onChange: (value: boolean) => {
                this.oneHandMode = value;
              }
            })
            this.RowDivider()
            SettingRow({
              icon: $r('sys.symbol.externaldrive'),
              iconColor: COLOR_PURPLE,
              iconBg: ICON_BG_PURPLE,
              label: '设置第三方音乐服务器',
              onTap: () => {
                this.rowTap('设置第三方音乐服务器');
              }
            })
          }
          .width('100%')
          .backgroundColor(CARD_BG)
          .borderRadius(16)
          .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
          .clip(true)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: BOTTOM_RESERVE })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .backgroundColor(PAGE_BG)
    // 主页的标题栏是悬浮在内容之上的，这里让出它的高度
    .padding({ top: $r('sys.float.single_line_titlebar_height') })
  }

  /** 行之间的淡分割线：从文字左边开始，和歌曲列表那边一个样式 */
  @Builder
  RowDivider() {
    Divider()
      .strokeWidth(1)
      .color(DIVIDER_COLOR)
      .margin({ left: DIVIDER_INSET })
  }

  /** 所有条目都还没做，先给个反馈方便确认哪个点到了 */
  private rowTap(name: string): void {
    console.info('设置项：' + name);
    this.toast(name + '：功能待接入');
  }

  /** showToast 会抛异常，包一层（不处理的话 ArkTS 会报 "Function may throw exceptions"） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      console.error('showToast 失败：' + JSON.stringify(err));
    }
  }

  /** 退出登录：破坏性操作，先确认 */
  private askLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录？',
      message: '退出后需要重新登录才能同步数据',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        action: () => {
          this.toast('已退出登录（演示）');
        }
      }
    });
  }
}
