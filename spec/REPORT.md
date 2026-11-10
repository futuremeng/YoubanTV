# REPORT · 「这段时间的账」那一页

**SPEC: REPORT-01, REPORT-02, REPORT-03, REPORT-04**

文档里把「周报」当落点引用了六次，又有六处规定某些东西**不进周报**——那条通道最容易把连击、完成度、
催签请回来。定案是：**本项目没有周报**，只有面板上的一页（`D78`）。

### REPORT-01 只有一个入口，没有定时推送
- 结论：这一页在「这段时间的账」那一页上（`panel.pages`）；**没有定时推送、没有通知、没有邮件**（`report.push = false`），
  也没到点自己弹的东西。窗口默认七天，可以选，但不存在「每周生成」这件事。
- 文案：这一页的标题就是那一页的名字；界面上不出现「周报」二字（`agreement.panel.never`）。
- 测试：fixtures/report.yaml#REPORT-01

### REPORT-02 每一行都从事件数出来，不做区间对比
- 条件：`report.rows` 的每一项都必须指明是哪一种事件；模型里没有第二本账，也没有「这一窗 vs 上一窗」那条路（`report.comparison = false`）。
- 结论：**没有「比上周进步」那一句**；没有分数、没有排名。事件里没有的数，这一页就不显示，也不补一个。
- 测试：fixtures/report.yaml#REPORT-02

### REPORT-03 只看自己的账
- 结论：可见范围只有本人（`report.visibleTo = ['self']`）；别人的这一页不是别人的管理入口——管理动作是**设定约定**，走签署与动议（`AUTO-10`）。
- 测试：fixtures/report.yaml#REPORT-03

### REPORT-04 不许有的那批词只有一份清单
- 条件：这一页读 `agreement.panel.never` 那一份（`report.neverFrom`），**不抄第二份**；抄了就红。
- 结论：那批词（催签、红点、完成度、连续天数、周报、得分、打卡）在这页的产出里出现 0 次。
- 测试：fixtures/report.yaml#REPORT-04
