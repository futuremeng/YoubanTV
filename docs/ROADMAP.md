# 落地路线

原则：每片单独可验证；跨片变更单独立片；每片收口跑一次 `make check`（契约 + 决策表 + 设计棘轮 + 字号 +
包校验 + 血统扫描，`ARCHITECTURE.md §8`）。里程碑**编号按决策先后分配**，执行顺序以下表的
依赖列为准（M7 是收口片，M8 与 M4 并行）。

## M1 · 规格化与契约

| # | 交付 | 验收 |
|---|---|---|
| 1.1 | `contract/contract.json` v1（**已入库**）：端点、schema、枚举、`principal: member:<id>` + `roles: [ruleEditor, keyHolder]`（D33）、`protocolVersion`；`Profile` 与 `audience` 字段；自管字段四项的**本人写入口**（`AUTO-14`）；动议端点 `POST /api/motions`（D34，含 `roleChange` / `coWatch`）；scopes 清单 `read/rules/content/grade/diagnostics/egress`（`control` 退役）；`forbiddenFields`（含 `forbiddenEvents`）与 `retired` 段；`egressSwitch` 枚举与事件的 `auxValues`（`due_shown` / `llm_generate_failed` / 审计）| 面板与设备端由它生成；`make contract` 一条命令（**待生成器**）；schema 字段集与 `PROFILE-01` 一致；非本人的 scope 对自管字段只读；`roles` 不由 `audience` 推导（CI）；写入口的 `profile` 只能取当前激活身份或 `none`（CI，`PROFILE-10`）；`tools/check-contract-refs.sh` 已跑绿 |
| 1.2 | 决策表夹具 `fixtures/{commit,day,profile,ask,onboard}.yaml`（**已入库**：63 条规格条目、179 条用例，覆盖 `COMMIT` / `DAY` / `PROFILE` / `ASK` / `ONBOARD` 全部条目与 `AUTO` / `PACK` 的可判定部分）+ 断言词汇 `fixtures/vocab.yaml` 与格式说明 `fixtures/FORMAT.md`（D41：249 个自由键收敛到 46 个谓词） | 每条分支 ≥1 条；`COMMIT-01`、`COMMIT-07` 与 `COMMIT-11` 各含对应断言（冻结时长与 `pauseMs` 单列 / 恢复续算 / `profile=none` 不判定）；每条 `due` 断言同时给出**形态层与落层**（`ARCHITECTURE.md §9`）；`tools/check-fixtures.sh` 已跑绿（键与取值合法，反向验证可失败）；**夹具执行器已跑绿**（`tools/run-fixtures.rb` 跑 `model/` 的规范模型）：**706 条断言通过、0 失败、未支持 0**，覆盖 `COMMIT` / `DAY` / `LAYER` / `ONBOARD` / `SENSE` / `AUTO` / `PROFILE` / `ASK` / `PACK` 的可判定部分（余下集中在跨设备同步与 `GRADE` 评分链）；反向验证（改坏判定、改坏幂等、去掉能力登记表这一份来源、把清单变成第二条台账、拆掉 D36 门槛、让出网开关参与取材、拆掉题面形状门禁、取消补一补池封顶、把确认题的迁移并回答错那一步）都能变红；其余条目按「未支持」如实报出
| 1.3 | `spec/ASK.md`、`spec/PACK.md`（含 `audience`、`presentationHints`） | 选题管线与内容包格式可照此实现 |
| 1.4 | 内核输出结构定稿（**已入库**）：`contract.json` 的 `commitState` 给出字段表与 `tierFor(due)` 那张唯一的表，`model/commit.rb` 是唯一的产出点，`tools/tv-status.rb` 把它当 JSON 打出来（就是电视端将来读的那一份） | 四处一致由门守：`tools/check-contract-refs.sh` 跑一次真产出并比对契约；夹具侧 `LAYER-13` 两条；把契约里的字段多加一个、把某个层改成文档里没有的、在模型里另写一份强度默认档，三种改坏都会让门变红 |

## M2 · 内核（纯 Kotlin JVM）

`profile → ledger → day → commit → session → task → ask → srs → plan → context → content → verify`

- 验收：决策表分支覆盖 100%；重放 CLI；假时钟场景（跨零点 / 暂停冻结 / 改表跳变 / 免题段）；
  `core` 的 import 集合只含 Kotlin 标准库。
- CI 门：`enforcement` 与阻断类 API 在 `core` / `device` 中的出现位置（`COMMIT-10`）；
  `audience` 的分支位置限定为内容绑定与默认值两处（`PROFILE-02`）。
- 内核依赖关系由构建脚本断言：`core` 只被 `device` / `panel` 依赖。


**现在到哪一步：M2 的验收过了。** `kotlinc 1.9.24`（GitHub releases 的完整发行版；Maven 那个裸 jar 缺
intellij 依赖）→ `sh tools/build-core.sh` → `ruby tools/align-core.rb`：**221 个 case × 10 个字段逐位相同**。
它已进 `tools/check-fixtures.sh` 当常设门，并做过反证：把 Kotlin 的 `watched < grace` 那一支改坏，
立刻报 681 处不一致；改回来又归零——这一道是活的，不是摆设。

烧的过程里有三件事值得记：
1. 40 处里有 **27 处是比对器没把输入喂成同一份**（形态请求、已受理的暂停、探针结论、跨天）。
   那不是内核分歧，是我的比对器在替内核做决定——把原始事实（墙钟/单调钟的增量）送过去、
   滚不滚交给 Kotlin 自己判（DAY-07 那条），才算真的对齐。
2. 探针那两个门槛数（0.95 / 20）只写在 Ruby 一处；比对器送的是它的结论，
   不在比对器里另抄一份。设备端将来要自己判探针，那两个数得先进契约。
3. 空行不是事件、`.ttc` 要选面、adb push 的文件应用读不到——这三条见 `facts/DEVICES.md`。

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
- **装上了的原生壳层**：`device/android/build-apk.sh`（不用 Gradle：aapt2 → javac → d8 → zip →
  zipalign → apksigner）打出 0.06 MB 的包，`adb install` 到电视上起得来，**遥控器按键已落到设备**
  （`input keyevent 23` → 应用私有目录里的 `youban-input.json`，`facts/DEVICES.md#F17`）。
  还差三件才说得上 M3 完成：① 汉字渲染**通了**——真因是 TextView 只给 `textSize` 不给
  `textAppearance` 时不接中文回退，另有编译期一条 `javac -encoding UTF-8`（`facts/DEVICES.md#F17`）；
  中文这条由两条机器判据把关（`probe text` 码位、`probe glyphs` 字形不重样），不再靠我看截屏；② **设备上跑内核这一件成了**：Kotlin 内核与 stdlib 已 d8 进
  同一个 dex（APK 0.60 MB），事件账落在设备本地 `youban-events.jsonl`（广播带的是**事件**不是结论），
  **内核在设备上跑起来了**：设备本地事件账 `youban-events.jsonl` 里一条 WATCHED(ms=3600000)，
  屏幕给出「超出约定时间。今天已按约定使用完。」，码位逐位对得上（`facts/DEVICES.md#F17`）。
  路上三个坑都记在 F17：adb push 出来的文件属主是 shell，应用读不到（要 push 到应用自己那个目录）；
  广播带 JSON 字符串会被两道 shell 吃掉字符（改成 `--es kind … --el ms …`）；事件账末尾的空行不是事件。
  字形那条**是我读截屏读错的**：设备自己一比是 14 种不同字形、没有空白（`facts/DEVICES.md#F17`）——
  以后中文这条以 `probe text` / `probe glyphs` 两条机器判据为准，不以我看图为准。
  ③ 设备清单的设备侧改走装了 APK 的那条（`tools/tv-app-state.rb`）：**两台设备各 12 道全绿**
  （8 步判定 + 4 步自检：按键 / 码位 / 字形 / 两端同源）。Mac 画卡推相册那条留作呈现通路演练，
  不再当设备测试的依据——同一台旧设备它八步只开得出四步屏，而且验的是 Mac 画的图。
- 常驻那几条也画了：内核输出多一个 `panels` 字段（句子在契约 `commitState.panels`，数量从事件账来填），
  界面只把它们用「 · 」串起来。align 因此涨到 12 个字段——加这个字段时它当场抓到 Kotlin 少了
  「免题段说明」与「进度」两条规则，补上才归零；再反证一次（Ruby 那边把「进度」那条注掉）立刻红。
- **现在能验的部分**：`ruby tools/tv-at.rb --serial=…` 跑 `tools/tv-device.yaml`，**两台设备各 12 道全绿**
  （8 步判定：内核侧夹具 + 设备侧显示自证；4 步设备自检：按键落到设备 / 码位不含 U+FFFD /
  字形不重样 / 两端同源）。遥控器按键已通（`facts/DEVICES.md#F17`）。
- **按键这条链已通**：挂着要受理的动议时，确认键写 `MOTION_SETTLED` → 设备上的内核重算 → 结论与规范模型
  13 个字段逐位相同（`facts/DEVICES.md#F22`，设备测试第 6 道 `key`）。没挂着动议时账上一个字都不写。
- **生命周期这一条改过实现了**：没有前台服务、没有开机广播，每一次到前台重跑探针并记时间
  （`facts/DEVICES.md#F25`）；装包清单与实现由一道新的门逐条比对（`tools/check-manifest.rb`）。
- **仍未做的**：题目浮层（L2 那张卡）的真实焦点与遮挡——做它的那天才声明悬浮窗权限。这条不许说「已跑通」。

## M3.5 · 建立约定（首启与切换身份）

**设计已落**（`spec/AGREE.md`、`docs/AGREEMENT.md`、契约 `agreement` 一节）：装完应用第一次打开的必做
只有一件事——把一份约定立起来（六步，每步都能「先用默认」）；**切换身份就是换一组约定**，
那一组有自己的版本与签署记录，一份的收紧不会改掉另一组。默认值表从此只有一处（原来 Ruby 一份、
Kotlin 一份，连「默认算不算在时段内」都只有一边写）。

**为什么放在 M3 之后、M4 之前**：M4 的面板要显示「生效条目 + 签署人与时刻」（AGREE-12），
没有建立过程就没有可显示的东西；设备端的内核与事件账已就位，`PLAN_SIGNED` / `PROFILE_SWITCH`
进得来，缺的只是「谁问、问几步、签没签」这一层；再往后的 M5 / M5.5 都建立在「这台设备这一档
受哪几条例约约束」之上。

**已落**：首启那六步在设备上能走（确认键进流程、最后一屏写 `PLAN_SIGNED`，设备自检第 7 道 `setup`，见 `facts/DEVICES.md#F23`）。

**活清单**：`fixtures/agree.yaml` 现在故意红着——8 条未支持（`defaultsOnly` / `signaturePending` /
`switchTo` / `otherProfileUnchanged` / `agreementStep`），那就是 M3.5 的全部实现面。验收两条设备测试：
首启走到签署后，设备上算出的结论与规范模型逐字段一致；切到另一身份后加载的是另一组约定。

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
| M3.5 | M3 | M4 之前 |
| M4 | M2、M3、M3.5 | 与 M5 / M5.5 |
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
- **F12 已开跑（2026-11-09）**：一台 Konka Android TV 9652（Android 9）与一台 Smartisan OD103（Android 7.1.1），
  两机 × 两条通路四行样本均 **0/20**（`probes/f12.yaml`）→ 这两台定格 `ambient`，`focused` 不作默认档（D44）。
  还欠：第三方播放器各一轮（要真进去一部片子）、音频焦点丢失通路（要一个能稳抢焦点的旁路 App）、
  以及 F13（等计次算法落地才能与人工计数对照）。
