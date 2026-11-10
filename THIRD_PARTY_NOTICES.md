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
| 摄像头相关库 | 若引入必须 Apache/MIT 且**在 API 25 上可加载** | 待定 | 实测：MediaPipe Tasks 的 `.so` 在 Android 7.1 缺 API 26 locale 符号，`dlopen` 直接失败；引入前先跑可行性 spike |

| 外部技能（本机的 agent skill）`mblode/agent-skills@product-design` | MIT | **否** | 开发期装在本机技能目录，只作产品判据（D75）；不进仓库、不进 APK、不参与判定 |

明确**不使用**的东西：任何专有崩溃上报 SDK、任何第三方统计脚本、任何随仓库提交的 `.aar` / `.so` 二进制。
历史上存在过的那类做法（仓库内放 AAR、页面加载第三方统计）在本项目里被 CI 门挡住。

一条例外要说在前面：**自创 CC0 种子题库的编写源**目前放在旧 fork 仓库的 `packs/starter-cc0/`
（那里已有题库源与生成器，重写一遍是纯浪费）。这是「旧仓库只当 CC0 内容的草稿纸」的用法——
它必须已停止分发、纯私有，且本仓库**不依赖、不复制**它的任何代码或数据。理由见
`docs/DECISIONS.md` 的 D19，说明也写在 `docs/PROVENANCE.md`。
