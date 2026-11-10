# COMMIT —— 约定引擎条目

`spec/GATE.md` 退役，判定顺序由本表接替。规则不变：**只有一份实现**，界面与面板只读它的输出，
四量按激活身份取，判定不因 `audience` 而不同。

### COMMIT-01 免题段
- 条件：`watched[profile] < grace[p]`
- 输出：`status=honored`，`due=null`
- 界面：角标显示剩余，处于该段时不出题。

### COMMIT-02 做题约定到期
- 条件：`grace[p] ≤ watched[p] < moveFrom[p]` 且今日做题约定未达成
- 输出：`due{kind:quiz, mode, deficit:{questions|accuracy}, window, howToAsk}`
- 界面：按 `mode`——`ambient` 用角落浮层；`focused` 先请求播放器暂停，答完恢复；暂停未响应时转 `ambient`
  并说明当前模式（F12）。

### COMMIT-03 运动约定到期
- 条件：`watched[p] ≥ moveFrom[p]` 且运动约定未达成
- 输出：`due{kind:exercise, mode, deficit:{reps|seconds}}`；`nextAction=exercise`
- `ambient` 由传感器端计次；`focused` 暂停内容做满一组；本人手动确认走同一条 `POST /api/exercise`
  （`signalSource=manual`，由该身份自己确认，`AUTO-14`）。

### COMMIT-04 超时 = overdue，不阻断
- 条件：`watched[p] ≥ allowance[p]` 且仍在观看
- 输出：`status=overdue` + `OVER` 事件累加；呈现只有状态条
- 边界取 `≥`：恰好等于约定线即 `overdue`；`overMs = 0` 时**不写** `OVER`（零量事件只是噪声）
- 界面：L1.5 状态条「超出约定 <X> 分钟」；家庭协议页与「这段时间的账」那一页里可见。措辞为状态句（`LAYER-09`）。

### COMMIT-05 达成即 honored
- 条件：约定要求全部满足
- 输出：`status=honored` + `DONE` / `ROUND_DONE` 事件；激励入账范围只有星与掌握进度，
  时长不按完成发放或兑换（`AUTO-13`、`COMMITMENTS.md §2`）。

### COMMIT-06 未达成约定的后果
`MISSED` 落账、补一补池 +1、次日协议自动加一条议题、`overdue` 状态条（L1.5）。共四类，无其它出口。
自管强度下这些只出现在自己那一页的账（`REPORT-03`）。新增后果需追加进 `COMMITMENTS.md §3` 的表。

### COMMIT-07 暂停的实现
`pause` 动议受理后变更状态（`AUTO-03`、`AUTO-16`）：提示条 + 角标「已暂停 <时长>，<时刻> 恢复」；
`pauseMs` 单列记账，暂停时长与 `watchedMs` 分列；播放状态由使用者与设备保持。解除后从冻结值继续。
对他人计时会话的暂停只能走动议，**受理只发生在对方自己的界面**（`PROFILE-10`）；对自己的计时会话可即时暂停。

### COMMIT-08 约定的版本与签署
`PLAN_SIGNED(profile, planVersion, by:[self,counterparty])`；未签署的计划不生效；收紧自下一份签署生效（`AUTO-04`）；
`planVersion` 进每条事件，事后能回答「当时按哪版约定判的」。规则字段本身的变动写 `PLAN_CHANGE`。

### COMMIT-09 状态必须可解释
每个 `due` 都带 `ruleId` + `deficit` + `nextAction` + `window`；界面不得自行判断或拼文案（判定单点
实现的纪律由 `GATE.md`「仍然有效的纪律」段继承）。每次呈现写 `due_shown` 事件，用于回答「这道题是什么时候问的」。

### COMMIT-10 设备控制面的取值（CI 门）
`enforcement` 的接口面只有 `present()`；可调用的系统控制只有媒体暂停 / 恢复请求（由已受理的动议或本身份
自己的动作触发）与悬浮窗呈现。`pause(profile = <他人>)` 这类单方面控制 API 同样出现即红（`AUTO-16`）。
Lock Task、设备管理员、`performGlobalAction`、全屏遮罩、`flagSecure`、播放劫持这几类 API 在
`core` 与 `device` 中出现即红。`Tier` 枚举里 L4 是空位。能改变观看状态的只有 L5，需家庭显式配对。

### COMMIT-11 未选身份时不判定
- 条件：无激活身份（`profile=none`）
- 输出：`status=honored`、`due=null`；计时会话仍以 `profile=none` 落账（`DAY-01`、`PROFILE-04`）
- 界面：L1.5 提示「当前未选择身份，选定身份后才开始按约定计时」；不出题目、不发运动邀请、不发共看邀请
- 测试：`fixtures/commit.yaml#COMMIT-11`
