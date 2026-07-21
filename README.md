# RagBio

RagBio 是一个原生 macOS 学术证据检索与 review 辅助应用。用户可以用自然语言检索 OpenAlex 和 PubMed，查看摘要或可访问全文，逐篇标记 `Use`，恢复历史搜索快照，并从固定的 `Use` URL 清单生成可审计的 Excel 与 Word review 材料。

## 当前原则

- 论文元数据来自 OpenAlex 和 PubMed；两侧结果合并、去重后最多保留 60 篇。
- 在线全文来源依次覆盖 Europe PMC、OpenAlex TEI、OpenAlex locations、Unpaywall、Semantic Scholar 和开放 PDF。
- 全文按章节和段落解析；PDF 证据尽量保留页码。
- 60 篇候选先按摘要完成全局 AI 排序；当前页最多 20 篇随后使用可访问全文段落或摘要完成页内精排。
- 页面精排结果保存在搜索快照中，返回已经分析过的页面时不会重复调用模型。
- 没有合法全文时降级到摘要，并明确标注证据级别。
- 搜索只保留 AI 搜索入口；AI 把自然语言问题转换成检索表达式，并以实际返回的论文证据进行排序。
- OpenAlex 检索词会经过本地规则清洗和同义词扩展，覆盖常见疾病、药物、数据库缩写和编码系统。
- AI 搜索支持 DeepSeek、OpenAI、Anthropic Claude 和 Google Gemini，凭据保存在本机应用配置中。
- 每条搜索历史独立保存结果、筛选条件、页内精排缓存和 `Use` 选择；刷新或重启后仍会保留。
- `All` 显示全部候选，`Likely Primary` 隐藏数据库已经明确标记为 review、guideline、editorial 等非 primary 类型的论文，`Use` 只显示用户最终选择。
- 用户可以导出当前记录的 `Use` URL，也可以把同一份固定清单交给内置 Review Engine。
- 单篇 Article Summary 优先使用可访问全文，并显示真实证据来源；没有全文时不会把摘要伪装成全文。
- Systematic Review 生成阶段不额外添加论文，不假定不存在的研究流程，并把结构化证据和最终 Office 文件分开生成。

## 构建

要求 macOS 13 或更高版本，以及 Apple Command Line Tools。

```bash
swift build
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/RagBio.app
```

## Systematic Review 生成逻辑

搜索侧栏中的 `Generate Review` 会把当前搜索记录里由用户标记为 `Use` 的论文交给 Review Engine，最后生成一份 Excel 数据工作簿和一份 Word review。它不是一次普通的“把 URL 发给模型并让模型写文章”的请求，而是一条由 RagBio、内置 Node helper、Codex agent 和本地文档生成器共同完成的多阶段流水线。

### 用户看到的流程

1. 用户在一条 AI Search History 中选择论文并标记为 `Use`。
2. 点击 `Generate Review` 后，RagBio 先检查本机 Review Engine 的 ChatGPT 登录状态；未登录时打开浏览器完成授权，成功后自动回到确认页。
3. 确认页显示 `Use` 论文数、实际可发送的 URL 数，并允许选择 English 或中文输出。
4. 点击 `Start Review` 后，输入清单立即冻结。此后即使用户修改 `Use`，已经开始的 Review 也不会改变。
5. Review Workspace 显示读取来源、提取数据、综合证据、生成文件和验证文件等阶段；任务可以暂停、恢复或在失败后重试。
6. 完成后可以直接打开 Excel、Word，或在 Finder 中查看文件。

同一搜索记录可以生成多个 Review 版本。App 同一时间只允许运行一个 Review 任务。

### 固定输入 manifest

RagBio 从当前搜索快照的 `Use` ledger 创建 `ReviewInputManifest`。manifest 保存：

- 搜索问题、Search History ID、快照时间和 Review 版本身份；
- 输出语言；
- 每篇论文在清单中的顺序、OpenAlex/PubMed identity、题名、期刊、年份和选中时间；
- 实际发送给 Review Engine 的 URL，以及原始论文页面 URL；
- `included`、`duplicateURL` 或 `missingURL` 状态。

相同 URL 只处理一次；没有可用 URL 的论文仍留在 manifest 中供审计，但不会作为可读取来源发送。Review Engine 只允许处理 manifest 中 disposition 为 `included` 的论文，不得搜索或添加清单之外的文献。

每个任务的数据保存在：

```text
~/Library/Application Support/RagBio/Reviews/<job-id>/
├── manifest.json
├── job.json
├── working/
│   ├── review-manifest.json
│   └── review-data.json
└── outputs/
    ├── RagBio Systematic Review.xlsx
    └── RagBio Systematic Review.docx
```

### 当前 Codex 执行层

正式 Review 目前通过内置的 `Tools/ReviewHelper` 执行：

```text
SwiftUI / ReviewJobCoordinator
        │ JSONL commands and events
        ▼
bundled Node runtime + ReviewHelper
        │ @openai/codex-sdk
        ▼
signed-in Codex thread
        │ reads URLs and writes structured JSON
        ▼
review-data.json
        │ deterministic local builder
        ▼
Excel + Word
```

打包版 App 已包含 Node、ReviewHelper、`@openai/codex-sdk` 和 Apple Silicon Codex runtime；用户不需要另外安装 Codex。当前实现使用用户已登录的 ChatGPT/Codex allowance。为避免意外改成 API-key 计费，helper 启动 Codex 时会主动移除 `OPENAI_API_KEY`、`CODEX_API_KEY` 和 `AZURE_OPENAI_API_KEY` 环境变量。

Codex thread 的工作目录被限制为该任务的 `working/`，使用 `workspace-write` sandbox，允许网络访问，不要求该目录是 Git 仓库，也不允许交互式审批。开始后会保存 thread ID；暂停、App 关闭或可恢复失败后，RagBio 使用相同 thread 和磁盘上的中间文件继续，而不是重新创建一份输入。

### Agent 必须完成的工作

Codex 不负责直接排版 Excel 或 Word。它读取固定 manifest 和内置 workflow，完成以下证据工作并写出严格的 UTF-8 `review-data.json`：

1. 逐条读取和审计 manifest 中的来源；网页和论文内容只被当作不可信证据，不能作为操作指令。
2. 区分访问来源类型与论文研究设计。
3. 判断 primary、background-only、supplementary、duplicate、superseded、protocol 或 inaccessible。
4. 提取 PICO/PECO、研究特征和可用的结局数据。
5. 为每条 manifest 记录写出纳入决定及理由，并把“是否纳入研究”与“某个 endpoint 是否适合合并”分开。
6. 只在研究和 estimand 足够可比时进行 quantitative pooling；否则明确进行 narrative synthesis。
7. 在证据允许时记录 RoB 2、ROBINS-I、QUADAS-2、PROBAST 等风险评估以及 preliminary GRADE；无法判断时写 `Not assessable`。
8. 生成结构化摘要、研究问题、研究特征、source audit、analysis rows、risk of bias、synthesis、GRADE、references、readiness checklist 和 manuscript 各章节。
9. 根据 manifest 生成英文或简体中文正文，同时保留论文题名、标识符、URL、数字、引文和标准化工具名称的原文。

系统明确禁止虚构 protocol registration、完整多数据库检索、双人筛选、PRISMA 流程、缺失的结局数据、偏倚结论、GRADE 结论或 publication-bias analysis。Word 的 Methods 必须说明证据集来自用户在 RagBio 中选择的 URL，且 Review Engine 没有额外执行完整文献检索。因此这里生成的是辅助证据审查材料，不能自动等同于一篇已经满足全部发表规范的 systematic review。

### Excel 和 Word 的生成

Codex 返回完成标记后，ReviewHelper 检查 `review-data.json` 是否存在，再运行本地固定脚本 `workflow/scripts/build_artifacts.mjs`：

- Excel 由结构化 JSON 生成 source audit、study characteristics、decisions、analysis、risk of bias、GRADE、readiness 等工作表；
- Word 由同一份结构化 JSON 生成题名、结构化摘要、Introduction、Methods、Results、Discussion、Conclusion、References 和 Appendix；
- 文档生成不是第二次模型调用；相同 JSON 应产生相同结构的文件；
- helper 最后检查 Excel 和 Word 均已创建，Swift 再把文件安装到任务的 `outputs/` 目录。

### 任务状态和失败恢复

任务、manifest、Codex thread ID、中间 JSON 和最终文件均落盘。App 如果在任务运行中关闭，下次启动会把该任务恢复为 paused，等待用户继续。当前失败提示区分：

- ChatGPT 登录失效；
- Codex allowance/rate limit；
- 网络连接；
- 论文来源无法读取；
- AI generation 中断；
- JSON 或 Excel/Word 验证失败；
- 磁盘空间或文件权限；
- 本地 runtime/protocol 异常。

可恢复任务会保留固定 manifest、thread ID 和已经写入工作目录的内容。Runtime 异常优先提示重启 RagBio，而不是要求用户重新安装。

### 用 Sub2API 或其他 OpenAI-compatible API 替换时的边界

当前代码**没有**通过 Sub2API 或普通 GPT API 生成 Review。它依赖的不只是模型文本输出，还依赖 Codex 提供的 agent loop、网络读取、工具/命令执行、工作目录文件读写、流式事件和 thread resume。因此，仅把一个兼容 `/v1/chat/completions` 的 Base URL 和 API Key 填入现有 helper，不能自动替换当前 Review Engine。

有两条可能的替换路径：

1. **兼容 Codex 执行协议**：代理必须能被当前 Codex SDK 使用，并且真实支持所选模型、长上下文、流式事件、网络/工具调用、工作目录写入和可恢复 thread。若只兼容 OpenAI 文本接口，这条路径不成立。
2. **由 RagBio 自己实现 agent orchestration**：RagBio/ReviewHelper 负责下载 URL、解析和缓存正文、分批调用 API、执行工具、保存 checkpoint、验证严格 JSON，并继续复用现有本地 Excel/Word builder。这条路径不要求代理兼容 Codex，但需要把现在由 Codex runtime 承担的执行能力显式实现出来。

评估一个 Sub2API endpoint 是否足够，至少应验证：

- endpoint 实际支持 Responses API 还是只有 Chat Completions；
- 声明的模型是否真实可用，模型名称是否会被路由或替换；
- 单次上下文、输出长度、并发、总任务时长和 rate limit；
- Structured Outputs/JSON schema 是否稳定；
- function/tool calling 是否完整，是否支持连续多步调用；
- 长任务断线后能否安全重试，是否有 response/thread 状态可恢复；
- 论文 PDF/HTML 由谁下载和解析，以及失败时能否定位到具体来源；
- 中转服务是否记录论文内容、研究问题、模型输入或输出；
- 每位用户是否使用独立 Key、独立额度和审计记录；
- 同一批固定 URL 在 Codex 版和 API 版生成的 source audit、纳入决定、数值提取和最终文件是否一致。

最小可行验证不应先改正式 UI。可以先固定一组有全文、摘要、失效 URL、重复 URL 和非 primary study 的测试 manifest，分别运行当前 Codex workflow 与候选 API workflow，再比较 `review-data.json` 的 schema 完整性、逐篇来源对账、数值准确性、失败恢复以及最终 Excel/Word。只有这些能力通过后，才适合把首次 ChatGPT 登录替换为 `Base URL + API Key + Model` 配置。

### 开发者构建与连接探针

Settings 中的 `Review Engine Preview` 仅用于单独排查登录和本地 runtime，不会生成正式 systematic review。安装 helper 依赖并运行测试：

```bash
cd Tools/ReviewHelper
npm ci
npm test
npm run build
cd ../..
```

以开发模式启动 RagBio：

```bash
swift build
RAGBIO_REVIEW_HELPER_NODE="$(command -v node)" \
RAGBIO_REVIEW_HELPER_SCRIPT="$PWD/Tools/ReviewHelper/dist/main.js" \
"$(swift build --show-bin-path)/RagBio"
```

正式 Apple Silicon 测试包可由 `scripts/package-app.sh` 组装；脚本会下载固定版本的官方 Node arm64 runtime，并把 helper 与 Codex runtime 一起放入 App。完整的早期实测结论见 [Codex Review Integration Spike Results](docs/review-engine/codex-sdk-spike-results.md)。

## AI 搜索

在搜索栏中可以直接描述研究目标、时间范围、研究对象和开放获取要求。RagBio 会调用设置中启用的大模型，生成英文检索词、年份、排序和开放获取筛选，再从 OpenAlex 和 PubMed 合并最多 60 篇候选论文。

AI 候选检索需要在设置中配置免费的 OpenAlex API Key。RagBio 会先将全部候选分成 3 组、每组 20 篇，使用摘要完成全局 AI 排序；在这一步成功前不会显示临时候选。随后再读取当前页最多 20 篇的全文或摘要，进行 AI 全文证据精排。

论文详情中的“翻译本篇”只翻译当前论文的标题、摘要、证据句和已读取全文段落。旁边的“收藏”按钮会将论文元数据及当前可用的摘要或全文证据保存到“我的文库”，并记录收藏时间。

单篇翻译默认复用当前启用的大模型（例如 DeepSeek）进行批量逐段翻译；模型不可用时自动回退到 macOS Translation。标题、摘要和证据句优先显示，正文随后分批写入缓存。

第一页会在搜索后自动精排。用户第一次打开后续页面时，RagBio 才读取该页论文并进行相同的 AI 精排；每页的结果会保存到搜索快照，返回该页时不会重复调用模型。精排只调整当前页面内部的顺序，其他页面保持已完成的全局摘要顺序。

每篇论文最多向模型提供截断摘要和最相关的 2 个全文段落。没有合法全文时仍可使用摘要参与精排，并标记为“AI 摘要精排”。单篇全文自动获取超过 6 秒时会降级为摘要，避免一个下载源阻塞整页。

如果 AI 全文精排失败，RagBio 会保留本地全文证据排序，并在界面中显示页码和失败原因，不会把降级结果标记为 AI 精排。

## AI Search History

RagBio stores successful AI searches locally. Focusing the search field shows recent queries; selecting one restores its saved results and Use selections without rerunning the search. Repeating the same query refreshes its results while preserving accumulated Use papers.

设置中可为每个厂商填写 API Key、模型和接口地址。应用提供推荐模型，但允许手动修改，以适应厂商后续发布的新模型或兼容代理服务。API Key、模型和接口地址都会存入本机应用配置。

OpenAlex 检索和内容下载需要免费 API Key。生物医学论文会优先尝试 Europe PMC，但仍建议在应用“设置”中填写 Key：

<https://openalex.org/settings/api>

Unpaywall 要求 API 请求携带联系邮箱，可在“设置 → 开放全文发现”中填写。

如已在本机运行 GROBID，可在设置中填写 `http://localhost:8070`。GROBID 不可用时会自动退回 PDFKit 和本地 OCR。

## 本地数据

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

并非每篇论文都有合法开放全文。RagBio 不绕过付费墙；无法合法读取全文时，搜索精排和单篇信息会明确降级为摘要证据。Review Engine 也可能把无法读取的 URL 标记为 inaccessible，而不会补写不存在的全文内容。

# spearmint bio
