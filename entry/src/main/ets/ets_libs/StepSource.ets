/**
 * StepSource.ets —— "步数检测源"设置（跨页面共享）
 *
 * 存 AppStorage 而不是磁盘：这是演示/调试开关，重开 App 复位也合理。
 * 算法参数设置页写入，播放器页读取并据此决定要不要启动 native 步频管线。
 */
export const STEP_SOURCE_KEY: string = 'stepSourceMode';
export const STEP_SCENARIO_KEY: string = 'stepScenarioIndex';

/** 真实传感器（加速度计，尚未接线） */
export const SOURCE_REAL: number = 0;
/** 模拟演示（native GaitSim 合成三轴） */
export const SOURCE_SIM: number = 1;

export interface StepScenario {
  name: string;
  desc: string;
}

/**
 * 场景顺序必须与 native gaitsim::scenarios::at() 一致：
 *   0 run160 / 1 run200 / 2 runRamp / 3 runStopRun / 4 walk108 / 5 standingStill
 */
export const STEP_SCENARIOS: StepScenario[] = [
  { name: '跑步 160 步/分', desc: '常见跑距步频' },
  { name: '跑步 200 步/分', desc: '有用区间上限' },
  { name: '跑步 120→200 步/分', desc: '每 15 秒变档，考跟随速度' },
  { name: '跑 20 秒 / 停 8 秒', desc: '循环；考误报与重新起步' },
  { name: '步行 108 步/分', desc: '基准场景' },
  { name: '站立不动', desc: '无步态，出步即误报' }
];

export function getStepSource(): number {
  const v: number | undefined = AppStorage.get<number>(STEP_SOURCE_KEY);
  return v === undefined ? SOURCE_SIM : v;
}

export function setStepSource(v: number): void {
  AppStorage.setOrCreate<number>(STEP_SOURCE_KEY, v);
}

export function getStepScenario(): number {
  const v: number | undefined = AppStorage.get<number>(STEP_SCENARIO_KEY);
  if (v === undefined || v < 0 || v >= STEP_SCENARIOS.length) {
    return 0;
  }
  return v;
}

export function setStepScenario(v: number): void {
  AppStorage.setOrCreate<number>(STEP_SCENARIO_KEY, v);
}
