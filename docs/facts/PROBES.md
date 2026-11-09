# F12 / F13 实测协议

这两条是**机型事实**，只能测出来，不能推出来。仓库里的默认值不等它们（D36）：没数据就是最保守档——
`focused` 不作默认档（`LAYER-07`）、摄像头通道默认关（`SENSE-02`）。测出来之后抬默认档只走下面这条路。

样本落在 [`probes/f12.yaml`](probes/f12.yaml) 与 [`probes/f13.yaml`](probes/f13.yaml)；
两者与门槛常量、[`DEVICES.md`](DEVICES.md) 的措辞由 [`../../tools/probe-gate.sh`](../../tools/probe-gate.sh) 校验一致。

## F12 请求播放器暂停的响应率

**要测的东西**：音频焦点丢失 / `KEYCODE_MEDIA_PAUSE` 在各机型自带播放器与第三方播放器上是否真的停下来。
遥控器能收到广播（F10）不算——「广播被收到」与「播放器照办」是两件事，分开记。

一台连着 adb 的设备上，一条命令跑完 20 次：

```sh
brew install android-platform-tools          # 或装你自己的 platform-tools
adb devices                                  # 确认设备已授权
# 先在设备上把内容播起来（自带播放器或第三方播放器，各跑一轮）
tools/f12-adb-probe.sh "Pixel 6A" stock 20 --android=14
```

脚本每轮做：确认处于播放态 → `KEYCODE_MEDIA_PAUSE` → 读 `dumpsys media_session` 的状态 →
`2`（已暂停）记 1，否则记 0 → 恢复播放 → 下一轮。跑完自动写进样本文件并给出结论。

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
