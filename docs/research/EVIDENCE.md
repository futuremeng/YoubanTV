# 研究与证据（心理学 / 人机交互）

## 0. 这一页怎么用

| 等级 | 含义 |
|---|---|
| **A** | 元分析、系统综述、伞形综述、RCT |
| **B** | 队列 / 纵向 / 准实验 |
| **C** | 横断相关 |
| **D** | 理论、概念、临床指南、分类学 |

每条给 DOI。检索过程与查询词在 §8，可复现。

**核对状态**：本次只核对了**书目元数据**（标题、作者、期刊、DOI），没有逐篇读全文。引用方向以摘要与
领域常识为准；凡结论有方向性风险的条目都标了「读全文」这一待办。表格里的设计推论属于我们的判断，
证据本身不下这个结论。

## 1. 屏幕时间与福祉：效应量比宣传的小，语境比分钟数重要

| 证据 | 结论（一句话） | 等级 |
|---|---|---|
| Orben & Przybylski, 2019, *Psychological Science*, [10.1177/0956797619830329](https://doi.org/10.1177/0956797619830329) | 数字科技使用与青少年福祉的关联量级与「戴眼镜」「吃土豆」相当，单独变量解释力 <1% | A/B |
| Przybylski & Weinstein, 2019, *Child Development*, [10.1111/cdev.13007](https://doi.org/10.1111/cdev.13007) | 人群数据里没有支持「每日屏幕剂量阈值」的证据；关联在极低与极高使用处都变弱 | B |
| Twenge & Campbell, 2018, *Preventive Medicine Reports*, [10.1016/j.pmedr.2018.10.003](https://doi.org/10.1016/j.pmedr.2018.10.003) | 高剂量组与较低福祉的关联明显，但报告口径（家长 vs 儿童）差异会显著改变结论 | C |
| Vasconcellos et al., 2025, *Psychological Bulletin*, [10.1037/bul0000468](https://doi.org/10.1037/bul0000468) | 纵向元分析：屏幕使用与社情绪问题的合并效应小，且异质性高 | A |
| Mallawaarachchi et al., 2024, *JAMA Pediatrics*, [10.1001/jamapediatrics.2024.2620](https://doi.org/10.1001/jamapediatrics.2024.2620) | 学龄前**使用语境**（是否共同使用、内容类型）与结局的关联强于单纯时长 | A |
| Madigan et al., 2020, *JAMA Pediatrics*, [10.1001/jamapediatrics.2020.0327](https://doi.org/10.1001/jamapediatrics.2020.0327) | 屏幕与语言能力的关联在扣除家庭语境后明显减弱 | A |

**落到设计**：`allowance` 是家庭自定的**目标线**，界面与文档一律不写「超过 X 分钟有害」这类剂量因果话术。
真正能被证据支撑的干预点在**语境**（谁在一起、做什么），这条见 §2。

## 2. 共同观看与在场：`co-watch` 时段、`presence`、家长端提示的依据

| 证据 | 结论 | 对设计的支持 |
|---|---|---|
| McDaniel & Radesky, 2018, *Child Development*, [10.1111/cdev.12822](https://doi.org/10.1111/cdev.12822) | 家长设备在场（technoference）与儿童行为问题相关，关联强度高于儿童自身屏幕时长 | 支持 `co-watch` 时段与「人到场」优先于分钟数 |
| McDaniel & Radesky, 2018, *Pediatric Research*, [10.1038/s41390-018-0052-6](https://doi.org/10.1038/s41390-018-0052-6) | 纵向：家长设备分散注意与养育压力相互加强 | 支持家长端在场提示 |
| Toledo-Vargas et al., 2025, *JAMA Pediatrics*, [10.1001/jamapediatrics.2025.0682](https://doi.org/10.1001/jamapediatrics.2025.0682) | 学龄前系统综述 + 元分析：养育者技术在场与儿童发展的关联普遍为负向、量级小 | 支持 `aloneMs` → 家长端提示 |
| Brushe et al., 2024, *JAMA Pediatrics*, [10.1001/jamapediatrics.2023.6790](https://doi.org/10.1001/jamapediatrics.2023.6790) | 屏幕存在时亲子谈话量下降（12–36 月） | 支持「有人在场的观看」与 `withMs` |
| Paavonen et al., 2009, *Child: Care, Health and Development*, [10.1111/j.1365-2214.2009.01009.x](https://doi.org/10.1111/j.1365-2214.2009.01009.x) | 共同观看与讨论可降低幼儿的电视相关恐惧 | 支持共看段的存在 |

**孤独值的对偶写法**（`withMs`、共看时段）在这里有依据；把「独自观看时长」渲染成使用者的**情绪指标**
在这批文献里没有依据，反而是 §5 那条路径。

## 3. 中介方式与家庭规则：怎么说比管多少重要

| 证据 | 结论 | 对设计的支持 |
|---|---|---|
| Collier et al., 2016, *Developmental Psychology*, [10.1037/dev0000108](https://doi.org/10.1037/dev0000108) | 家长中介的合并效应弱且混合；**限制性中介**与更多问题行为相关 | 支持「协商强度 + 解释」优先于「阻断」 |
| Fam et al., 2023, *Canadian Journal of Behavioural Science*, [10.1037/cbs0000320](https://doi.org/10.1037/cbs0000320) | 中介与问题性使用关联不一致；方式比频次更重要 | 同上 |
| Nathanson, 1999, *Communication Research*, [10.1177/009365099026002002](https://doi.org/10.1177/009365099026002002) | 中介类型与儿童攻击性的关联依类型而分 | 支持解释型而非命令型 |
| Hawk et al., 2023, *Journal of Research on Adolescence*, [10.1111/jora.12873](https://doi.org/10.1111/jora.12873) | 「全家一起的规则」比「只约束青少年」与更少的社媒困难相关 | 直接支持身份模型：规则对所有身份同一套机制 |
| Fletcher, Steinberg & Williams-Wheeler, 2004, *Child Development*, [10.1111/j.1467-8624.2004.00706.x](https://doi.org/10.1111/j.1467-8624.2004.00706.x) | 「父母知道」的效应主要来自孩子的主动告知，不是监控强度 | 支持「不做反侦查 / 不做监控」 |
| 家庭内差异与信息来源，2019, *Developmental Psychology*, [10.1037/dev0000641](https://doi.org/10.1037/dev0000641) | 同一家庭内孩子主动告知的差异比父母监控行为差异更能预测结局 | 同上 |

## 4. 自主支持与反抗：强制的反噬

| 证据 | 结论 | 对设计的支持 |
|---|---|---|
| Vasquez et al., 2015, *Educational Psychology Review*, [10.1007/s10648-015-9329-z](https://doi.org/10.1007/s10648-015-9329-z) | 自主支持与学业成就、心理功能的正向关联（元分析） | 支持协商强度与身份自管 |
| Laurin & Joussemet, 2017, *Motivation and Emotion*, [10.1007/s11031-017-9627-5](https://doi.org/10.1007/s11031-017-9627-5) | 自主支持的养育行为与幼儿规则内化正向相关（前瞻性观察） | 支持「约定 + 签署」优于「闸门」 |
| Savard et al., 2013, *Motivation and Emotion*, [10.1007/s11031-013-9351-8](https://doi.org/10.1007/s11031-013-9351-8) | 情绪行为问题严重的青少年仍从自主支持中获益 | 支持「即使需要结构，也不取消自主支持」 |
| Rains, 2013, *Human Communication Research*, [10.1111/j.1468-2958.2012.01443.x](https://doi.org/10.1111/j.1468-2958.2012.01443.x) | 自由威胁引发反抗，态度朝目标反方向移动（元分析） | 支持拦截式闸门会反噬 |
| Brehm & Brehm, 1981, *Psychological Reactance*, [10.1016/B978-0-12-129840-1](https://doi.org/10.1016/B978-0-12-129840-1.50020-X) | 反抗理论原始著作 | 同上 |

## 5. 内疚 / 羞耻式诉求：有效但带代价，且作用在成人说服情境

| 证据 | 结论 | 对本项目的问题 |
|---|---|---|
| Peng et al., 2023, *Frontiers in Psychology*, [10.3389/fpsyg.2023.1201631](https://doi.org/10.3389/fpsyg.2023.1201631) | 内疚诉求在公益说服中有效，效果受诉求强度与信息类型调节 | 有效性的场景是**慈善/公共健康**，不是家庭内部的时间约定 |
| Xu & Guo, 2018, *Health Communication*, [10.1080/10410236.2017.1278633](https://doi.org/10.1080/10410236.2017.1278633) | 内疚对健康态度与意图有中小效应 | 同上；儿童长期暴露缺少证据 |
| Hibbert et al., 2007, *Psychology & Marketing*, [10.1002/mar.20181](https://doi.org/10.1002/mar.20181) | 受众识别出内疚诉求是被设计时，产生被操纵感并降低后续意愿 | 家庭场景里「被设计的情绪」破坏的是信任本身 |
| Tangney, Wagner & Gramzow, 1992, *Journal of Abnormal Psychology*, [10.1037/0021-843X.101.3.469](https://doi.org/10.1037/0021-843X.101.3.469) | 羞耻倾向与病理谱关联，内疚倾向的关联结构与羞耻不同 | 「你孤独」这类标注的语义近羞耻指向（我是坏的），不是内疚指向（我做了某事） |
| Kochanska et al., 2009, *JPSP*, [10.1037/a0015471](https://doi.org/10.1037/a0015471) | 内疚倾向与努力控制共同降低外化问题的路径依赖温和教养背景 | 提示：内疚不是可独立调用的杠杆 |

**结论**：孤独值作为**显示给使用者的情绪指标**缺证据支持，且有反向机制的证据（被操纵感 + 反抗）。

## 6. 奖惩与内在动机

| 证据 | 结论 | 对设计的支持 |
|---|---|---|
| Deci, Koestner & Ryan, 1999, *Psychological Bulletin*, [10.1037/0033-2909.125.6.627](https://doi.org/10.1037/0033-2909.125.6.627) | 期望中的物质奖励削弱内在动机（元分析） | 奖励与观看权限解耦（`AUTO-13`） |
| Cerasoli, Nicklin & Ford, 2014, *Psychological Bulletin*, [10.1037/a0035661](https://doi.org/10.1037/a0035661) | 内在动机与外在激励**共同**预测表现；激励对量效应强、对质效应弱 | 允许星与掌握记录，不用它换观看资格 |
| Gollwitzer & Sheeran, 2006, *Advances in Experimental Social Psychology*, [10.1016/S0065-2601(06)38002-1](https://doi.org/10.1016/S0065-2601(06)38002-1) | 「在什么时候做什么」的具体计划显著提升执行率 | 支持时段格子与 `due.window` 这类时间锚点 |
| Gamification 与内在动机的元分析：**证据不一致**，多为教育技术类小样本 | — | 成就 / 连击类机制按「证据不明」处理，不引入 |

## 7. 操纵性设计与 AI 陪伴

| 证据 | 结论 | 对设计的支持 |
|---|---|---|
| Mathur et al., 2019, *PACM HCI*, [10.1145/3359183](https://doi.org/10.1145/3359183) | 11k 站点中暗模式普遍，多数界面在用户不知情时施加压力 | 文案与机制的显式化要求 |
| Narayanan et al., 2020, *Queue*, [10.1145/3400899.3400901](https://doi.org/10.1145/3400899.3400901) | 暗模式分类与产业实践综述 | 用「状态句 + 一步可拒」作为默认 |
| Gray et al., 2023, *DIS*, [10.1145/3563703.3596635](https://doi.org/10.1145/3563703.3596635) | 暗模式研究的系统综述：定义收敛在「损害自主性的设计」 | `AUTO-05`、`AUTO-12` |
| Newall, 2025, *Addiction*, [10.1111/add.70085](https://doi.org/10.1111/add.70085) | sludge / dark nudge 分类，成瘾性平台的激励设计 | 反对连击、签到、成就类机制 |
| Shamsudhin & Jotterand, 2021, [10.1007/978-3-030-74188-4_7](https://doi.org/10.1007/978-3-030-74188-4_7) | 社交机器人与暗模式的边界：说服何时变成操纵 | 应用不声称情感、陪伴来源标注为人 |
| Folk & Dunn, 2026, *Psychological Science*, [10.1177/09567976261427747](https://doi.org/10.1177/09567976261427747) | 纵向：转向 AI 陪伴与孤独**双向**预测，替代人际关系的担忧部分成立 | 反对「看得越久它越陪你」这类规则 |
| De Freitas et al., 2025, *Journal of Consumer Research*, [10.1093/jcr/ucaf040](https://doi.org/10.1093/jcr/ucaf040) | 实验证据：AI 陪伴可在特定条件下降低孤独感 | 陪伴类功能有价值，但来源与边界需说清 |
| Jacobs, 2024, *Frontiers in Digital Health*, [10.3389/fdgth.2024.1281037](https://doi.org/10.3389/fdgth.2024.1281037) | AI 陪伴改变社会承认的结构，风险在替代而非补充 | 同上 |

## 8. 运动中断（`exerciseTask` 的依据）

| 证据 | 结论 | 等级 |
|---|---|---|
| Daly-Smith et al., 2018, *BMJ Open Sport & Exercise Medicine*, [10.1136/bmjsem-2018-000341](https://doi.org/10.1136/bmjsem-2018-000341) | 急性课堂运动中断即时提升身体活动量与部分认知指标；长期学业效应证据不足 | A |
| Latino & Tafuri, 2023, *Sustainability*, [10.3390/su15086616](https://doi.org/10.3390/su15086616) | 学龄儿童身体活动与学业表现的系統综述：关联正向但不稳定 | A |
| Donnelly et al., 2016, *MSSE*, [10.1249/MSS.0000000000000966](https://doi.org/10.1249/MSS.0000000000000966) | 身体活动、体能与认知的大规模系统综述 | A |

界面话术取「即时效果」这一层：「做完这一组，身体先醒过来」，不写「提高成绩」。

## 9. 政策与临床立场

AAP, *Media and Young Minds*, 2016, *Pediatrics*, [10.1542/peds.2016-2591](https://doi.org/10.1542/peds.2016-2591) —
指南层面的要点是媒介计划、共同使用与家庭规则，而非单一剂量上限。属 D 类（临床共识）。

## 10. 结论→设计条目的映射

| 设计条目 | 支撑 |
|---|---|
| 约定线是目标线，界面不作剂量因果话术 | §1 全部 |
| `co-watch` 时段、`withMs`、家长端在场提示 | §2 全部 |
| 协商强度（陪伴 / 协商 / 自管）、双方签署、申诉通道 | §3、§4 |
| 功能与身份无关（全家同一套规则） | Hawk et al. 2023 |
| 不做监控、不做反侦查 | §3 最后两行 |
| 不用拦截式闸门 | §4 Rains |
| 孤独值 / 内疚式文案的否决 | §5 全部 |
| 激励与观看资格解耦 | §6 前两行 |
| 无连击 / 成就 / 签到 | §6 第四行、§7 Newall |
| 应用不声称情感、陪伴来源标注为人 | §7 Shamsudhin、Folk & Dunn |
| 运动段的设计与话术 | §8 |

## 11. 证据薄弱，不要拿来当依据

- 「X 分钟屏幕导致抑郁 / 焦虑」的因果话术。
- 任何把「孤独」当作可计算指标的做法（我们的 `aloneMs` 是可测的行为量，不是情绪量）。
- 用成就、连击、签到提高守约率的长期效果。
- 用 AI 拟人陪伴替代家庭互动。
- 屏幕使用「剂量阈值」（如每岁 X 分钟）的精确数字。

## 12. 检索方法与可复现

2026-02 通过 Crossref REST API（`/works?query.bibliographic=` / `query.title=`）与 PubMed E-utilities
（`esearch` + `efetch` / `esummary`）检索；查询词示例：
`parental mediation meta-analysis children media use`、`co-viewing children outcomes`、
`autonomy support parenting internalization`、`parental monitoring solicitation adolescent`、
`psychological reactance`、`screen time well-being meta-analysis`、`dark patterns`、
`guilt appeals persuasion`、`AI companions loneliness`、`physically active breaks children cognition`、
`technoference`、`implementation intentions meta-analysis`。

全文核对任务（M5.5 之前完成）：§5 全部、§6 前两行、§7 的 Folk & Dunn 与 De Freitas。核对结果回填本表的
「核对状态」列，未核对的条目不得出现在对外文案里。
