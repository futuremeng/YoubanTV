# GATE —— 迁移映射（本页只用于查旧编号）

判定表已退役，实现见 [`COMMIT.md`](COMMIT.md)。本页保留编号对应关系，便于查历史夹具与旧记录。
**本页的编号不得出现在代码的 `SPEC:` 标签里**（追溯门只认 `### <id>` 标题，本页无条目）；
引用现役纪律时直接写 `COMMIT-*` 或本页的「仍然有效的纪律」段。

| 旧 GATE | 旧语义 | 现在 |
|---|---|---|
| GATE-01 | 家长暂停 = 冻结倒数、余额不变 | `COMMIT-07`（需 `pause` 动议受理；`pauseMs` 单列，冻结段与 `watchedMs` 分列） |
| GATE-02 | 自由时段 | `dayPlan.quiet` + `COMMIT-01`（免题段） |
| GATE-03 | 时段外拒绝启动 | 时段规则按身份生效，呈现走 L1.5 / L2（`LAYERING.md §2` 第 3 行） |
| GATE-04 | 免答题额度剩余 | `COMMIT-01` |
| GATE-05 | 余额剩余 → 出题解锁 | `COMMIT-02`（`due.kind=quiz`） |
| GATE-06 | 额度用完 → 锁屏 | `COMMIT-04`（`status=overdue` + `OVER`） |
| GATE-07 | 运动段 | `COMMIT-03`（`due.kind=exercise`） |
| GATE-08 | 组数用完 | 组数作为任务参数由该身份自设，见 `DAY-05`、`ASK-07`、`AUTO-14` |
| GATE-09 | 需要答题才继续 | `COMMIT-02` / `COMMIT-05` |
| GATE-10 | 暂停语义 | `COMMIT-07` |
| GATE-11 | 判定单点实现 | `COMMIT-09`（单一实现 + 呈现纪律） |

仍然有效的纪律：题目预载（作答时只渲染）、呈现写 `due_shown` 事件、界面只读内核结论。

`nextAction` 的取值现为 `quiz | exercise | free | motion | none`；`hold` 在枚举范围之外。
`verdict`、`unlocked`、`unspentMs`、`phase` 已退出契约。
D33 / D34 后的别名退役：`parent` 主体→ `member:<id>` + `roles`；`REQUEST` / `REQUEST_SETTLED` →
`MOTION` / `MOTION_SETTLED`（超时未受理另写 `MOTION_UNANSWERED`）；`POST /api/requests` → `POST /api/motions`；
`control` scope → 退役（单用户场景下没有「远端控制」这件事，受理不是一种权限；`ARCHITECTURE.md §5`）。
