<div align="center">

# 有伴 · YoubanTV

### 一台电视，三代人各有时段

**一套功能，全家共用**：换个身份就是换题库、换知识大纲、换运动项目。
电视端数时间，手机端做陪伴。

**时间由设备数，约定由全家定。** · Android 电视 / 平板 / 手机，无需自建服务器

</div>

---

## 这是什么

一家人共用一台电视或平板。有伴把它变成一条写得清楚的约定：**每人每天看多久、什么时段看、
该做的事是什么**，全部在界面上可见。

- 每个身份有自己的题库、知识大纲、运动项目与约定线；切换身份即切换内容；同一身份在电视与手机上的
  时长合并计算。
- 手机端是完整的陪伴端：自己那份约定、动一动的邀请、把「一起看」安排出来（[`docs/MOBILE.md`](docs/MOBILE.md)）。
- 约定由三方要素构成：免题段（按约定无需做题的时段）、做题段、运动段；时段规则按身份生效。
- 学习参数自己定：组数、每组题量、每次题目数与补一补节奏由每个人自己设定，面板只显示不代设
  （[`spec/AUTONOMY.md`](spec/AUTONOMY.md) 的 `AUTO-14`、D31）。
- 题目有两种参与形式：`focused` 停下来做（请求内容暂停，答完恢复）与 `ambient` 边看边做（角落浮层）。
- 白天的老人时段配置为安静运行：约定线宽、免题段覆盖全天、提示收敛。
- 任一成员在手机浏览器里查看同一份账（同一局域网，扫码即开）；约定字段的编辑权由家庭协议授予、可轮值（D33）。
- 每个成员有自己的账本视图与动议入口；受理、婉拒与改判都附理由并留档。
- 主观题先由本人对照评分标准自评入账，其他人的动作是**查阅与修订**；更新由当前使用者查阅说明后安装
  （`AUTO-15`、D32）。
- 对别人状态的改变一律是**动议**：提一条，对方在自己的界面里一次受理才生效；没受理就不生效（D34、`AUTO-16`）。
- 一台设备**一次只有一个人**用：电视端靠模式切换区分人，手机端各用各的（D35、`PROFILE-10`）。所以上一条
  天然是异步的——对方下次打开自己的界面时再受理；角色的交接也是本机里的这样两次确认。

题库、时长账本、答题记录都存在被控设备本机；联网只发生在监护人凭据（`keyHolder`）显式开启的四条路上
（[`docs/PRIVACY.md`](docs/PRIVACY.md)）。

## 四条产品约定

1. **结论可解释**：每次呈现都给出「哪条约定 + 差多少 + 下一步」；所有人看的是同一份账本；
   收紧的改动在下一次签署前不生效。
2. **执行方式是可替换的适配器**：内核产出 `CommitState`（守约 / 该做了 / 超时），`enforcement` 按层呈现。
   未达成约定的结果是记录与补做；做题与运动的完成不兑换时长，只入账。
3. **默认停在最软的够用层**：无到期项时只有状态提示——常驻提示条 + 角标（L1.5），持续给出当前状态与
   恢复时刻；有到期项时的呈现档随协商强度取默认档（陪伴式 L3 / 协商式 L2 / 自管式 L1）。层的取值是
   `L0 / L1 / L1.5 / L2 / L3 / L5`，只描述侵入度与呈现时机（[`docs/LAYERING.md`](docs/LAYERING.md)）。
4. **伴 = 同伴**：默认只取「当前内容是否受控」的布尔与时长；开启伴看上下文（默认关）后额外取一条前台
   窗口标题，只在内存中用于出题。

需要物理停止观看时，用的是家庭自己配置的插座 / 切源 / 路由时段（L5）。应用可被随时卸载，关于页写明这一点。

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/COMMITMENTS.md`](docs/COMMITMENTS.md) | 约定与守约：结论结构、两种参与形式、未达成约定的后果、生效条件 |
| [`docs/LAYERING.md`](docs/LAYERING.md) | 分层策略：层的定义、19 个场景各在哪层、升层与回退、措辞规则 |
| [`docs/PROFILES.md`](docs/PROFILES.md) | 身份模型：内容绑定与默认值、按身份分账、切换留痕、呈现令牌 |
| [`docs/PRODUCT.md`](docs/PRODUCT.md) | 产品定义、范围、核心模型、规则模型、协商强度 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 模块划分、技术选型、契约、质量门槛 |
| [`docs/PRIVACY.md`](docs/PRIVACY.md) | 每项数据的存放与去向、出网清单、系统能力与取值范围 |
| [`docs/NAMING.md`](docs/NAMING.md) | 定名与标识表、界面用词表、待核事项 |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | D1–D39 决策与状态、实测与探测项 |
| [`docs/facts/DEVICES.md`](docs/facts/DEVICES.md) | 实机事实（现象 + 复核命令 + 结论） |
| [`docs/PROVENANCE.md`](docs/PROVENANCE.md) | 血统与出处：与上游项目的关系、启发来源与致谢 |
| [`docs/MOBILE.md`](docs/MOBILE.md) | 手机端（陪伴端）：三个能力面、共在功能、跨设备计时、范围之外 |
| [`docs/research/EVIDENCE.md`](docs/research/EVIDENCE.md) | 心理学与 HCI 证据：结论 → 设计条目的映射、证据薄弱清单 |
| [`docs/research/MOBILE-COMPANION.md`](docs/research/MOBILE-COMPANION.md) | 手机端与陪伴端的证据整理：提示时机、促成人际接触、体感与姿态的边界 |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | 实现切片 M1–M8：交付项、验收与依赖顺序 |
| [`spec/`](spec/README.md) | 行为规格条目（代码里的 `SPEC:` 标签指向这里） |
| [`contract/contract.json`](contract/contract.json) | 契约单一来源：主体与角色、scopes、端点、枚举、禁止字段与退役取值 |
| [`fixtures/`](fixtures/) | 决策表与行为夹具：`COMMIT` / `DAY` / `PROFILE` / `ASK` 每条至少一条断言 |
| [`tools/check-contract-refs.sh`](tools/check-contract-refs.sh) | 契约与夹具的引用完整性门（数据侧） |

## 状态

重写进行中：契约与夹具已入库（M1.1 / M1.2 的数据部分），代码尚未开始。现阶段**私域**：不分发、
没有公开下载与托管服务、没有第三方统计。将来是否公开是独立决策，条件见
[`docs/DECISIONS.md`](docs/DECISIONS.md) 的 D29 / D30。

代码采用 Apache-2.0（见 `LICENSE`），第三方与内容许可见 `THIRD_PARTY_NOTICES.md`；许可选择与是否
公开无关。实现切片见 [`docs/ROADMAP.md`](docs/ROADMAP.md)，当前进度是文档与规格基线。
