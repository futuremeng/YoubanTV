# 约定与守约（Commitments）

## 1. 结论结构

内核输出两件事：这份约定走到哪一步，以及此刻该做的事。条目见
[`../spec/COMMIT.md`](../spec/COMMIT.md)。

```
CommitState {
  activeProfile, planVersion,                 // 谁签的哪一版约定
  status: honored | due | overdue,            // 守约 / 该做了 / 超时
  due: { kind: quiz|exercise|free, mode: focused|ambient,
         deficit: {kind, amount, unit}, window: {earliest, latest},
         ruleId, nextAction, howToAsk }?,
  log: WATCHED · DONE · ANSWER · ROUND_DONE · OVER · MISSED
       PLAN_SIGNED · PLAN_CHANGE · PROFILE_SWITCH
       MOTION · MOTION_SETTLED · MOTION_UNANSWERED · REVISION · ROLE_CHANGE · REMOTE
}
```

| status | 进入条件 | 呈现 |
|---|---|---|
| `honored` | 免题段内，或约定要求已满足 | 角标显示剩余；完成时一句状态确认，星与掌握进度入账 |
| `due` | 做题或运动的约定到期未达成 | 按 `howToAsk` 呈现题目；`ambient` 不打断，`focused` 请求播放器暂停 |
| `overdue` | 约定时长用尽仍在看 | 状态条显示超出时长；协议页与「这段时间的账」那一页里可见 |

免题段的语义是「这段时间按约定无需做题」，与 `honored` 同一状态。

## 2. 账本

`allowance` 按身份各一套，是当天的**约定线**（目标线）。时长照常记录，超出部分记 `OVER` 并进入
`overdue`。时长、做题、运动、协议各记各的账，之间无发放与夹顶关系：**完成做题或运动只写事件与星 /
掌握进度，不发放也不兑换时长**，契约里没有 `grantMinutes` 这类字段（`COMMIT-05`、`AUTO-13`）。
按约定获批的临时加时是**当日约定线的偏移**，单独留痕，不改动 `dayPlan` 本身（`AUTO-03`）。

## 3. 未达成的后果

| 后果 | 落在哪 | 可见范围 |
|---|---|---|
| `MISSED` 事件 | 本人账本 | 本人 + 家庭协议页 |
| 补一补池 +1 | 该身份内容绑定的题库 | 本人 |
| 次日协议新增一条议题 | `plan` 模块 | 协商强度下双方；自管强度下只在该身份那一页的账（`REPORT-03`） |
| `overdue` 状态条 | L1.5 | 本人 + 面板 |

新增后果需追加进这张表，取值只有这四类（`COMMIT-06`）。需要物理停止观看时走 L5：智能插座断电、
HDMI-CEC 切源、路由时段，由家庭自行安装与配对。

## 4. 两种参与形式

`participation: focused | ambient` 是所有任务与运动项目的通用属性。

| | focused（停下来做） | ambient（边看边做） |
|---|---|---|
| 实现 | 请求播放器暂停（音频焦点 + 媒体键）+ 题目浮层；作答结束后恢复播放 | 内容持续播放，题目在角落、第二屏或手机端 |
| 题目形状 | 长题、多选、填空、主观题均可 | 题干 ≤30 字、每选项 ≤2 行、单键作答、预估 ≤5 秒；题型限于预测 / 观察 / 判断 |
| 降级 | 播放器未响应暂停请求 → 自动转 `ambient`，界面写明「本机尝试暂停内容未成功，已改为不打断模式」（F12） | — |
| 内容包声明 | 每题 `supports: [focused, ambient]`，缺省按 `focused` | 同 |

运动项目是同一属性的另一个实例：`focused` = 暂停内容做满一组；`ambient` = 边看边做，由传感器端计次
（手机端与传感器端的实现见 [`MOBILE.md`](MOBILE.md)、[`../spec/SENSE.md`](../spec/SENSE.md)）。

适用条件：`focused` 适合剧集、课堂、纪录片等有明确暂停点的媒体；短内容流媒体上 `ambient` 是合适的默认值。
`presentationHints` 里的内容类型字段决定每个包的默认 `mode`。

## 4b. 在场档位与共看

`aloneMs` 是该身份当前的独自观看时长（可测行为量）。它决定 `presence` 形态与 `inviteTier` 打扰档位
（`quiet` / `light` / `engaged`，取值见 `SENSE-07`），也决定向其他家庭成员设备发出一条时长提示。
显示给使用者的对偶量是 `withMs`：今天一起看了多久。共看时段（`dayPlan.slots.type = co-watch`）内
提示收敛为静默运行，时长与题目按该身份的约定照常。运动计次与共看邀请共用同一条计次入口，
但各自入账（`SENSE-01`）。

## 5. 强制力

层取值只有 `L0 / L1 / L1.5 / L2 / L3 / L5`；`L4` 是保留空位（D23）。应用可被随时卸载，关于页写明这一点。
设备待确认清单不改变强制力：未确认的条目只把对应能力降到保守档，不阻断、不打分（`ONBOARD-05/06`）。
应用内的暂停与解除暂停由**已受理的动议**触发，效果是状态与提示（`COMMIT-07`、`AUTO-16`）；受理发生在
被请求方自己的界面，单用户场景下天然是异步的（`PROFILE-10`）。L5 由外部设备执行，本机只发请求，且
**只由已签署的时段规则触发**：逐次的动议不能命令插座断电或切源。

## 6. 出题与伴看上下文

出题依据的顺序：身份的内容绑定 → 知识大纲 → 履约与答题历史 →（可选）观看上下文。
上下文的取值边界与出网条件见 [`../spec/CONTEXT.md`](../spec/CONTEXT.md)；默认关闭，取值是当前前台窗口的
一条标题，只在内存中使用。

## 7. 生效条件

依据见 [`research/EVIDENCE.md`](research/EVIDENCE.md)（§2 陪伴与在场、§5 内疚式诉求、§7 操纵性设计与 AI 陪伴）。

这套模型依赖三个条件：使用者具备把约定作为抽象目标的能力（经验值约 8 岁以上）、内容存在可暂停或
可穿插的段落、家庭成员本人参与约定。条件不齐时可选的做法是 L5 物理时段，或者由在场的家人直接沟通；
两种做法都在产品文档里写明，作为配置选项。
