# PROFILE —— 身份模型条目

条文见 [`../docs/PROFILES.md`](../docs/PROFILES.md)。这里是可测的断言。

### PROFILE-01 身份只决定内容与默认值
`Profile = {id, label, audience, content{packs[], outlineScope{}, exerciseTasks[]},
defaults{mode, schedulePrefs, presentation}}`。契约与代码里**不存在**按身份的权限字段、
功能开关字段、能力上限字段。

`roles: [ruleEditor, keyHolder]`（`AUTO-10`）是例外中的例外：它是**经家庭协议授予与收回的可变角色**，
住在成员身上而不是 audience 上；任一 audience 都可持有任一角色，角色不得由 `audience` 推导（CI 门见 `PROFILE-02`）。

### PROFILE-02 机制不分身份（CI 门）
`core/` 与 `device/` 里按 `audience` 分支的代码只允许出现在两处：**内容绑定解析**与**默认值挑选**。
其余出现即红。判据：`profile.audience` 不得出现在 `commit`、`day`、`enforcement`、`task`、`srs`、
`grade`、`net` 的条件表达式里；`roles`（`AUTO-10`）也不得由 `audience` 推导。

### PROFILE-03 能力范围一致
不存在 `allowanceCeiling`、`ageLimit`、`selfManageRequiresAge`、`featureToggleByAudience`。
协商强度（陪伴式 / 协商式 / 自管式）是约定字段编辑权的**委托程度**（`AUTO-07`），由身份自己选，
切换档位不改变任何功能可见性，也不需要谁批准；角色（`ruleEditor` / `keyHolder`）同样与 `audience` 无关。

### PROFILE-04 时长归属激活身份
- 设备同一时刻只有一个激活身份（`PROFILE-10`）；`WATCHED` / `DONE` / `ANSWER` / `ROUND_DONE` / `OVER` /
  `MOTION` / `MOTION_SETTLED` 均带 `profile` 与
  `device`。事件集合以 `PRODUCT.md §3` 为单一清单。
- 每个身份有独立的一套 `dayPlan` 与四量；跨身份不得互相扣时间，也不得互相设上限。
- 同一身份在两台设备上**各自记账**：这台的判定只算这台的事件，另一台的段不进这台账（`DAY-10`、D77）。
- 未选身份时写 `profile=none` 的空转会话，不做判定（`COMMIT-11`），并给出选择身份的提示（L1.5）。

### PROFILE-05 切换留痕，不设防
- `PROFILE_SWITCH(from, to, at, reason?)` 事件；界面上当前身份常驻可见（角标旁）。
- 身份切换由使用者自主完成；面板按身份显示用量与切换记录。
- 成员若认为需要约束，走时段规则、家庭协议或一条已受理的动议，**不通过**给某个身份加能力上限实现。

### PROFILE-06 内容按身份绑定，schema 不分身份
- 题目 schema v3、`verify` 语义、大纲三表（`outline_topics` / `outline_edges` / `topic_progress`）
  对所有身份同一套。
- 内容包 manifest 带 `audience: [child|grown-up|senior]` 与 `presentationHints`；一个包可绑多个身份。
- 大人与老人的题库与大纲以数据包交付；新增一个 audience 的工作量是数据加内容绑定。

### PROFILE-07 运动是通用机制
`exerciseTask = {kind, targetReps|targetSeconds, safety?}` 来自身份的内容绑定（平衡与单腿类的 `safety` 必填，
`SENSE-05`）；`ExerciseCounter` 只数节律（不绑信号源，摄像头 / IMU / 手动三条路同一入口）；
`POST /api/exercise` 按激活身份写 `ROUND_DONE`，**不增减也不发放观看时长**（`COMMIT-05`）。
代码里只有一个运动模块。

### PROFILE-08 主体一律是成员，权力是角色
- `principal = member:<id>`（全体成员同一主体）+ `roles: [ruleEditor, keyHolder]`，由家庭协议授予与收回
  （`AUTO-10`、`AUTO-09`、D33）；契约里不保留 `parent` 主体。
- `/api/me`（账本与规则视图）、`/api/myPlan`（自管字段，以及自管强度下的
  整份计划）、`/api/me/purge`（清除自己的记录）、`/api/motions`（动议）对任何成员同一语义
  （自管字段见 `AUTO-14`，动议见 `AUTO-03`）。
- 一个身份被删除时：其内容与协议保留为归档，不静默删数据；面板明确说清留了什么。

### PROFILE-09 呈现差异只走令牌
`presentation: 标准 | 大字` 只改字号档、对比度、遥控键位收敛；**不得**因此改变规则、功能或文案集合。
大字档必须仍满足字号门禁（电视正文 ≥20f）。

### PROFILE-10 单用户场景：一次一个人，电视端多一个模式切换
- 任一设备在同一时刻只有**一个操作者与一个激活身份**；不存在两个主体并发写同一本账。写入串行化为
  事件顺序，分歧以事件顺序为准（`DAY-07`）。
- 电视端区分人靠**模式切换**（`PROFILE_SWITCH`），不是并发多用户；手机端是单用户（家庭成员各用各的
  设备），没有模式切换这一层（`MOBILE.md §1`）。
- 因此所有「需要对方同意」的动作天然**异步**：对方界面里一条待受理；双方不需要同时在场，也不需要
  跨设备信令与新端点（`AUTO-16`）。
- 角色的授予、接受与收回只发生在**本机当前激活模式内**：交出 = 在对方自己的模式里由他本人点「接受」；
  收回 = 在自己模式里点「交回」（`AUTO-09`）。

### PROFILE-11 这一档的约定项有哪几类，按受众挑一次
- 条件：这份清单写在 `agreement.defaults` 按受众的那几行里（`dueKinds`，取值 ∈ `dueKind`）——**位点只有一处**，
  就是 `PROFILE-02` 的默认值挑选。孩子的两类都要（题目 + 运动）；大人只要运动；老人的两样都不要，
  只剩时长那一本账。**内核不自己发明种类**：清单里没有的种类不出到期项。
- 结论：`due.kind` ∈ 这份清单；清单为空即 `due=null`，判定的其余部分照常（`overdue` 与受众无关，`COMMIT-04`）。
  这一条堵住的是一句兑现不了的承诺：大人与老人的屏上**不会出现「还差 N 题」**（`D76`）。
  题对这两档是**可选的**——装了绑到这一档的包就有题可做、自由练习那一类任务照旧能开，
  只是不构成到期项、不会被追问；「有题可出」不再是这一档可用的前提（`PACK-05`、`ASK-01` 的兜底那一层照旧）。
- 测试：fixtures/profile.yaml#PROFILE-11
- 依据：`docs/DECISIONS.md#D76`（内容不是这一档的前提）、`docs/PROFILES.md` 的内容那一行
- CI 门：`core` 与 `device` 里任何写入口的 `profile` 参数只能取**当前激活身份或 `none`**；「以他人身份写入」
  的路径不存在。
- 测试：`fixtures/profile.yaml#PROFILE-10`（跨身份写入路径不存在；动议只能由被请求方本人受理）
