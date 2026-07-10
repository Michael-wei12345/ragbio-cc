# RagBio GPT Handoff Context

最后更新：2026-07-09

本文档用于直接提供给 GPT 或其他工程/产品协作者，让对方在不了解历史对话的情况下，完整理解 RagBio 当前的产品目标、数据来源、主要功能、技术架构、关键流程、可信边界和已知限制。

如果你是 GPT，请按以下规则理解 RagBio：

- 不要把 RagBio 理解成“让大模型直接回答论文问题”的聊天工具。
- RagBio 的核心是“先找真实论文和可追溯证据，再辅助用户做文献综述”。
- OpenAlex 主要负责论文发现和元数据；全文来自多个合法开放来源或用户导入 PDF。
- 大模型只参与自然语言检索规划、候选粗排、翻译和全文摘要生成。
- 没有读到全文时，App 不能假装读取过正文。
- 只有真正全文来源才能生成 `Literature Review Summary`。

---

## 1. 一句话概括

RagBio 是一个原生 macOS 学术证据检索应用：它用 OpenAlex 发现论文，用 Europe PMC / OpenAlex TEI / 开放 PDF / Unpaywall / Semantic Scholar / 用户 PDF 获取合法全文，用本机解析和段落检索保留可追溯证据，并可选调用大模型辅助 AI 搜索、翻译和 Literature Review Summary。

---

## 2. 产品目标

RagBio 解决的问题：

1. 用户输入研究问题后，快速找到相关论文。
2. 区分“只有摘要”和“已经读取全文”的证据等级。
3. 对已读取全文的论文生成适合 literature review 使用的结构化英文总结。
4. 保留 summary 所依据的原文段落，方便用户核查。
5. 支持用户导入自己的 PDF，建立本地文库。
6. 支持把一次检索整理成 Evidence Table 和 Field Scan Report。
7. 支持保存命名 research project，方便后续继续阅读。

RagBio 不做的事：

- 不绕过付费墙。
- 不自动登录出版社网站。
- 不保存出版社账号密码。
- 不把模型记忆当作论文事实。
- 不把 OpenAlex 摘要伪装成全文。

---

## 3. 技术栈

RagBio 是 SwiftPM macOS App。

主要技术：

- Swift
- SwiftUI
- PDFKit
- Vision OCR
- NaturalLanguage sentence embedding
- URLSession
- UserDefaults
- 本机 Application Support JSON 存储

构建命令：

```bash
swift build
./scripts/build-app.sh
```

打包后的 App：

```text
/Users/menjiwei/Documents/rag-bio/dist/RagBio.app
```

---

## 4. 主要代码文件

核心文件：

- `Sources/RagBio/RagBioApp.swift`：App 入口和 macOS 窗口。
- `Sources/RagBio/ContentView.swift`：在线检索 UI、论文详情、设置页、按钮和 tab。
- `Sources/RagBio/SearchStore.swift`：在线检索、AI 搜索、全文读取、翻译、summary、scan、project 的主要状态机。
- `Sources/RagBio/OpenAlexClient.swift`：OpenAlex works API client。
- `Sources/RagBio/OpenAlexQueryNormalizer.swift`：OpenAlex query 清洗和同义词扩展。
- `Sources/RagBio/AIProvider.swift`：AI provider、配置、AI 数据结构。
- `Sources/RagBio/AIQueryPlanner.swift`：AI search plan、AI 粗排、翻译、全文 summary、Field Scan prompt。
- `Sources/RagBio/FullTextService.swift`：全文来源发现、读取、缓存。
- `Sources/RagBio/FullTextParser.swift`：XML / PDF / OCR 解析。
- `Sources/RagBio/HybridRetriever.swift`：本机段落检索。
- `Sources/RagBio/LiteratureReviewSummary.swift`：本地 summary 兜底逻辑。
- `Sources/RagBio/LiteratureReviewCitationBuilder.swift`：summary 字段到全文来源段落的本地匹配。
- `Sources/RagBio/EvidenceExtractor.swift`：OpenAlex 摘要 evidence 句子抽取。
- `Sources/RagBio/ScanModels.swift`：Scan Decision、Evidence Table、Field Scan 数据模型。
- `Sources/RagBio/EvidenceTableService.swift`：确定性生成 Evidence Table。
- `Sources/RagBio/FieldScanService.swift`：从 Evidence Table 生成和校验 Field Scan Report。
- `Sources/RagBio/OnlineSearchSessionStore.swift`：上次在线检索 session 持久化。
- `Sources/RagBio/OnlineSearchProjectStore.swift`：命名 research project 持久化。
- `Sources/RagBio/LibraryStore.swift`：本地文库状态。
- `Sources/RagBio/LibraryService.swift`：文库 catalog、PDF 导入、URL 引用、收藏持久化。
- `Sources/RagBio/LibraryView.swift`：我的文库 UI。
- `Sources/RagBio/CredentialStore.swift`：API Key 和设置存储。
- `Sources/RagBio/CredentialValidator.swift`：API Key / endpoint 测试。
- `Sources/RagBio/Models.swift`：核心数据模型。

文档：

- `README.md`：项目说明。
- `RAGBIO_APP_LOGIC.md`：工程级全局逻辑说明。
- `AI_SEARCH_LOGIC.md`：AI 搜索专项说明。
- `DEVELOPMENT_LOG.md`：开发日志。
- `RAGBIO_GPT_HANDOFF.md`：当前这份给 GPT 的完整上下文。

---

## 5. 信息源总览

### 5.1 论文发现和元数据

论文列表的主信息源是 OpenAlex。

OpenAlex 提供：

- 标题
- 作者
- 发表日期 / 年份
- 期刊 / 来源
- 引用数
- DOI / PMID / PMCID
- OpenAlex ID
- 摘要 inverted index
- open access 状态
- locations
- PDF URL
- content URLs
- has fulltext 标记

### 5.2 全文来源

全文来源不只有 OpenAlex。RagBio 按顺序尝试：

1. 本机全文缓存。
2. Europe PMC XML。
3. OpenAlex TEI XML。
4. OpenAlex / publisher 开放 PDF location。
5. Unpaywall PDF。
6. OpenAlex PDF。
7. Semantic Scholar PDF。
8. OpenAlex 摘要 fallback。

只有 1 到 7 算真正全文。第 8 个只是摘要 fallback，不算全文。

### 5.3 用户自有资料

用户可以导入：

- 本地 PDF。
- 文件夹中的 PDF。
- Zotero storage 目录中的 PDF。
- URL 引用。
- 在线论文收藏。

导入 PDF 会复制到 RagBio 本机文库并解析成段落。URL 引用只保存链接，不下载网页，也不建立段落索引。

---

## 6. 核心数据模型

### 6.1 Work

`Work` 是 OpenAlex work 在 App 内的表示。

包含：

- `id`
- `doi`
- `title`
- `publicationDate`
- `publicationYear`
- `citedByCount`
- `authorships`
- `abstractInvertedIndex`
- `primaryLocation`
- `bestOpenAccessLocation`
- `openAccess`
- `contentURLs`
- `hasFullText`
- `ids`
- `locations`
- `isRetracted`
- `type`
- `language`

重要 computed properties：

- `abstractText`：从 OpenAlex inverted index 还原摘要。
- `landingPageURL`：优先使用 OA location、primary location、DOI、OpenAlex ID。
- `pdfURL`：优先使用 best OA PDF、primary PDF。
- `isOpenAccess`
- `hasAvailableFullText`
- `normalizedDOI`
- `normalizedPMID`
- `normalizedPMCID`

### 6.2 FullTextDocument

`FullTextDocument` 是全文或摘要被解析后的统一结构。

字段：

- `workID`
- `title`
- `source`
- `sourceURL`
- `paragraphs`
- `loadedAt`

### 6.3 FullTextParagraph

一个段落包含：

- `id`
- `section`
- `text`
- `ordinal`
- `page`

`locator` 会显示为类似：

```text
Methods · 第 9 段 · 第 4 页
```

### 6.4 FullTextSource

来源枚举：

- `europePMC`
- `openAlexTEI`
- `openAlexPDF`
- `unpaywallPDF`
- `publisherPDF`
- `localGROBID`
- `importedPDF`
- `abstract`

关键规则：

```swift
source.isFullText == true
```

只有非 `abstract` 才是真全文。

### 6.5 LibraryItem

`LibraryItem` 表示本地文库条目，可能来自：

- 用户导入 PDF。
- 在线收藏。
- URL 引用。

保存：

- 标题
- 原始文件名
- 存储文件名
- hash
- 添加时间
- 修改时间
- 标签
- 页数
- 词数
- 段落数
- source work id
- source URL
- 作者
- 期刊
- 年份

---

## 7. 在线关键词搜索逻辑

关键词搜索流程：

1. 用户输入关键词。
2. `SearchStore.search()` 判断模式为 `.keyword`。
3. 清空 AI 状态。
4. 对 query 调用 `OpenAlexQueryNormalizer.normalize(...)`。
5. 调用 `OpenAlexClient.search(...)`。
6. 返回一页结果，默认 20 篇。
7. 从 OpenAlex 摘要中抽取 evidence 句子。
8. 显示论文列表和详情页。

关键词搜索不会自动遍历全部全文来源。用户可以手动点“读取全文”或“导入 PDF”。

OpenAlex 请求：

- endpoint：`https://api.openalex.org/works`
- search 参数：普通文本搜索。
- 默认过滤：`is_retracted:false`
- 可选过滤：起始年份、开放获取。
- 排序：相关性、最新发表、引用最多。
- select：只取 App 需要的字段。
- 支持 OpenAlex API Key。
- 内存缓存 30 分钟，最多 100 条。

---

## 8. OpenAlex Query Normalizer

OpenAlex 的 `search` 不是专业布尔检索，所以 App 会先清洗 query。

清洗内容：

- 移除 `AND`、`OR`、`NOT`。
- 移除括号、引号、字段语法。
- 移除类似 `title:`、`abstract:` 的字段前缀。
- 拆成普通文本 token。
- 去重。
- 限制长度，避免过长 prompt 污染搜索。

同义词扩展：

- `NDC` 会保留原词，并扩展到 `National Drug Code`、`drug codes`、`RxNorm`、`prescription claims` 等。
- `GI` 会扩展到 `gastrointestinal`、`digestive`。
- `ASD` 会扩展到 `autism spectrum disorder`。
- `IBD` 会扩展到 `inflammatory bowel disease`、`Crohn disease`、`ulcerative colitis`。
- `NSCLC` 会扩展到 `non-small cell lung cancer`。
- `children` 会扩展到 `pediatric`。
- `female / girls` 会扩展到 sex differences / gender differences。

高歧义缩写如 `AD`、`PD` 不会自动扩展，避免误解。

---

## 9. AI 搜索总体逻辑

AI 搜索不是让模型直接联网搜索。它是分阶段流程：

1. 大模型把自然语言研究问题转换成 `AISearchPlan`。
2. App 用 `AISearchPlan.searchQuery` 去 OpenAlex 获取候选。
3. 本机快速排序先显示结果，避免空白。
4. 大模型对前 25 篇做摘要级粗排。
5. App 对前 20 篇尝试读取全文。
6. 读到全文的论文用本机段落检索做证据精排。
7. 读到全文的论文生成英文 Literature Review Summary。
8. 用户翻页后，当前页继续后台补全文和 summary。

关键参数：

```swift
pageSize = 20
aiCandidateLimit = 50
aiCandidatePageSize = 50
aiCoarseRankingBatchSize = 25
aiCoarseRankingLimit = 25
aiEvidenceCandidateLimit = 20
```

---

## 10. AI Search Plan

`AISearchPlan` 字段：

```swift
searchQuery: String
fromYear: Int?
openAccessOnly: Bool
sort: SearchSort
explanation: String
```

含义：

- `searchQuery`：给 OpenAlex 的英文普通搜索词。
- `fromYear`：可选起始年份。
- `openAccessOnly`：是否只看开放获取。
- `sort`：相关性 / 最新发表 / 引用最多。
- `explanation`：中文解释模型如何理解用户问题。

约束：

- 模型不应该输出布尔查询。
- 模型不应该输出字段语法。
- 模型应该保留用户关心的缩写。
- 例如 NDC 在药物/claims/处方语境中优先理解为 National Drug Code。

超时：

- AI plan 最多等 6 秒。
- 如果大模型没有返回，App 直接提示失败。
- 当前实现不会再用本地规则伪造 AI 检索式。

---

## 11. AI 候选获取

AI plan 成功后：

1. 检查 OpenAlex API Key。
2. 用 `plan.searchQuery` 查询 OpenAlex。
3. 应用 sort、fromYear、openAccessOnly。
4. `per-page = 50`。
5. 去重。
6. 最多保留 50 篇。

候选只是候选，不是最终排序。

---

## 12. AI 粗排和本地快速排序

### 本地快速排序

先显示结果，避免界面空白。

输入：

- 用户原始问题。
- AI search query。
- 标题。
- 摘要。
- 期刊。
- 是否有摘要。
- 是否开放获取。

逻辑：

- 标题命中加分高。
- 摘要命中加分低。
- 期刊命中少量加分。
- 有摘要加分。
- 开放获取加分。
- 原始顺序靠前有基础分。

输出：

- `aiScores`
- `aiReasons`
- `aiEvidenceLevels = 临时候选`

### AI 摘要粗排

大模型只处理前 25 篇。

输入：

- 用户问题。
- 候选论文标题。
- 年份。
- 期刊。
- OpenAlex 摘要。

输出：

- `score`：0 到 100。
- `relevant`：是否相关。
- `reason`：中文一句话原因。

粗排失败时：

- 保留本地快速排序。
- UI 明确提示 AI 粗排未返回。
- 不把它当最终 AI 结果。

---

## 13. 证据精排和全文补强

证据精排目标：让读到全文的论文获得更可靠排序和 summary。

流程：

1. 取 AI ranked works 前 20 篇。
2. 先无全文构造 evidence inputs。
3. 本地 `fallbackEvidenceRanking(...)` 生成初始排序。
4. 立即显示。
5. 并发尝试读取这 20 篇全文。
6. 单篇软超时 6 秒。
7. 只接受 `source.isFullText == true`。
8. 自动获取全文必须通过标题匹配校验。
9. 成功后写入 `aiFullTextDocuments`。
10. 用 `HybridRetriever.search(...)` 对全文段落检索，每篇取最相关 3 段。
11. 再本地更新排序和证据等级。
12. 启动 Literature Review Summary 生成。

当前证据精排主要是本地逻辑，不再调用大模型进行全文 rerank。

证据等级：

- `全文段落精排`：全文参与本地证据排序。
- `仅摘要精排`：只有摘要。
- `全文已读取`：当前页后台补全文成功。
- `临时候选`：候选已展示，但未完成 AI 或证据阶段。

---

## 14. 翻页后台补全文

AI 搜索翻页时会调用：

```swift
enrichVisibleAIPageFullTextInBackground(...)
```

逻辑：

- 只处理当前页可见论文。
- 已有全文、正在 summary、正在读取的跳过。
- 单篇软超时 14 秒。
- 读到全文后写入 `aiFullTextDocuments`。
- 更新证据等级为 `全文已读取`。
- 触发 Literature Review Summary。
- 失败会写入 `aiVisiblePageFullTextFailures`。

所以有些论文一开始只有摘要，过一会儿或翻页后可能出现全文 summary。

---

## 15. 全文获取链路

`FullTextService.load(...)` 负责全文读取。

顺序：

1. `FullTextCache`。
2. Europe PMC XML。
3. OpenAlex TEI XML。
4. OpenAlex location 中公开 PDF。
5. Unpaywall PDF。
6. OpenAlex PDF。
7. Semantic Scholar PDF。
8. OpenAlex 摘要 fallback。

规则：

- 真全文会缓存。
- 摘要 fallback 不缓存。
- 同一失败全文 URL 有 10 分钟冷却，避免重复阻塞。
- 冷却 key 会移除 `api_key` 和 `email`，不把凭据放进 key。
- 用户点击重新读取会清缓存和冷却。

Europe PMC：

- 优先 PMCID。
- 没有 PMCID 时尝试 DOI、PMID、标题+年份。
- 找到后读取 XML。

OpenAlex TEI / PDF：

- 需要 OpenAlex API Key 的场景较多。
- 没有 key 时记录错误并继续试其他来源。

PDF：

- 使用 PDFKit 解析。
- 如果文本层不足，尝试 Vision OCR。

用户导入 PDF：

- 标记为 `importedPDF`。
- 用户主动选择，因此信任为当前论文全文。

---

## 16. 全文标题匹配校验

自动抓取的全文可能不是当前论文，所以需要校验。

规则：

- 自动全文必须和当前 `Work.title` 有足够关键词重合。
- 明显不匹配则丢弃。
- 如果错误全文进了缓存，会清掉缓存。
- 不匹配全文不会用于证据精排和 summary。

用户手动导入 PDF 不走严格校验。

---

## 17. PDF / XML / OCR 解析

XML：

- 使用 `StructuredXMLParser`。
- 尽量提取 body、section、paragraph、page break。
- 输出 `FullTextDocument`。

PDF：

- 使用 `PDFTextParser`。
- 先用 PDFKit 读取文本。
- 文本层不足时用 Vision OCR。
- OCR 语言包括 English、简体中文、繁体中文。

PDF 清洗：

- 识别跨页重复短行，过滤页眉页脚。
- 过滤页码、Page x、URL/DOI、下载声明、版权声明。
- 遇到 References / Bibliography / Literature Cited / Works Cited / 参考文献 后停止继续解析。
- 合并连字符断行。
- 不尝试复杂双栏重排。

扫描工作台的意义：

- 用于 PDF 读不出来、乱码、段落很乱、或 PDF 是扫描版时检查解析质量。
- 它不是论文搜索功能，而是 PDF 原文解析/OCR/校对工作区。

---

## 18. 本地段落检索

`HybridRetriever.search(...)` 是本机检索，不调用大模型。

输入：

- query。
- `FullTextParagraph` 数组。
- limit。

打分：

```swift
score = lexicalNormalized * 0.72 + semantic * 0.28
```

组成：

- 词法命中。
- TF-IDF 类似分数。
- 完整 query 命中。
- section 命中。
- macOS NaturalLanguage sentence embedding 语义相似度。

用途：

- 全文定位。
- AI 证据精排。
- 本地文库检索。
- Evidence Report。
- Literature Review Summary source locate。

---

## 19. Literature Review Summary

这是用户最关心的 review 用摘要。

生成条件：

- 必须有真正全文。
- `document.source.isFullText == true`。
- 摘要 fallback 不生成。

触发时机：

- AI 搜索全文补强成功。
- 翻页后台补全文成功。
- 用户点击读取全文成功。
- 用户导入 PDF 成功。

输出语言：

- 英文。

字段：

- Topic
- Methods
- Results
- Key Metrics
- Outlook

AI prompt 要求：

- 只能使用传入全文摘录。
- 不允许使用模型记忆。
- 不允许编造结果。
- 每个字段必须是完整英文句子。
- 指标必须有标签和上下文，不能是裸数字。

示例：

```text
Sample size: 152,904 veterans
OIC prevalence: 12.6%
Search cutoff: July 2024
```

不允许：

```text
152,904
12.6%
98%
```

上下文选择：

- 优先 abstract、summary、introduction、background、methods、participants、data、results、discussion、conclusion、limitations、future。
- 没有这些 section 时取前 16 个段落。
- 每段最多 900 字符。
- 总上下文约 7000 字符。

失败兜底：

- AI summary 失败时用 `LiteratureReviewSummary.make(...)` 本地生成。
- 本地兜底也只基于全文段落。
- 没有全文不生成。

---

## 20. Source passages used

`Source passages used` 是 Literature Review Summary 的来源依据。

区别：

- `Literature Review Summary`：给人的结构化总结。
- `Source passages used`：支撑总结的原文段落。

例子：

```text
Topic -> Introduction 第 1 段
Methods -> Participants 第 9 段
Results -> Results 第 21 段
Outlook -> Discussion 第 27 段
```

实现：

- `LiteratureReviewCitationBuilder` 本地匹配 summary 字段和全文段落。
- 依据 section 名、词汇重合、关键数字重合。
- 不调用大模型。
- 不联网。

UI：

- 每个字段可显示 `Source: <locator>`。
- `Source passages used` 折叠区列出所有来源段落。
- `Locate` 按钮跳到“全文定位”tab，并把目标段落置顶。

---

## 21. OpenAlex 摘要 vs Literature Review Summary

OpenAlex 摘要：

- 来自 OpenAlex `abstract_inverted_index`。
- 没有全文时也能显示。
- 不代表 RagBio 读过正文。
- 不一定结构完整。

Literature Review Summary：

- 来自 RagBio 读取到的全文 XML / PDF。
- 只对全文生成。
- 英文结构化输出。
- 包括 Topic、Methods、Results、Key Metrics、Outlook。
- 带来源段落。

如果只有 OpenAlex 摘要，不能显示 Literature Review Summary。

---

## 22. 摘要级论文简述

列表里的 `论文简述` / `摘要简述` 不是 Literature Review Summary。

用途：

- 快速扫列表。
- 对没有全文的论文给一句话概括。

来源：

- AI 粗排返回的 reason。
- 或本地 `abstractOnlyPaperSummary(...)`。

限制：

- 可能只基于标题和摘要。
- 不适合作为 literature review 正文依据。

---

## 23. 翻译逻辑

入口：

- 详情页 `翻译本篇`。

行为：

- 只翻译当前选中论文。
- 不批量翻译整页。
- 可翻译标题、摘要、证据句、全文段落。
- 点击后切换该论文中文/英文显示。

优先级：

1. 当前 AI provider 可用时，优先大模型批量翻译。
2. 失败或不可用时，回退到 macOS Translation。

缓存：

- `translatedTitles`
- `translatedAbstracts`
- `translatedEvidence`
- `translatedPassages`
- `translatedWorkIDs`

翻译缓存当前只在运行时存在，不永久保存。

---

## 24. 收藏和我的文库

收藏：

- 在线论文详情页点击收藏。
- 写入我的文库。
- 如果已有收藏，复用已有条目。
- 保存论文元数据。
- 如果当前已有全文，保存全文段落 JSON。
- 如果没有全文但有摘要，保存摘要文档。
- 记录收藏时间。

文库存储：

```text
~/Library/Application Support/RagBio/Library/
```

结构：

```text
Library/
  catalog.json
  Files/
  Documents/
```

PDF 导入：

- 复制 PDF 到 `Files/`。
- 计算 SHA256，避免重复。
- 解析成 `FullTextDocument`。
- 保存段落 JSON 到 `Documents/`。

URL 导入：

- 用户输入 URL 和可选标题。
- 没有 scheme 时补 `https://`。
- 只接受 http / https。
- 只保存链接，不下载 PDF，不解析网页。
- 不参与跨 PDF 段落检索。

导出文库 URL：

- 把所有 `LibraryItem.sourceURL` 导出成文本。
- 每行一个 URL。
- 空 URL 过滤。
- 重复 URL 去重。
- 不导出本地 PDF 原始路径。

我的文库功能：

- PDF 多选导入。
- 文件夹递归导入。
- Zotero storage 递归导入。
- URL 引用。
- 本地跨 PDF 检索。
- 标签和标题编辑。
- 重建索引。
- 删除。
- 导出 Markdown 报告。
- 导出 URL 列表。

删除条目只删除 RagBio 本地副本，不删除用户原始文件。

---

## 25. Research Scan

Research Scan 是一次在线检索结果上的整理层。

目标：

- 把搜索结果筛选成可审查的 Evidence Table。
- 再从 Evidence Table 生成 Field Scan Report。

### Scan Decision

枚举：

```swift
unreviewed
use
maybe
exclude
```

含义：

- `Use`：确定要纳入当前研究扫描。
- `Maybe`：可能纳入。
- `Exclude`：当前主题下排除。
- `Unreviewed`：还没判断。

边界：

- 只属于当前在线检索 session / project。
- 不是收藏。
- 新搜索会清空当前 scan decisions。
- 可以随 session / project 保存和恢复。

UI：

- 列表卡片和详情页都有决策按钮。
- 支持 filter：All / Use / Maybe / Exclude / Unreviewed。

---

## 26. Evidence Table

Evidence Table 是确定性工程产物，不调用大模型。

输入：

- 当前排序论文列表。
- scan decisions。
- OpenAlex 元数据。
- OpenAlex 摘要。
- AI 分数、理由、证据等级。
- 已生成的全文 Literature Review Summary。
- summary 字段来源段落引用。

行选择规则：

1. 如果有 Use 或 Maybe，只包含这些论文。
2. 如果没有 Use / Maybe，包含当前排序列表，并显示 warning。
3. Exclude 永不进入 Evidence Table。

每行包含：

- work id。
- title。
- year。
- authors。
- venue。
- DOI / PMID / PMCID / OpenAlex ID。
- scan decision。
- access status。
- AI score。
- AI reason。
- AI evidence level。
- abstract text / abstract evidence。
- full-text summary 的 Topic / Methods / Results / Key Metrics / Outlook。
- 每个 summary field 的 source refs。

导出：

- Markdown。
- CSV。

---

## 27. Field Scan Report

Field Scan Report 由 `FieldScanService.generate(...)` 生成。

输入：

- Evidence Table rows。

不是直接从 Work 列表或 OpenAlex 原始结果生成。

行选择：

- 有 Use / Maybe 时，只使用这些 rows。
- 否则使用 Evidence Table 中所有非 Exclude rows。

大模型 prompt 约束：

- 只能使用 Evidence Table rows。
- 每条 claim 必须带 `supporting_work_ids`。
- 不能引用不存在的 work id。
- 不能用模型记忆补写论文事实。
- 必须区分 full-text-supported、abstract-only、mixed evidence。
- 证据弱时必须写 limitations。

本机校验：

- 删除引用无效 work id 的 theme / claim / must-read paper。
- 没有合法 work id 支撑的 claim 丢弃。
- 计算 support level。
- 限制 section 数量。
- 输入少于 5 篇或没有全文支撑时追加 limitation。
- generation 过期时忽略旧结果。

---

## 28. Named Research Projects

除了默认 autosave，RagBio 支持命名 research project。

默认 autosave：

```text
~/Library/Application Support/RagBio/SearchSession/online-search.json
```

命名项目：

```text
~/Library/Application Support/RagBio/SearchSession/Projects/index.json
~/Library/Application Support/RagBio/SearchSession/Projects/<project-id>.json
```

项目保存：

- query / lastQuery。
- search mode。
- sort / filters。
- current page。
- selected work。
- works。
- aiRankedWorks。
- lastAIPlan。
- aiScores / aiReasons / aiEvidenceLevels。
- fullTextReviewSummaries。
- scanDecisions。
- Evidence Table 当前版本和历史。
- Field Scan Report 当前版本和历史。
- user notes。

不保存：

- API keys。
- raw full-text body。
- translation cache。
- loading progress。
- active async task。
- publisher credentials。

打开项目时：

1. 取消旧 AI enhancement task。
2. 递增 search generation。
3. 递增 corpus analysis generation。
4. 防止半恢复状态触发 autosave。
5. 清空 transient loading state、translation state、当前全文视图。
6. 恢复 works、ranking、scores、reason、summary、scan decisions、Evidence Table、Field Scan Report。
7. 不自动重跑 AI 搜索、全文补强或 Field Scan。

UI：

- Pin Current Search as Project。
- Open Project。
- Rename Project。
- Duplicate Project。
- Delete Project。

---

## 29. 缓存和持久化

OpenAlex 搜索缓存：

- 内存缓存。
- 30 分钟。
- 最多 100 条。
- key 包含 query、sort、fromYear、openAccessOnly、page、perPage。

全文缓存：

```text
~/Library/Application Support/RagBio/FullText/
```

只缓存真正全文，不缓存摘要 fallback。

在线 session：

```text
~/Library/Application Support/RagBio/SearchSession/online-search.json
```

保存：

- 搜索输入。
- OpenAlex query。
- 搜索模式。
- 排序筛选。
- 当前页 works。
- aiRankedWorks。
- aiScores。
- aiReasons。
- aiEvidenceLevels。
- fullTextReviewSummaries。
- 当前页码。
- selected work。
- lastAIPlan。
- scan decisions。
- Evidence Table。
- Field Scan Report。

不保存：

- API Key。
- 全文正文。
- 翻译结果。
- loading state。

---

## 30. 设置和凭据

设置分两类。

开放全文和检索源：

- OpenAlex API Key。
- Semantic Scholar API Key。
- Unpaywall contact email。
- Europe PMC 连接测试。
- GROBID endpoint。

AI 搜索 provider：

- DeepSeek。
- OpenAI。
- Anthropic Claude。
- Google Gemini。

每个 provider 有：

- API Key。
- model。
- base URL。
- 测试按钮。
- 推荐模型。

凭据存储：

- 当前使用 `UserDefaults(suiteName: "com.local.RagBio") ?? .standard`。
- 保存到 `credential.mirror.<key>`。
- 内存中有 `memoryCache`。
- 不使用 Keychain，因此不会频繁弹钥匙串。

安全边界：

- UserDefaults 安全性低于 Keychain。
- 后续正式发布可考虑迁回安全存储，但要解决授权弹窗体验。

AI provider endpoint：

- DeepSeek：OpenAI-compatible `/v1/chat/completions`。
- OpenAI：OpenAI-compatible `/v1/chat/completions`。
- Anthropic：`/v1/messages`。
- Gemini：`/v1beta/models/<model>:generateContent`。

DeepSeek 会显式关闭 thinking，因为这是低延迟结构化任务。

---

## 31. 主要 UI Tab 逻辑

在线检索详情页的主要 tab：

### 论文信息

显示：

- 标题。
- 作者。
- 年份。
- 期刊。
- 引用数。
- access 状态。
- OpenAlex 摘要。
- Literature Review Summary。
- Source passages used。

### 全文定位

用于在当前论文全文里主动搜索段落。

用户输入关键词，例如：

```text
GI symptoms predict autism
```

App 会在全文段落里返回最相关段落、章节、段落序号、页码和相关度。

### 证据报告

用于把当前检索结果和证据整理成 Markdown 报告。

### 扫描工作台

用于 PDF 原文解析质量检查 / OCR 工作区。

什么时候用：

- PDF 读不出来。
- PDF 是图片扫描版。
- 复制文字乱码。
- 段落切分很乱。
- 需要检查 OCR 和页码对应关系。

如果在线论文摘要和全文定位都正常，一般不需要用扫描工作台。

---

## 32. 超时和失败策略

核心策略：

先显示可用结果，再后台补强证据。

超时：

- AI search plan：6 秒。
- OpenAlex AI 候选页：8 秒软超时。
- AI 粗排：软超时。
- 前 20 篇全文补强：单篇 6 秒。
- 翻页后台补全文：单篇 14 秒。
- AI full-text summary：35 秒。

失败处理：

- AI plan 失败：直接提示，不生成临时候选检索式。
- OpenAlex 失败：显示检索失败。
- AI 粗排失败：保留本地快速排序，并标明不是完整 AI 结果。
- 全文读取失败：保留摘要级显示。
- Summary 失败：显示错误或用本地全文兜底。
- 标题匹配失败：丢弃全文。

状态隔离：

- `searchGeneration` 隔离异步搜索。
- 新搜索会取消旧任务。
- 旧请求返回太晚会被丢弃。
- `aiEnhancementTask` 新搜索时会取消。
- `ensureSearchIsActive(...)` 检查 generation 和 search mode。

---

## 33. 数据隐私和外部请求

发送到外部服务：

- OpenAlex：query、筛选条件、API Key。
- Europe PMC / Unpaywall / Semantic Scholar / PDF URL：DOI、PMID、PMCID、标题或 URL。
- AI provider：用户研究问题、候选标题/摘要、全文摘录、翻译文本、Evidence Table rows。

保留在本机：

- 用户导入 PDF 副本。
- PDF 解析段落 JSON。
- 文库 catalog。
- 全文缓存。
- 在线 session。
- 命名 project。
- API Key 设置。

不会发送：

- 本机 PDF 全文不会自动发给 AI，除非生成 summary 或相关 AI 功能需要全文摘录。
- Publisher 账号密码不会保存或发送。

---

## 34. 当前已知限制

1. OpenAlex search 不是完整布尔检索。
2. AI 搜索质量依赖 search plan。
3. AI 粗排只优先处理前 25 篇。
4. 证据精排目前是本地逻辑，不是大模型全文 rerank。
5. 全文获取受开放获取和 PDF/XML 可用性限制。
6. PDF/OCR 对复杂双栏、表格、脚注仍可能有噪声。
7. Literature Review Summary 只基于约 7000 字符全文摘录，不等于人工完整精读。
8. UserDefaults 存 API Key 安全级别低于 Keychain。
9. 在线 session 不恢复 raw full-text body 或翻译结果。
10. URL 引用不抓网页正文。
11. 翻译缓存不持久化。
12. 扫描工作台主要是解析/OCR辅助，不是搜索结果质量评估器。

---

## 35. 给后续 GPT 的工程建议

如果继续改这个项目，请遵守：

- 每次改动更新 `DEVELOPMENT_LOG.md`。
- 不要把 UI、网络、解析、AI prompt、持久化全塞进一个文件。
- 尽量保持分层：
  - UI：`ContentView` / `LibraryView`
  - 状态机：`SearchStore` / `LibraryStore`
  - 外部 API：`OpenAlexClient` / `AIQueryPlanner` / `FullTextService`
  - 解析：`FullTextParser`
  - 检索：`HybridRetriever`
  - 持久化：`LibraryService` / `OnlineSearchSessionStore` / `OnlineSearchProjectStore`
  - 数据模型：`Models` / `ScanModels`
- 新功能优先做成独立 service / helper / model，不继续膨胀 `ContentView`。
- 不要让大模型生成无法追溯的论文事实。
- 读不到全文时，UI 必须明确降级为摘要或元数据。
- 修改后至少运行：

```bash
swift build
git diff --check
```

如果改了 App 运行逻辑，还要运行：

```bash
./scripts/build-app.sh
```

---

## 36. 最重要的可信边界

RagBio 的可信边界只有一个核心原则：

```text
能追溯到真实论文元数据、摘要或全文段落的内容，才可以展示为证据。
不能追溯的内容，只能作为搜索辅助或 UI 状态说明，不能作为论文事实。
```

