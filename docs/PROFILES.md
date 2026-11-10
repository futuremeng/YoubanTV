# 身份模型（Profiles）

## 1. 定义

```
Profile {
  id, label,                                  // 「小明」「爸爸」「奶奶」由家庭自己命名
  audience: child | grown-up | senior,        // 用于内容过滤与默认值挑选
  content: { packs: [packId...],
             outlineScope: { subjects[], levels[] },
             exerciseTasks: [{ kind, targetReps|targetSeconds, safety? }] },
  defaults: { mode: 陪伴式|协商式|自管式,
              schedulePrefs: { allowance, grace, moveFrom, slots, quiet },
              presentation: 标准 | 大字 }
}
```

`audience` 参与两件事：内容过滤、默认值挑选。功能集合与规则逻辑与 `audience` 无关（`PROFILE-01/02`）。

## 2. 三条不变量

| # | 内容 | 实现方式 |
|---|---|---|
| I1 | 功能与身份无关 | CI 门：`audience` 在 `core` / `device` 里只出现在内容绑定与默认值两处（`PROFILE-02`） |
| I2 | 能力对所有身份相同 | 契约与代码里没有额度上限、年龄闸门、按身份的功能开关这类字段 |
| I3 | 差异只有三处 | 内容绑定、默认值、呈现令牌 |

协商强度由每个身份自己选择；切换强度时全部功能保持可见（`PROFILE-03`）。

## 3. 一台设备多人共用：时长归属

设备同一时刻只有**一个操作者与一个激活身份**：多人共用靠模式切换，不是并发多用户（D35、`PROFILE-10`）。
时长与约定按激活身份记账：

- 每个身份有自己的一套 `dayPlan`（默认值不同）与自己的记录：`watchedMs`、`roundsDone`、`pauseMs`、
  `overMs`。
- 计时归属当前激活身份；`WATCHED` / `DONE` / `ANSWER` / `ROUND_DONE` / `OVER` / `MOTION` / `MOTION_SETTLED`
  都带 `profile` 与
  `device`。同一身份在多台上的当日时长是各设备事件的并集，重叠区间去重（`MOBILE.md §5`）。
- 身份切换写 `PROFILE_SWITCH(from, to, at, reason?)`，当前身份在角标旁常驻可见。
- 未选身份时计时会话记为 `profile=none`，并给出选择身份的提示。
- 老人身份的默认值把约定线设得很宽、时段用途取「仅时段内需要答题」、免题段覆盖全天：体验上是安静运行，
  实现上是同一套机制的另一组默认值。

用量透明度由三处提供：面板按身份显示时长与切换记录；时段规则按身份生效；账本对自己完全可见、对他人只读。
需要约束某个身份的观看时间时，配置项是时段规则与家庭协议。

## 4. 内容与大纲

| audience | 内容 | 状态 |
|---|---|---|
| child | 学科题库 + 学科知识大纲 | 首发：自创 CC0 种子包 |
| grown-up | 通用题库（健康、法律、驾驶、理财、语言…）+ 成人知识大纲 | 后续内容包 |
| senior | 大字题、慢速题、防骗常识、戏曲 / 历史 / 健康大纲 | 后续内容包 |

- 题目 schema v3、`verify` 语义与大纲三表（`outline_topics` / `outline_edges` / `topic_progress`）对所有
  身份同一套。
- 内容包 manifest 带 `audience[]` 与 `presentationHints`；一个包可绑定多个身份。
- 新增一个 audience 的工作量是一个数据包加一份内容绑定。

## 5. 运动

`exerciseTask = { kind, targetReps | targetSeconds, safety? }` 来自身份的内容绑定；`safety` 对平衡与单腿类
项目必填（`SENSE-05`）。运动计次只写 `ROUND_DONE` 入账，**不发放也不兑换观看时长**
（`COMMITMENTS.md §2`）。`ExerciseCounter` 只数节律，与信号源无关（自动计数 / 分层传感器端 / 本人手动确认走同一入口，确认由
该身份自己在设备上做，`AUTO-14`）；手动确认与传感器上报共用 `POST /api/exercise`，按激活身份记账。

条目示例：孩子 开合跳 / 深蹲 / 原地跑；大人 快走 / 拉伸 / 力量组；老人 坐姿操 / 慢走 / 平衡练习。
每个身份的 `moveFrom` 与运动时长是各自的默认值；约定里也可以只有做题、没有运动段。

## 6. 界面与协议

- 启动时选择激活身份，记住上次；学习页、状态条、账本页顶部显示当前身份。切换提示走 L1.5。
- 主体一律是 `member:<id>`（全体成员同一主体）+ `roles: [ruleEditor, keyHolder]`（D33）；端点 `GET /api/me`、
  `PUT /api/myPlan`、`POST /api/me/purge`、`POST /api/motions` 对所有成员同一语义。
- 面板的「这一档」页做四件事：命名、绑定内容包与大纲范围、选协商强度、选呈现令牌。
  新成员加入后，每台已装配设备自动多出与该成员有关的待确认条目（`ONBOARDING.md §4`）。
  角色的交接与轮值在**本机当前激活模式内**完成（`AUTO-09`）；面板与其它设备只读这份归属记录。
  学习参数（组数、每组题量、每次题目数上限、补一补是否先补完）不在面板编辑：由该身份在学习端自己设，
  面板只显示当前值与改动记录（`AUTO-14`、D31）。
- `presentation: 大字` 的取值是字号档整体上移一档、对比度提高、遥控键位收敛到 4 键；规则与文案集合相同，
  仍满足字号门禁（电视正文 ≥20f）。
- 身份被删除时，其内容与协议转为归档，历史账本保留。

## 7. 影响的文档

| 位置 | 内容 |
|---|---|
| `PRODUCT.md §1 §7` | 身份表与协商强度 |
| `spec/AUTONOMY.md` | `AUTO-07` 强度由身份选择；`AUTO-10` 主体由激活身份派生；`AUTO-14` 学习参数归本人；`AUTO-15` 批改与确认为查阅修订 |
| `spec/DAY.md` | 记录与零点刷新带 `profile` 维度 |
| `spec/GATE.md`→`COMMIT.md` | 判定取激活身份的四量；`window` 按身份算 |
| `spec/LAYER.md` | LAYER-07 矩阵按强度 |
| `DECISIONS.md` | D12 / D13 / D20–D22 / D31 |
| `ARCHITECTURE.md` | `core/profile`、`audience` 的 CI 门、端点与主体 |
| `ROADMAP.md` | M1 的 PROFILE 规格与契约字段、M3 的身份选择器、M5 的 `audience` 标注 |
