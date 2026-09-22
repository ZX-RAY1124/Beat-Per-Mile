export const add: (a: number, b: number) => number;
export const squire:(a: number, b: number ) => number;
export const test_audio:(name:string) => string;
export const music_play: (url:string, callback : (progress: number) => void) => number;
export const music_resume:(id: number) => void;
export const music_pause:(id:number) => void;
export const music_cancel:(id: number) => void;
export const changeSpeed:(speed: number) => void;
/** ⚠️ 旧接口：同步执行，会阻塞主线程（长音频触发 THREAD_BLOCK_6S），且不回传结果。仅保留兼容，勿在新代码使用 */
export const musicAnalyse:(path: string) => void;
/** 分析返回的歌曲信息（字段名与 PlayListStore 的 SongJSON 对齐） */
export interface SongMeta {
  /** 歌曲名。容器无 title 标签时退回文件名（去扩展名） */
  name: string;
  /** 作者/艺术家。容器无该标签时为空串 */
  author: string;
  /** 总时长，形如 "3:42"；超过 1 小时为 "1:02:03" */
  time: string;
  /** 检测到的 BPM */
  BPM: number;
}

/**
 * 异步分析音频文件，并在**与音频文件相同的目录**下生成 `<同名去扩展名>_beats.csv`。
 * 立即返回，分析在 native 工作线程进行。
 * @param path 沙箱内音频文件的绝对路径
 * @param callback 成功时 meta 为 SongMeta；失败时 meta 为 null 且 err 给出原因
 */
export const analyzeMusicAsync: (path: string,
  callback: (meta: SongMeta | null, err?: string) => void) => void;
/**
 * 轮询分析进度（用于把"还要等多久 / 卡在哪一步"显示出来）。
 * 返回 JSON 字符串：{"phase":"decode|detect|write|done|failed|idle","pct":0~100 或 -1,
 *                    "elapsedMs":number,"running":boolean,"error":string}
 * 建议 setInterval 每 300~500ms 调一次，done/failed 时停掉定时器。
 */
export const getAnalyseStatus: () => string;
