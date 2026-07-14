# RagBio

RagBio 是一个原生 macOS 学术证据检索应用。它可以在线发现开放全文，也可以把用户自己的 PDF 建成本地检索文库，在 Mac 上建立段落索引并生成可追溯的证据报告。

## 当前原则

- 论文标题、作者、日期、DOI 等字段直接来自 OpenAlex。
- 在线来源依次覆盖 Europe PMC、OpenAlex TEI、OpenAlex 全部 locations、Unpaywall、Semantic Scholar 和开放 PDF。
- 全文按章节和段落解析；PDF 证据尽量保留页码。
- 使用本地关键词相关性和系统语义向量进行混合检索。
- 报告只引用检索到的原文段落，不让模型补写。
- 没有合法全文时降级到摘要，并明确标注证据级别。
- 用户可多选、拖放或递归导入文件夹和 Zotero `storage` 中的 PDF。
- 本地文库支持跨 PDF 检索、标签、重建索引、去重、删除以及 Markdown 报告。
- 用户导入的 PDF 只在本机解析和缓存；扫描页会使用 macOS Vision OCR。
- 可选连接本机 GROBID 服务，以获得更准确的章节和段落结构。
- 搜索仅使用 AI；AI 把自然语言描述转换成可审查的 OpenAlex 检索计划。
- OpenAlex 检索词会经过本地规则清洗和同义词扩展，覆盖常见疾病、药物、数据库缩写和编码系统。
- AI 搜索支持 DeepSeek、OpenAI、Anthropic Claude 和 Google Gemini，凭据保存在本机应用配置中。
- 在线 AI 搜索使用每条历史独立持久化的 `Use` 选择；刷新或重启后仍会保留，并可按历史导出 URL。
- 可以从当前搜索历史生成 deterministic Evidence Table，并在此基础上生成带 `work_id` 支撑的 Field Scan Report。

## 构建

要求 macOS 13 或更高版本，以及 Apple Command Line Tools。

```bash
swift build
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/RagBio.app
```

## AI 搜索

在搜索栏中可以直接描述研究目标、时间范围、研究对象和开放获取要求。RagBio 会调用设置中启用的大模型，生成英文检索词、年份、排序和开放获取筛选，再从 OpenAlex 获取最多 50 篇候选论文。

AI 候选检索需要在设置中配置免费的 OpenAlex API Key。RagBio 会获取候选并完成摘要粗排，立即显示结果；随后对前 20 篇证据候选尝试全文段落二次重排。

论文详情中的“翻译本篇”只翻译当前论文的标题、摘要、证据句和已读取全文段落。旁边的“收藏”按钮会将论文元数据及当前可用的摘要或全文证据保存到“我的文库”，并记录收藏时间。

单篇翻译默认复用当前启用的大模型（例如 DeepSeek）进行批量逐段翻译；模型不可用时自动回退到 macOS Translation。标题、摘要和证据句优先显示，正文随后分批写入缓存。

普通检索返回列表后，“分析本页”只使用已经缓存的全文或 OpenAlex 摘要，不会自动遍历远程全文来源。这样列表可以立即使用；需要获取某篇新全文时，使用论文详情中的“读取全文”。

相同的 OpenAlex 关键词、筛选条件和页码会在内存中缓存 30 分钟。AI 搜索通常一次获取最多 50 篇候选，取得后立即显示，再优先对前 25 篇做摘要粗排并继续正文精排。

AI 正文阶段会对前 20 篇证据候选尝试获取全文；能读到全文的论文会进入全文段落精排并生成 literature review 摘要，其余候选继续使用摘要。摘要与段落输入长度不再做过度压缩，界面会显示 OpenAlex、首屏和精排阶段耗时。

候选论文会按 20 篇一组交给大模型，仅根据标题、年份、期刊和摘要判断与原始问题的真实相关性。明显无关的论文会被排除，其余论文按 0–100 的相关度重新排序；界面会显示每篇论文的相关度和中文入选理由。重排结果在本次检索中缓存，之后每 20 篇本地翻页，不会重复消耗模型 API。

粗排后的前 40 篇会进入第二次重排。RagBio 先尝试取得合法全文，在本机用混合检索筛出每篇最相关的 3 个段落，然后把“截断摘要 + 关键段落”交给大模型进行最终评分。摘要用于提供论文整体背景，正文段落用于核验论文是否真正回答问题。没有全文的论文仍可参与，但会明确标记为“仅摘要精排”，置信度低于“全文段落精排”。

单篇全文自动获取超过 25 秒时会降级为摘要证据，避免某个下载源阻塞整次搜索。

## Research Scan

搜索结果只使用 `Use` 标记。每条 AI 搜索历史独立保存自己的 `Use` 论文；刷新相同查询或重启应用后仍会保留，也可以导出所选论文的 URL。`Use` 不会把论文保存到全局文库；全局保存仍然使用“收藏”。

在详情页的“扫描工作台”可以生成 Evidence Table：

- 如果用户标了 `Use`，表格只包含这些论文。
- 如果还没有标记任何 `Use`，表格会基于当前排序生成，并显示 warning。
- Evidence Table 是本地 deterministic 生成，不调用大模型。
- Markdown 和 CSV 导出会包含论文元数据、访问状态、AI 分数/理由、摘要、已有全文 summary 和来源段落引用。

Field Scan Report 只从 Evidence Table 生成。大模型可以组织主题、发现、方法、研究空白和必读论文，但每条 claim 必须引用输入表里的 `work_id`。App 会丢弃没有合法 `work_id` 支撑的 claim，并标注 full-text、abstract-only 或 mixed support level。

### AI Search History

RagBio stores successful AI searches locally. Focusing the search field shows recent queries; selecting one restores its saved results and Use selections without rerunning the search. Repeating the same query refreshes its results while preserving accumulated Use papers.

设置中可为每个厂商填写 API Key、模型和接口地址。应用提供推荐模型，但允许手动修改，以适应厂商后续发布的新模型或兼容代理服务。API Key、模型和接口地址都会存入本机应用配置。

OpenAlex 检索和内容下载需要免费 API Key。生物医学论文会优先尝试 Europe PMC，但仍建议在应用“设置”中填写 Key：

<https://openalex.org/settings/api>

Unpaywall 要求 API 请求携带联系邮箱，可在“设置 → 开放全文发现”中填写。

如已在本机运行 GROBID，可在设置中填写 `http://localhost:8070`。GROBID 不可用时会自动退回 PDFKit 和本地 OCR。

## 本地数据

文库副本与索引保存在：

```text
~/Library/Application Support/RagBio/Library/
```

全文缓存保存在：

```text
~/Library/Application Support/RagBio/FullText/
```

AI Search History 保存在：

```text
~/Library/Application Support/RagBio/SearchHistory/index.json
~/Library/Application Support/RagBio/SearchHistory/records/<history-id>.json
```

首次启用 AI Search History 时，RagBio 会一次性删除旧的 Projects 和 Autosaved Search 数据，且不会迁移这些旧搜索。历史记录包含论文元数据、筛选状态、`Use` 选择和已生成的摘要；不包含 API 凭据或原始全文内容。原始全文仍只保存在独立的 FullText 缓存中。

## 数据边界

并非每篇论文都有合法开放全文。RagBio 不绕过付费墙；对于你有权访问的论文，可以使用“导入 PDF”。扫描版 PDF 可能因为缺少文本层而无法解析。

# spearmint bio
