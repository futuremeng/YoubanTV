# 事实数据：F12 / F13 的实测样本

这两个文件是 F12、F13 的**样本登记处**。协议与跑法见 [`../PROBES.md`](../PROBES.md)。
默认值不因这里空着而卡住（D36）：空着就是最保守档——`focused` 不作默认、摄像头通道默认关。

门槛常量写在这里，与 [`DECISIONS.md`](DECISIONS.md)「暂定取值」表由 `tools/probe-gate.sh` 校验一致。

## F12 请求播放器暂停的响应率

`source` 只能是 `adb`（脚本自动记）或 `manual`（人工对照记）。
`simulated` / `estimated` 一律**不得**用来抬默认档，`trials: []` 表示未测。

```yaml
threshold: { sampleMin: 20, responseRate: 0.95 }
devices:
  - model: 待填
    android: 待填
    player: stock        # stock | third-party
    source: pending
    trials: []           # 1 = 暂停真的停了，0 = 收到广播但没停
```

## F13 手机端姿态计次的可用性与误计率

```yaml
threshold: { selfTestAttempts: 20, falseCountMax: 0.05, referenceTrials: 200 }
projects:
  - name: 开合跳
    device: 待填
    cameraDistanceCm: null
    lightLux: null
    selfTest: { attempts: 0, falseCounts: 0 }   # 首次标定自检：决定摄像头通道能否开
    reference: { trials: 0, manualSum: 0, autoSum: 0 } # 与人工计数对照：只用于分档回填
    frameMs: null
    tempC: null
    source: pending
```

## 谁读这份数据

- [`LAYER.md`](../../spec/LAYER.md#LAYER-07) / [`DECISIONS.md`](../DECISIONS.md) 的 D36：某机型响应率达标 → `focused` 才作默认档。
- [`SENSE.md`](../../spec/SENSE.md#SENSE-02) / [`SENSE-04`](../../spec/SENSE.md#SENSE-04)：标定自检达标 → 摄像头通道才允许开。
- [`DEVICES.md`](DEVICES.md) 的 F12/F13 措辞必须与这里的状态一致，由 `tools/probe-gate.sh` 守。
