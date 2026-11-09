# 落地路线

原则：每片单独可验证；跨片变更单独立片；每片收口跑一次 `make check`（契约 + 决策表 + 设计棘轮 + 字号 +
包校验 + 血统扫描，`ARCHITECTURE.md §8`）。里程碑**编号按决策先后分配**，执行顺序以下表的
依赖列为准（M7 是收口片，M8 与 M4 并行）。

## M1 · 规格化与契约

| # | 交付 | 验收 |
|---|---|---|
| 1.1 | `contract/contract.json` v1（**已入库**）：端点、schema、枚举、`principal: member:<id>` + `roles: [ruleEditor, keyHolder]`（D33）、`protocolVersion`；`Profile` 与 `audience` 字段；自管字段四项的**本人写入口**（`AUTO-14`）；动议端点 `POST /api/motions`（D34，含 `roleChange` / `coWatch`）；scopes 清单 `read/rules/content/grade/diagnostics/egress`（`control` 退役）；`forbiddenFields`（含 `forbiddenEvents`）与 `retired` 段；`egressSwitch` 枚举与事件的 `auxValues`（`due_shown` / `llm_generate_failed` / 审计）| 面板与设备端由它生成；`make contract` 一条命令（**待生成器**）；schema 字段集与 `PROFILE-01` 一致；非本人的 scope 对自管字段只读；`roles` 不由 `audience` 推导（CI）；写入口的 `profile` 只能取当前激活身份或 `none`（CI，`PROFILE-10`）；`tools/check-contract-refs.sh` 已跑绿 |
| 1.2 | 决策表夹具 `fixtures/{commit,day,profile,ask,onboard}.yaml`（**已入库**：63 条规格条目、179 条用例，覆盖 `COMMIT` / `DAY` / `PROFILE` / `ASK` / `ONBOARD` 全部条目与 `AUTO` / `PACK` 的可判定部分）+ 断言词汇 `fixtures/vocab.yaml` 与格式说明 `fixtures/FORMAT.md`（D41：249 个自由键收敛到 46 个谓词） | 每条分支 ≥1 条；`COMMIT-01`、`COMMIT-07` 与 `COMMIT-11` 各含对应断言（冻结时长与 `pauseMs` 单列 / 恢复续算 / `profile=none` 不判定）；每条 `due` 断言同时给出**形态层与落层**（`ARCHITECTURE.md §9`）；`tools/check-fixtures.sh` 已跑绿（键与取值合法，反向验证可失败）；**夹具执行器已跑绿**（`tools/run-fixtures.rb` 跑 `model/` 的规范模型）：`COMMIT-01/02/03/04/11` 与 `DAY-01/06` 共 78 条断言全绿、0 未支持（其余条目 121 条断言通过、0 失败、210 条如实记未支持），反向验证（改坏判定、改坏幂等、去掉边界条件）都能变红；其余条目按「未支持」如实报出
| 1.3 | `spec/ASK.md`、`spec/PACK.md`（含 `audience`、`presentationHints`） | 选题管线与内容包格式可照此实现 |
| 1.4 | 内核输出结构定稿：`CommitState` + `tierFor(due)`（与 `LAYER-07` 的强度默认档合成落层） | 契约、`ARCHITECTURE.md §9`、`LAYERING.md §3`、夹具四处一致 |

## M2 · 内核（纯 Kotlin JVM）

`profile → ledger → day → commit → session → task → ask → srs → plan → context → content → verify`

- 验收：决策表分支覆盖 100%；重放 CLI；假时钟场景（跨零点 / 暂停冻结 / 改表跳变 / 免题段）；
  `core` 的 import 集合只含 Kotlin 标准库。
- CI 门：`enforcement` 与阻断类 API 在 `core` / `device` 中的出现位置（`COMMIT-10`）；
  `audience` 的分支位置限定为内容绑定与默认值两处（`PROFILE-02`）。
- 内核依赖关系由构建脚本断言：`core` 只被 `device` / `panel` 依赖。

## M3 · 设备端最小闭环

`capability`（当前层 + 探针）、`enforcement` 的 **L1 + L1.5 + L2 + L3**（接口 `present(due, tier)`）、
`store`（`profiles` + 带 `profile` 的事件）、`net`（主体 `member:<id>` + `roles`）、**身份选择器**、**清单页**（`onboard` 派生 + 首启引导前五项）、
题目浮层（`focused` 请求暂停 / `ambient` 角标）、状态条、引导页。

- 验收：一台电视盒子 + 一台手机跑通「选身份 → 免题段 → 约定到期出题（两种形式都能跑，暂停未响应自动转
  `ambient`）→ 计时 → 超时（记 `OVER` + 状态条）→ `pause` 动议受理后暂停（提示 + `pauseMs` 记账）→ 恢复 →
  切换身份互不结转 → 未选身份不判定（`COMMIT-11`）→ 零点刷新按身份各算 → 清单页能把未完成项逐条降级到位」；
  重启一次、改表一次、拔网一次；包体 ≤5MB；升级演练保留数据。
- 生命周期与清理：`onStop` + 前台服务 + 开机重探。设备控制面在设备端只有媒体控制与悬浮窗两项。
- L4 的取值在枚举里为空位；需要物理停止观看时由 L5 承担，配置入口在面板「设备」页。

## M4 · 家庭面板

契约生成的客户端；规则三层 + 家庭协议（自管字段四项只显示与回看，无写入口，`AUTO-14`）；**计划模拟器**（`GET /api/simulate` 调内核同一份代码）；
能力与层级视图（当前层 + 升降层历史）；**动议的历史与只读视图**（受理只发生在被请求方自己的界面，
`AUTO-03`、`PROFILE-10`）；题库与内容包；自评结果的**查阅与修订**（`AUTO-15`）；
成长记录；诊断（含每台设备的**待确认清单**与完成度，`ONBOARDING.md §5`）；关于。角色与轮值的交接入口不在面板上（`AUTO-09`）。

## M5 · 内容包

`.qpack` 格式（含 `audience`、`presentationHints`）与许可校验；自创 CC0 种子题库（300–800 题，编写位置按
D19 与 `PROVENANCE.md §2`）；按身份绑定与统计；实时出题与「收下这题」；`/api/topics`。

- 大人与老人的题库与知识大纲以数据包交付，接口即 `PACK-01`（`PROFILE-06`）。
- 验收：`unpack` 后 APK 内的题目数据只命中种子包；装一个带 CC BY 的包时署名与许可在界面可见。

## M5.5 · 伴看智能体（依赖 M5 与 M2 的 `commit`）

- 出题管线：内容绑定 → 大纲 → 履约历史 →（可选）上下文 → 机检 → 按 `mode` 呈现；
  首发提供 `onDemand` 与 `timed`，`atPausePoint` 作为实验特性（`CONTEXT-06`）。
- 伴看上下文开关与取值边界（默认关、一次一条前台标题、内存内）；题目角落显示「依据：当前节目名称」。
- authoring 门禁：`ambient` 题的字数、选项行数、单键可答校验；机检通过的题才入库。
- 验收：开关关闭时抓包结果为空；开启时出网请求只有题目请求且题目带依据标注；对某节目设置排除后
  该节目期间出现的是大纲题。

## M6 · 周边

Home Assistant 与只读令牌；L5 执行器（CEC / 智能插座 / 路由时段，需配对）；更新链 + 可复现构建 + SBOM；
传感器端与运动计数（D4、`SENSE-01..07`）；跨城共看的可选自架信令端点（D27）；安装指南与文案打磨。

## M8 · 手机端陪伴端

`device` 的 mobile 装配（学习面）、`sense`（节律计次 + 标定与自检）、`presence`（共看安排与邀请、
在场提示、原话送达）、`sensor` 角色复用。

- 验收：同一身份在电视与手机上各看 20 分钟（含 5 分钟重叠）后当日时长为 35 分钟；手机端与电视端的
  约定状态一致；共看邀请一步接受后两台设备显示同一状态条；`presence` 三档的邀请频率上限按契约生效；
  摄像头通道关闭时抓包与文件扫描都无画面相关数据。
- 依赖：M2（`commit`）与 M3（capability）；只有「作为电视端的传感器端」一项依赖 M6（`SENSE-06`），
  其余可与 M4 并行。
- F13 未回填时，摄像头通道保持默认关，交付内容为加速度计节律 + 手动确认；开启只看首次标定的自检门槛（D36）。

## M7 · 装机与（未来的）发布

现阶段是**私域装机**：内部 tag、家庭内安装、自家两台设备的真机验收（逐台把清单页的固定项跑完并回填
`facts/DEVICES.md`）、`NOTICE` 与
`THIRD_PARTY_NOTICES` 复核、从旧 fork 的导入向导（D3）。

公开发布是独立切片，触发条件与前置事项见 `DECISIONS.md` 的 D30 与「转为公开前要补齐的事」
（历史检查、N1–N5、更新通道宿主、面向第三方的隐私措辞、CC0 来源声明）。

## 依赖与并行

| 片 | 依赖 | 可并行 |
|---|---|---|
| M1 | — | — |
| M2 | M1.4（接口形状定稿） | 与 M3 同步开工 |
| M3 | M1.4 | 与 M2 同步开工 |
| M4 | M2、M3 | 与 M5 / M5.5 |
| M5 → M5.5 | M2（`commit`） | 与 M4 |
| M6 | M3（能力登记表）、M5（包校验） | 与 M8 |
| M8 | M2、M3；仅传感器端子项依赖 M6 | 与 M4、M6 |
| M7 | M1–M6、M8 全部收口 | — |

关键路径：M1 → M2 → M3 → M4 / M5 → M5.5 → M6 → M7；M8 从 M3 定稿后并入，与 M4 / M6 并行，
在 M7 收口前交付。

- D3 / D4 / D5 / D7 / D8 / D9 / D10 / D11 只阻塞对应里程碑。
- D15 / D16 / D17 / D23 / D24 / D25 / D31 / D32 / D33 / D34 / D35 / D36 / D37 / D38 / D39 / D40 已定，直接落进 M1–M5.5；D26 / D27 / D28 落进 M8 与 M6。
- F12 与 F13 **不再阻塞默认值**（D36）：`focused` 按探测响应率≥95% 逐机型抬档，探不到即 `ambient`；
  摄像头通道按首次标定的误计率门槛开启，未达标就停在加速度计节律 + 手动确认。两项探针在 M6 内交付。
