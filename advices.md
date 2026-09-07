# AIChatApp 开源项目整合建议

> 基于当前架构（SwiftUI macOS + SwiftPM + MarkdownUI + SwiftMath、OpenAI 兼容 SSE 流式、UserDefaults/JSON 持久化、动态定价、多模态图片/PDF）整理。
>
> 建议按「投入产出比」分层。第一梯队已在本仓库 `feat/agentic-features` 分支实现。

---

## 🥇 第一梯队：功能空白（已实现）

### 1. 工具调用 / Function Calling（+ 内置工具集）
- **借鉴**：[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)（未来做 MCP 标准协议时）
- **当前实现**：`OpenAIService` 扩展 `tools` + `tool_calls` 字段，内置 4 个工具（`calc` / `web_search` / `web_fetch` / `weather`；`get_time` 因系统已内置时间戳注入而省略），服务层内部维护 tool-call 循环（最多 5 轮 + 收尾答案轮），流式体验不变
- **注意**：部分中继/模型（如 DeepSeek-reasoner）不支持 tools → 开关放到 profile 设置里
- **下一步**：把 `web_search` 等升级为 MCP server，对接文件系统、终端等

### 2. 联网搜索
- **借鉴**：[DuckDuckGo Instant Answer API](https://duckduckgo.com/api)（零 key）、[searxng](https://github.com/searxng/searxng)（自部署聚合）
- **当前实现**：内置 `web_search` + `web_fetch` 工具，走 DDG Instant Answer + HTML 抓取降级；`web_fetch` 可抓取搜索结果指向的网页全文（纯文本 ≤8000 字符）
- **下一步**：渲染"引用来源"标记（Perplexity 式）；接入自建 searxng

### 3. 准确的 Token 计数
- **借鉴**：OpenAI [tiktoken](https://github.com/openai/tiktoken)（官方近似算法）；真实 BPE 可用 [`intervinn/SwiftTokenizers`](https://github.com/intervinn/SwiftTokenizers)
- **当前实现**：`AccurateTokenCounter`——cl100k_base 官方近似（英/数/空白分桶）+ CJK 微调，替换原字符启发式，误差通常 <5%
- **下一步**：内嵌 `.tiktoken` vocab 文件换真实 BPE（注意 SPM bundle 复制，先例是 SwiftMath）

### 4. 历史全文搜索
- **借鉴**：[`SQLite.swift`](https://github.com/stephencelis/SQLite.swift) / [`GRDB.swift`](https://github.com/groue/GRDB.swift)（FTS5）；或 macOS SearchKit（零依赖）
- **当前实现**：内存全文检索（标题 + 消息内容，大小写不敏感，命中跳转 + 高亮），会话量在桌面应用规模足够
- **下一步**：换 SQLite/FTS5 支撑万级消息

---

## 🥈 第二梯队：体验增强（性价比高）

| 功能 | 借鉴项目 | 说明 |
|---|---|---|
| 代码块语法高亮 | ~~[`raspu/Highlightr`](https://github.com/raspu/Highlightr)~~ | ✅ **已实现**：自研 `ThemeCodeSyntaxHighlighter`（正则 tokenizer，零依赖，16 种语言关键字表）+ 语言栏 + 复制按钮 |
| 思考过程折叠 | — | ✅ **已实现**：DeepSeek `reasoning_content` 抓取并持久化（工具轮回传是 API 硬要求），气泡内「💭 思考过程」默认折叠 |
| 导出会话为 PDF | ~~第三方 md→pdf 库~~ | ✅ **已实现**：`ImageRenderer` + `CGPDFContext` 把 `MarkdownText` 真实视图树画进 PDF，**复用高亮/公式/表格**且文字为矢量可搜索；零依赖。局限见下 |
| Mermaid 流程图 | 复用 `MathSegmenter` 的 provider 管线思路 | ` ```mermaid ` 块走 WKWebView 快照，架构与数学渲染同构 |
| LaTeX 编译为 PDF | — | ✅ **已实现（可选开关）**：Agent 模式新工具 `compile_latex`。双重门槛 = profile 开关 + 本机 TeX 工具链（探测 `/Library/TeX/texbin` 等，xelatex/pdflatex/lualatex），缺任一则工具不注册（模型看不到）且设置开关置灰。产物存 `~/Documents/AIChatApp/LaTeX/<name>-<时间戳>/`，工具结果里带 `ARTIFACT: file://` 行 → 聊天里渲染成可点击 PDF 卡片。安全边界：模型只能给文件名主干，写不出输出目录 |
| 朗读回复（TTS） | 零依赖：系统 `AVSpeechSynthesizer` | 助手消息加 🔈 按钮，中文用 `zh-CN` voice |
| 语音输入（STT） | [`WhisperKit`](https://github.com/argmaxinc/WhisperKit) | Apple Silicon 原生优化；可先用系统听写 API 过渡 |
| API Key 安全 | [`kishikawakatsumi/KeychainAccess`](https://github.com/kishikawakatsumi/KeychainAccess) | ⚠️ **仍是明文**：`~/Library/Preferences/com.aichat.app.plist` 里可直接读出 key，Keychain 是安全底线 |
| 会话累计花费 | — | 每条消息已持久化真实 `usage`，可算「本会话花费 / 今日累计」，纯 UI 活 |

### PDF 导出的已知局限（后续可优化）

1. **跨页处理是"整幅切带"**：内容按页高切片，正好落在分页线上的一行文字会被从中间截断。彻底解决需要按消息块测高、做块级分页（约半天）。
2. **代码块长行会被裁切**：屏幕上代码块是横向滚动的（`ScrollView(.horizontal)`），PDF 里没有滚动概念，超出页宽的长行看不到。可为导出路径单独提供"自动换行"版代码块样式。

---

## ⚠️ 上下文缓存的硬约束（血泪教训，改 prompt 结构前必读）

DeepSeek 硬盘缓存按 **"下一轮请求的前缀完整包含上一轮落盘单元"** 匹配，因此：

- **任何每轮会变的消息都不能放在 `messages` 末尾**——上一轮的单元以它结尾，下一轮该位置换成了新内容 → 单元永远匹配不上，命中率跌到只剩 system prompt（实测 9%）
- 曾踩的两个坑：① 时间戳消息挂在末尾；② profile（长期记忆）消息挂在末尾
- 正确布局：`system prompt → profile → 完整历史`（动态内容放最前，实测命中率 99%）
- 实时信息（如当前时间）**改用工具获取**：工具消息只活在当轮请求内、不落盘历史，对下一轮前缀零污染
- 序列化 Swift 字典必须加 `.sortedKeys`——字典 key 顺序每次随机，否则同一份数据每轮字节都不同
- **⚠️ 2026-08-31 新增（本次实测）：`JSONEncoder` 不设 `.sortedKeys` 时，连 Codable struct 的字段顺序都是随机哈希序**——Foundation 内部键值容器是哈希表，per-process 随机种子。所以**所有 chat payload 编码必须统一用 `.sortedKeys` 的共享 encoder**（`chatPayloadEncoder`）。之前"struct 声明序保证稳定"的假设是错的：同进程内看起来稳定，每次重启 App 整个请求（含 tools、messages 的每个字段）字节全变，缓存每轮全灭。另外 `tools[].function.parameters` 是 `[String: Any]`，`PayloadJSON` 里要显式按 key 排序编码，双保险。
- 时序：本次就是"Agent 模式开着（每轮都带 tools）→ 重启 App → tools JSON key 乱序 → 缓存崩溃"，且 `includeTimestamp` 开关冗余（Agent 已含 get_time），已关。

---


## 🥉 第三梯队：架构级（长期价值）

1. **SQLite/GRDB 替代 JSON 持久化**：会话多了 JSON 全量读写会卡（流式期间禁持久化即是缓解）；GRDB 增量写 + FTS 一步到位
2. **本地知识库 / RAG**：扩展 `UserProfileStore` 成可检索记忆库；macOS 15.5+ 自带 `Embedding`/`SemanticSearch`（零依赖）或 [`huggingface/swift-transformers`](https://github.com/huggingface/swift-transformers)
3. **本地模型兜底**：Ollama 提供 OpenAI 兼容端点 `http://localhost:11434/v1` → 设置页加"本地模型"预设，几乎零代码
4. **本地绘图**：Apple [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion)（Core ML），依赖重，非核心诉求不建议先做

---

## 💡 值得"借鉴设计"而非"整合代码"的项目

- **Cherry Studio / Chatbox / Lobe Chat**：多模型桌面客户端成熟形态——MCP 面板、知识库、翻译、提示词超市的 UI 设计直接参考
- **OpenRouter 缓存机制**：请求已 byte-stable（prompt cache 友好），可在 UI 上把"缓存命中"作为卖点展示

---

## 📌 建议优先级（如果只做三件）

1. **Keychain 存密钥**（半天，安全底线）
2. **代码高亮 + 语音朗读**（各半天，观感提升最直接）
3. **工具调用（内置 3-4 个工具起步）**（1-2 天，功能质变）
