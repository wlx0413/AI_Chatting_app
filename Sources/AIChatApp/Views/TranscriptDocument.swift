import SwiftUI

/// Print/PDF layout for one chat session.
///
/// Deliberately **not** the on-screen bubble layout: no avatars, no action
/// bars, no scroll views (a ScrollView would clip to one screen inside a PDF
/// context). Content is rendered with the same `MarkdownText` used in the chat
/// so code highlighting, tables and math match the app exactly.
///
/// 分页：`blocks` 把整篇拆成 header / 每条消息 / footer 的独立子视图。
/// `PDFExportService` 逐块测量高度后**整块摆放**——换页只发生在消息之间，
/// 不会再从一行文字中间截断（“腰斩”）。
struct TranscriptDocument: View {

    let session: ChatSession
    let appearance: AppearanceStore
    let localization: LocalizationManager

    init(
        session: ChatSession,
        appearance: AppearanceStore,
        localization: LocalizationManager
    ) {
        self.session = session
        self.appearance = appearance
        self.localization = localization
    }

    /// 分块列表：header + 每条非空消息 + footer。
    var blocks: [TranscriptBlock] {
        var result: [TranscriptBlock] = [.header]
        for message in session.messages
        where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.message(message))
        }
        result.append(.footer)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(blocks) { block in
                block.makeView(session: session, appearance: appearance)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 一个可独立测量 / 渲染的导出块。
enum TranscriptBlock: Identifiable {
    case header
    case message(ChatMessage)
    case footer

    var id: String {
        switch self {
        case .header:         return "header"
        case .message(let m): return "message-\(m.id.uuidString)"
        case .footer:         return "footer"
        }
    }

    @ViewBuilder
    func makeView(session: ChatSession, appearance: AppearanceStore) -> some View {
        switch self {
        case .header:
            TranscriptHeaderView(session: session, appearance: appearance)
        case .message(let message):
            TranscriptMessageView(message: message, appearance: appearance)
        case .footer:
            TranscriptFooterView(session: session)
        }
    }
}

// MARK: - Block views

private struct TranscriptHeaderView: View {
    let session: ChatSession
    let appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize + 6)
                .bold()
                .foregroundStyle(.black)

            Text("\(session.createdAt.formatted(date: .long, time: .shortened))  ·  \(L("msg.count", session.messages.count))")
                .font(.caption)
                .foregroundStyle(.gray)

            Divider()
        }
    }
}

private struct TranscriptMessageView: View {
    let message: ChatMessage
    let appearance: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(roleLabel(message.role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == .user ? Color.gray : Color.black)
                Text(message.timestamp.formatted(date: .numeric, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.gray)
                if let model = message.model, !model.isEmpty, message.role == .assistant {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }

            if message.role == .assistant {
                MarkdownText(text: message.content, fontSize: nil)
                    .environmentObject(appearance)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // User messages are plain text in the app; keep them verbatim
                // (a light card makes the turn boundaries scannable on paper).
                Text(message.content)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.gray.opacity(0.12))
                    )
            }

            // Web sources collected by the agent tools.
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("sources.title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.gray)
                    ForEach(message.sources) { source in
                        Text("· \(source.title) — \(source.url)")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func roleLabel(_ role: ChatMessageRole) -> String {
        switch role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }
}

private struct TranscriptFooterView: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            Text(L("export.pdf.footer", L("app.name"), Date().formatted(date: .abbreviated, time: .shortened)))
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }
}
