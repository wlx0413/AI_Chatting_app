import SwiftUI
import UniformTypeIdentifiers

/// Main chat pane: top configuration bar, scrollable message list,
/// streaming indicator, and multi-line input bar with image attachments.
///
/// Modern macOS 14+ SwiftUI API:
/// - `TextEditor` + `.onSubmit` for Enter-to-send / Shift+Enter-newline
/// - `ScrollViewReader` for smooth autoscroll during streaming
/// - `ProgressView`, `Label`, `overlay(alignment:)`, `foregroundStyle`
struct ChatView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    /// 全局外观（字体预设 / 字号 / 主题）。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    /// 拖拽上传中转桥（消息列表区 drop → 输入栏待发送附件）。
    @StateObject private var dropRouter = ChatDropRouter()

    /// 拖拽文件悬停在聊天面板上时高亮。
    @State private var isDropTargeted = false

    /// 「生成个性化块」弹窗状态。
    @State private var showGenerateBlock = false

    /// 生成时用户输入的知识块名字。
    @State private var blockName = ""

    // MARK: - Body

    /// 个性化块采集会话顶部操作栏：提示 + 「生成个性化块」。
    private var personalizationBar: some View {
        HStack(spacing: 8) {
            Label(L("kb.collecting"), systemImage: "brain")
                .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                blockName = chatViewModel.activeSession?.title ?? ""
                showGenerateBlock = true
            } label: {
                if chatViewModel.isGeneratingBlock {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("kb.generating"))
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                } else {
                    Label(L("kb.generate"), systemImage: "square.and.arrow.down.on.square")
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(appearance.accentColor)
            .controlSize(.small)
            .disabled(chatViewModel.activeSession?.messages.isEmpty == true || chatViewModel.isGeneratingBlock)
            .help(L("kb.generate.help"))
            .animation(.easeInOut(duration: 0.2), value: chatViewModel.isGeneratingBlock)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// 从拖放提供的 NSItemProvider 异步读取文件 URL。Finder 拖出的文件以
    /// `public.file-url` 提供，需处理 item 为 URL / NSURL / Data(URL 字符串) 三种形态。
    private static func loadDroppedFileURLs(
        _ providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) {
        guard !providers.isEmpty else { completion([]); return }
        var urls: [URL] = []
        let lock = NSLock()
        var remaining = providers.count
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                lock.lock()
                if let url = item as? URL {
                    urls.append(url)
                } else if let nsurl = item as? NSURL {
                    urls.append(nsurl as URL)
                } else if let data = item as? Data,
                          let s = String(data: data, encoding: .utf8),
                          let url = URL(string: s) {
                    urls.append(url)
                }
                remaining -= 1
                let done = remaining == 0
                lock.unlock()
                if done { completion(urls) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()

            Divider()

            if let session = chatViewModel.activeSession {
                MessageList(
                    session: session,
                    streamingMessageID: chatViewModel.streamingAssistantID,
                    hasReceivedFirstToken: chatViewModel.hasReceivedFirstToken,
                    highlightMessageID: chatViewModel.highlightMessageID
                )
            } else {
                ContentUnavailableView(
                    L("no.chat.selected"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(L("no.chat.description"))
                )
            }

            Divider()

            // 个性化块采集会话：顶部提示 + 「生成个性化块」按钮。
            if chatViewModel.activeSession?.isPersonalizationCollection == true {
                personalizationBar
                Divider()
            }

            // Live token counter + cost estimate for the *next* request —
            // includes history + system prompt + user profile (all re-sent).
            UsageBarView(
                messages: chatViewModel.activeMessages,
                model: configStore.activeConfig?.selectedModel ?? "",
                dynamicPrices: configStore.activeConfig?.modelPrices ?? [:],
                systemPrompt: configStore.activeConfig?.systemPrompt ?? "",
                profileJSON: chatViewModel.userProfileStore.jsonPayload,
                customPrice: configStore.activeConfig?.customPrice,
                cacheUsage: chatViewModel.lastCacheUsage
            )

            InputBarView(
                onSend: { text, attachments, documents in
                    chatViewModel.sendMessage(
                        text,
                        config: configStore.activeConfig,
                        model: configStore.activeConfig?.selectedModel ?? "",
                        attachments: attachments,
                        documents: documents
                    )
                },
                isStreaming: chatViewModel.isStreaming,
                dropRouter: dropRouter
            )
            // 「生成个性化块」：输入名字后把采集会话整理成命名个性化块。
            .alert(L("kb.generate"), isPresented: $showGenerateBlock) {
                TextField(L("kb.name"), text: $blockName)
                Button(L("kb.generate.action")) {
                    if let session = chatViewModel.activeSession {
                        chatViewModel.generatePersonalizationBlock(from: session, name: blockName)
                    }
                }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(L("kb.generate.message"))
            }
        }
        .background(appearance.chatBackground)
        // 拖拽上传：整个聊天面板都是 drop 目标，转发给输入栏挂载的 handler。
        // 用 `onDrop(of: [.fileURL])` 而非 `dropDestination(for: URL.self)`：后者对
        // Finder 拖出的文件（public.file-url）支持不稳，经常收不到文件 URL。
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: { (providers: [NSItemProvider]) -> Bool in
                Self.loadDroppedFileURLs(providers) { urls in
                    if !urls.isEmpty {
                        DispatchQueue.main.async { dropRouter.onDrop?(urls) }
                    }
                }
                return true
            }
        )
        // 拖拽悬停提示：虚线框 + 「松手附加」胶囊。
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(appearance.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .overlay {
                        Text(L("attach.drop.hint"))
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(appearance.accentColor.opacity(0.18))
                            .clipShape(Capsule())
                    }
            }
        }
        // Memory-change toast (auto-dismisses after 4s).
        .overlay(alignment: .bottom) {
            if let notice = chatViewModel.memoryNotice {
                MemoryNoticeBanner(notice: notice) {
                    chatViewModel.memoryNotice = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.bottom, 92)
                .id(notice.id)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if chatViewModel.memoryNotice?.id == notice.id {
                        chatViewModel.memoryNotice = nil
                    }
                }
            }
        }
        // Cache-reset toast: shown when the shared profile changed or a message
        // was deleted/regenerated since the last request (both change the
        // byte-identical prefix, so the history cache is reset).
        .overlay(alignment: .bottom) {
            if let notice = chatViewModel.cacheResetNotice {
                CacheResetBanner(reason: notice.reason) {
                    chatViewModel.cacheResetNotice = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.bottom, 128)
                .id(notice.id)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if chatViewModel.cacheResetNotice?.id == notice.id {
                        chatViewModel.cacheResetNotice = nil
                    }
                }
            }
        }
        .animation(.default, value: chatViewModel.memoryNotice)
        .animation(.default, value: chatViewModel.cacheResetNotice)
        // Error banner.
        .overlay(alignment: .top) {
            if let error = chatViewModel.errorMessage {
                ErrorBannerView(message: error) {
                    chatViewModel.clearError()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .id(chatViewModel.errorDismissToken)
            }
        }
        .animation(.default, value: chatViewModel.errorMessage)
    }
}

// MARK: - Memory-change toast

/// Small transient toast shown when the AI added/updated/removed memories.
private struct MemoryNoticeBanner: View {

    /// The memory-change event to display.
    let notice: MemoryNotice

    /// Dismiss action.
    let onDismiss: () -> Void

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var message: String {
        var parts: [String] = []
        if notice.addedCount > 0 {
            parts.append(addedText(notice.addedCount))
        }
        if notice.removedCount > 0 {
            parts.append(removedText(notice.removedCount))
        }
        return parts.joined(separator: " · ")
    }

    private func addedText(_ n: Int) -> String {
        // "Memory added/updated (n)"
        L("memory.added") + " (\(n))"
    }

    private func removedText(_ n: Int) -> String {
        L("memory.removed") + " (\(n))"
    }
}

/// Small transient toast shown when the byte-identical cache prefix changed
/// (shared profile updated, or a message deleted/regenerated), resetting the
/// relay's cache for the affected history.
private struct CacheResetBanner: View {

    /// Why the cache was reset (drives the icon + text).
    let reason: CacheResetNotice.Reason

    /// Dismiss action.
    let onDismiss: () -> Void

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reason == .historyEdited ? "trash" : "arrow.clockwise")
                .foregroundStyle(.tint)
            Text(L(reason == .historyEdited ? "cache.reset.history" : "cache.reset.profile"))
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}



// MARK: - Top configuration bar

/// Horizontal bar with profile + model pickers and streaming controls.
private struct TopBarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var configStore: ConfigStore

    /// 全局外观（字体预设 / 字号）。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Profile picker
            Picker(L("profile"), selection: $configStore.activeConfigID) {
                ForEach(configStore.configs) { config in
                    Text(config.displayName)
                        .tag(Optional(config.id))
                }
                if configStore.configs.isEmpty {
                    Text(L("no.configs.tag"))
                        .tag(Optional<UUID>.none)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .tint(appearance.accentColor)

            // Model picker (populated from the active profile).
            // Multimodal (vision) models get a subtle photo icon on the right.
            if let activeConfig = configStore.activeConfig {
                Picker(L("model"), selection: modelPickerBinding(for: activeConfig)) {
                    if activeConfig.availableModels.isEmpty {
                        Text(L("model.empty.tag")).tag("")
                    }
                    ForEach(activeConfig.availableModels, id: \.self) { model in
                        HStack(spacing: 4) {
                            Text(model)
                            if MultimodalSupport.isMultimodal(model) {
                                Image(systemName: "photo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 200)
                .tint(appearance.accentColor)
            }

            Spacer()

            // Agent mode toggle (built-in tool calling: web search / calc /
            // time). Off by default so normal chats keep the plain `tools`-free
            // request body (prompt-cache friendly, relay-safe).
            if configStore.activeConfig != nil {
                Toggle(L("agent.mode"), isOn: agentModeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                    .tint(appearance.accentColor)
                    .help(L("agent.mode.help"))
            }

            // Generation controls
            if chatViewModel.isStreaming {
                ProgressView().controlSize(.small)
                Button {
                    chatViewModel.cancelStreaming()
                } label: {
                    Label(L("stop"), systemImage: "stop.fill")
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    chatViewModel.createNewChat()
                } label: {
                    Label(L("new.chat"), systemImage: "square.and.pencil")
                        .font(appearance.fontPreset.font(size: appearance.pointSize))
                }
                .buttonStyle(.bordered)
                .tint(appearance.accentColor)
                .help(L("new.chat.help"))
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help(L("settings.open.help"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    /// Writes model selections straight through to the stored profile.
    private func modelPickerBinding(for config: APIServerConfig) -> Binding<String> {
        Binding(
            get: {
                configStore.configs.first(where: { $0.id == config.id })?.selectedModel ?? ""
            },
            set: { newModel in
                guard let index = configStore.configs.firstIndex(where: { $0.id == config.id }) else { return }
                configStore.configs[index].selectedModel = newModel
            }
        )
    }

    /// Agent mode toggle reads/writes the active profile's `toolsEnabled`.
    private var agentModeBinding: Binding<Bool> {
        Binding(
            get: { configStore.activeConfig?.toolsEnabled ?? false },
            set: { newValue in
                guard let id = configStore.activeConfigID,
                      let index = configStore.configs.firstIndex(where: { $0.id == id }) else { return }
                configStore.configs[index].toolsEnabled = newValue
            }
        )
    }
}

// MARK: - Message list

/// 消息列表底部哨兵的位置（滚动坐标系内 maxY）：内容底边到视口顶部的距离。
private struct MessageListBottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 消息列表滚动视口高度。
private struct MessageListViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Scrollable list of messages with smooth autocroll during streaming.
private struct MessageList: View {

    /// Session being displayed.
    let session: ChatSession

    /// The id of the assistant message currently being streamed.
    let streamingMessageID: UUID?

    /// `true` once streaming has yielded content (drives two-stage indicator).
    let hasReceivedFirstToken: Bool

    /// Message id to scroll to + highlight (jump from the sidebar search).
    let highlightMessageID: UUID?

    /// 底部哨兵在滚动坐标系中的 maxY（内容底边到视口顶部的距离）。
    @State private var bottomEdgeY: CGFloat = .infinity

    /// 聊天滚动视口高度。
    @State private var viewportHeight: CGFloat = 0

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 外层 VStack：底部哨兵必须放在 LazyVStack **之外** —— 实测
                // LazyVStack 内任何额外子项都会在滚动时被惰性卸载/重挂载，
                // 干扰 defaultScrollAnchor 的定位（上翻会停在中途、卡住）。
                VStack(spacing: 0) {
                    // LazyVStack：只实体化视口附近的消息——真实对话里每条都是
                    // 重型 MarkdownUI 表格/标题/列表，VStack 会让全部消息每 tick
                    // 重渲染（实测 30 条 ≈ 21ms/tick vs LazyVStack ≈ 2ms/tick）。
                    LazyVStack(spacing: 14) {
                        ForEach(session.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: message.id == streamingMessageID,
                                hasReceivedFirstToken: hasReceivedFirstToken,
                                isHighlighted: message.id == highlightMessageID
                            )
                            .id(message.id)
                        }
                    }
                    .padding(16)
                    // 底部哨兵：精确测量内容底边位置，用于“发送时保持阅读位置”。
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MessageListBottomEdgeKey.self,
                            value: geo.frame(in: .named("chatScroll")).maxY
                        )
                    }
                    .frame(height: 0)
                }
            }
            .coordinateSpace(name: "chatScroll")
            // 滚动正确性交给 .defaultScrollAnchor(.bottom)：
            //   - 首次/切会话 → 初始落在底部
            //   - 流式长高 → 视口跟随真实内容底部
            //   - 用户上翻阅读 → 尊重阅读位置，绝不拽回底部
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: MessageListViewportHeightKey.self,
                        value: geo.size.height
                    )
                }
            }
            .onPreferenceChange(MessageListBottomEdgeKey.self) { bottomEdgeY = $0 }
            .onPreferenceChange(MessageListViewportHeightKey.self) { viewportHeight = $0 }
            .onChange(of: session.messages.last?.id) { oldID, _ in
                // 发送新消息时“保持阅读位置，绝不拽走”：
                // append 后 anchor 会把视口拽到新底部；若底部哨兵显示视口
                // 确实在底部（发送前用户就停在底部），就把视口钉回发送前的
                // 最后一条消息（oldID），精确还原阅读位置。上翻时 anchor 不
                // 拽 → 哨兵不在底部 → 什么都不做，视口纹丝不动。
                if let oldID,
                   bottomEdgeY <= viewportHeight + 4,
                   session.messages.contains(where: { $0.id == oldID }) {
                    proxy.scrollTo(oldID, anchor: .bottom)
                }
            }
            // 侧栏搜索跳转：居中 + 高亮（用户主动操作，允许动画）。
            .onChange(of: highlightMessageID) { _, newID in
                if let newID {
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Message bubble

/// Renders a single chat message as a bubble with role-appropriate styling
/// and inline image previews for attachments.
///
/// Overlap fix: `.fixedSize(horizontal: false, vertical: true)` on the outer
/// container prevents LazyVStack from collapsing a bubble's width/height
/// while Markdown is re-rendering during streaming — the previous cause of
/// overlapping (a new message appearing on top of an older one).
private struct MessageBubble: View {

    /// Message to display.
    let message: ChatMessage

    /// `true` while this assistant message is being streamed.
    let isStreaming: Bool

    /// `true` once streaming has yielded the first content token.
    let hasReceivedFirstToken: Bool

    /// `true` when this message is the sidebar-search highlight target.
    let isHighlighted: Bool

    /// `true` while the generation-metadata popover is open.
    @State private var showDetail = false

    /// `true` while the DeepSeek "thinking" section is expanded.
    @State private var showReasoning = false

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatar
            }

            // 列内对齐跟随角色：assistant 靠左（头像在左），user 靠右（头像在右）。
            // 元信息行（You + 时间）与图片/文档附件也随之对齐，不再漂到最左边。
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                    // Per-message send/receive time: persisted with the message
                    // (JSON `timestamp`) but never sent to the API, so prompt
                    // caching is unaffected.
                    Text(message.timestamp.formatted(date: .numeric, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(message.timestamp.formatted(date: .complete, time: .standard))

                    if message.role == .assistant {
                        Button {
                            showDetail.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help(L("detail.help"))
                        .popover(isPresented: $showDetail) {
                            MessageDetailView(message: message)
                        }
                    }
                }

                // Image attachments preview (user messages).
                if !message.attachments.isEmpty {
                    attachmentGrid
                }

                // Document (PDF) attachments preview (user messages).
                if !message.documentAttachments.isEmpty {
                    documentGrid
                }

                // Collapsed "thinking" section (DeepSeek reasoning models).
                if message.role == .assistant,
                   let reasoning = message.reasoningContent,
                   !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reasoningSection(reasoning)
                }

                if !contentDisplay.isEmpty {
                    if message.role == .assistant {
                        MarkdownText(text: message.content, fontSize: nil)
                            // Inner: let the markdown breathe to the full row.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            // Outer cap so long tables don't stretch the app.
                            .frame(maxWidth: 620,
                                   alignment: message.role == .user ? .trailing : .leading)
                            // Never compress bubble height while streaming.
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(contentDisplay)
                            .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                            .foregroundStyle(appearance.userBubbleTextColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: 620,
                                   alignment: message.role == .user ? .trailing : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        // Before the first token: "Waiting for response…";
                        // once tokens flow: "Generating…". Both render modes
                        // (streaming & non-streaming render) use SSE transport,
                        // so this two-stage indicator applies to both.
                        Text(L(hasReceivedFirstToken ? "generating" : "generating.waiting"))
                            .appearanceFont(appearance.fontPreset, size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                // Sources card below AI replies (Agent mode web references).
                if message.role == .assistant && !isStreaming && !message.sources.isEmpty {
                    sourcesCard
                        .padding(.top, 2)
                }

                // Quick actions below AI messages: Retry / Copy / Delete.
                if message.role == .assistant && !isStreaming {
                    messageActionBar
                }
            }

            if message.role == .user {
                avatar
            }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        // KEY FIX: prevent the whole bubble from being squeezed into a
        // zero-height row by LazyVStack while its Markdown re-lays out.
        .fixedSize(horizontal: false, vertical: true)
        // Search-result highlight (from the sidebar full-text search).
        .padding(3)
        .background(isHighlighted ? appearance.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        // Right-click actions: copy / delete.
        .contextMenu {
            Button {
                chatViewModel.copyMessage(message)
            } label: {
                Label(L("msg.copy"), systemImage: "doc.on.doc")
            }
            .disabled(message.content.isEmpty)

            Divider()

            Button(role: .destructive) {
                chatViewModel.deleteMessage(message)
            } label: {
                Label(L("msg.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Sources card

    /// "📎 来源" card listing the web references collected from web_search /
    /// web_fetch during the tool loop. Clickable links open in the browser.
    @ViewBuilder
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("sources.title"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(message.sources) { source in
                Link(destination: Self.sourceURL(source.url)) {
                    HStack(spacing: 6) {
                        Image(systemName: source.url.hasPrefix("file://") ? "doc" : "link")
                            .font(.system(size: 10))
                            .foregroundStyle(appearance.accentColor)
                        Text(source.title.isEmpty ? source.url : source.title)
                            .font(.system(size: 11))
                            .foregroundStyle(appearance.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .help(source.url)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .frame(maxWidth: 620, alignment: .leading)
    }

    private static func sourceURL(_ string: String) -> URL {
        // Produced files come through as file:// URLs (compile_latex etc.).
        if string.hasPrefix("file://") {
            return URL(string: string) ?? URL(string: "https://")!
        }
        return URL(string: string) ?? URL(string: "https://")!
    }

    // MARK: - Quick action bar (below assistant messages)

    @ViewBuilder
    private var messageActionBar: some View {
        HStack(spacing: 8) {
            actionButton(
                title: L("msg.retry"),
                systemImage: "arrow.clockwise",
                help: L("msg.retry")
            ) {
                chatViewModel.retryMessage(message)
            }

            actionButton(
                title: L("msg.copy"),
                systemImage: "doc.on.doc",
                help: L("msg.copy")
            ) {
                chatViewModel.copyMessage(message)
            }
            .disabled(message.content.isEmpty)

            actionButton(
                title: L("msg.delete"),
                systemImage: "trash",
                help: L("msg.delete")
            ) {
                chatViewModel.deleteMessage(message)
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(appearance.fontPreset.font(size: 10))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Attachment grid

    private var attachmentGrid: some View {
        HStack(spacing: 6) {
            ForEach(message.attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Document (PDF) attachments: file icon + name + page count.
    private var documentGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(message.documentAttachments) { document in
                HStack(spacing: 6) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.filename)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            if document.pageCount > 0 {
                                Text(L("pdf.pages", document.pageCount))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            // 发送方式徽标（PNG / 文字 / 都发）。
                            Text(document.sendMode.badgeText)
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(document.sendMode.badgeColor.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // 用户消息靠右：限宽避免文档卡片横贯整行、与右对齐的气泡脱节。
        .frame(maxWidth: 380, alignment: .trailing)
    }

    // MARK: - Reasoning ("thinking") section

    /// Collapsible view of a reasoning model's thinking text.
    ///
    /// The text is persisted on the message (and passed back to the API on tool
    /// rounds, which DeepSeek requires) — this just surfaces it, collapsed by
    /// default so it never competes with the answer.
    @ViewBuilder
    private func reasoningSection(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    showReasoning.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("💭 \(L("reasoning.title"))")
                        .font(.caption)
                    Text(L("reasoning.chars", reasoning.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("reasoning.help"))

            if showReasoning {
                Text(reasoning)
                    .appearanceFont(appearance.fontPreset, size: max(appearance.pointSize - 1.5, 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.07))
                    )
                    .overlay(alignment: .leading) {
                        // Left rule marks it as "meta" content, not the answer.
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(appearance.accentColor.opacity(0.45))
                            .frame(width: 3)
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 2)
    }


    // MARK: - Derived

    private var roleLabel: String {
        switch message.role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return appearance.userBubbleColor
        case .assistant:
            return appearance.assistantBubbleColor
        case .system:
            return Color(nsColor: .selectedControlColor).opacity(0.4)
        }
    }

    private var contentDisplay: String {
        // Non-streaming render mode: bubble content stays empty while streaming
        // (full reply written once at the end), so no "…" placeholder needed.
        // Streaming render mode fills content progressively (throttled), so the
        // "…" fallback only applies when there is genuinely no content yet.
        message.content.isEmpty && isStreaming ? "" : message.content
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
            .font(.title3)
            .foregroundStyle(message.role == .user ? appearance.accentColor : .purple)
            .frame(width: 28, height: 28)
    }
}

// MARK: - Message detail popover

/// Generation metadata for an assistant reply: model, exact send/receive time,
/// relay-reported token usage and the tool-call flow (Agent mode / get_time).
///
/// All data comes from fields persisted on the message itself — none of it is
/// ever serialized into the API payload, so prompt caching is unaffected.
private struct MessageDetailView: View {
    let message: ChatMessage

    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("detail.title"), systemImage: "info.circle")
                .font(.headline)

            detailRow(L("detail.role"), roleLabel)
            detailRow(L("detail.time"),
                      message.timestamp.formatted(date: .complete, time: .standard))

            if let model = message.model, !model.isEmpty {
                detailRow(L("detail.model"), model)
            }

            if let usage = message.usage {
                Divider()
                Label(L("detail.tokens"), systemImage: "number")
                    .font(.subheadline.weight(.semibold))
                if let p = usage.promptTokens {
                    detailRow(L("detail.tokens.input"), TokenUsage.formatCount(p))
                }
                if let c = usage.completionTokens {
                    detailRow(L("detail.tokens.output"), TokenUsage.formatCount(c))
                }
                if let hit = usage.cacheHitTokens, let miss = usage.cacheMissTokens {
                    let total = hit + miss
                    let ratio = total > 0 ? String(format: "%.0f%%", Double(hit) / Double(total) * 100) : "–"
                    detailRow(L("detail.tokens.cache"),
                              "\(TokenUsage.formatCount(hit)) / \(TokenUsage.formatCount(miss))  (\(ratio))")
                }
            }

            if !message.toolFlow.isEmpty {
                Divider()
                Label(L("detail.tools"), systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(message.toolFlow.enumerated()), id: \.offset) { index, record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(record.name)")
                            .font(.caption.weight(.semibold))
                        if !record.arguments.isEmpty {
                            Text(record.arguments)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if !record.resultPreview.isEmpty {
                            Text(record.resultPreview)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if message.model == nil && message.usage == nil && message.toolFlow.isEmpty {
                Text(L("detail.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Attachment thumbnail


// MARK: - Attachment thumbnail

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment

    var body: some View {
        if let data = attachment.decodedData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 180, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
        } else {
            Text("🖼 \(attachment.filename)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Usage bar

/// Bottom status bar: live token counts + cost estimate.
private struct UsageBarView: View {
    let messages: [ChatMessage]
    let model: String
    let dynamicPrices: [String: ModelPrice]
    let systemPrompt: String
    let profileJSON: String?
    let customPrice: CustomPrice?

    /// Relay-reported cache hit/miss for the last completed request.
    let cacheUsage: StreamUsage?

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    private var summary: (input: Int, output: Int, freshInput: Int) {
        TokenUsage.summarize(messages, systemPrompt: systemPrompt, profileJSON: profileJSON)
    }

    /// `true` when the relay returned a real `usage` for the last request.
    private var hasRealUsage: Bool {
        cacheUsage?.promptTokens != nil && cacheUsage?.completionTokens != nil
    }

    /// Tokens shown in the bar: the relay-reported REAL usage when available,
    /// otherwise the local estimate for the next request.
    private var displayInput: Int {
        hasRealUsage ? (cacheUsage?.promptTokens ?? 0) : summary.input
    }

    private var displayOutput: Int {
        hasRealUsage ? (cacheUsage?.completionTokens ?? 0) : summary.output
    }

    private var costEstimate: TokenUsage.CostEstimate? {
        TokenUsage.estimatedCost(
            model: model,
            inputTokens: displayInput,
            outputTokens: displayOutput,
            freshTokens: summary.freshInput,
            dynamicPrices: dynamicPrices,
            customPrice: customPrice
        )
    }

    private var priceUnknown: Bool {
        !model.isEmpty
            && TokenUsage.pricing(
                for: model,
                dynamicPrices: dynamicPrices,
                customPrice: customPrice
            ) == nil
    }

    private var usingCustomPrice: Bool {
        customPrice?.isValid == true
    }

    private var usingDynamicPrice: Bool {
        guard let price = dynamicPrices[model] else { return false }
        return price.isValid
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(L("usage.tokens",
                   TokenUsage.formatCount(displayInput),
                   TokenUsage.formatCount(displayOutput)))
                .font(.caption).foregroundStyle(.secondary)
                .help(L(hasRealUsage ? "usage.tokens.real" : "usage.tokens.estimate"))

            if let estimate = costEstimate {
                Text("≈ \(TokenUsage.formatCost(estimate.full))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L("usage.cost.full"))
                // Realistic estimate: the repeatedly re-sent context (history
                // prefix) hits the cache at the cached-input rate; only the
                // newest user message is billed at the full input rate.
                if let blended = estimate.blended, blended < estimate.full {
                    Text(L("usage.cost.cached", TokenUsage.formatCost(blended)))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L("usage.cost.cached.help"))
                } else if let cached = estimate.cached, cached < estimate.full {
                    Text(L("usage.cost.cached", TokenUsage.formatCost(cached)))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L("usage.cost.cached.help"))
                }
            }

            if priceUnknown {
                Text(L("price.unknown"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if usingCustomPrice {
                Text(L("custom.price.badge"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if usingDynamicPrice {
                Text(L("relay.price"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Relay-reported prefix-cache hit rate for the last request
            // (DeepSeek `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`).
            if let usage = cacheUsage, let ratio = usage.cacheHitRatio {
                Text(L("usage.cache.hit", Int((ratio * 100).rounded())))
                    .font(.caption)
                    .foregroundStyle(ratio >= 0.5 ? Color.secondary : Color.orange)
                    .help(L("usage.cache.detail", usage.cacheHitTokens ?? 0, usage.cacheMissTokens ?? 0))
            }

            if !messages.isEmpty {
                Text(L("msg.count", messages.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 拖拽文件的中转桥：把整个聊天面板（消息列表区）收到的文件 drop 转发给
/// 输入栏的待发送附件状态。输入栏出现时注册自己的 handler，消失时清空。
private final class ChatDropRouter: ObservableObject {
    /// 当前输入栏注册的 drop 处理器（nil = 无输入栏）。
    var onDrop: (([URL]) -> Void)?
}

// MARK: - Input bar

/// Multi-line input with image attachments:
/// - `TextEditor`: Enter sends, Shift+Enter inserts a newline (native).
/// - 🖼 button opens NSOpenPanel to attach images.
/// - Thumbnail previews can be removed before sending.
private struct InputBarView: View {

    let onSend: (String, [ImageAttachment], [DocumentAttachment]) -> Void
    let isStreaming: Bool

    /// 拖拽上传中转桥（父级聊天面板的 drop 转发到这里）。
    let dropRouter: ChatDropRouter

    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draft = ""
    @State private var pendingAttachments: [ImageAttachment] = []
    @State private var pendingDocuments: [DocumentAttachment] = []

    /// 支持直接拖入的图片扩展名（与上传按钮一致）。
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Attachment preview row (images + PDFs).
            if !pendingAttachments.isEmpty || !pendingDocuments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { attachment in
                        PendingAttachmentChip(attachment: attachment) {
                            removeAttachment(attachment)
                        }
                    }
                    ForEach(pendingDocuments) { document in
                        PendingDocumentChip(
                            document: document,
                            onRemove: { removeDocument(document) },
                            onSetMode: { mode in setDocumentMode(document, mode) }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    pickImages()
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 14))
                        // 固定框 + 居中：不同 SF Symbol 自带高度基准不同，
                        // 不套框时两个按钮视觉上会上下错位。
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L("attach.image"))

                Button {
                    pickPDFs()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L("attach.pdf"))

                // 输入框：NSTextView 包装，支持 Cmd+V 粘贴剪贴板图片、
                // 拖拽文件到输入框，Enter 发送 / Shift+Enter 换行。
                PasteImageEditor(
                    text: $draft,
                    font: appearance.fontPreset.nsFont(size: appearance.pointSize),
                    onPasteImage: { data, mime in addPastedImage(data, mime: mime) },
                    onDroppedFiles: { urls in handleDropped(urls) },
                    onEnter: { onSubmit() }
                )
                .frame(minHeight: 40, maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

                Button {
                    onSubmit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(isSendDisabled ? Color.gray : appearance.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(isSendDisabled)
                .help(L("send"))
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        // 挂载拖拽处理器：整个聊天面板的 drop 通过 router 到这里。
        .onAppear {
            dropRouter.onDrop = { urls in
                handleDropped(urls)
            }
        }
        .onDisappear {
            if dropRouter.onDrop != nil {
                dropRouter.onDrop = nil
            }
        }
    }

    private var isSendDisabled: Bool {
        let textEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isStreaming || (textEmpty && pendingAttachments.isEmpty && pendingDocuments.isEmpty)
    }

    private func onSubmit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false || !pendingAttachments.isEmpty || !pendingDocuments.isEmpty else { return }
        guard !isStreaming else { return }

        let attachments = pendingAttachments
        let documents = pendingDocuments
        draft = ""
        pendingAttachments = []
        pendingDocuments = []
        onSend(text, attachments, documents)
    }

    private func removeAttachment(_ attachment: ImageAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    private func removeDocument(_ document: DocumentAttachment) {
        pendingDocuments.removeAll { $0.id == document.id }
    }

    /// 修改某个待发送 PDF 的发送方式（图片 / 文字 / 都发）。
    private func setDocumentMode(_ document: DocumentAttachment, _ mode: PDFSendMode) {
        guard let index = pendingDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        pendingDocuments[index].sendMode = mode
    }

    // MARK: - 附件添加（按钮选择与拖拽共用）

    /// 拖入的文件统一入口：图片/PDF 分别进入待发送列表，其余忽略。
    private func handleDropped(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                addImage(from: url)
            } else if ext == "pdf" {
                addPDF(from: url)
            }
        }
    }

    /// 剪贴板粘贴的图片进入待发送列表（与按钮/拖拽同一条 10MB 上限）。
    private func addPastedImage(_ data: Data, mime: String) {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { return } // cap 10MB
        let ext = mime == "image/png" ? "png" : "tif"
        pendingAttachments.append(
            ImageAttachment(
                filename: "Pasted Image.\(ext)",
                mimeType: mime,
                base64Data: data.base64EncodedString()
            )
        )
    }

    private func addImage(from url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        guard data.count <= 10 * 1024 * 1024 else { return } // cap 10MB
        let mime = Self.mimeType(for: url.pathExtension)
        pendingAttachments.append(
            ImageAttachment(
                filename: url.lastPathComponent,
                mimeType: mime,
                base64Data: data.base64EncodedString()
            )
        )
    }

    private func addPDF(from url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        // PDFs get a larger cap than images (documents are heavier).
        guard data.count <= 30 * 1024 * 1024 else { return } // cap 30MB
        let pages = PDFProcessor.pageCount(from: data)
        guard pages > 0 else { return } // invalid / non-PDF
        pendingDocuments.append(
            DocumentAttachment(
                filename: url.lastPathComponent,
                mimeType: "application/pdf",
                base64Data: data.base64EncodedString(),
                pageCount: pages
            )
        )
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = L("attach.image")
        panel.prompt = L("attach.image")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Modern macOS 12+ API: build UTTypes from extensions (avoids the
        // deprecated `allowedFileTypes`).
        panel.allowedContentTypes = Self.imageExtensions
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addImage(from: url)
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "bmp":  return "image/bmp"
        case "tiff": return "image/tiff"
        default:     return "image/png"
        }
    }

    private func pickPDFs() {
        let panel = NSOpenPanel()
        panel.title = L("attach.pdf")
        panel.prompt = L("attach.pdf")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pdf")]
            .compactMap { $0 }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addPDF(from: url)
        }
    }
}

// MARK: - 粘贴图片 / 拖拽文件编辑器

/// `NSTextView` 包装的输入编辑器：在保留 Enter 发送 / Shift+Enter 换行的
/// 基础上，支持 Cmd+V 粘贴剪贴板图片（png/tiff/Finder 图片文件）为附件，
/// 以及把文件直接拖进输入框（走同一套 handleDropped 逻辑）。
private struct PasteImageEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let onPasteImage: (Data, String) -> Void
    let onDroppedFiles: ([URL]) -> Void
    let onEnter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage
        textView.onDroppedFiles = onDroppedFiles
        textView.onEnter = onEnter
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView

        // 首次挂载后（window 已存在）自动聚焦输入框。
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! EditorTextView

        if textView.string != text {
            let hadText = !textView.string.isEmpty
            textView.string = text
            // 发送后草稿清空：把焦点还给输入框。
            if hadText && text.isEmpty {
                nsView.window?.makeFirstResponder(textView)
            }
        }
        if textView.font != font {
            textView.font = font
        }
        textView.onPasteImage = onPasteImage
        textView.onDroppedFiles = onDroppedFiles
        textView.onEnter = onEnter
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteImageEditor
        init(_ parent: PasteImageEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  tv.string != parent.text else { return }
            parent.text = tv.string
        }
    }
}

/// `NSTextView` 子类：拦截粘贴（剪贴板图片 → 附件）、拖拽文件（图片/PDF →
/// 附件）、Enter 发送 / Shift+Enter 换行。
private final class EditorTextView: NSTextView {
    var onPasteImage: ((Data, String) -> Void)?
    var onDroppedFiles: (([URL]) -> Void)?
    var onEnter: (() -> Void)?

    // MARK: - Cmd+V 粘贴图片

    override func paste(_ sender: Any?) {
        if let (data, mime) = Self.clipboardImage() {
            onPasteImage?(data, mime)
            return
        }
        // 剪贴板没有图片时走默认粘贴（文本粘贴完全不受影响）。
        super.paste(sender)
    }

    /// 从通用剪贴板提取图片：优先 png/tiff 数据，其次任意 NSImage 对象（转 PNG），
    /// 再其次是 Finder 复制的图片文件 URL（读文件内容）。返回 `(数据, MIME)`。
    static func clipboardImage() -> (Data, String)? {
        let pb = NSPasteboard.general
        // 1) 直接有 PNG / TIFF 数据（macOS 截图一般这两种）。
        if let data = pb.data(forType: .png) {
            return (data, "image/png")
        }
        if let data = pb.data(forType: .tiff) {
            return (data, "image/tiff")
        }
        // 2) Finder 里复制的图片文件 URL → 读文件内容。
        if let urlString = pb.string(forType: .fileURL),
           let url = URL(string: urlString),
           let uti = UTType(filenameExtension: url.pathExtension),
           uti.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            return (data, uti.preferredMIMEType ?? "image/png")
        }
        // 3) 任意 NSImage 对象 → 转 PNG（覆盖其它剪贴板图片格式）。
        if let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            if let png = rep.representation(using: .png, properties: [:]) {
                return (png, "image/png")
            }
            return (tiff, "image/tiff")
        }
        return nil
    }

    // MARK: - Enter 发送 / Shift+Enter 换行

    override func insertNewline(_ sender: Any?) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if shiftHeld {
            super.insertNewline(sender) // Shift+Enter：换行
        } else {
            onEnter?() // Enter：发送
        }
    }

    // MARK: - 拖拽文件到输入框

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasUsableFiles(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasUsableFiles(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDroppedFiles?(urls)
        return true
    }

    private func hasUsableFiles(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.contains { url in
            let ext = url.pathExtension.lowercased()
            return ext == "pdf"
                || ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(ext)
        }
    }
}

// MARK: - Pending attachment chip

private struct PendingAttachmentChip: View {
    let attachment: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let data = attachment.decodedData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(3)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pending document chip

private struct PendingDocumentChip: View {
    let document: DocumentAttachment
    let onRemove: () -> Void
    let onSetMode: (PDFSendMode) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(document.filename)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if document.pageCount > 0 {
                        Text(L("pdf.pages", document.pageCount))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    // 当前发送方式徽标。
                    Text(document.sendMode.badgeText)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(document.sendMode.badgeColor.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: 120)

            // "..." 详情菜单：选择发送方式（全部 PNG / 提取文字 / 都发）。
            Menu {
                ForEach(PDFSendMode.allCases) { mode in
                    Button {
                        onSetMode(mode)
                    } label: {
                        if mode == document.sendMode {
                            Label(mode.localizedName, systemImage: "checkmark")
                        } else {
                            Label(mode.localizedName, systemImage: mode.symbol)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("pdf.mode.title"))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(4)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - PDF 发送方式显示辅助

extension PDFSendMode {
    /// 菜单里的完整名称（本地化）。
    var localizedName: String {
        switch self {
        case .images: return L("pdf.mode.images")
        case .text:   return L("pdf.mode.text")
        case .both:   return L("pdf.mode.both")
        }
    }

    /// 菜单 / 徽标用的 SF Symbol。
    var symbol: String {
        switch self {
        case .images: return "photo.on.rectangle"
        case .text:   return "text.alignleft"
        case .both:   return "doc.richtext"
        }
    }

    /// 徽标短文本（本地化）。
    var badgeText: String {
        switch self {
        case .images: return L("pdf.mode.badge.images")
        case .text:   return L("pdf.mode.badge.text")
        case .both:   return L("pdf.mode.badge.both")
        }
    }

    /// 徽标颜色（按类型区分）。
    var badgeColor: Color {
        switch self {
        case .images: return .blue
        case .text:   return .green
        case .both:   return .purple
        }
    }
}

// MARK: - Error banner

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        }
    }
}