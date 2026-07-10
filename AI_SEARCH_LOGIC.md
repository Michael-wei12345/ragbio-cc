# RagBio AI 搜索逻辑说明

本文档说明当前 RagBio 的 AI 搜索链路。目标是让用户知道：输入一句自然语言后，App 到底如何检索、排序、读取全文、生成摘要，以及哪些结果可以信任到什么程度。

## 1. 总原则

RagBio 的 AI 搜索不是让大模型直接“回答论文事实”。当前设计是：

1. 大模型只负责把用户描述转换成可审查的检索计划。
2. 论文元数据、标题、作者、年份、摘要等来自 OpenAlex。
3. 能读取全文时，正文证据来自合法开放全文或用户导入 PDF。
4. 大模型参与排序和全文综述摘要，但必须基于已提供的标题、摘要或全文段落。
5. 没有全文时，不生成全文 literature review 摘要。

## 2. 用户输入到 OpenAlex 检索式

用户切换到 `AI 搜索` 后，可以输入自然语言，例如：

```text
Association between gastrointestinal symptoms and National Drug Codes
```

RagBio 会调用当前设置里的大模型厂商，例如 DeepSeek、OpenAI、Anthropic 或 Gemini，生成一个 `AISearchPlan`：

- `search_query`：英文 OpenAlex 检索式
- `from_year`：起始年份，可为空
- `open_access_only`：是否只检索开放获取
- `sort`：相关性、最新发表或引用数
- `explanation`：中文解释，告诉用户模型如何理解这个问题

`search_query` 不是数据库布尔查询。RagBio 会要求模型输出空格分隔的英文关键词，不使用 `AND`、`OR`、`NOT`、括号或字段语法，避免 OpenAlex 普通搜索把这些词当作噪声或导致结果跑偏。

缩写处理规则：

- 对 `NDC` 这类大写缩写，RagBio 会要求模型保留原缩写，不要随意改写成另一个概念。
- 在药物、处方、医保 claims、EHR、不良反应或药品编码语境下，`NDC` 优先按 `National Drug Code(s)` 理解，检索式应同时保留 `NDC` 和 `National Drug Code(s)`。
- 模型返回后，App 还会经过 `OpenAlexQueryNormalizer` 做本地规则扩展。当前规则覆盖 MeSH-like 疾病概念、药物别名、医疗编码系统和常见数据库缩写，例如 `IBD`、`NSCLC`、`NSAID`、`PPI`、`RxNorm`、`FAERS`、`OMOP`、`ICD`、`CPT`、`MedDRA`。
- 对高度歧义缩写不会盲目扩展。例如 `PD` 可能是 Parkinson disease，也可能出现在 `PD-1/PD-L1`，因此不会单独触发 Parkinson 扩展。

如果大模型在短时间内没有返回，App 会直接提示“AI 检索计划生成失败”，不会再用本地规则临时生成检索式。

## 3. 获取候选论文

当前 AI 搜索会从 OpenAlex 获取最多 `50` 篇候选论文。

当前实现参数：

- `aiCandidateLimit = 50`
- `aiCandidatePageSize = 50`

也就是说，通常一次 OpenAlex 请求取回最多 50 篇候选。候选去重后进入后续排序。

这些候选只是“可能相关”，还不是最终排序结果。

## 4. AI 摘要粗排

候选论文会进入第一轮 AI 粗排。输入给模型的内容包括：

- 论文标题
- 年份
- 期刊或来源
- OpenAlex 摘要，截断到一定长度

模型输出：

- `score`：0 到 100 的相关度分数
- `relevant`：是否真正有用
- `reason`：中文短句，说明论文研究什么

这里的判断标准不是单纯关键词匹配，而是模型根据用户原始问题判断论文是否真正有用。

如果 AI 粗排超时或失败，App 会保留临时候选，并在界面提示“AI 粗排暂未返回”。这种情况下列表不是最终 AI 排序。

## 5. 本地粗排兜底

为了避免已经拿到 OpenAlex 候选后界面长期空白，RagBio 有一个本地粗排兜底逻辑。这个兜底只发生在“大模型已经成功生成 AI 检索式”之后，不再用于替代 AI 检索计划。

本地粗排会根据标题和摘要里的关键词重合、是否有摘要、是否开放获取等因素给出临时分数。它只用于先显示结果，不等于最终 AI 判断。

界面会标记这种结果，避免用户误以为这是完整 AI 排序。

## 6. 全文二次精排

AI 粗排后，RagBio 会对前面的候选做第二阶段证据精排。

当前实现参数：

- `aiEvidenceCandidateLimit = 20`

也就是说：

1. 前 20 篇进入证据精排范围。
2. RagBio 会尝试为这 20 篇全部读取合法全文。
3. 成功读取全文的论文，会用全文段落参与二次判断，并生成英文 literature review 摘要。
4. 没有全文的论文只使用摘要参与判断，不生成全文 literature review 摘要。
5. 全文补强阶段不会把 OpenAlex 摘要回退当作全文；只有 `Europe PMC XML`、`OpenAlex TEI/PDF`、开放 PDF、Unpaywall、本机 GROBID 或用户导入 PDF 才算全文。

界面中的证据等级：

- `全文段落精排`：读到了合法全文，并用全文段落参与排序；论文详情页会生成英文 literature review 摘要，包含 Topic、Methods、Results、Key Metrics 和 Outlook。
- `仅摘要精排`：没有可用全文，只用标题和摘要排序；列表里只显示一句中文改写概括，不直接截取摘要原句。

## 7. 全文来源和校验

RagBio 尝试读取全文时，会按已有全文服务逻辑寻找合法开放来源，例如：

- Europe PMC XML
- OpenAlex TEI XML
- OpenAlex PDF
- Unpaywall 开放版本
- Publisher PDF
- 本机 GROBID
- 用户导入 PDF

为了避免错误 PDF 被误用，当前实现增加了标题匹配校验：

- 自动获取的全文必须和当前论文标题有足够关键词重合。
- 如果开放 PDF 和论文标题明显不匹配，会丢弃该全文并清理缓存。
- 不匹配的全文不会参与全文段落精排，也不会生成 literature review 摘要。
- 用户手动导入的 PDF 暂时信任，因为这是用户自己选择的文件。

## 8. 全文段落检索

读到全文后，RagBio 会在本机对全文段落做混合检索。

检索输入是 AI 生成的 OpenAlex 检索式或当前查询词。检索目标是找出每篇论文中最能回答用户问题的段落。

这些段落会用于：

- 全文二次精排
- 证据报告
- 详情页的全文定位

## 9. Literature Review 摘要

对于读到全文的文章，RagBio 会生成“文献综述摘要”。这个摘要用于辅助写 literature review。

它只对真正有全文文档的文章生成。没有全文时，不生成这个模块。

摘要字段固定为：

- `主题`：论文研究什么
- `方法`：研究设计、数据来源、样本、测量方式或分析方法
- `结果`：主要发现
- `关键指标`：样本量、百分比、效应量、p 值、数据库数量、代码数量等
- `展望`：局限、启示、未来研究或结论

每个字段都会绑定一个全文来源段落：

- `主题` 优先匹配 abstract、background、introduction 等段落。
- `方法` 优先匹配 methods、participants、data 等段落。
- `结果` 优先匹配 results、findings、outcome 等段落。
- `关键指标` 会额外匹配 summary 里的数字、百分比、p 值或效应量。
- `展望` 优先匹配 discussion、conclusion、limitations、future 等段落。

界面会在每个字段下显示 `Source: <locator>`，并提供 `Locate` 按钮跳到对应全文段落。底部的 `Source passages used` 折叠区会集中列出这些字段级来源。

生成逻辑：

1. 如果当前大模型配置可用，RagBio 会把全文候选段落交给模型生成结构化英文摘要。
2. 模型被要求只使用提供的全文内容，不允许根据记忆补写。
3. 如果模型失败或未配置，App 会使用本地全文初稿兜底，并在状态里说明。
4. 结果会缓存到 `fullTextReviewSummaries`，避免切换页面后消失。

## 10. 为什么有时不显示全文综述摘要

当前设计下，不显示“文献综述摘要”通常有几种原因：

1. 这篇文章没有读到合法全文，只能显示 OpenAlex 摘要。
2. 读取到的开放 PDF 没通过标题匹配校验，被丢弃。
3. 正在生成摘要，界面会显示生成中状态。
4. 大模型失败时，会显示失败说明并使用本地全文初稿兜底。

如果一篇论文只标记为 `仅摘要精排`，说明它没有可用全文，不会生成 literature review 摘要。

## 11. 详情页显示逻辑

当前论文详情页主要显示：

1. 论文元数据：标题、作者、年份、期刊、引用数、开放获取状态。
2. 如果读到全文：显示“文献综述摘要”。
3. 如果没有全文但有 OpenAlex 摘要：只显示 OpenAlex 摘要。
4. 用户可以点击“读取全文”尝试重新获取全文。
5. 用户可以点击“导入 PDF”使用自己有权访问的论文 PDF。

详情页顶部原来的紫色 `相关度 + 摘要简述` 块已经移除，因为它容易和真正的 literature review 摘要混淆。

## 12. Research Scan 输出

AI 搜索得到的排序结果不是最终报告。用户可以在列表或详情页对论文做当前扫描内的决策：

- `Use`：本次 field scan 应该使用。
- `Maybe`：暂时保留，可能有用。
- `Exclude`：本次扫描排除。
- `Unreviewed`：还没判断。

这些决策只属于当前 search session，不等于收藏。收藏是把论文保存到全局“我的文库”。

点击 `Generate Evidence Table` 后，App 会本地生成 Evidence Table：

- 如果有 `Use` 或 `Maybe`，只包含这些论文。
- 如果还没标任何论文，会基于当前排序生成，并带 warning。
- `Exclude` 不进入表格。
- 这一步不调用大模型。

Evidence Table row 会整合：

- OpenAlex 元数据和摘要。
- AI score、reason、evidence level。
- 当前访问状态：metadata-only、abstract-only、full-text-read、user-PDF-imported 等。
- 已生成的 full-text literature review summary。
- summary 字段对应的 source passage refs。

点击 `Generate Field Scan` 后，大模型只读取 Evidence Table rows，生成 field-level 报告。每个 theme、claim、method、gap、future direction 和 must-read paper 都必须引用输入 row 中的 `work_id`。App 会在本机校验这些 id；引用不存在论文的 claim 会被丢弃。

Field Scan Report 和普通 AI 搜索排序的区别：

- AI 搜索排序回答“哪些论文可能相关”。
- Evidence Table 回答“本次扫描实际纳入了哪些证据”。
- Field Scan Report 回答“基于这些纳入证据，这个领域目前有哪些主题、发现、方法、争议和空白”。

## 13. Named Research Projects

AI 搜索结果默认仍会写入最近一次 autosave。用户也可以点击 `Pin Current Search as Project`，把当前搜索固定为命名 research project。

项目会保存：

- 当前 query、搜索模式、排序和筛选。
- OpenAlex 结果、AI 排序、AI reasons 和 evidence levels。
- scan decisions。
- Evidence Table。
- Field Scan Report。

项目不会保存 API Key、翻译缓存、raw full-text body 或正在运行的后台任务。打开项目时，App 会取消旧后台任务并恢复项目状态，但不会自动重跑昂贵 AI 流程。

## 14. 当前限制

当前 AI 搜索仍有一些限制：

- OpenAlex 的检索结果质量会影响后续所有排序。
- 没有开放全文的文章只能摘要精排。
- PDF 文本层质量差时，全文段落可能有页眉、脚注或断行噪声。
- 大模型摘要质量取决于提供的全文段落是否覆盖 Methods、Results、Discussion。
- 当前会尝试读取前 20 篇证据候选的全文；这会增加搜索耗时，但能为更多可访问全文的文章生成 literature review 摘要。
- Field Scan Report 只和 Evidence Table 一样可靠；如果 Evidence Table 多数是 abstract-only，报告会标注为初步结论。

## 15. 推荐使用方式

如果要写 literature review，建议按这个流程使用：

1. 用 AI 搜索描述研究问题。
2. 优先查看标记为 `全文段落精排` 的论文。
3. 在详情页确认“文献综述摘要”是否出现。
4. 对关键论文点击“读取全文”或导入自己的 PDF。
5. 使用“全文定位”搜索具体概念，核对摘要中的方法、结果和关键指标。
6. 用 `Use / Maybe / Exclude` 标记本次扫描要纳入的论文。
7. 生成 Evidence Table，检查每行的 access status 和 source refs。
8. 再生成 Field Scan Report，用它整理主题、方法、争议和研究空白。
9. 不要直接引用模型摘要，最终引用应回到原文段落或论文页面。
