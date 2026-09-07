import Foundation

/// A conversation consisting of an ordered list of messages.
struct ChatSession: Identifiable, Codable, Hashable {

    /// Stable identifier for this session.
    var id: UUID

    /// Display title shown in the sidebar.
    var title: String

    /// AI-chosen emoji shown before the title in the sidebar.
    var emoji: String?

    /// All messages in chronological order.
    var messages: [ChatMessage]

    /// When the session was created.
    var createdAt: Date

    /// `true` when this session is a dedicated personalization-collection chat (started
    /// via "添加个性化块"): it uses the collector system prompt and offers a
    /// "生成个性化块" action that turns the transcript into a named personalization block.
    var isPersonalizationCollection: Bool

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        emoji: String? = nil,
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        isPersonalizationCollection: Bool = false
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.messages = messages
        self.createdAt = createdAt
        self.isPersonalizationCollection = isPersonalizationCollection
    }

    /// Derives a meaningful title from the first meaningful user message.
    mutating func autoTitle() {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || title == "New Chat" else {
            return
        }

        for message in messages where message.role == .user {
            let cleaned = message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { continue }

            // Keep it short enough for a sidebar label.
            let maxLength = 24
            title = cleaned.count > maxLength
                ? String(cleaned.prefix(maxLength)) + "…"
                : cleaned
            return
        }
    }

    // MARK: - Codable
    //
    // Custom decode so sessions persisted before `emoji` / `isPersonalizationCollection`
    // existed still decode (decodeIfPresent → default), avoiding silent data loss
    // in the store's `try?` decode. `emoji` is omitted from JSON when nil.

    private enum CodingKeys: String, CodingKey {
        case id, title, emoji, messages, createdAt, isPersonalizationCollection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isPersonalizationCollection = try container.decodeIfPresent(Bool.self, forKey: .isPersonalizationCollection) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encode(messages, forKey: .messages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isPersonalizationCollection, forKey: .isPersonalizationCollection)
    }
}