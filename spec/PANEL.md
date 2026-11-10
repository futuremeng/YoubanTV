# PANEL · 页面清单

**SPEC: PANEL-01, PANEL-02**

家庭面板是这套设计里唯一的**编辑面**：约定字段、时段表、清单确认、出网开关、角色交接都落在它的某一页上。
所以「有哪些页、每页回答哪个问题」必须像 `commitState` 那张表一样只有一处——否则同一个地方会长出两个名字，
而首启那句「要改去……」会指向一个没人认领的页。

### PANEL-01 页面的清单只有一处
- 条件：`contract.panel.pages` 是页名与用途的唯一来源；文档、契约句子与界面里出现的「……」页 / 「……」那一页
  都必须能在这张表里查到（曾用名记在 `panel.renamedFrom`，只作说明，不再出现在引用里）。
- 结论：引用查不到即红；这张表不新增功能——**每页都是同一本账的一个视图**，页与页之间不各存一份状态（`ARCHITECTURE.md §1`）。
- 测试：fixtures/panel.yaml#PANEL-01

### PANEL-02 那句「要改去哪儿」的页名从这张表取
- 条件：首启某一步按默认跑、且这一步在遥控器上改不了时，屏上那句「按默认 · 要改去……」里的页名
  由 `contract.panel.pages[].title` 拼出（`agreement.ui.defaultsWhere` 的 `{where}`，`AGREE-05`）。
- 结论：`where` 里出现的页名查不到即红；壳层与设备端不手抄页名，也不自己编一个地方。
- 测试：fixtures/panel.yaml#PANEL-02

## 那条通道已经改名了

「周报」以前被当落点引用了六次（`COMMIT.md`、`AUTONOMY.md`、`PRODUCT.md`），另有六处规定某些东西**不进那一页的账**
（`AGREE.md`、`ONBOARD.md`、`CONTEXT.md`）。定案：**本项目没有周报**——只有这张表里的「这段时间的账」那一页，
只从事件数出来、只看自己的、不做区间对比（[`REPORT.md`](REPORT.md)、D78）。界面上也不出现「周报」二字
（`agreement.panel.never` 把它列进不许有的词，那一页读同一份清单，不抄第二份）。
