# PACK —— 内容包格式与许可

一个 `.qpack` 是**带签名的 zip**：`manifest.json` + 题目 + 知识大纲 + 素材 + `ATTRIBUTION.md`。
APK 内只含自创 CC0 种子包；任何第三方内容都必须以包的形式安装与卸载。

### PACK-01 manifest 必填字段
`packId`、`version`、`license`（SPDX id + 原文摘要）、`attribution`（署名文本与 URL）、
`source`（作者 / 来源 / 采集方式）、`signature`、`checksums`、
**`audience: [child|grown-up|senior]`**、**`presentationHints`**、`outline` 引用、`questionCount`。
字段齐全是安装前置条件；许可信息在装前确认。

### PACK-02 许可白名单，机器判定
允许的 license：`CC0-1.0`、`CC-BY-4.0`、`Apache-2.0`、自创。出现 `ND` / `SA` / `All Rights Reserved` /
字段缺失 → 拒绝安装并说明哪一条挡住。CI 扫 `packs/` 目录，白名单之外即红。
- **条件条目是白名单唯一的扩展**（`contentPack.license.conditional`，D82）：`CC BY-NC 4.0` **只在**
  `contentPack.distribution = private` 时可装——家庭自用就是非商业，NC 的实质条件在这台设备上成立，
  署名按 `PACK-03` 显示。**这条不是一个可以随手改的字段**：它跟着 D29/D30（不公开发布、不收费）走，
  `distribution` 一旦不是 `private`，这一条立刻变成拒装，并按 `revokeIf` 那三条撤——按 `PACK-04` 卸干净，
  已答记录保留并标注来源为「已卸载内容」。
- 测试：fixtures/pack.yaml#PACK-02

### PACK-09 包怎么来、谁签、门扫不到时不许绿
- 导出：`ruby tools/make-pack.rb --from=<编写源仓>`（本机是 `../cn-math-taxonomy`）——按 `contentPack.audienceBinding`
  的年级过滤（**高中段 g10–g16 一题不绑**，D76），裁掉的边要报出条数；产出 `packs/<packId>.qpack` + `manifest.json` +
  `ATTRIBUTION.md` + `checksums.json`。包本体**不入库**（`trackedInRepo = false`）：它是本地一次导出的产物，
  编写源在别人的仓（`PACK-08`）。
- 签：`checksums` 是逐文件 SHA-256；`signature` 用第一次导出时生成的随机 key（`packs/.pack-key`）HMAC 签 manifest。
  **只防误改与半途中断，不作信任锚**（`integrity.signature`）——这条要如实这么写，家里没有公钥体系。
- **门扫不到东西时不许绿**：`packs/` 为空或 key 不在，`ruby tools/check-packs.rb` 报「本地未导出」并以红收（空目录不算绿）。
- 署名的落点逐条带状态写在 `contentPack.attributionVisible`：已落的那几处必须真在（`THIRD_PARTY_NOTICES.md`
  里能找到这个 `packId`）；未落的那几处不许被当成已落——「题面角落那一行」要等出题那一片。
- **预设「手上有那一本教材」的那类题不进题集**（`contentPack.textbookDependent`）：题面或解析里出现
  「课文 / 原文 / 教材」那批标记的，导出时滤掉、门再验一遍（抽查 354 / 13339，D82）。**大纲里的知识点照留**——
  大纲是地图不是题，只是那一题不出。这台设备不知道孩子用的是哪一版课本，这类题在孩子那边就是「什么课文？」。
- **题的字段那一节**（`contentPack.schemas`：id / topicId / difficulty / type / prompt / answer / verify）
  在装包时判一次：少一格就红——少 `id` 没法判重，少 `verify` 没法机检（`ASK-08`）。
  `verify` 空着的题**在导出那一步就滤掉**，不是进来了再拒：那条纪律是「机检不过：不出、不入库、不重试」。
  这一格空着的题在源库里是 567 道，装包那道门当场报出来的（`D84`）。
- **取题只有一处**（`model/pack.rb` 的 `pick`）：绑定年级（那张表只有 `contentPack.audienceBinding` 一处）
  → 难度阶梯（`contentPack.pick.difficultyLadder`）→ 把账里答过的排除（靠 `ANSWER` 带的 `questionId`）。
  顺序是**确定**的（按 id 排，同一天的同一轮跑两次出同一道题），不靠随机数。池空了就是这一层落空——
  按 `ASK-01` 往下走一层，**不在这里编一道题，也不重复出答过的那道**。
- **这台设备带没带题库**写在 `contentPack.onDevice`（`D85`）：那一行的措辞只在这一处拼，两个内核都从这里拼。
  带没带是**声明**不是推断——包体不入库、APK 里也不带，拿「本机有没有 `packs/`」去猜，在规范模型那台会报成
  「带了」，而那恰恰是设备上错的那一句。`carried` 改 true 时这道门去 APK 的 assets 里验那个包真在：
  **那一行不许说假话**。屏上没有题面（电视端不出题），所以这一行说的是「题在另一台上出」；
  署名落点里「题面角落那一处」仍算未落，**不拿别的落点顶**。
- **大纲查询那一处**（`GET /api/topics` 的名字，`D86`）：知识点与先修边**只从包里的两张表**答，
  不在别处再存一份大纲（`PACK-05`）。年级绑不绑这一处**不自己判**——只问绑定表里那批年级（那张表只有一处）；
  绑在表外的年级（高中段）答那一条拒绝，**不回题也不回知识点**（`D76`）。这里**不收 audience**：
  1.0 里出题只属于那一档，要问哪个年级直接查表——少一个按受众分支的位点。
- 测试：fixtures/pack.yaml#PACK-09

### PACK-03 署名与来源的显示位置
`ATTRIBUTION.md` 的内容进面板「内容库」页与题目详情角落（「本题来自 <pack> · CC BY 4.0」）。
卸载时显示：该包贡献的题数与作答次数；署名文本随来源声明保留。

### PACK-04 卸载必须真的卸干净
卸载删除题目、素材与大纲条目；已答记录保留并标注来源为「已卸载内容」，进度视图保持可见。

### PACK-05 大纲与题目同包同版本
`outline_topics` / `outline_edges` 随包安装与卸载；跨包引用必须显式声明并在安装时校验，
悬空引用时拒装并列出引用项。同一知识点可由多包贡献，语义按 id 合并（`ASK-09`）。

### PACK-06 内容不分身份的是 schema，分身份的只是绑定
题目 schema v3 与 `verify` 语义对所有 `audience` 同一套；新增一个 audience（比如「考前冲刺」）
**不需要改内核**，只需要新包 + 该身份的内容绑定（CI 门见 `PROFILE-02`）。

### PACK-07 完整性与降级
签名或校验和不符 → 拒装；已装包被篡改 → 该包题源整体停用并提示，提示里列出可选处理。
包内解析失败的单题跳过并记录（不阻塞整包）。题目一律**预载**，不在作答瞬间解析（预载纪律见 `GATE.md`「仍然有效的纪律」段）。

### PACK-08 起草与来源隔离
种子包（CC0）的草稿留在编写源仓，不进本仓库；草稿期的取材来源限于本项目自己的记录
（`PROVENANCE.md §2`）。每包附来源声明，人工核对后进入白名单。
