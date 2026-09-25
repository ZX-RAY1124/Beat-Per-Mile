/**
 * StepSensor.ets —— 真实步频数据源（加速度计）
 *
 * 链路：@kit.SensorServiceKit 订阅 ACCELEROMETER（单位 m/s²、含重力，与 native GaitSim 同一约定）
 *   → 攒批（每 5 个样点 ≈ 100ms）→ libentry.stepSensorPush()
 *   → native StepDetector → TempoFollower → 倍速
 *
 * ★ 与模拟源共用同一条 native 管线（napi_bridge_center.cpp 里的 g_stepPipeline），
 *   由 stepSensorStart() / stepSensorStop() 切换。
 * ★ 订阅是**进程内单例**：播放器和「设置 → 传感器测试」共用，避免重复订阅。
 */
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { stepSensorPush, stepPipelineStatus } from 'libentry.so';

/** 调试/测试信息（AppStorage，JSON 字符串）：设置页读它显示 */
export const SENSOR_DEBUG_KEY: string = 'stepSensorDebug';

/** 目标采样率（Hz）与攒批大小：50Hz → 每 5 个样点一批 ≈ 100ms */
const TARGET_HZ: number = 50;
const BATCH_N: number = 5;
/** interval 单位是纳秒；加速度计支持 5,000,000 ~ 200,000,000 ns */
const INTERVAL_NS: number = 1000000000 / TARGET_HZ;

/** 推给 AppStorage 的调试快照 */
export interface SensorDebug {
  running: boolean;
  x: number;
  y: number;
  z: number;
  /** 实测回调频率（Hz） */
  hz: number;
  /** 累计样点数 */
  samples: number;
  /** native 检测到的步频（步/分） */
  cadence: number;
  /** native 累计步数 */
  steps: number;
  error: string;
}

/** stepPipelineStatus() 里我们用到的字段 */
interface PipelineStatusLite {
  cadenceSpm: number;
  steps: number;
}

class StepSensorHub {
  private running: boolean = false;
  private ax: number[] = [];
  private ay: number[] = [];
  private az: number[] = [];
  private total: number = 0;
  private winStartMs: number = 0;
  private winCount: number = 0;
  private hz: number = 0;
  private lastX: number = 0;
  private lastY: number = 0;
  private lastZ: number = 0;
  private cadence: number = 0;
  private steps: number = 0;
  private err: string = '';

  isRunning(): boolean { return this.running; }

  /** 当前调试快照。★ 设置页用定时轮询读它（AppStorage/@Watch 那条路不刷新） */
  snapshot(): SensorDebug {
    const d: SensorDebug = {
      running: this.running,
      x: this.lastX,
      y: this.lastY,
      z: this.lastZ,
      hz: this.hz,
      samples: this.total,
      cadence: this.cadence,
      steps: this.steps,
      error: this.err
    };
    return d;
  }

  /** 开始订阅（已在跑则直接返回 true）；失败原因写进调试快照 */
  start(): boolean {
    if (this.running) { return true; }
    this.reset();
    this.winStartMs = Date.now();
    try {
      const opt: sensor.Options = { interval: INTERVAL_NS };
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.onData(data.x, data.y, data.z);
      }, opt);
      this.running = true;
      this.publish();
      console.info('[StepSensor] 已订阅加速度计');
      return true;
    } catch (e) {
      const be = e as BusinessError;
      this.err = 'sensor.on 失败 ' + be.code + ': ' + be.message;
      console.error('[StepSensor] ' + this.err);
      this.publish();
      return false;
    }
  }

  /** 停止订阅并清空缓存 */
  stop(): void {
    if (!this.running) { return; }
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (e) {
      const be = e as BusinessError;
      this.err = 'sensor.off 失败 ' + be.code;
    }
    this.running = false;
    this.reset();
    this.publish();
    console.info('[StepSensor] 已取消订阅');
  }

  private reset(): void {
    this.ax = [];
    this.ay = [];
    this.az = [];
    this.total = 0;
    this.winCount = 0;
    this.hz = 0;
    this.cadence = 0;
    this.steps = 0;
  }

  private onData(x: number, y: number, z: number): void {
    this.lastX = x;
    this.lastY = y;
    this.lastZ = z;
    this.ax.push(x);
    this.ay.push(y);
    this.az.push(z);
    this.total++;
    this.winCount++;
    const now: number = Date.now();
    const dt: number = now - this.winStartMs;
    if (dt >= 1000) {
      this.hz = this.winCount * 1000 / dt;
      this.winCount = 0;
      this.winStartMs = now;
    }
    if (this.ax.length >= BATCH_N) {
      this.flush();
    }
    if (this.total % 10 === 0) {
      this.publish();
    }
    if (this.total % 50 === 0) {
      console.info('[StepSensor] onData total=' + this.total + ' x=' + x.toFixed(2));
    }
  }

  /** 把攒好的一批送 native；顺带刷新 native 管线的步频/步数 */
  private flush(): void {
    const n: number = this.ax.length;
    if (n === 0) { return; }
    // 摊平成一维 [x0,y0,z0, x1,y1,z1, ...]：普通 number[]，不走 typed array
    const flat: number[] = [];
    for (let i = 0; i < n; i++) {
      flat.push(this.ax[i]);
      flat.push(this.ay[i]);
      flat.push(this.az[i]);
    }
    try {
      stepSensorPush(flat, n, TARGET_HZ);
    } catch (e) {
      const be = e as BusinessError;
      this.err = 'stepSensorPush 失败 ' + be.code;
    }
    this.ax = [];
    this.ay = [];
    this.az = [];
    try {
      const st: PipelineStatusLite = JSON.parse(stepPipelineStatus()) as PipelineStatusLite;
      this.cadence = st.cadenceSpm;
      this.steps = st.steps;
    } catch (e) {
      // 管线未启动时也返回合法 JSON，这里只兜底
    }
  }

  private publish(): void {
    const d: SensorDebug = {
      running: this.running,
      x: this.lastX,
      y: this.lastY,
      z: this.lastZ,
      hz: this.hz,
      samples: this.total,
      cadence: this.cadence,
      steps: this.steps,
      error: this.err
    };
    AppStorage.setOrCreate<string>(SENSOR_DEBUG_KEY, JSON.stringify(d));
  }
}

/** 进程内单例：播放器与设置页测试共用 */
export const stepSensor: StepSensorHub = new StepSensorHub();
console.info('[StepSensor] module init (此日志出现几次 = 模块被实例化几次)');
