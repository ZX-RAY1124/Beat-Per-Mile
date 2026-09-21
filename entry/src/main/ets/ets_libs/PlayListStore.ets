import { UIAbility } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import { fileIo } from "@kit.CoreFileKit";

export const SONG_LIST_REVISION_KEY: string = 'songListStoreRevision';

/** 全局版本号，用于返回后刷新 */
export function bumpRevision(): void{
  const n : number| undefined = AppStorage.get<number>(SONG_LIST_REVISION_KEY);
  AppStorage.setOrCreate<number>(SONG_LIST_REVISION_KEY, (n === undefined ? 0 : n) + 1);
}

export enum selection {
  ONLINE,
  OFFLINE
}


/** 一首歌的JSON标签*/
export interface SongJSON {
  name: string;
  author: string,
  time: string;
  BPM: number;
  type: selection;
}

export interface SongListJSON {
  index: number,
  name: string,
  songList: SongJSON[],
  colorPlan: number
}


/** 宽字段，用于数据检查*/
export interface SongJSON_ROW {
  name?: string;
  author?: string,
  time?: string;
  BPM?: number;
  type?: selection;
}

interface songListJSON_ROW {
  index: number
  name?: string,
  songList?: SongJSON[],
  colorPlan?: number
}

/**文件夹名*/
export const MainDIR: string = 'SongList'

/** 秒 → 分钟 */
export function secToMin(sec: number): number {
  return sec / 60;
}

/** 分钟 → 秒 */
export function minToSec(min: number): number {
  return min * 60;
}



/** 文件夹的绝对路径*/
export function songListDir(ctx: common.UIAbilityContext): string{
  return ctx.filesDir + '/' + MainDIR;
}

/** 确保文件夹存在，返回它的路径 */
export function ensureDir(ctx: common.UIAbilityContext): string {
  const dir: string = songListDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  } catch (e){
    return '';   //改
  }
  return dir;
}

/** 第 index 条（0 开始）对应的文件名：1.json、2.json … */
export function fileNameOf(index: number): string {
  return (index + 1).toString() + '.json';
}


/** 解析文件 **通用类***/
function parseFile(text: string, idx: number) : SongListJSON {
  try{
    const raw : songListJSON_ROW = JSON.parse(text) as songListJSON_ROW;
    const file: SongListJSON = {
      name: raw.name !== undefined ? raw.name : '',
      songList: raw.songList !== undefined ? raw.songList : [],
      colorPlan: raw.colorPlan !== undefined ? raw.colorPlan : 0,
      index: idx ? idx : 0
    }
    return file;

  } catch (e){
    console.error('解析播放列表 JSON 失败：' + JSON.stringify(e));
    const bad: SongListJSON =  {
      name:  '',
      songList: [],
      colorPlan: 0,
      index: 0
    }
    return bad;
  }

}

function writeFile(path: string, file: SongListJSON): boolean{
  try {
    const text: string = JSON.stringify(file);
    const f: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, text);
    fileIo.closeSync(f);
    return true;
  } catch (err) {
    console.error('写歌单失败：' + path + ' ' + JSON.stringify(err));
    return false;
  }

}

/** 覆盖写第 index 个歌单 */
export function saveAt(ctx: common.UIAbilityContext, index: number, file: SongListJSON): boolean {
  const dir: string = ensureDir(ctx);
  const ok: boolean = writeFile(dir + '/' + fileNameOf(index), file);
  if (ok) {
    bumpRevision(); //写成了才通知，免得列表白刷一次
  }
  return ok;
}

/** 追加歌曲列表，成为最后那个编号；返回它的下标，失败返回 -1 */
export function appendSongList(ctx: common.UIAbilityContext, file: SongListJSON): number {
  const idx: number[] = listIndexes(ctx);
  const nextIndex: number = idx.length; //0 开始的下标 = 已有条数
  const dir: string = ensureDir(ctx);
  const ok: boolean = writeFile(dir + '/' + fileNameOf(nextIndex), file);
  if (ok) {
    bumpRevision();
  }
  return ok ? nextIndex : -1;
}

/** 删除索引对应的文件*/
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
    console.error('删除歌单失败：' + JSON.stringify(err));
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

/** 读出全部曲线，顺序就是列表顺序（1.json 排第一） */
export function loadAll(ctx: common.UIAbilityContext): SongListJSON[] {
  const dir: string = ensureDir(ctx);
  const idx: number[] = listIndexes(ctx);
  const out: SongListJSON[] = [];
  for (let i = 0; i < idx.length; i++) {
    const path: string = dir + '/' + idx[i].toString() + '.json';
    try {
      const text: string = fileIo.readTextSync(path);
      out.push(parseFile(text, idx[i]));
    } catch (err) {
      console.error('读曲线失败：' + path + ' ' + JSON.stringify(err));
    }
  }
  return out;
}

/** 歌单数目 */
export function count(ctx: common.UIAbilityContext): number {
  return listIndexes(ctx).length;
}