# F12 / F13 实测协议

这两条是**机型事实**，只能测出来，不能推出来。仓库里的默认值不等它们（D36）：没数据就是最保守档——
`focused` 不作默认档（`LAYER-07`）、摄像头通道默认关（`SENSE-02`）。测出来之后抬默认档只走下面这条路。

样本落在 [`probes/f12.yaml`](probes/f12.yaml) 与 [`probes/f13.yaml`](probes/f13.yaml)；
两者与门槛常量、[`DEVICES.md`](DEVICES.md) 的措辞由 [`../../tools/probe-gate.sh`](../../tools/probe-gate.sh) 校验一致。

## F12 请求播放器暂停的响应率

**要测的东西**：音频焦点丢失 / `KEYCODE_MEDIA_PAUSE` 在各机型自带播放器与第三方播放器上是否真的停下来。
遥控器能收到广播（F10）不算——「广播被收到」与「播放器照办」是两件事，分开记。

一台连着 adb 的设备上，一条命令跑完 20 次（自带播放器与第三方播放器各跑一轮，通路分开记）：

```sh
ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "某机型" stock 20 --android=14 --channel=keyevent
ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "某机型" stock 20 --android=14 --channel=dispatch
```

**判据是画面，不是状态字段**。实测前这里写的是「读 `dumpsys media_session` 的状态，`2` 记 1」——
那条错了：Smartisan OD103 上发完暂停后 `state=2`（Paused），而画面里的时间码照走。
很多自带播放器压根不发布 `PlaybackState`（读出来是 unknown）。「收到了暂停」与「内容真的停了」
是两件事，后者才算数（F10 的遥控器广播同理）。会话状态仍然逐轮打印，只当旁证。

### 准备一段带时间码的内容

内容必须是**自己生成的**，把解码时钟烧进画面左上角，不然无法区分「停了」与「截屏拿不到新帧」：

```sh
cat > /tmp/dt.txt <<'EOF'
color=c=0x202020:s=1280x720:r=15,drawtext=fontfile=/System/Library/Fonts/Menlo.ttc:text='T %{pts\:hms}':fontcolor=white:fontsize=h*0.11:x=w*0.04:y=h*0.04:box=1:boxcolor=black@0.6
EOF
ffmpeg -y -hide_banner -filter_complex_script /tmp/dt.txt -t 900 -preset veryfast -crf 34 /tmp/f12-clock.mp4
adb push /tmp/f12-clock.mp4 /sdcard/Download/
```

两件事记住：引号多的滤镜走 `-filter_complex_script`，直接写在命令行上会被 shell 吃掉参数
（当时就在画面上渲染出了文件名）；`fontfile` 要换成自己机器上真的存在的字体。生成后**自己验一帧**：
取同一次解码里的相邻几帧，裁那块区域，哈希必须各不相同——不然你测的是一个静态图。

网页播放器走 HTML 包一层（`<video src="f12-clock.mp4" controls muted loop autoplay>`）；
用 `--clip=` 指那个 html，用 `--launch=` 给起播意图。

### 跑

```sh
brew install android-platform-tools          # 或装你自己的 platform-tools
adb devices                                  # 确认设备已授权
ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "Konka Android TV 9652" stock 20 \
    --android=9 --channel=keyevent --stop=com.smartisanos.mediaplayer.giant
ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "Smartisan OD103" stock 20 --android=7.1.1 \
    --channel=dispatch --stop=com.android.browser --clip=/sdcard/Download/player5.html \
    --launch='am start -a android.intent.action.VIEW -d file://%s -t text/html' \
    --tap=540,1150 --crop=460x80x40x230 --static=300x120x650x550
```

每轮：发暂停 → 在 2.4s 窗口里取 2~3 次时间码区域，相邻两次相同就记「停了」（迟到的暂停也是真停了，
但窗口就是 2.4s，别当成 1.5s 内的响应）→ 恢复（播放键 → 播放/暂停键 → 点按）→ 下一轮。
同时每轮记一笔「会话自称已暂停 N/n」当旁证（`sessionPaused`）：它与画面判定的差就是 F12 要的事实。
跑完自动写进样本文件并给出结论。

**两道控制，跑不过就不写样本**：

1. 推进控制：时间码三帧两两不同。不成立就是没在播，或截屏拿不到画面（DRM 是黑屏）。
2. 静止控制：内容里本就静止的那块，均值在 ±2 内。浮层、菜单、屏保会把它拉出好几个级——
   那时「画面不变」不能当作「停了」。

每轮还有一道恢复控制：发播放后画面必须重新推进，否则从这一轮起样本不可信，直接中止不写。

### 踩过的坑

- **整屏哈希会被浮层带偏**：暂停时进度条与中心 ▶ 还在淡入淡出，曾把一次真暂停测成 20 次「没停」。
  只裁时间码区域。
- **裁切区域要按设备显式给**（`--crop=WxHxXxY`）：手机有地址栏，视频被顶下去，裁偏到字顶会让
  控制项假通过、判定变噪声。默认值只对全屏播放的电视成立。
- **静止控制要对缩放抖动容忍**：逐像素比会被电视的缩放/编码偶发抖动假报「截屏不可信」，改成均值差 ≤2。
- **换片段要先 `--stop=<包名>`**：播放器已在前台时新的 VIEW 意图会被 `onNewIntent` 吞掉，屏幕上还是
  上一个片段，控制项就假失败。
- **播完不等于停**：自带播放器会连播同目录下一个文件，或单文件循环。所以「自然结束」不能当控制项。
- **screencap 的 stdout 可能混日志**（Smartisan 7.1 就是），要先剥到 PNG 头再哈希。
- **暂停会迟到**：网页播放器见过 2.4s 才落地、且播放键恢复不动的，得留点按这一条恢复通路。
  而 `input tap` 要的是**两个参数**不是 `x,y` 一个串——写成串会被当成一个参数，点按默默失败，
  恢复阶梯就少了一阶（脚本里踩过）。
- **变量后面紧跟中文会被并进变量名**：`C` locale 下 `"$n；…"` 让 bash 找一个叫 `n；` 的变量，直接
  `unbound variable`。带中文提示的 shell 一律写成 `${n}`。

### 结果（2026-11-09，两台设备，四行样本）

两台设备的两条通路都是 **0/20**。两道控制均通过，所以这是结论而不是测量失败：
这两台机型上 `focused` 不作默认档，停在 `ambient` 并写明原因（`LAYER-07`）。
第三方播放器与音频焦点丢失通路仍未测，见 `DEVICES.md` §F12。

没有 adb 的设备（例如只能手动操作的电视）就人工按遥控器计数，用 `--source=manual` 录入：

```sh
tools/probe-record.rb --fact=f12 --device="Mi TV Master" --player=third-party \
  --source=manual --android=11 --trials=1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1
```

**每档 ≥20 次**（暂定门槛，见 `DECISIONS.md`「暂定取值」）。响应率 ≥95% 才把该机型默认档写成 `focused`；
不达标就停在 `ambient` 并在界面写明原因——**这不是缺陷，是设计**（`LAYER-07`、F12）。

## F13 手机端姿态计次的可用性与误计率

两段，用途不同，别混：

1. **标定自检**（决定摄像头通道能否开）：一台手机架固定机位，做连续 20 次动作，人工数与算法数逐次比对。
   误计率 ≤5% 才允许开该通道；不达标就停在加速度计 + 手动确认，不卡其他功能（`SENSE-02`、D36）。

   ```sh
   tools/probe-record.rb --fact=f13 --name=开合跳 --device="Pixel 6A" \
     --source=manual --attempts=20 --false-counts=1 --distance=180 --lux=320 --frame-ms=28 --temp=34
   ```

2. **对照实验**（只用于按项目分档回填 F13，不阻塞开关）：每项目 ≥200 次，人工计数与算法计数对照，
   按项目（开合跳 / 深蹲 / 坐姿操）与机型分档，同时记帧处理耗时与温升。

   ```sh
   tools/probe-record.rb --fact=f13 --name=深蹲 --device="Pixel 6A" --source=manual \
     --attempts=20 --false-counts=0 --reference=210:640:628
   ```

站位/坐位、距离、光照的具体取值见 `SENSE-04`；用途边界见 `SENSE-03`（只用于计次与节律，不作健康结论）。

## 回填之后会发生什么

- 某机型达标 → `model/day.rb` 的默认档可以按机型抬成 `focused`，界面文案去掉「不响应时自动改为不打断模式」那句兜底；
  `LAYER-07` 的矩阵按机型加一列实测分档。
- 某项目自检达标 → 摄像头通道的默认值由关改为可选开，清单条目 `*.probe.calibration` 由探针证据自动 `done`（`ONBOARD-04`）。
- `DEVICES.md` 的 F12/F13 去掉「待实测」，措辞改成实测结论——**改了数据就要改这里**，否则 `probe-gate.sh` 红。

## 一条不许绕的规矩

`source` 只能是 `adb` 或 `manual`。拿仿真、公开评测或「估计值」当样本，`probe-gate.sh` 直接判红；
模拟数据只能用来验证代码路径，不能用来抬默认档。缺数据就把默认档留在最保守一侧，别替用户猜机型。
