# 第三方许可声明

规矩：**依赖清单由构建解析生成**，本文件只写需要人记住的例外与随包数据。CI 出 SBOM 与许可报告，
白名单 Apache-2.0 / MIT / BSD / CC0 / CC-BY，黑名单 GPL / AGPL / SSPL / 专有二进制——命中即红。

| 组件 | 许可 | 随 APK | 说明 |
|---|---|---|---|
| Kotlin stdlib, kotlinx-coroutines | Apache-2.0 | 是 | 运行时必需 |
| KaTeX 及其字体 | MIT | 是 | 公式渲染；**从 KaTeX 上游发行物取**，仓库不放副本，其 `LICENSE` 随库进包 |
| 面板前端（Vite / TypeScript / Preact 等） | MIT / Apache-2.0 | 编译产物进包 | 由包管理器锁定版本 |
| holiday-cn 节假日数据 | 见上游仓库 | 当年快照进包 | 运行时可同步更新；来源与许可写进本表与「关于」页 |
| 内容包 `.qpack` | **各自许可** | **不进包** | manifest 带 SPDX、署名块、签名；安装界面必须显示；不合规即拒装 |
| 种子题库 `starter-cc0` | CC0（本项目原创） | 否，作为首个内容包 | 自建、可自由使用 |
| K12 题库与知识大纲 `k12-compulsory`（导出包 id） | **CC BY-NC 4.0**（第三方：`cn-math-taxonomy`，作者见下） | 是，以内容包形式**装在家庭设备上**，包本体不入库 | 来源 <https://github.com/xiaoyang111222/cn-math-taxonomy>；知识点 3298、先修边 4868、题 13339；本包只取义务教育段（小学 g1–g6、初中 g7–g9），高中段 g10–g16 一题不绑（D76）。**署名**：该仓 README 与其 `LICENSE`（CC BY-NC 4.0），并保留其「商业使用需单独授权」的声明 |
| 摄像头相关库 | 若引入必须 Apache/MIT 且**在 API 25 上可加载** | 待定 | 实测：MediaPipe Tasks 的 `.so` 在 Android 7.1 缺 API 26 locale 符号，`dlopen` 直接失败；引入前先跑可行性 spike |

| 外部技能（本机的 agent skill）`mblode/agent-skills@product-design` | MIT | **否** | 开发期装在本机技能目录，只作产品判据（D75）；不进仓库、不进 APK、不参与判定 |

明确**不使用**的东西：任何专有崩溃上报 SDK、任何第三方统计脚本、任何随仓库提交的 `.aar` / `.so` 二进制。
历史上存在过的那类做法（仓库内放 AAR、页面加载第三方统计）在本项目里被 CI 门挡住。

**K12 内容包 `k12-compulsory` 这一条例外要说满**（D82）：它的许可是 **CC BY-NC 4.0**，不在
`spec/PACK.md#PACK-02` 的白名单里；装它靠的是 `contract.contentPack.license.conditional` **那唯一一条**
条件条目——只在 `contentPack.distribution = private` 时可装，理由是家庭自用就是非商业、NC 的实质条件
在这台设备上成立，署名按 `PACK-03` 显示。**这条跟着 D29/D30 走**：本项目一旦转为公开发布、开始收费、
或对家庭之外分发，这一条自动变成拒装，并按 `revokeIf` 那三条把包卸干净（已答记录保留并标注来源为
「已卸载内容」，`PACK-04`）。门是 `ruby tools/check-packs.rb`；它扫本地 `packs/` 目录，**目录为空时报
「本地未导出」并以红收**，不因为扫不到东西就绿。

一条例外要说在前面：**自创 CC0 种子题库的编写源**目前放在旧 fork 仓库的 `packs/starter-cc0/`
（那里已有题库源与生成器，重写一遍是纯浪费）。这是「旧仓库只当 CC0 内容的草稿纸」的用法——
它必须已停止分发、纯私有，且本仓库**不依赖、不复制**它的任何代码或数据。理由见
`docs/DECISIONS.md` 的 D19，说明也写在 `docs/PROVENANCE.md`。

**`playpets` 只作形状语言参考，未取任何素材**（D83）：<https://github.com/gaerae/playpets>，MIT。
取的是**做法**——常驻一小块、不抢焦点、帧循环只在有东西动时跑（它那条 ADR 的量法：成本与「画了多少像素」无关、
与「第几帧变了」有关）——以及美术的**形状语言**（圆的形、无描边、暖色、可信的接触阴影）。
**没有搬一张图、一个字形**：它的美术另有 provenance（生成图 + 每图一份 `icon-provenance.json`），
搬进来就得跟着那份 provenance 走，不值当。本项目那一只自己画，落点见 `docs/PROVENANCE.md §6`；
它在设备上那条分界见 `spec/PET.md#PET-01`。
