import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 曲线 / 标签的本地存储
 *
 * 位置：<filesDir>/Curve/，也就是
 *   /data/storage/el2/base/haps/entry/files/Curve/
 * 一条曲线一个 json 文件，**文件名就是它在列表里的序号**：第 1 条是 1.json、第 2 条是 2.json……
 * 所以增删之后要保证文件名连续（删了 2.json，原来的 3.json 要改名成 2.json）。
 *
 * ⚠️ 单位：文件里的 time 是**秒**，而曲线编辑页界面上用的是**分钟**。
 *    转换统一走 secToMin() / minToSec()，别在别处手写 /60。
 */

/**
 * 曲线数据的全局版本号（放在 AppStorage 里）。
 *
 * 为什么需要它：编辑页保存后，列表页要重读磁盘缩略图才会变。
 * 最自然的做法是 pushPathByName 的 onPop 回调，但是**实测标签编辑页返回时那个回调不触发**，
 * 靠它就会出现"json 明明改了、列表却不刷新"。
 * 改成"谁写盘谁把版本号 +1"，列表页 @Watch 监听它，就跟用户怎么退出编辑页无关了。
 */
export const CURVE_REVISION_KEY: string = 'curveStoreRevision';

/** 通知外界：曲线数据变了（saveAt / appendCurve / deleteAt 内部调用） */
export function bumpRevision(): void {
  const n: number | undefined = AppStorage.get<number>(CURVE_REVISION_KEY);
  AppStorage.setOrCreate<number>(CURVE_REVISION_KEY, (n === undefined ? 0 : n) + 1);
}

/** JSON 里一个曲线点 */
export interface CurvePointJson {
  /** 时间（秒） */
  time: number;
  bpm: number;
  /** 插值方式，目前固定 "linear" */
  type: string;
}

/** JSON 里一个标签 */
export interface CurveTagJson {
  /** 时间（秒） */
  time: number;
  text: string;
}

/** 一个曲线文件的完整内容 */
export interface CurveFile {
  name: string;
  points: CurvePointJson[];
  tags: CurveTagJson[];
}

/** 解析时用的宽松类型（文件可能缺字段） */
interface CurveFileRaw {
  name?: string;
  points?: CurvePointJson[];
  tags?: CurveTagJson[];
}

/** 曲线文件夹名 */
export const CURVE_DIR: string = 'Curve';

/**
 * 跳转到曲线编辑 / 标签编辑页时传的参数
 * 只传"第几条"，编辑页自己去磁盘读那个 json（曲线内容可能很大，不适合塞进路由参数）
 */
export interface CurveEditParam {
  /** 曲线在列表里的下标，0 开始；-1 表示"还没绑定文件" */
  index: number;
}

/** 插值方式：目前只支持线性 */
export const POINT_TYPE_LINEAR: string = 'linear';

/** 卡片缩略图用的 BPM 量程（把 bpm 映射成 0~1 的 y） */
const PREVIEW_BPM_MIN: number = 80;
const PREVIEW_BPM_MAX: number = 240;

// ==================== 单位换算 ====================

/** 秒 → 分钟 */
export function secToMin(sec: number): number {
  return sec / 60;
}

/** 分钟 → 秒 */
export function minToSec(min: number): number {
  return min * 60;
}

// ==================== 路径 ====================

/** 曲线文件夹的绝对路径（不创建） */
export function curveDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + CURVE_DIR;
}

/** 确保文件夹存在，返回它的路径 */
export function ensureDir(ctx: common.UIAbilityContext): string {
  const dir: string = curveDir(ctx);
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
  return dir;
}

/** 第 index 条（0 开始）对应的文件名：1.json、2.json … */
export function fileNameOf(index: number): string {
  return (index + 1).toString() + '.json';
}

// ==================== 造数据 ====================

/** 新建曲线时用的初始内容：头尾两点、一条恒定 120 BPM 的直线 */
export function emptyCurve(name: string, totalMinutes: number): CurveFile {
  const pts: CurvePointJson[] = [];
  pts.push({ time: 0, bpm: 120, type: POINT_TYPE_LINEAR });
  pts.push({ time: minToSec(totalMinutes), bpm: 120, type: POINT_TYPE_LINEAR });
  const tags: CurveTagJson[] = [];
  const file: CurveFile = { name: name, points: pts, tags: tags };
  return file;
}

/** 只改标签、保留原来的曲线：读 → 换掉 tags → 写回 */
export function makeWithTags(src: CurveFile, tags: CurveTagJson[]): CurveFile {
  const file: CurveFile = { name: src.name, points: src.points, tags: tags };
  return file;
}

// ==================== 读 ====================

/** "n.json" → n；不是这个形式返回 -1 */
function indexOfFileName(name: string): number {
  if (!name.endsWith('.json')) {
    return -1;
  }
  const n: number = Number.parseInt(name.substring(0, name.length - 5), 10);
  if (Number.isNaN(n) || n < 1) {
    return -1;
  }
  return n;
}

/** 文件夹里所有曲线的序号，从小到大 */
function listIndexes(ctx: common.UIAbilityContext): number[] {
  const dir: string = ensureDir(ctx);
  const names: string[] = fileIo.listFileSync(dir);
  const idx: number[] = [];
  for (let i = 0; i < names.length; i++) {
    const n: number = indexOfFileName(names[i]);
    if (n > 0) {
      idx.push(n);
    }
  }
  idx.sort((a: number, b: number): number => a - b);
  return idx;
}

function parseCurve(text: string): CurveFile {
  try {
    const raw: CurveFileRaw = JSON.parse(text) as CurveFileRaw;
    const file: CurveFile = {
      name: raw.name !== undefined ? raw.name : '',
      points: raw.points !== undefined ? raw.points : [],
      tags: raw.tags !== undefined ? raw.tags : []
    };
    return file;
  } catch (err) {
    console.error('解析曲线 JSON 失败：' + JSON.stringify(err));
    const bad: CurveFile = { name: '', points: [], tags: [] };
    return bad;
  }
}

/** 读出全部曲线，顺序就是列表顺序（1.json 排第一） */
export function loadAll(ctx: common.UIAbilityContext): CurveFile[] {
  const dir: string = ensureDir(ctx);
  const idx: number[] = listIndexes(ctx);
  const out: CurveFile[] = [];
  for (let i = 0; i < idx.length; i++) {
    const path: string = dir + '/' + idx[i].toString() + '.json';
    try {
      const text: string = fileIo.readTextSync(path);
      out.push(parseCurve(text));
    } catch (err) {
      console.error('读曲线失败：' + path + ' ' + JSON.stringify(err));
    }
  }
  return out;
}

/** 曲线条数 */
export function count(ctx: common.UIAbilityContext): number {
  return listIndexes(ctx).length;
}

// ==================== 写 ====================

function writeJson(path: string, file: CurveFile): boolean {
  try {
    const text: string = JSON.stringify(file);
    const f: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, text);
    fileIo.closeSync(f);
    return true;
  } catch (err) {
    console.error('写曲线失败：' + path + ' ' + JSON.stringify(err));
    return false;
  }
}

/** 覆盖写第 index 条曲线 */
export function saveAt(ctx: common.UIAbilityContext, index: number, file: CurveFile): boolean {
  const dir: string = ensureDir(ctx);
  const ok: boolean = writeJson(dir + '/' + fileNameOf(index), file);
  if (ok) {
    bumpRevision(); //写成了才通知，免得列表白刷一次
  }
  return ok;
}

/** 追加一条曲线，成为最后那个编号；返回它的下标，失败返回 -1 */
export function appendCurve(ctx: common.UIAbilityContext, file: CurveFile): number {
  const idx: number[] = listIndexes(ctx);
  const nextIndex: number = idx.length; //0 开始的下标 = 已有条数
  const dir: string = ensureDir(ctx);
  const ok: boolean = writeJson(dir + '/' + fileNameOf(nextIndex), file);
  if (ok) {
    bumpRevision();
  }
  return ok ? nextIndex : -1;
}

/**
 * 删除第 index 条，并把后面的文件依次改名上前一位
 * （文件名就是序号，所以删了中间那条必须重排，否则列表顺序和文件名对不上）
 */
export function deleteAt(ctx: common.UIAbilityContext, index: number): boolean {
  const dir: string = ensureDir(ctx);
  const idx: number[] = listIndexes(ctx);
  const target: number = index + 1;
  const targetPath: string = dir + '/' + target.toString() + '.json';
  if (!fileIo.accessSync(targetPath)) {
    return false;
  }
  try {
    fileIo.unlinkSync(targetPath);
  } catch (err) {
    console.error('删除曲线失败：' + JSON.stringify(err));
    return false;
  }
  for (let i = 0; i < idx.length; i++) {
    const n: number = idx[i];
    if (n > target) {
      try {
        fileIo.renameSync(dir + '/' + n.toString() + '.json',
          dir + '/' + (n - 1).toString() + '.json');
      } catch (err) {
        console.error('重排曲线文件失败：' + JSON.stringify(err));
      }
    }
  }
  bumpRevision(); //删完并且重排完了，列表再重读
  return true;
}

// ==================== 给卡片缩略图用 ====================

/**
 * 把曲线点转成缩略图要的 0~1 y 值（0 = 顶部，1 = 底部）
 * 注意：卡片上的折线目前是**按点等距**画的，没按真实时间间隔，只是形状示意
 */
export function pointsToPreview(points: CurvePointJson[]): number[] {
  const out: number[] = [];
  for (let i = 0; i < points.length; i++) {
    let v: number = 1 - (points[i].bpm - PREVIEW_BPM_MIN) / (PREVIEW_BPM_MAX - PREVIEW_BPM_MIN);
    if (v < 0) {
      v = 0;
    }
    if (v > 1) {
      v = 1;
    }
    out.push(v);
  }
  return out;
}
