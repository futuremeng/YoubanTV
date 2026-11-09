# 夹具格式与断言词汇

夹具是**规格与内核之间的接口**：一条用例 = 输入（状态 + 动作）→ 期望结论。
词汇的单一来源是 [`vocab.yaml`](vocab.yaml)，取值域来自 [`../contract/contract.json`](../contract/contract.json)；
本页只讲规则，不重复清单（避免两处漂移）。门禁：[`../tools/check-fixtures.sh`](../tools/check-fixtures.sh)。

## 1. 结构

```yaml
COMMIT-04:                     # 顶层键必须是已定义的规格 id
  spec: [spec/COMMIT.md#COMMIT-04]   # 必须非空；锚点由引用门校验存在
  given: { profile: "member:kid" }   # 可选，条目级初始状态
  cases:
    - name: 超时只记 overdue，不阻断观看   # 一句中文，说清这条在回答什么问题
      given: { watchedMs: 3720000 }        # 可选，覆盖条目级 given
      when: { stillWatching: true }        # 动作；一条 case 只有一个 when
      expect:                              # 断言，至少一条
        status: overdue
        events: [OVER]
        blocked: false
```

规则：条目级键只有 `spec` / `cases` / `given`；case 级键只有 `name` / `given` / `when` / `expect`。
`when2`、`expect2`、`then` 这类补丁键在 `vocab.yaml` 的 `bannedKeys` 里，出现即红。

`given` 是**这一轮之前的事实**，`when` 是**这一轮做的动作**：`given` 里的数量与已落事件由执行器
物化成台账里的旧账，`events: [...]` 问的是「这件事在台账里发生过」，`delta: {x: n}` 问的是
「这一轮让 x 涨了几」——要表达「这一笔没落」，用 `delta`，不要用 `noEvents`（后者问的是台账里
从来没写过这类事件）。

## 2. 三类键

| 位置 | 词汇 | 数量 | 校验 |
|---|---|---|---|
| `given` / `when` | `fields` | 127 | 键必须登记；带 `enum` 的取值必须存在于契约枚举 |
| `expect` | `predicates` | 46 | 键必须登记；枚举类取值、事件名、`absent` 目标、能力 id 全部校验 |
| 映射里的字段名 | `metricNames` + `kvKeys` | 134 + 40 | 度量名与结构键分开登记 |

### 断言谓词的分组

- **判定**：`status` `due` `mode` `nextAction` `tier` `tierCeiling` `kpState` `stars` `mastery` `gradedBy` `source` `authoring`
- **事件**：`events` `noEvents`
- **数**：`value` `delta` `unchanged` `identicalAcross` `cooldown` `pool`
- **界面**：`shown` `notShown` `visibleOn` `surface` `wording` `notify` `escalate` `inReport` `answerable`
- **生效与受理**：`effective` `applied` `accepted` `allowed` `writable` `blocked`
- **结构与同源**：`sameSource` `presentIn` `absent` `evidenceFrom` `capability` `egress` `checklist` `checklistStatus` `roles` `plan` `gate`

断言的取值里可以直接写 `given` 里出现过的字段名，执行器把它换成这一轮的给定值——`ASK-07` 的 `questionPickedAt: dueAt` 问的就是「呈现时刻就是那个到点时刻」，不为此引入新语法。

一条断言只回答一个问题。要写「A 且 B」就写两条；不要用 `xxxAndYyy` 复合键——那正是这批夹具此前的毛病（原有 249 个自由键，现在收敛到 46 个谓词）。

## 3. 否定断言

- `absent: [...]` —— 目标必须已登记：契约 `forbiddenFields`（含 `forbiddenEvents`）、`retired`、事件名、`apiNames`、`conceptNames`、tier 空位。
- 断言某条**路径不存在**时写成端点形式：`absent: ["POST /api/l5"]`，门禁不再要求它在 `endpoints` 里出现。
- 断言某类机制不存在时用 `conceptNames` 里的名字（`连击`、`签到`、`先批完才入账`……），别自造字段名。

## 4. 加一个新键

1. 先看 `vocab.yaml` 有没有同义的键（多数「新」断言其实是 `value` / `shown` / `absent` 的一种）。
2. 确需新键：加进 `fields` 或 `predicates`，并写它的来源（契约枚举名 / 事件名 / 度量名）。
3. 若取值域来自契约而契约里没有（如当初缺 `egressSwitch`），**先补契约**再补夹具——契约是单一来源。

## 5. 执行器与门禁

```sh
tools/run-fixtures.rb                    # 全量跑：如实报通过 / 失败 / 未支持
tools/run-fixtures.rb --only=COMMIT-04,DAY-06   # 目标条目：出现「未支持」即红
```

执行器跑的是 [`../model/`](../model/) 的规范模型。三条纪律：

- **键必须认识**：断言键在模型里没有对应查询就记「未支持」，不猜、不默认通过；`--only` 下未支持即红。
- **状态键必须被消费**：`given` 里凡是模型用不上的键，整条 case 记未支持——半套输入给出的结论不算结论。
- **状态要落得下去**：`given` 里的量是**写成事件**进账本的（`watchedMs` → `WATCHED`，`pauseMs` → 已受理的 `pause` 动议），不是在对象上摆字段。
- **取值只查四处**：判定结论 → 当日投影 → 跨天保留项 → 当日方案；四处都无定义就报「无处可取」。`absent` 只看**定义面**：契约的字段与取值、代码里的逻辑；说明文字、禁止清单与枚举空位里出现是正当的。

## 6. 跑门禁

```sh
tools/check-contract-refs.sh   # 规格 id 存在、锚点存在、禁止字段不出现、事件枚举与 PRODUCT §3 一致
tools/check-fixtures.sh        # 键 ∈ 词汇表、枚举与事件取值合法、结构合法、无补丁键
```

`tools/check-fixtures.sh coverage` 只报覆盖率，不判词汇：它列出**还没有夹具的条目**（`GATE-*` 是退役编号映射，不计入）。

两个都绿才谈得上执行器：执行器（M1.2 的 `tools/`）读的就是这份词汇，键不认识就无法判真假。
