# spec/ —— 行为规格条目

一条一个 id，格式 `<域>-<序号>`；**同一条规则的第二种情形可加小写字母后缀**（如 `DAY-04b`），
它仍是独立条目，引用与 `SPEC:` 标签里写全带后缀的 id。源文件头部标注 `// SPEC: COMMIT-04`。CI 已实现的静态检查五项：
上游标识只在登记位置出现（`docs/PROVENANCE.md` 等）；`SPEC:` 引用的条目存在；新增出网地址先登记；
内核不含执行手段与包名；跨身份写入路径不存在。**数据侧的契约引用门已实现**
（[`../tools/check-contract-refs.sh`](../tools/check-contract-refs.sh)：`contract/contract.json` 与
`fixtures/*.yaml` 里引用的每个条目必须存在，且不得出现禁止字段与退役取值）。
**还差一道未实现**：契约级条目至少被一处实现与一处测试引用（需代码，M1 落地）。
无 `### <id>` 标题的页（如 `GATE.md`）不得出现在 `SPEC:` 标签里。

| 域 | 管什么 | 文件 |
|---|---|---|
| `COMMIT` | 约定引擎：状态、到期项、两种参与形式、未达成约定的后果 | [`COMMIT.md`](COMMIT.md) |
| `DAY` | 按身份的当日账、时段规则、零点刷新、时间完整性 | [`DAY.md`](DAY.md) |
| `PROFILE` | 身份模型：内容绑定与默认值、按身份记账、切换留痕、呈现令牌 | [`PROFILE.md`](PROFILE.md) |
| `ASK` | 选题管线、知识点状态机、难度阶梯、两种参与形式的题目形状 | [`ASK.md`](ASK.md) |
| `PACK` | 内容包格式、许可与署名、按身份绑定 | [`PACK.md`](PACK.md) |
| `SENSE` | 体感计次：口径、数据边界、用途边界、标定与安全约束 | [`SENSE.md`](SENSE.md) |
| `CONTEXT` | 伴看上下文：取值边界、出网条件、出题时机 | [`CONTEXT.md`](CONTEXT.md) |
| `LAYER` | 层的取值、默认层、升层与回退、措辞规则 | [`LAYER.md`](LAYER.md) |
| `AUTO` | 自主性规则、协商强度与签署、主体权限、自管字段与查阅修订 | [`AUTONOMY.md`](AUTONOMY.md) |
| `ONBOARD` | 设备待确认清单：派生与装配差、随加入扩充、降级与再认证 | [`ONBOARD.md`](ONBOARD.md)（清单本体见 [`../docs/ONBOARDING.md`](../docs/ONBOARDING.md)） |
| 隐私（无 id） | 数据存放与去向、出网清单、系统能力取值 | [`../docs/PRIVACY.md`](../docs/PRIVACY.md)——引用时写 `AUTO-11` / `CONTEXT-02` 或该页节号，**不得写 `PRIV-*`** |
| ~~`GATE`~~ | 退役编号的迁移映射 | [`GATE.md`](GATE.md) |

条目写法：

```md
### COMMIT-04 约定时长用尽仍在看
- 条件：watchedMs[profile] ≥ allowance[profile]
- 结论：status=overdue, ruleId=COMMIT-04, due=null
- 文案（L1.5 状态句）：「超出约定 <X> 分钟。明天 <time> 重新计时。」
- 测试：fixtures/commit.yaml#COMMIT-04
- 事实依据：facts/DEVICES.md#F2（每层提示都有应用内替代）
```

规格只写行为与数字。实现需要参考既往做法时，先把它写成一条规格条目（附出处与实测依据），代码再引用它。
