import SwiftUI
import AppKit

/// Left sidebar: list of chat sessions with a "New Chat" button and
/// per-item delete support (modern macOS 14+ List with selection).
struct SidebarView: View {

    // MARK: - Environment

    @EnvironmentObject private var chatViewModel: ChatViewModel

    /// 全局外观（字体预设 / 字号）——观察变化以触发即时刷新。
    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else {
                VStack(spacing: 0) {
                    personalizationSection
                    sessionList
                }
            }
        }
        .background(appearance.sidebarBackground)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                searchField
                // 「新建会话」铺满整行；右侧小箭头在按钮内部，点开才是「添加个性化块」。
                Menu {
                    Button {
                        chatViewModel.createNewChat()
                    } label: {
                        Label(L("new.chat"), systemImage: "square.and.pencil")
                    }
                    Button {
                        chatViewModel.createPersonalizationCollection()
                    } label: {
                        Label(L("kb.add"), systemImage: "brain")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Label(L("new.chat"), systemImage: "square.and.pencil")
                            .font(appearance.fontPreset.font(size: appearance.pointSize))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(appearance.fontPreset.font(size: appearance.pointSize - 2))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(appearance.prominentButtonColor)
                    )
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .disabled(isSearching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !chatViewModel.sessions.isEmpty && !isSearching {
                HStack {
                    Text(L("chat.count", chatViewModel.sessions.count))
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        for session in chatViewModel.sessions {
                            chatViewModel.deleteSession(session)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .help(L("delete.all.chats"))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Search

    /// `true` when the user is actively searching (query non-empty).
    private var isSearching: Bool {
        !chatViewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Search field: magnifier + query + clear button.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L("search.placeholder"), text: $chatViewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
            if !chatViewModel.searchQuery.isEmpty {
                Button {
                    chatViewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("search.clear"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Saved personalization blocks: user-curated named facts the model can
    /// fetch via `fetch_personalization_block`. Collapsible; only shown when at
    /// least one block exists.
    private var personalizationSection: some View {
        Group {
            if !chatViewModel.personalizationBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("kb.title", chatViewModel.personalizationBlocks.count))
                        .font(appearance.fontPreset.font(size: appearance.pointSize - 1))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    ForEach(chatViewModel.personalizationBlocks) { block in
                        PersonalizationBlockRow(block: block) {
                            chatViewModel.deletePersonalizationBlock(block)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.035))

                Divider()
            }
        }
    }

    /// Full-text search result list (replaces the session list while searching).
    private var searchResultsList: some View {
        let results = chatViewModel.searchResults
        return Group {
            if results.isEmpty {
                ContentUnavailableView(
                    L("search.no.results"),
                    systemImage: "magnifyingglass",
                    description: Text(L("search.no.results.description"))
                )
            } else {
                List(results) { result in
                    SearchResultRow(result: result) {
                        chatViewModel.selectSearchResult(result)
                    }
                    .tag(result.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Normal session list. Uses scroll + manual selection highlight instead of
    /// `List(selection:)`: macOS 14+ renders the List selection highlight as a
    /// fixed system-blue overlay on interaction that cannot be themed, so the
    /// row draws its own selection tint (clay on Claude, system accent otherwise).
    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(chatViewModel.sessions) { session in
                    SidebarRow(
                        session: session,
                        isSelected: chatViewModel.activeSessionID == session.id,
                        onSelect: { chatViewModel.selectSession(id: session.id) }
                    )
                    .contextMenu {
                        Button {
                            exportPDF(session)
                        } label: {
                            Label(L("export.pdf"), systemImage: "arrow.down.doc")
                        }
                        .disabled(session.messages.isEmpty)

                        Divider()

                        Button(L("delete.chat"), role: .destructive) {
                            chatViewModel.deleteSession(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    // MARK: - PDF export

    /// Exports one session to PDF, surfacing failures in the chat error banner.
    private func exportPDF(_ session: ChatSession) {
        do {
            if let url = try PDFExportService.export(
                session: session,
                appearance: appearance,
                localization: localization
            ) {
                // Reveal the file so the user gets immediate confirmation.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            chatViewModel.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

/// A single chat session row in the sidebar.
private struct SidebarRow: View {

    /// Session to display.
    let session: ChatSession

    /// Whether this row is currently selected.
    let isSelected: Bool

    /// Selects this session.
    let onSelect: () -> Void

    /// Hover state for a subtle non-selected rollover background.
    @State private var isHovering = false

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if session.isPersonalizationCollection {
                        Image(systemName: "brain")
                            .font(.caption2)
                            .foregroundStyle(appearance.accentColor)
                    }
                    if let emoji = session.emoji, !emoji.isEmpty {
                        Text(emoji)
                            .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                    }
                    Text(session.title)
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? appearance.accentColor : Color.primary)
                }

                HStack(spacing: 4) {
                    Text(session.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !session.messages.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(L("msgs.count", session.messages.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    /// Row fill: theme selection tint when selected, soft gray rollover
    /// otherwise. Fully self-drawn — no system List highlight involved.
    private var rowBackgroundColor: Color {
        if isSelected {
            return appearance.sidebarSelectionColor
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }
}

/// One saved personalization block in the sidebar: name (click to preview the
/// content) + delete. The model reads these by name via `fetch_personalization_block`.
private struct PersonalizationBlockRow: View {

    let block: PersonalizationBlock
    let onDelete: () -> Void

    @EnvironmentObject private var appearance: AppearanceStore
    @State private var isHovering = false
    @State private var showContent = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showContent = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(appearance.accentColor)
                    Text(block.name)
                        .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showContent) {
                PersonalizationBlockContent(block: block)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
    }
}

/// Popover showing a personalization block's stored content (selectable text).
private struct PersonalizationBlockContent: View {

    let block: PersonalizationBlock

    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.name)
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                .bold()
            ScrollView {
                Text(block.content)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
    }
}

// MARK: - Search result row

/// One full-text search hit: session title + snippet + role badge.
private struct SearchResultRow: View {

    let result: MessageSearchResult
    let onSelect: () -> Void

    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.sessionTitle)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Text(result.snippet)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize - 1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(result.message.role == .user ? L("you") : L("assistant"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}