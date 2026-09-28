# `MainPlayer.ets`界面说明文档

> 最后更新：2026-09-28
>
> **现状**：`MainPlayer.ets`（`entry/src/main/ets/pages/MainPlayer.ets`，共 1849 行）是**正式播放器**，
> 入口是主页的两个大圆（路由 `Main_Play_Page`）。它已经不再是早期那个"只有演示数学、不发声"的版本：
> 现在同时接了真实出声（`NativeAudio`）、native 步频闭环（`stepPipeline*` / `stepSensor*`）、
> 预解码接歌硬切、八度对齐、摇杆擦洗、TTS 标签播报。旧的「预览播放器」`Player.ets` 只作为回归测试，
> 保留在「设置 → 预览播放器（测试）」里。
>
> 本文行号以 2026-09-28 的 `MainPlayer.ets` 为准；涉及核心库时一并标注来源文件。

---

## 一、页面定位与入口：模式在进页时决定，进页后不切换

`MainPlayer.ets:51-62` 的顶部注释给出了这一版的设计边界：

- **正式播放器**：把「预览播放器」(`Player.ets`) 的播放能力搬进来，成为真正出声的播放界面；
- **模式由入口决定，进页后不切换**：红圆 = 动态，绿圆 = 预设（选了有效曲线走曲线，否则恒速）；
- **进度环沿用"每秒轮询 + Progress 动画"**，但角度改用引擎的真实歌曲位置来求（见 §七）。

入口链路如下：

| 入口 | 路由参数 | 落到的模式 |
|---|---|---|
| 主页红圆「动态模式」`Main.ets:426` | `{ mode: MODE_DYNAMIC, width }` | `MODE_DYNAMIC`（native 步频闭环） |
| 主页绿圆「固定模式」`Main.ets:484` | `{ mode: MODE_CONSTANT, width }` | 有效曲线 → `MODE_CURVE`；否则 `MODE_CONSTANT` |

- 路由参数类型是 `MainPlayerParam { mode: number; width: number }`（`ets_libs/PlayerRouteParam.ets:8-13`），
  路由 `Main_Play_Page → MainPlayer.ets` 注册在 `resources/base/profile/router_map.json:53-57`。
- 页面在 `.onReady()` 里取参并调 `applyEntryMode()`（`MainPlayer.ets:848-873`）；
  判定逻辑在 `MainPlayer.ets:948-954`：只有明确传 `MODE_DYNAMIC` 才是动态，其余都当"预设"，
  再由 `this.hasCurve` 决定走曲线还是恒速。
- `hasCurve` 在 `aboutToAppear()` 里读 `ACTIVE_CURVE_KEY`（曲线列表页写入、`CurveList.ets:614`）：
  下标 ≥ 1 且该曲线文件点数 ≥ 2 时才 `setCurvePoints` + `setTagList`（`MainPlayer.ets:305-337`）。
- `.onReady()` 里还会**进入即播**：`engine.setPlaying(true)` → `startNative()` → `startPipeline()`
  → `noteSessionStart()` → `pullStatus()`（`MainPlayer.ets:863-872`）。

> ⚠️ 页面内**没有**切换模式的控件。想做"模式可切换"，要改的是主页入口或这里新增 UI，而不是这个页面已经写好的逻辑。

---

## 二、依赖模块（import 清单）

`MainPlayer.ets:1-49` 导入：

| 来源 | 用途 |
|---|---|
| `ets_libs/PlayListStore` | `SongJSON / SongListJSON / ACTIVE_PLAYLIST_KEY / loadAll`：歌单与"当前歌单"下标 |
| `ets_libs/RunDemoEngine` | `MODE_*`、`RunDemoEngine`、`RunStatus`、曲库/歌单解析、当前歌曲键 |
| `ets_libs/CurveStore` | `ACTIVE_CURVE_KEY / CurveFile / loadAll`：选中曲线与标签 |
| `ets_libs/NativeAudio` | `NativeAudio`、`NativePlayStatus`、`HARD_CUT_LEAD_MS / HARD_CUT_FADE_MS` |
| `libentry.so` | `stepPipelineStart/Stop/Status/SetChaseDelayWindow`、`stepSensorStart/Stop` |
| `ets_libs/StepSource` | `SOURCE_REAL / SOURCE_SIM`、`getChaseDelaySec / getStepScenario / getStepSource` |
| `ets_libs/StepSensor` | 真实加速度计订阅单例（`stepSensor`） |
| `ets_libs/StretchEngine` | `getStretchEngine()`：SignalSmith / Audio Kit 变速引擎选择 |
| `ets_libs/PlayerRouteParam` | `MainPlayerParam` |
| `ets_libs/TtsManager` | `voiceSpeaker`：标签到点 TTS 播报 |
| `@ohos.multimodalAwareness.motion` | `holdingHandChanged`：握持时把右侧悬浮栏移出屏幕 |

---

## 三、界面分区

整页根节点是 `HdsNavDestination`（`build()` 在 `MainPlayer.ets:636-882`），标题栏显示 `this.statusText`
（`MainPlayer.ets:881`）。从上到下分成 6 个区：

### 1. 顶部统计卡（BPM / 运动时间 / 歌曲倍速）

- 三栏 `Column`（`MainPlayer.ets:639-681`），依次绑定：
  `this.BPM_now`（当前目标步频）、`this.sport_time`（运动时间 `[时,分,秒]`）、
  `this.Speed`（歌曲倍速）+ `this.octaveMult`（八度对齐附加倍率，显示成 `x1.00` 这样的小字）。
- 下面是一条**只读**的 `Slider`，表示"总歌单播放进度"（`MainPlayer.ets:684-699`）：
  `value = this.playlistProgress`，并显式设了 `.hitTestBehavior(HitTestMode.None)`，用户拖不动。
- 变量确实就是 `this.BPM_now / this.sport_time / this.Speed`（声明在 `MainPlayer.ets:166-168`），
  在 `pullStatus()` 里统一回填（`MainPlayer.ets:1677-1679`）。

### 2. 歌曲信息卡（`Song_Column`，`MainPlayer.ets:528-585`）

定位 `position({ x: 25, y: 240 })`，内含：

- 唱片图标；
- `this.songTimePass`（已播 `+mm:ss`）与 `this.songTimeLast`（剩余 `-mm:ss`）；
- `Marquee` 滚动的歌名 `this.songName` 与作者 `this.Artist`（短文本自然静止，长文本在组件边界内滚动）；
- `this.rawSongBpm + 'BPM（' + this.levelSongBpm + 'BPM）'`：原始分析 BPM（括号内是选定八度层级后的 BPM）。

作者来自当前歌单条目 `authorFor()`（`MainPlayer.ets:970-984`），曲库本身不存作者。

### 3. 速度卡（`SpeedCard`，`MainPlayer.ets:392-462`）——恒速滑块与曲线预告共用同一个框

固定 `width(250)`、`position({ x: 25, y: 500 })`、`zIndex(2)`。两个内容互斥，由 `pullStatus()` 决定显示哪个：

- `this.showConstSlider`（`mode === MODE_CONSTANT`）：**目标步频滑块**（120~220，step 1）。
  拖动即 `engine.setConstBpm()`，下面的文案实时算 `倍速 = 目标步频 ÷ 层级BPM`。
- `this.showCurvePreview`（`mode === MODE_CURVE`）：**下一节拍点预告**——
  下一个节点 BPM（`cvNextBpm`）+ 倒计时（`cvNextInSec`，`etaText()` 格式化）+ 本段进度条（`cvProg`），
  走完显示「曲线已走完」（`cvDone`）。

> 注释里专门强调：`@Builder` 必须**不带参数**（带参 @Builder 的内容会被冻在首帧），且 `zIndex` 要高于后面 100%×100% 的 Column，否则触摸被吃掉（`MainPlayer.ets:388-391,460-461`）。

### 4. 进度环（大圆）

`MainPlayer.ets:761-826`：两层 240×240 的圆叠在 `position({ x: (WINDOWS_WID/2)-120, y: "15%" })`。

- 下层是发光层，`.opacity(this.glowOpacity)`，由**拍相位**驱动（每拍亮起后衰减）；
- 上层是双色渐变圆（`#ffee3939` → `#A78BFA`），`.rotate({ angle: this.rotate_angle })` 展示播放进度；
- 视觉半径是 `this.R = 240 * 4`（`MainPlayer.ets:214`，注意是半径，注释里说明原实现误写成 240*8 直径导致半张角只有一半）。

大圆本身**不可拖动**（`onClick` 是空的），快进快退走右侧摇杆（§七）。

### 5. 底部中央的"长按退出"

`MainPlayer.ets:715-748`：一个红色圆（`stop_circle_fill`）+ `ProgressType.Ring`，
`LongPressGesture({ duration: 1, repeat: true })` 每触发一次 `quit_progress += 0.5`，到 100 时调 `Quit()`
（`MainPlayer.ets:1535-1540`，`navPathStack.pop()`）；松手未满则清零。

### 6. 右侧悬浮栏（`FloatWidgetBuild`，`MainPlayer.ets:471-526`）

- 三个 `SideButton`：下一首（`nextSong()`）、暂停/播放（`pause()`，图标跟着 `this.Pauce_icon`）、上一首（`prevSong()`）；
- 最下面是**摇杆**（`rocker_Build()`，`MainPlayer.ets:589-633`）；
- 整栏可上下 `PanGesture` 拖动（`this.offset_bar`）；
- 订阅 `motion` 的 `holdingHandChanged`（`MainPlayer.ets:464-469`）：检测到"握着手机"时 `floatBarLROffset = windowWidth`，
  把悬浮栏移出屏幕，避免误触。

---

## 四、关键状态速查

### 4.1 展示用 `@State`（声明区 `MainPlayer.ets:129-267`）

| 变量 | 含义 |
|---|---|
| `BPM_now` | 当前目标步频（动态模式下取 native 管线实测步频） |
| `Speed` | 当前歌曲倍速 |
| `sport_time` | 运动时间 `[时,分,秒]` |
| `songTimePass / songTimeLast` | 已播 / 剩余 `[分,秒]` |
| `songName / Artist` | 歌名 / 作者 |
| `statusText` | 标题状态字：正在运动 / 暂停 / 加速中 / 减速中 |
| `glowOpacity` | 进度环边缘发光（拍相位驱动） |
| `playlistProgress` | 总歌单播放进度 0~1 |
| `isPause / Pauce_icon / hasStop` | 暂停态与按钮图标 |
| `nativeState` | native 会话状态字符串（idle/loading/prepared/ready/failed/gone） |
| `octaveMult / rawSongBpm / levelSongBpm` | 八度对齐结果与两级 BPM |
| `constBpmUi / showConstSlider` | 恒速滑块的值与显隐 |
| `showCurvePreview / cvNextBpm / cvNextInSec / cvProg / cvDone` | 曲线预告栏 |
| `stepSource / stepScenario / pipelineOn / pipelineCadence / pipelineMultiplier / pipelineState / pipelineSteps` | native 步频管线状态 |
| `rocker_offset / scrubbing` | 摇杆状态 |
| `quit_progress` | 长按退出进度 |

### 4.2 内部标量（`MainPlayer.ets:199-267`）

- 位置环：`posSecC / durSecC / speedC / songBpmC / firstBeatC / modeC / playingC`；
- 八度层级：`octaveMult / rawSongBpm / levelSongBpm` 与 `freezeOctaveLevel()`；
- 接歌：`pendingNext / pendingKey / prepareFailedKey / cutGuardUntil / autoNext / usePreparedCut`、
  `sessionReadyOnce / sessionStartMs / posBaselineSec`；
- 擦洗：`scrubRate / scrubPos / pendingSeekSec`；
- 队列：`songDb / songKey / songPath / playlists / playlistIndex / playlistTotalSec / playlistDoneSec`。

### 4.3 文件级常量

| 常量 | 值 | 含义/出处 |
|---|---|---|
| `TICK_MS` | `33` | 主循环周期（约 30fps），`MainPlayer.ets:65` |
| `PREPARE_AHEAD_SEC` | `30.0` | 距结束多少秒开始预解码下一首，`:68` |
| `MIN_SESSION_PLAY_MS` | `2500` | 新会话至少真播这么久才允许判定结束，`:71` |
| `OCTAVE_LOW / HIGH` | `0.8 / 1.6` | 八度对齐目标区间，`:78-79` |
| `NATIVE_RAW` | `'LostMemory.m4a'` | 没有 `song_data.json` 时的内置演示音源，`:82` |
| `ROCKER_MAX_DIST / FWD / BACK` | `60 / 8 / -6` | 摇杆最大拖动像素与两端倍率，`:85-87` |

---

## 五、三种模式在页面里怎么跑（模式来源）

`RunDemoEngine` 是页面唯一的状态来源，每帧 `engine.tick(dt)` 推进，`engine.status()` 取快照。
三种模式在引擎里的唯一分岔点是"目标步频从哪来"（`RunDemoEngine.ets:657-667`）：

| 模式 | 目标步频 | 倍速 |
|---|---|---|
| `MODE_DYNAMIC` | 实测步频（native 管线）；没在跑保持上一档 | 管线给的 `multiplier`，经 `setExternalSpeed()` 覆盖引擎 |
| `MODE_CONSTANT` | `engine.getConstBpm()`（滑块） | 目标步频 ÷ 层级BPM |
| `MODE_CURVE` | `tempoAt(曲线, 运动时间)`（线性插值） | 同上 |

### 动态模式：native 步频闭环

- `startPipeline()`（`MainPlayer.ets:1472-1500`）只在 `modeC === MODE_DYNAMIC` 时启动：
  - 先 `stepPipelineSetChaseDelayWindow(getChaseDelaySec())`；
  - **真实传感器**（`SOURCE_REAL`）：`stepSensorStart(songBpm, firstBeat, 0, 0)` + `stepSensor.start()`
    （native 不起模拟线程，由 `StepSensor.ets` 订阅加速度计攒批喂入）；
  - **模拟演示**（`SOURCE_SIM`）：`stepPipelineStart(scenario, songBpm, firstBeat, 0, 0)`
    （第 4 个参数 `mode=0` 即 FOLLOW，第 5 个 `targetBpm=0`）。
- `pollPipeline()`（`MainPlayer.ets:1516-1530`）每 6 个 tick 解析一次 `stepPipelineStatus()`，
  把 `multiplier` 通过 `engine.setExternalSpeed()` 喂给引擎，于是进度条/拍点光效都按**真实管线的倍速**走。

### 恒速模式

滑块 `onChange`（`MainPlayer.ets:415-418`）→ `engine.setConstBpm(v)`；
引擎按 `constBpm / levelBpm` 算倍速（`RunDemoEngine.ets:663-664` + `:669-677`）。

### 曲线模式

进页时把 `CurveStore` 的选中曲线塞进引擎（`MainPlayer.ets:305-337`），
标签一起塞进 `setTagList()` 供 TTS 用。引擎按运动时间求值（`RunDemoEngine.ets:593-598`）。

> ★ **预设（恒速/曲线）是开环的**：`startPipeline()` 在非动态模式直接 `return`（`MainPlayer.ets:1476-1479`），
> 不读步频、不做相位对齐。音乐是节拍基准，人跟着音乐跑。
> （`step_pipeline.hpp` 里确实实现了 PRESET + `phase_trim.hpp` 的相位微调分支，
> 但两个播放器目前都以 `mode=0` 调 `stepPipelineStart`，该分支尚未被页面启用。）

---

## 六、预解码接歌与步频闭环

两条独立但配合的回路：**音频侧**负责"不断音地换歌"，**步频侧**负责"倍速跟着脚步"。

### 预解码硬切（不断音）

1. 当前歌剩余 ≤ `PREPARE_AHEAD_SEC`（30s）时调 `prepareNextSong()`（`MainPlayer.ets:1228-1251`），
   用一个**独立** `NativeAudio` 实例 `prepareOnly()`（只解码不出声），失败记 `prepareFailedKey` 不重试。
2. `pendingReady()`（`:1254-1260`）确认预解码会话到了 `prepared/ready`（decode 还在后台就 start 会断音）。
3. `autoAdvance()`（`:1286-1329`）到点 `doHardCut()`（`:1332-1398`）：
   `t.startPrepared()` 让 B 瞬时起播 → 页面改用 B → 隔 `cutLeadSec()` 后给 A `fadeOut(HARD_CUT_FADE_MS)` 再 `stop()`。
4. 硬切时间参数在 `NativeAudio.ets:29-30`：`HARD_CUT_LEAD_MS = 120`、`HARD_CUT_FADE_MS = 80`（毫秒）；
   `cutLeadSec()`（`MainPlayer.ets:1271-1276`）**优先用 native 实测的 `startLatencyMs`**，测不到才退回 120ms。

### 防"连环跳"护栏

`usePreparedCut` 注释（`MainPlayer.ets:232-240`）记录过"新会话被误判已结束 → 连环跳"的事故，现在有两道护栏：

- `settled`：新会话必须 `sessionReadyOnce` 且真的播过 `MIN_SESSION_PLAY_MS = 2500ms`；
  一直没就绪的给 8 秒兜底（`:1295-1297`）；
- **位置合理性校验**：会话才起播 `playedMs`，`posSec` 不可能已经接近 `durSec`；
  上限 `posBaselineSec + (playedMs/1000)*2.5 + 5.0`，超了就忽略该帧（`:1299-1308`）；
- 另有 `cutGuardUntil` 在切歌后短暂闭锁（`:1290-1292`）。

### 手动切歌

`nextSong()/prevSong()`（`:1112-1127`）→ `switchToKey()`（`:1086-1109`）：
停管线/取消预解码/停 native → 换歌 → 需要的话重新 `startNative()` + `startPipeline()`。
首尾不循环，`songDb.length < 2` 时返回 null（`:1056-1083`）。

### 播放控制

`pause()`（`:1132-1149`）共用给侧栏与中央按钮；恢复时重定八度层级并重启管线，暂停时停管线 + `native.pause()`。

---

## 七、进度环与摇杆

### 进度环（只读展示）

- 圆露在屏幕里的半张角 `θ = ringHalfAngle() = asin((屏幕半宽) / R)`（`MainPlayer.ets:915-923`）；
  初始角 `rotate_angle = 90 - θ`，正好把交界点放到屏幕左边缘（`aboutToAppear` `:287-288`）。
- 进度 → 角度：`ringAngleAt(pos, dur) = (90-θ) + t·2θ`（`:926-932`），起点左边缘、终点右边缘。
- 刷新由 `startTimeProgressSongRight()` 每秒一次（`:1784-1799`），
  用**引擎真实位置**算目标角并 `Progress()` 动画过去。
  > 注释里记录了修复点：原实现用 `(90 - rotate_angle)*2 / perStep` 自己累加，
  > 而 perStep 取的是当时的占位值 60s（真实曲长近 198s），必然冲过头。现在角度直接由引擎位置算。
- 播放时 `pullGlow()`（`:1588-1599`）每帧把 `beatPhase` 映射成 `glowOpacity = (1-phase)^1.6`，实现"每拍亮一次"的光效。

### 摇杆（快进/快退 + 擦洗）

- 拖动时 `beginScrub()`（`:1411-1420`）：冻结引擎推进，`native.mute(30)` **只静音不暂停**；
- `scrubStep(dt)`（`:1423-1434`）按 `rockerRate()` 每帧推进 `scrubPos`；
- `rockerRate(off)`（`:1403-1409`）：偏移夹到 ±`ROCKER_MAX_DIST`，静止时 `(8 + (-6))/2 = 1`，上滑到 8、下滑到 -6；
- `endScrub()`（`:1436-1462`）松手才 `seek`：会话活着就 `native.seek` + 按需 `unmute`/补 `pause`；
  会话还没建起来（刚进页就拖）则记 `pendingSeekSec`，起播后 `applyPendingSeek()` 补一次（`:1187-1192`）。

---

## 八、八度对齐（`freezeOctaveLevel`，`MainPlayer.ets:1629-1649`）

- 目的：让有效倍速 `m = 目标步频 C / 层级BPM (B·2^k)` 落进 `[OCTAVE_LOW, OCTAVE_HIGH) = [0.8, 1.6)`；
  区间宽度正好一个八度、候选层级彼此也差 2 倍，所以**有且只有一档命中**，且取偏快的一侧。
- 做法：先按区间几何中点 `√(LOW·HIGH)` 做 `log2` 四舍五入得 `k`，再对边界各修一次；
  附加倍率 `octaveMult = 2^(-k)` 仅用于显示，`engine.setLevelBpm(B·2^k)` 才是引擎/管线真正用的拍网格周期。
- **整首只定一次**（每次"开始播放一首歌"时），因为若每帧按变化的 C 重算，曲线跨过区间边界时倍率会突然 ×2，就是"倍速断层"（注释 `:1619-1628`）。

---

## 九、TTS 标签播报

- `aboutToAppear()` 里 `voiceSpeaker.initEngine()`（`MainPlayer.ets:275`），`aboutToDisappear()` 里 `release()`（`:351`）；
- 曲线模式下 `pullStatus()` 会调 `refreshTag(workoutSec)`（`:1666, 1728-1747`）：
  找到第一个时间大于当前运动时间的标签，把它的文字交给 `voiceSpeaker.speakText()`。
- `TtsManager` 用 `@kit.CoreSpeechKit.textToSpeech`，中文女声、在线、支持后台播报（`TtsManager.ets:8-28`）。

---

## 十、主循环与刷新节奏

`startTick()`（`MainPlayer.ets:1543-1578`）每 `TICK_MS = 33ms` 一轮：

1. `dt` 夹到 ≤0.5s；
2. 擦洗中走 `scrubStep(dt)`，否则 `engine.tick(dt)`；
3. `pullGlow()`（每帧只写 `glowOpacity` 一个 @State，避免整页重绘，注释 `:1587`）；
4. 每约 1 秒 `updateStatusText()` 判定加速/减速/暂停（`:1758-1773`）；
5. 每 6 个 tick（约 5Hz，或临近结尾时）才做重活：`pollNative()` → `native.setSpeed(speedC)` → `pollPipeline()` → `pullStatus()`。

`pollNative()`（`:1195-1223`）会：回填 `nativeState`/`startLatencyMs`、把 `ready` 记进 `sessionReadyOnce`、
会话消失就 `markEnded()`、只在 `ready` 时 `engine.syncPosition(posSec)` 并允许位置前进（加载期冻结），
最后调 `autoAdvance()` 触发接歌。

---

## 十一、已知问题与注意事项

| # | 现象/边界 | 代码依据 |
|---|---|---|
| 1 | **模式不可在页面内切换**，只能换入口 | `MainPlayer.ets:51-62, 948-954`；主页只有两个圆 |
| 2 | 预设（恒速/曲线）**不启动 native 管线**，是纯开环；`phase_trim` 的 PRESET 分支页面未用 | `MainPlayer.ets:1476-1479`；`step_pipeline.hpp:235-250` |
| 3 | TTS：`refreshTag` 在 `nx > 0` 时才播报，**第 0 个标签永远不会念**；且 `pullStatus()` 约 5Hz 都会再调一次，存在**同一标签重复播报**风险 | `MainPlayer.ets:1733-1746, 1666` |
| 4 | 长按退出按 `+= 0.5` 累计，需 200 次触发才到 100，实际需要按住很久 | `MainPlayer.ets:725-739` |
| 5 | 进度环角度**每秒**才更新一次（+ 擦洗时），不是逐帧；拖动大圆本身没有交互 | `MainPlayer.ets:1784-1799, 761-826` |
| 6 | native 侧仍是**全局单例 + 全局倍速**，`music_play` 的进度回调被注释、没有按 id 的进度查询；页面靠 `musicGetStatus` 轮询回填 | `NativeAudio.ets:1-14, 146-148`；`types/libentry/index.d.ts:117-123` |
| 7 | 歌单选择有兜底：显式选中的歌单不可用就退到第一个"有歌"的歌单，再不行才整库；且下标要 `Number()` 归一化（PersistentStorage 落盘可能是字符串 `"0"`） | `MainPlayer.ets:105-125, 296-303, 986-1016` |
| 8 | 接歌硬切的 120/80ms 是保守起步值，真机需要实测；页面优先用 native 实测 `startLatencyMs` | `NativeAudio.ets:19-30`；`MainPlayer.ets:1271-1276` |
| 9 | 悬浮栏会被 `holdingHandChanged` 移出屏幕（握持自动躲让），调试时若"侧栏不见了"是这个原因 | `MainPlayer.ets:464-469` |

---

## 十二、相关文件

| 文件 | 说明 |
|---|---|
| `entry/src/main/ets/pages/MainPlayer.ets` | 正式播放器（本文对象） |
| `entry/src/main/ets/pages/Main.ets` | 主页：两个入口圆 + 底部四个 Tab |
| `entry/src/main/ets/ets_libs/PlayerRouteParam.ets` | `MainPlayerParam` |
| `entry/src/main/ets/ets_libs/RunDemoEngine.ets` | 模式数学 / 曲库 / 曲线求值 |
| `entry/src/main/ets/ets_libs/NativeAudio.ets` | native 播放薄封装、硬切时值 |
| `entry/src/main/ets/ets_libs/StepSource.ets` | 步数检测源 / 模拟场景 / 起步校正设置 |
| `entry/src/main/ets/ets_libs/StepSensor.ets` | 真实加速度计订阅（与设置页共用单例） |
| `entry/src/main/ets/ets_libs/StretchEngine.ets` | 变速引擎选择（SignalSmith / Audio Kit） |
| `entry/src/main/ets/ets_libs/TtsManager.ets` | 标签 TTS |
| `entry/src/main/cpp/step_pipeline.hpp` / `TempoFollower.hpp` / `phase_trim.hpp` | 动态跟随与预设相位微调的 native 核心 |
