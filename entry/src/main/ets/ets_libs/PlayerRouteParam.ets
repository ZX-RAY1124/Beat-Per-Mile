/**
 * 主页 → MainPlayer 的路由参数。
 *
 * 红/绿两个圆共用同一个路由 `Main_Play_Page`，模式由入口决定，进页后不再切换：
 *   红圆 → MODE_DYNAMIC（动态检测）
 *   绿圆 → MODE_CONSTANT（"预设"：选了有效曲线走曲线，否则恒速，由 MainPlayer 内部再判定）
 */
export interface MainPlayerParam {
  /** RunDemoEngine 的 MODE_*；绿圆固定传 MODE_CONSTANT 表示"预设" */
  mode: number;
  /** 窗口宽度：MainPlayer 里圆的定位要用 */
  width: number;
}
