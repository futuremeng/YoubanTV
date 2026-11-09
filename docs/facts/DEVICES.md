# 实机事实（现象 → 复核命令 → 结论）

写代码前先读这一页。规则：每条都必须能被复核命令重跑；结论只说做到了什么，不说"应该能"。
设备代号：`BOX-A` = 电视盒子（Android 5+，Amlogic，1080p，75 寸 / 3 米）；
`BOX-B` = 电视（Android 7+，厂商定制固件）；`PHONE-C` = 手机（Android 7.1 / API 25 / 骁龙 625）。

## F1 厂商固件会在重启时静默清掉悬浮窗授权

- 现象：重启后 `SYSTEM_ALERT_WINDOW` 由 `allow` 变回 `ignore`，应用外呈现静默失效，界面上毫无痕迹。
- 复核：`adb shell appops get <pkg> SYSTEM_ALERT_WINDOW`（重启前后各一次）。
- 结论：授权状态**必须**由能力登记表定期探测；降级必须画在应用画面上（F2）。升层文案要写明这条可能失效。

## F2 电视上几乎收不到通知

- 现象：通知栏在电视形态里基本不可用，靠通知提示「呈现已失效」等于没提示。
- 复核：装包后触发一次提示，看通知栏；对照 `dumpsys notification --noredact | grep <pkg>`。
- 结论：**每一层提示都必须有应用内替代**（常驻提示条或悬浮提示）；通知只是锦上添花，写进分层措辞规则。

## F3 开机自启的可靠通道只有一条

- 现象：开机广播在部分固件上根本不会为未运行应用拉起进程；手动 `am broadcast` 能让界面"点亮"，
  开机自启的判定只认**开机后 300 秒内**收到的广播。
- 复核：`adb shell dumpsys activity broadcast | grep BOOT`；对照应用内开机时间线。
- 结论：自启那一行**只报事实**（做到了 / 断在哪一条 / 该去系统里勾哪个开关）。厂商白名单里的
  「启用应用」实测有效（约 23 秒前台启动），归入 L5。界面按实测能力描述每一条。

## F4 Android 7（API 25）上现成姿态模型起不来

- 现象：`libmediapipe_tasks_jni.so` `dlopen` 失败，报缺 `strtod_l`。
- 复核：对每个候选 `.so` 取 `.dynsym` 里 `st_shndx==SHN_UNDEF` 的符号，减去本机 `libc.so` 导出集合。
- 结论：这类库是照更高 API 构建的，**manifest 的 minSdk 是声明，ABI 需实测**。运动计数走无模型信号，
  或换后端；**计次逻辑与信号源解耦**（摄像头 / IMU / 手动确认三条路共用同一入口）。

## F5 那台盒子的 load average 判读方式

- 现象：`load average` 常年 50–60，但 CPU 三四成到七八成空闲、`procs_blocked=0`、iowait 0–4%。
- 复核：`adb shell cat /proc/loadavg` 对照 `top`；D 状态的是厂商视频/显示内核线程。
- 结论：**不要拿 load 当"等机器安静"的条件**（等不到）。性能对比用帧计数与尾帧耗时。

## F6 帧流稀，小于帧代价的卡顿测不出来

- 现象：答题页定速按键一轮只有 30–40 帧，带不带重资源各三轮看不出差别。
- 复核：`dumpsys gfxinfo <pkg> --reset` → 定速按键 → 读计数。
- 结论：静态页面用 gfxinfo 的帧数判小卡顿无效；改用 Choreographer 回调自记帧间隔。
  资源装载的代价用包体与导入耗时度量。

## F7 Gradle Sync 会删掉不属于自己产出的文件

- 现象：随包资产放进被 `Sync` 的目录后，在干净工作树上构出的包**少了一个目录、包体小约 2MB**，
  而且构建"成功"——假通过。
- 复核：构完 `unzip -l app.apk | grep -c assets/<dir>` 必须等于预期文件数；比较包体大小。
- 结论：非产出资产放独立目录或改 `Copy` + 前置清理；**任何验证构包都要看目录命中数**，不看大小猜。

## F8 老库升级路径是全新装机测不出来的盲区

- 现象：新表建表少一列，全新装机一切正常，老库覆盖升级后第一条插入整批失败，只留一条失败记录。
- 复核：装旧版本 → 塞一条自定义数据 → `install -r` 新版本 → 查数据与失败事件。
- 结论：**建表语句必须单点定义**、列名由行对象的 `cells()` 单点提供，并用单测逐张核对；
  每次带 schema 变更的发版必跑升级演练。

## F9 观看距离决定字号下限

- 现象：75 寸 / 1080p / density 1.5 / 3 米下，13–16f 只有约 19–24′ 张角，坐远处读不动。
- 复核：`wm density` + 字号换算张角。
- 结论：电视端正文 ≥20f、说明 ≥18f、任何文字 ≥16f；新增文字必须用字号档位，不写裸字号（有门禁）。

## F10 设备级强制在厂商固件上的可达性

- 现象：设备管理员状态无法用 adb 证实；无障碍在部分固件上绑不上；设备所有者一般要求设备未初始化。
- 复核：`dpm set-active-admin` / `settings get secure enabled_accessibility_services`。
- 结论：设备管理员与拦设置在这批设备上做到一半是常态；本项目已把设备级强制从产品中移除（D23）。
  界面只描述这台设备做得到的能力，引导流程只请求达成当前层所必需的授权。
  设备可被随时卸载；需要物理停止观看时由 L5 承担。

## F11 改系统时间会刷新当天额度

- 现象：把时间调到明天，当天的账与约定线被重新起算（旧模型下表现为「当天额度重新发放」）。远程控制额外
  用开机经过时间核对，改表不能延长它。
- 复核：改表前后读状态。
- 结论：当日账侧要补一道完整性：持久化「见过的最大墙上时间 + dayToken」，往回跳不得重当天，
  往前跳需要单调时钟差值佐证才能滚动到新一天。

## F12 请求播放器暂停的响应率（两台设备已实测）

- 跑法与样本：[`PROBES.md`](PROBES.md) §F12；样本登记在 [`probes/f12.yaml`](probes/f12.yaml)；
  一致性与反造假由 `tools/probe-gate.sh` 守（来源不是 adb/manual 的样本不得抬默认档）。

- 实测结果（2026-11-09，本机 adb，`source: adb`）：

  | 设备 | 通路 | n | 响应率 | 默认档 |
  | --- | --- | --- | --- | --- |
  | Konka Android TV 9652（Android 9，自带播放器） | `KEYCODE_MEDIA_PAUSE` | 20 | 0% | ambient |
  | 同上 | `media dispatch pause` | 20 | 0% | ambient |
  | Smartisan OD103（Android 7.1.1，自带浏览器网页播放器） | `KEYCODE_MEDIA_PAUSE` | 20 | 0% | ambient |
  | 同上 | `media dispatch pause` | 20 | 0% | ambient |

  四行都先过了两道控制（时间码在走 + 静止区均值恒定），所以「没停」是结论，不是测量失败。

- **结论：这两台设备拿不到 `focused` 作默认档**，界面停在 `ambient` 并写明原因（`LAYER-07`）。
  这不是缺陷，是设计。
- 会话状态只能当旁证。两个方向都不可靠：这台 Smartisan 在预试验里发完暂停后 `dumpsys media_session`
  报 `state=2`（Paused），而画面里的 burned-in 时间码照走；正式四行样本里会话状态又一律读不到
  （自带播放器不发布 `PlaybackState`）。所以判据以画面为准，每轮额外记一笔「会话自称已暂停 N/n」作旁证
  （`PROBES.md` §F12、D44）。
- 不响应不是「某个键码没猜对」：这台电视对 `85 / 126 / 127 / 128 / 23 / 66 / 92` 与屏幕中心点按都无反应。
- **仍未测**：第三方播放器（两台设备各一轮）。电视端第三方 App 首页是广告轮播，进正片要账号与导航；
  手机端没有本地视频的 VIEW 处理器。下次真实观影时按同一脚本补测，不要拿估计值填。
- 仍未测：音频焦点丢失通路——需要一个能稳定抢走焦点的旁路 App，本机没有。

## F13 手机端姿态计次的可用性与误计率待实测

- 跑法与样本：[`PROBES.md`](PROBES.md) §F13；样本登记在 [`probes/f13.yaml`](probes/f13.yaml)（自检 + 对照两段）。
  本次两台设备都没测：计次算法还没实现，没有可对照的算法计数；不拿人工估计值填。

- 待测：前置摄像头姿态计次在手机上的可用距离、光照下限、遮挡影响与误计率；与人工计数对照 ≥200 次，
  按项目（开合跳 / 深蹲 / 坐姿操）与机型分档。
- 复核：固定机位与固定节奏对照录制，人工计数与算法计数逐次比对；同时记录帧处理耗时与温升。
- 结论：在数据回填前，摄像头通道的默认值为关，界面按加速度计与手动确认两条路径描述（`SENSE-04`）。
  **本条不再阻塞默认值**（D36）：开启只看首次标定的自检门槛（连续 20 次误计率 ≤5%，`SENSE-02`），
  未达标就停在加速度计 + 手动确认，不卡住其他功能。
  无标记动作捕捉在临床量级存在系统偏差，本项目的用途限于计次与节律（`SENSE-03`、
  `research/MOBILE-COMPANION.md` §4）。

## F14 自带浏览器画不出网页里的中文（呈现通路，不是产品界面）

- 现象（2026-11-09，PHONE-C）：用 `tools/tv-present.rb` 把一块状态页推到手机自带浏览器，
  中文全是方块；指名包名 `-p com.android.browser` 并在页里 `@font-face` 引
  `/system/fonts/DroidSansFallback.ttf` 之后，只有开头几个字有字形，其余仍是方块。
  另外两次时序坑也在这里：不 force-stop 前台应用会看到上一轮的旧页面；force-stop 后立刻
  `am start` 会拿到白页。现在这条命令自己验：画面平均亮度（`signalstats` 的 YAVG）低于
  200 才算画出来了，否则直接报错，不出「已显示」。
- 复核：`ruby tools/tv-present.rb fixtures/day.yaml DAY-01 --serial=<手机> --shot=/tmp/x.png`
  然后看截图；对照 `adb shell pm list packages | grep browser`（这台机器上同时装了 Chromium，
  它会按同源策略挡掉 `file://` 页面里的字体引用）。
- 结论：**网页这条路只够验证「判定 → 落层 → 这一层该说什么」这条链，不能当设备端界面**；
  M3 的界面必须是 device/ 的原生 UI（用系统字体，不走这条路）。电视端见下一条（BOX-B 连网页都不接）。

## F15 这台电视不接任何网页：免安装的呈现只能走图片，而且黑屏会骗过亮度检查

- 现象（2026-11-09，BOX-B，Konka Android TV 9652 / Android 9）：
  `cmd package resolve-activity -a VIEW -t text/html` 解不到任何组件——自带的
  `com.giant.htmlviewer` 不接 `file://` 的 HTML；系统字体里也没有 `DroidSansFallback.ttf`，
  只有 `DroidSans*.ttf` + `NotoColorEmoji.ttf`，所以就算能开网页也是方块。
  能接的是 `com.bytedance.giant.gallery`（`image/png` ✓ 已解到）。
- 三个坑都实测踩过：① 电视会自己进屏保，屏保是深色画面，光看「画面变暗」会把屏保当成显示成功；
  ② 相册载入时是一屏黑 + 转圈，同样过不了「变暗」这一条；③ 灰度比对如果按 `txt:` 的
  `(n,n,n)` 格式解析灰度图，读回来全是空 → 差值恒为 0 → 黑屏也判「一致」。现在按
  `-depth 8 gray:-` 的原始字节读，并把这条踩坑写在代码注释里。
- 复核：`ruby tools/tv-present.rb fixtures/layer.yaml LAYER-07 --serial=<电视> --shot=/tmp/x.png`
  （它会打印「通路：image/png 交给 com.bytedance.giant.gallery」和灰度平均差；对不上就直接报错）。
  对照 `adb shell cmd package resolve-activity --brief -a android.intent.action.VIEW -t text/html`。
- 结论：在这台电视上，**免安装的呈现通路只有一条：本地图形 + 相册打开**；它验证的是
  「判定 → 落层 → 措辞」这条链，不是界面。要用原生界面必须装 APK → 需要 Android SDK
  （今晚 `dl.google.com` 不可达）。字形要用常规体：`45 Light` 这类薄体在 72px + 电视缩放下糊成重影。

## F16 adb 在这两台设备上能到哪、不能到哪（电视端设备测试的前提）

- 实测（2026-11-09，BOX-B 与 PHONE-C 各跑同一份 `fixtures/tv-device.yaml`，8 步全过）：
  - **能到的**：推文件、`am start -W` 打开、`screencap`、`dumpsys window` 看前台、读一手事实
    （`date +%s`、`/proc/uptime`、`persist.sys.timezone`、`wm size`、`dumpsys power` 的醒/睡）。
    这五项正好是内核要的时间输入（`probedAt` / 墙钟差 / 单调钟差）与呈现自证所需的全部。
  - **不能到的**：这台设备上没有任何组件认领我们的状态更新
    （`cmd package query-receivers -a com.youban.STATE` → 空），所以**遥控器按键现在没人接**，
    换页只能从 Mac 侧走 adb。要让遥控器能用，必须有 `device/` 的原生 APK。
  - **老设备的坑**：OD103 / Android 7.1 上 `resolve-activity` 对 `file://` 的 HTML 问不到组件，
    但 `am start -a VIEW` 打得开；而且此时 `mCurrentFocus` 是 `android`，真正在前台的是 `mFocusedApp`。
    只看前者会把确实打开着的应用当成没打开——通路探测现在两处都读，问不到就现场开一次，
    用「前台换了 + 画面是深的」认定这条通路真能用。
- 复核：`ruby tools/tv-at.rb --serial=<序列号> --facts`（打印上述事实与「输入通路」）、
  `ruby tools/tv-at.rb --serial=<序列号>`（跑清单）、`--only=LAYER-07`（跑一步）、`--cycle=3`（连播）。
- 结论：**adb 能承担调试与设备测试**——判定 → 落层 → 措辞 → 呈现这条链每一步都要自证；
  但它替代不了界面：输入、按键受理、焦点这些必须有原生 APK。M3 之前电视端的「测试」就是这条命令。
