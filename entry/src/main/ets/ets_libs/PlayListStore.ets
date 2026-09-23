import { UIAbility } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import { fileIo } from "@kit.CoreFileKit";

export const SONG_LIST_REVISION_KEY: string = 'songListStoreRevision';

/**
 * 歌单列表页选中的歌单下标（AppStorage）——播放器据此组装播放队列。
 * ⚠️ 别删：Playlist.ets 和 Player.ets 都在 import 它
 *    （Playlist 写入、Player 读取），删掉会直接编译不过。
 */
export const ACTIVE_PLAYLIST_KEY: string = 'activePlaylistIndex';

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
  /**
   * 音频文件名（含扩展名），即 Media 目录内的实际文件名。
   * ★ 删除时必须靠它精确定位文件：显示名 name 与文件名可能不同
   *   （重名导入会存成 xxx-1.wav，而 name 仍是容器里的标题），
   *   所以不能拿 name 反推文件名。
   * 旧数据没有这个字段，读出来可能是 undefined，用之前必须判空。
   */
  filename?: string;
}

export interface totalSongList{
  songList: SongJSON[];
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
  filename?: string;
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

/**
 * 从**所有已保存的歌单**里剔除某首歌。
 *
 * 为什么删歌时必须调用：歌单 json 里存的是各自的 songList **副本**
 * （saveAt 的调用方各自组装），歌从曲库删掉后那些副本不会自动消失。
 * 不清理的话，歌单里会残留一条指向已删文件的 filename —— 播放器按
 * filename 去 song_data.json / Media 找文件必然落空，表现为"歌单里少歌"。
 *
 * 匹配规则与删除主流程保持一致：
 *   ① filename 非空 → 按 filename 精确匹配（稳定 id）
 *   ② filename 为空（早期数据）→ 退回按 name 匹配
 *
 * @param filename 音频文件名（含扩展名），可为空串
 * @param name     展示名，作为 filename 缺失时的兜底
 * @return 被改动过的歌单数量
 */
export function removeSongFromAllPlaylists(ctx: common.UIAbilityContext,
                                           filename: string,
                                           name: string): number {
  const dir: string = ensureDir(ctx);
  if (dir.length === 0) {
    return 0;
  }
  const idx: number[] = listIndexes(ctx);
  let touched: number = 0;

  for (let i = 0; i < idx.length; i++) {
    const path: string = dir + '/' + idx[i].toString() + '.json';
    let file: SongListJSON;
    try {
      const text: string = fileIo.readTextSync(path);
      file = parseFile(text, idx[i]);
    } catch (err) {
      console.error('读歌单失败，跳过：' + path + ' ' + JSON.stringify(err));
      continue;
    }

    const src: SongJSON[] = file.songList;
    const next: SongJSON[] = [];
    let hit: boolean = false;
    for (let k = 0; k < src.length; k++) {
      const cur: SongJSON = src[k];
      if (cur === undefined || cur === null) {
        continue;
      }
      const curFn: string = (cur.filename !== undefined && cur.filename !== null)
        ? cur.filename : '';
      let match: boolean = false;
      if (filename.length > 0) {
        match = (curFn === filename);
      } else {
        match = (cur.name === name);
      }
      if (match) {
        hit = true;
        continue;      // 丢掉这一条
      }
      next.push(cur);
    }

    if (hit) {
      file.songList = next;
      // writeFile 用 TRUNC 打开，不会留旧尾巴
      if (writeFile(path, file)) {
        touched++;
        console.info('已从歌单 ' + idx[i].toString() + '.json 中移除歌曲');
      }
    }
  }

  if (touched > 0) {
    bumpRevision();     // 让歌单列表 / 播放器重读
  }
  return touched;
}

/** 歌单数目 */
export function count(ctx: common.UIAbilityContext): number {
  return listIndexes(ctx).length;
}