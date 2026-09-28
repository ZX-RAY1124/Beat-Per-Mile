/**
 * StretchEngine.ets —— "变速引擎"设置（跨页面共享，落盘）
 *
 * 两个选项对应 native 的 g_stretchEngine（见 napi_bridge_center.cpp::setStretchEngineMode）：
 *   ENGINE_SIGNALSMITH = 0：自研 SignalSmith Stretch（默认）。LiveStretchPlayer 按倍速变速，
 *                          渲染器倍速固定 1.0。
 *   ENGINE_AUDIOKIT    = 1：系统 Audio Kit。引擎跑 speed=1.0 原速直通、产线程按倍速产出，
 *                          真正的变速交给 OH_AudioRenderer_SetSpeed（系统 Sonic，锁音高）。
 *
 * ★ 与 StepSource.ets 的区别：这里是用户可见的正式设置，用 PersistentStorage 落盘
 *   （和 Main.ets 的当前歌单同一套做法），杀进程/装新包后仍然记得。
 * ★ native 侧是全局开关，任意时刻所有在响的流共用同一个引擎。
 */
export const STRETCH_ENGINE_KEY: string = 'stretchEngineMode';

/** 自研 SignalSmith Stretch（默认） */
export const ENGINE_SIGNALSMITH: number = 0;
/** 系统 Audio Kit：OH_AudioRenderer_SetSpeed */
export const ENGINE_AUDIOKIT: number = 1;

/**
 * 落盘。放在模块顶层：任何页面调用 getStretchEngine() 之前本模块必已加载，
 * 磁盘值已经接上，不需要各页面各自 persist 一遍。
 */
PersistentStorage.persistProp<number>(STRETCH_ENGINE_KEY, ENGINE_SIGNALSMITH);

/** 读当前选择；值非法（未落盘 / 越界）时回到默认的 SignalSmith */
export function getStretchEngine(): number {
  const v: number | undefined = AppStorage.get<number>(STRETCH_ENGINE_KEY);
  if (v === undefined || (v !== ENGINE_SIGNALSMITH && v !== ENGINE_AUDIOKIT)) {
    return ENGINE_SIGNALSMITH;
  }
  return v;
}

/** 写选择。只接受两个合法值，其它一律归到默认 */
export function setStretchEngine(v: number): void {
  const n: number = (v === ENGINE_AUDIOKIT) ? ENGINE_AUDIOKIT : ENGINE_SIGNALSMITH;
  AppStorage.setOrCreate<number>(STRETCH_ENGINE_KEY, n);
}
