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

## Review Engine integration spike（开发者）

RagBio 的搜索侧栏现在提供 `Generate Review`。它会冻结当前 Search History 中全部 `Use` 论文的 URL 清单，显示确认页，然后通过本机 Codex SDK 和用户已登录的 ChatGPT/Codex 额度执行内置 SR/MA workflow。任务、manifest、中间目录和最终文件持久化在：

```text
~/Library/Application Support/RagBio/Reviews/
```

Review Workspace 支持阶段进度、暂停、同一 Codex thread 恢复、失败重试，以及完成后的 `Open Excel`、`Open Word` 和 `Show in Finder`。Review Engine 仅处理固定 manifest 中的 URL，不额外添加论文；未记录的注册、完整检索、双人筛选、PRISMA、偏倚和 GRADE 信息不会被假定为已完成。

下方 Settings 中的 `Review Engine Preview` 仍是开发者连接探针，用来单独排查登录和本地 runtime，不会生成正式 systematic review。

当前分支包含一个内部连接探针，用来验证 RagBio 是否能通过本机 Codex SDK 复用用户的 ChatGPT/Codex 登录、流式显示阶段、暂停/恢复任务，并打开生成的 Excel 和 Word 文件。它只验证底层连接，不是面向用户的 Systematic Review 功能，也不会读取或复制 `~/.codex/auth.json`。

安装依赖并运行 helper 测试：

```bash
cd Tools/ReviewHelper
npm ci
npm test
npm run build
cd ../..
```

运行完全离线的 fixture：

```bash
printf '%s\n' \
  '{"type":"probe.start","requestId":"readme-fixture","mode":"fixture","workingDirectory":"/tmp/ragbio-review-probe"}' \
  | node Tools/ReviewHelper/dist/main.js
```

以开发模式启动 RagBio，并在 Settings 中打开 `Review Engine Preview`：

```bash
swift build
RAGBIO_REVIEW_HELPER_NODE="$(command -v node)" \
RAGBIO_REVIEW_HELPER_SCRIPT="$PWD/Tools/ReviewHelper/dist/main.js" \
"$(swift build --show-bin-path)/RagBio"
```

组装包含 Node、helper 和 pinned arm64 Codex runtime 的本地测试 App 时，应传入可独立分发的官方 Node arm64 可执行文件；不要使用依赖 `/opt/homebrew` 动态库的 Homebrew Node：

```bash
RAGBIO_REVIEW_NODE_BINARY=/absolute/path/to/official-node-arm64/bin/node \
  Tools/ReviewHelper/scripts/assemble-spike-app.sh
Tools/ReviewHelper/scripts/inspect-runtime.sh
open .build/review-spike/RagBio.app
```

fixture 文件写入命令指定的 working directory；开发探针和组装 App 均写在 `.build/` 或临时目录。删除这些探针输出不会删除 Search History、`Use` 记录或 FullText 缓存。完整的实测结论见 [Codex Review Integration Spike Results](docs/review-engine/codex-sdk-spike-results.md)。

## AI 搜索

在搜索栏中可以直接描述研究目标、时间范围、研究对象和开放获取要求。RagBio 会调用设置中启用的大模型，生成英文检索词、年份、排序和开放获取筛选，再从 OpenAlex 和 PubMed 合并最多 60 篇候选论文。

AI 候选检索需要在设置中配置免费的 OpenAlex API Key。RagBio 会先将全部候选分成 3 组、每组 20 篇，使用摘要完成全局 AI 排序；在这一步成功前不会显示临时候选。随后再读取当前页最多 20 篇的全文或摘要，进行 AI 全文证据精排。

论文详情中的“翻译本篇”只翻译当前论文的标题、摘要、证据句和已读取全文段落。旁边的“收藏”按钮会将论文元数据及当前可用的摘要或全文证据保存到“我的文库”，并记录收藏时间。

单篇翻译默认复用当前启用的大模型（例如 DeepSeek）进行批量逐段翻译；模型不可用时自动回退到 macOS Translation。标题、摘要和证据句优先显示，正文随后分批写入缓存。

第一页会在搜索后自动精排。用户第一次打开后续页面时，RagBio 才读取该页论文并进行相同的 AI 精排；每页的结果会保存到搜索快照，返回该页时不会重复调用模型。精排只调整当前页面内部的顺序，其他页面保持已完成的全局摘要顺序。

每篇论文最多向模型提供截断摘要和最相关的 2 个全文段落。没有合法全文时仍可使用摘要参与精排，并标记为“AI 摘要精排”。单篇全文自动获取超过 6 秒时会降级为摘要，避免一个下载源阻塞整页。

如果 AI 全文精排失败，RagBio 会保留本地全文证据排序，并在界面中显示页码和失败原因，不会把降级结果标记为 AI 精排。

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
