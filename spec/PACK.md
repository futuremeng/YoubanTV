# PACK —— 内容包格式与许可

一个 `.qpack` 是**带签名的 zip**：`manifest.json` + 题目 + 知识大纲 + 素材 + `ATTRIBUTION.md`。
APK 内只含自创 CC0 种子包；任何第三方内容都必须以包的形式安装与卸载。

### PACK-01 manifest 必填字段
`packId`、`version`、`license`（SPDX id + 原文摘要）、`attribution`（署名文本与 URL）、
`source`（作者 / 来源 / 采集方式）、`signature`、`checksums`、
**`audience: [child|grown-up|senior]`**、**`presentationHints`**、`outline` 引用、`questionCount`。
字段齐全是安装前置条件；许可信息在装前确认。

### PACK-02 许可白名单，机器判定
允许的 license：`CC0-1.0`、`CC-BY-4.0`、`Apache-2.0`、自创。出现 `NC` / `ND` / `SA` / `All Rights Reserved` /
字段缺失 → 拒绝安装并说明哪一条挡住。CI 扫 `packs/` 目录，白名单之外即红。

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
