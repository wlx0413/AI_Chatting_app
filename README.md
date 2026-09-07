# AI Chat（AIChatApp）

macOS 原生 AI 聊天桌面应用：支持 OpenAI Chat Completions 兼容接口、多模态（图片）视觉模型、PDF 文档上传，以及 Markdown + LaTeX 数学公式渲染。对话可离线保存在本地，无需任何 Xcode 工程文件，纯 SwiftPM 构建。

> 当前仓库为 **Apple Silicon (arm64) 原生适配** 版本：修复了旧版打包缺少 SwiftMath 数学字体资源导致的启动闪退，并把依赖全部本地化（`Vendor/`），支持**完全离线、可复现**的双架构构建。

---

## ✨ 功能特性

- **多模型 / 多服务商**：兼容 OpenAI Chat Completions 接口，支持自定义 `Base URL` + `API Key` + 任意模型名。
- **视觉多模态**：识别 `gpt-4o`、`gpt-4.1`、`gpt-4-turbo`、`claude-3.x`、`gemini-1.x` 等视觉模型；发图自动按模型能力匹配（文本模型自动降级）。
- **PDF 文档上传**：上传后可选择发送方式——整页转图片 / 提取文字 / 两者都发（视觉模型逐页渲染，上限可调）。
- **丰富的「粘贴 / 拖拽」文件支持**：
  - 图片、PDF 文件：在 Finder 复制后于输入框直接 `Cmd+V`（或拖入），即变成待发送附件；
  - `txt / md / csv / json / yaml / xml / log` 等文本文件：粘贴时自动读出内容放进输入框正文（多文件带文件名区分、超长自动截断）；
  - 系统截图（`Cmd+Shift+Ctrl+4`）：剪贴板里的 TIFF 会自动转成 PNG 再发送——**不会再出现“图片发不出去”**；
  - 网页复制 / 微信等工具截取的图片同样支持（统一转码为模型可识别的 PNG/JPEG）。
- **Markdown / GitHub 风格渲染**：表格、代码高亮、任务列表等。
- **LaTeX 数学公式**：`$...$` / `$$...$$` 原生排版（SwiftMath + 随包数学字体）。
- **流式回复**：打字机式输出，可随时停止。
- **会话管理**：多会话侧边栏、全文搜索、消息复制 / 重试 / 删除 / 导出。
- **Agent 模式**：内置工具调用（function calling），模型可中途调用工具并追加结果。
- **记忆与个性化**：从历史会话一键生成「个性化块 / 知识库」，可增删记忆。
- **数据与导出**：PDF 导出对话、会话备份 / 恢复、Token 用量与缓存统计。
- **个性化外观**：多套主题、导入自定义字体、界面语言切换。

---

## 🖥 系统要求

- macOS **14.0+**
- Apple Silicon（arm64）或 Intel（x86_64）芯片
- 仅需安装 Xcode Command Line Tools（用 `swift build` 编译），**不需要 Xcode 工程**

---

## 📦 安装（直接使用）

打开项目 `dist/` 目录（或发布页）下载对应 DMG：

| 文件 | 适用 |
| --- | --- |
| `AIChatApp-1.0.3-arm64.dmg` | Apple Silicon Mac（M1/M2/M3/M4/M5…） |
| `AIChatApp-1.0.3-x86_64.dmg` | Intel Mac |

双击挂载后把 `AIChatApp.app` 拖进「应用程序」即可。

## 🔧 从源码构建

依赖已全部放于 `Vendor/`，**构建过程完全离线**，不依赖 GitHub 网络抓取。

```bash
# 1) arm64（Apple Silicon）release + DMG
./build_arm64.sh

# 2) x86_64（Intel）release + DMG
ARCH=x86_64 ./build_arm64.sh

# 3) 同一台机器混编两种架构（推荐给 x86_64 独立缓存，避免冲突）
SWIFT_SCRATCH=.build-x86 ARCH=x86_64 ./build_arm64.sh
```

产物：
- `.stage/AIChatApp.app` —— 可直接运行的 .app
- `dist/AIChatApp-1.0.3-<arch>.dmg` —— 安装包

> 注：构建脚本会优先使用 `~/aichat-sdk/MacOSX.sdk`（仅当系统 SDK 缺失 `CarbonCore/MacErrors.h` 的少数环境需要该修复层）；正常的 macOS 上会自动回退系统 SDK，无需任何额外操作。

## 🚀 快速上手

1. 启动应用，进入「设置」填写 API `Base URL`、`API Key` 与模型名（支持任何兼容服务）。
2. 左侧「新建会话」，输入问题发送（`Enter` 发送，`Shift+Enter` 换行）。
3. 添加图片：拖拽 / 点 🖼 按钮 / 截图后 `Cmd+V`。
4. 添加 PDF：拖拽 / 点 📄 按钮 / Finder 复制后 `Cmd+V`，发送前可选「图片 / 文字 / 都发」。
5. 粘贴文本文件：Finder 里 `Cmd+C` 复制 `txt/md/csv/json…`，回到输入框 `Cmd+V`，内容直接进入正文。

---

## 🧩 常见问题

### 旧版本启动就闪退 / 退出
旧版打包产物缺少 `SwiftMath_SwiftMath.bundle`（数学字体资源），渲染含公式内容时触发 `NSBundle.module` 断言崩溃。请使用本仓库（arm64 适配）重新构建或直接下载新 DMG——打包流程已把该 bundle 放进 `Contents/Resources`。

### 截图粘贴后模型看不到图
macOS 系统截图进剪贴板是 **TIFF** 格式，多数视觉接口不接受 `image/tiff`。本版本在粘贴时自动把 TIFF 转成 PNG；发送前还有一层兜底转码，历史遗留的 TIFF 图片也能正常发出。

### 依赖拉取失败 / 构建需要联网
不需要。所有依赖（swift-markdown-ui、SwiftMath、NetworkImage、swift-cmark）都已 vendored 到 `Vendor/`。

## 📁 目录结构

```
Sources/AIChatApp/
├── App/                 # 入口
├── Models/              # 会话、消息、附件、多模态模型识别等
├── Services/            # 网络请求、PDF 处理、存储、工具调用等
├── ViewModels/          # 会话/设置视图模型
├── Views/               # SwiftUI 界面（聊天、侧栏、设置、数学渲染…）
└── Localization/        # 中英文界面字符串
Vendor/                  # 本地依赖（离线）
Assets/                  # 图标等资源
build_arm64.sh           # 一键构建脚本（arm64 / x86_64 可切换）
scripts/                 # 打包辅助脚本
```

## 📚 技术栈与依赖

| 依赖 | 用途 | 版本 |
| --- | --- | --- |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | GFM Markdown / 表格渲染 | 2.4.1 |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | LaTeX 数学公式原生排版 | 1.7.3 |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | 异步网络图片 | 6.0.1 |
| [swift-cmark](https://github.com/commonmark/cmark) | CommonMark 解析底层 | 0.8.0 |

> 上游为可复现离线构建已将以上包固定版本放在 `Vendor/`，无需联网解析。

---

*README 随本仓库的 arm64 适配改动一起维护；合并到上游 `winstonhuangHZ/AI_Chatting_app` 的 `main` 后，此文档即为该项目主页说明。*

