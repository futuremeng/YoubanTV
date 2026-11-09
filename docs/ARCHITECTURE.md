# 架构与选型

## 0. 结构原则

结论与呈现分离：纯 Kotlin 内核产出 `CommitState`；`enforcement` 按层呈现；界面只读能力登记表；
面板与设备端共享契约，各自实现。

## 1. 仓库布局

```
YoubanTV/
├── spec/                     # 行为规格，一条一个 id；代码里的 `SPEC:` 标签指向这里
├── contract/                 # 契约单一来源：端点 + schema + 枚举 + protocolVersion（已入库：contract.json v1）
├── fixtures/                 # 决策表与行为夹具（已入库：commit、day、profile、ask、onboard）
├── core/                     # 纯 Kotlin JVM，零 android 依赖
├── device/                   # Android 应用（同一套代码，tv / mobile 两种装配）
│   └── src/main/java/com/youban/device/{enforcement,capability,ui,store,net,pack,grade,sense,presence,log}/
├── panel/                    # 家庭面板：Vite + TS，客户端与 DTO 由 contract 生成，产物不入库
├── sensor/                   # 传感器端（手机的传感器角色复用同一份代码）
├── packs/starter-cc0/        # 自创种子题库源，产出 .qpack，不打进 APK
├── tools/                    # 契约生成器、qpack 打包器、决策表夹具执行器、发版与可复现校验、adb 冒烟
├── docs/                     # 用户与运维文档 + 实机事实
└── Makefile                  # make check = 契约（含 `tools/check-contract-refs.sh`）+ 决策表 + 棘轮 + 字号 + 包校验 + 血统扫描
```

每个源文件头部一行 `// SPEC: COMMIT-04`。CI 已实现的静态检查五项：上游标识只出现在
`PROVENANCE.md` / `NOTICE` / `NAMING.md §3` 登记的位置；`SPEC:` 引用的条目存在；新增出网地址先登记；
内核不含执行手段与包名；跨身份写入路径不存在（写入口的 `profile` 只能取当前激活身份或 `none`，
`PROFILE-10`；契约与夹具的引用完整性由 `tools/check-contract-refs.sh` 守（数据侧已实现：契约与夹具
里引用的每个条目都必须存在，契约不得出现禁止字段与退役取值，事件枚举与 `PRODUCT.md §3` 一致）。
**还差一道未实现**：契约级条目至少被一处实现与一处测试引用（需代码，M1 落地）。

## 2. 内核（core）

```
ledger/    事件定义、追加、按天投影、重放
day/       DayPlan、状态计算、生效组数
commit/    约定引擎 → CommitState { status, due{kind, mode, deficit, window, howToAsk}, ruleId }
context/   伴看上下文的取值边界：前台标题一次一条、内存内、按开关取值（CONTEXT-01/02）
session/   计时会话：接受单调时钟差值，产出 WATCHED
task/      任务快照、三种目标类型 × 两种参与形式、通过判定、收紧规则自下一任务生效
ask/       选题管线、知识点状态机、难度阶梯、取材顺序、去重
srs/       SM-2 简化式
profile/   身份 = 内容绑定 + 默认值 + 呈现令牌（PROFILE-01）
plan/      家庭协议与动议（MOTION / MOTION_SETTLED / MOTION_UNANSWERED / PLAN_SIGNED / PLAN_CHANGE / PROFILE_SWITCH / ROLE_CHANGE）
onboard/   设备待确认清单的派生：从事件 + 能力登记表 + roles 现值算出条目与状态，自身不落账
content/   qpack 解析、许可清单校验、题源标记
verify/    求值：白名单语法 + 求值超时 + 回落文本比对
grade/     自评与查阅修订：本人对照评分标准自评 → 星与掌握进度先入账 →（可选）AI 批 → 修订重算；按 opId 幂等
```

- 依赖约束：`core` 只依赖 Kotlin 标准库，`import android.*` / `androidx.*` 由 CI grep 门拦截。
- 时间经 `MonotonicClock` 注入，测试使用假时钟；诊断以结构返回。
- 内核的取值域是约定状态与到期项，界面与面板据此决定呈现；层的选择发生在 `enforcement`。
- `audience` 在内核中只出现在两处：内容绑定解析、默认值挑选。其余模块的条件表达式按 `PROFILE-02` 校验。

## 3. 设备端（device）

| 模块 | 职责 | 关键点 |
|---|---|---|
| `capability/` | 能力登记表：当前层、状态、证据、探测时间、TTL、升层与回退方法 | 探针在后台线程；取不到报 `unknown`；文案只读它 |
| `enforcement/` | 呈现执行器：`Observer` / `Nudge` / `StatusBar` / `InAppAsk` / `OverlayAsk` / `External` | 统一接口 `present(due, tier) -> shown`；接口面只有呈现（`COMMIT-10`）；对他人状态的变更只能经已受理的动议（`AUTO-16`）；层可回退且保留数据；L5 开关留审计事件 |
| `ui/` | 身份选择器、学习页、题目浮层、状态条、引导页、清单页、规则编辑验证、更新页 | 文案按层取（`LAYERING.md §4`）；当前身份常驻可见；「大字」是令牌切换；规则编辑验证只守约定字段的写入，不挡自管字段、查阅修订、计次与安装（`AUTO-14`、`AUTO-15`） |
| `store/` | SQLite：`profiles` + `ledger_events`（含 `profile` 列）+ 按身份投影表 + `questions` + `outline_*` + `reviews` + `requests` + `kv` + `schema_meta` | WAL；建表语句单一来源、列名由 Row 的 `cells()` 提供；schema 变更走老库升级演练（F8） |
| `net/` | 极简 HTTP/1.1 + 由契约生成的路由 + 配对与 scopes + 限流 | 主体 `member:<id>` + `roles`（`AUTO-10`）；`/api/me`、`/api/myPlan`、`/api/me/purge`、`/api/motions` 对所有成员同一语义 |
| `pack/` | 内容包安装 / 卸载 / 统计、后台分批导入 | 逐行分批、每批一事务、重启不重导 |
| `grade/` | 待查阅队列、OpenAI 兼容与 Ollama provider、超时与重试预算、数据披露记录 | 自评与 AI 批先入账（`gradedBy=self|ai`，`AUTO-15`）；修订写 `REVISION` 附理由并重算；密钥只在设备，配置读取只返回「是否已配置」 |
| `sense/` | 节律计次、标定与自检、误计率区间 | 三条信号源归一为节律输入；姿态关键点只在内存（`SENSE-01/02`） |
| `presence/` | 共看安排与邀请、在场提示、原话送达 | 文本与时间戳；跨城走可选自架信令端点 |
| `log/` | 本机环形日志、开机时间线、脱敏导出 | 字段经脱敏；崩溃由本机 handler 记录 |

进程模型：一个前台服务承载判定循环与计时；Activity 画结论；跨进程状态经存储共享。

### 3.1 装配矩阵

| 装配 | 学习面 | 身体面 | 共在面 | 管理面 |
|---|---|---|---|---|
| `tv` | ✓ | 作为被控设备入账 | ✓（提示与角标） | — |
| `mobile` | ✓ | ✓（本机计次 + 可作为传感器端） | ✓ | 面板的响应式视图 |
| `sensor` | — | 计次并上报 | — | — |

三种装配共享 `core`，装配差异只出现在 `device/*/build` 与 `capability` 的取值上。

## 4. 技术栈（🔴 D9）

| 路线 | 内容 | 门槛 |
|---|---|---|
| **A（默认）** | 框架 Views + 自研轻量 UI kit（字号阶梯、令牌主题、焦点装饰、遥控器键位）；依赖只有 Kotlin / JUnit；SQLite 用框架 API + 手写 DAO；HTTP 自行实现 | 正式包 ≤5MB；在役最弱电视盒子答题页无可感知卡顿 |
| B（M6 后再议） | AndroidX + Room + Compose（含 `androidx.tv`） | A 路线给出包体 / 冷启动 / 帧时间基线，且 B 的 spike 劣化 <15% 才切 |

依据：目标设备含 Android 5 的电视盒子与 Android 7.1 的手机（实测：MediaPipe 的 `.so` 在 API 25 `dlopen` 失败）；3 米字号、遥控器焦点、减弱动画在 Views 路线上已有实机验证。
公式渲染用离屏 WebView 栅格化 KaTeX（MIT，取上游发行物）为位图并缓存；渲染失败时显示原文并标注来源。

## 5. 契约与协议

- 端点、schema、枚举单一来源在 `contract/`；面板客户端与设备端 DTO 由它生成。
- 主体与角色：`principal = member:<id>`（全体成员同一主体，D33）+ `roles: [ruleEditor, keyHolder]`；角色的
  交接是**本机当前激活模式内的两次确认**（`AUTO-09`、`PROFILE-10`），不是跨设备的并发会话。
- scopes：`read`（账本与规则视图）/ `rules`（约定字段编辑权）/ `content`（题库与内容包）/
  `grade`（查阅与修订，不含「先批完才入账」这类开关）/ `diagnostics`（日志）；`egress`（出网开关与
  数据保留天数，只有 `keyHolder`）。发起动议不需要 scope（人人可发）；**受理不是一种权限**——它只发生在
  被请求方自己的界面。`control` 已退役（单用户场景下没有「远端控制」这件事，`GATE.md` 别名表）。
  功能集合与成员身份无关（`PROFILE-01`）；对他人状态的变更只能经已受理的动议（`AUTO-16`）；
  自管字段（组数、每组题量、每次题目数上限、补一补是否先补完）只能由本人写入，面板无写入口（`AUTO-14`）。
- 单用户场景（`PROFILE-10`）：任何写入口的 `profile` 参数只能取**当前激活身份或 `none`**；「以他人身份写入」
  的路径在 `core` 与 `device` 中不存在（CI 门）。
- 契约字段取值：`Profile{id, label, audience, content{packs[], outlineScope, exerciseTasks[]},
  defaults{mode, schedulePrefs, presentation}}`；范围外的字段（额度上限、按身份的功能开关）在 schema 里无定义；
  时长兑换类字段（如按组 / 按次发放分钟）同样无定义——完成只写事件（`COMMITMENTS.md §2`）。
  自管字段四项经 `PUT /api/myPlan` 由本人写入（`AUTO-14`），`rules` scope 对它们只读。
  事件带 `device` 字段，用于同一身份跨设备的计时合并。
- 配对密钥绑定**设备 / 面板凭据**（只授予访问），不随角色轮值转移；出网开关绑定 `keyHolder` 角色（`AUTO-10`）。
  密钥 → 短时令牌（scope + TTL）；长令牌**绑定设备 / 面板凭据**，角色从 `roles` 读而不从令牌推导；
  变更出网开关需当场再认证（D38）。改密码或重启令全部令牌失效，配对后密码只用于签发。
- 免验证端点只有 `/api/hello`，字段：型号、协议版本、是否已配对、能力摘要。
- 共在面端点：`/api/cowatch`（安排与邀请）、`/api/messages`（家人原话，文本 + 时间戳，来源标注到人）。
  跨城信令由家庭自架的可选端点转发密文与时间戳，本项目不提供托管服务。
- 写端点幂等（`opId`）；自评、AI 批与修订按 `opId` 去重。`protocolVersion` 覆盖主体与端点变更。

## 6. 设计系统

8 档字号阶梯（75 寸 / 3 米定标：正文 ≥20f、说明 ≥18f、任何文字 ≥16f；手机端逐点钉住）。
`presentation: 标准 | 大字` 的取值是字号档整体上移、对比度提高、遥控键位收敛（D22）。
颜色走角色 + 亮度档命名的令牌；动效在一处判定 `prefers-reduced-motion`；状态同时用形状与文字表达。
两道门禁：设计 lint 棘轮（FAIL 只准降）、字号逐点比对（基线 = 本仓库首个提交）。

## 7. 分发与可复现（现阶段私域）

分发范围限于自家设备（D29）：tag 在私有仓库，APK 经家庭内分发安装；公开 Releases 与镜像在 D30
触发后启用。清单带 sha256 / size / notes / protocolVersion / dbSchema；
依赖锁定 + 构建时间固定化 → 两次独立构建逐字节一致；CI 出 SBOM 与许可报告，白名单 Apache-2.0 / MIT / BSD /
 CC0 / CC-BY（与 `THIRD_PARTY_NOTICES.md` 同一张表），GPL / AGPL / SSPL 与专有二进制进不了依赖树；发版前工作区干净。

## 8. 质量门槛（只准升不准降）

决策表分支覆盖 100%；契约测试；老库升级演练（F8）；内容包装卸演练；`make check` 的六项门禁
（契约 / 决策表 / 设计棘轮 / 字号 / 包校验 / 血统扫描，见 §1）；可复现构建；真机验收含重启、改表、
断网各一次；提交钩子登记新增的 `@SuppressLint` / `@Suppress` / `eslint-disable` / 跳过的测试 / 门禁数字变更。

## 9. 分层执行器 `enforcement/`

内核产出的结论结构：

```
CommitState { status: honored|due|overdue, activeProfile, planVersion,
              due: { kind: quiz|exercise|free, mode: focused|ambient,
                     deficit: {kind, amount, unit}, window: {earliest, latest},
                     howToAsk, ruleId, nextAction }? }
```

层在一处推导，可单测「每条结论落在哪一层」。**形态层**由 `due` 的形状给出：

```
tierFor(due)                                  # 形态首选层
  = due == null                                 → L1 角标（含待受理动议的一条提示）；持续状态（overdue / 已受理的暂停）→ L1.5
  = kind == free 或 nextAction == motion        → L1.5 状态提示
  = mode == ambient                             → L1.5 应用内浮层
  = mode == focused                             → L2 请求播放器暂停 + 浮层
```

**落层 = min(形态首选层, 该身份协商强度的默认档)**（天花板与默认档见 `LAYER-07`）。三点说明：

- 陪伴式的默认档是 L3：高于形态首选层时**不再往上抬**，而是额外默认开启 **L3 的应用外呈现通道**——
  悬浮窗可用时同一结论离开本应用仍可见（浮层在内容角落，避让字幕区）；暂停请求本身仍是 L2 动作。
- 自管式的默认档是 L1，低于 `focused` 的 L2 下限（请求暂停就不得低于 L2）：此时题目按 `ambient` 呈现
  并写明原因，该身份知情升档后才请求暂停（`LAYER-07`、F12）。
- 手机端不取 L3，落层上限就是 L2（`LAYERING.md §1` 规矩 4）。

- L1.5 承载**已受理动议**的状态（暂停、临时加时、停止提示）与其他状态类信息：常驻提示条 + 顶栏角标 +
  一次通知。答题与运动的呈现时机走 L2 / L3。
- 动议本身只用 L1 一条提示（可忽略）；未受理不生效，写 `MOTION_UNANSWERED`（`AUTO-16`）；自己发起的
  停止提示与自管强度下的加时→ L1，只留痕。
- 暂停语义：暂停时长以 `pauseMs` 单列，计入账本，与 `watchedMs` 分列；恢复后从冻结值继续（`COMMIT-07`）。
- 生命周期与清理走 `onStop` + 前台服务 + 开机重探。
- 无障碍作为 L3 的判定加速器，接口面只返回判定结果（`LAYER-06`）。
