import Foundation

/// A stored "knowledge block": a named bundle of durable facts collected in a
/// dedicated knowledge-collection conversation, later exposed to the model as a
/// `fetch_personalization_block` tool so normal chats can read it on demand.
struct PersonalizationBlock: Identifiable, Codable, Hashable {

    /// Stable identifier.
    let id: UUID

    /// The block's name — the value the model passes to `fetch_personalization_block`.
    var name: String

    /// The assembled content (user + assistant transcript of the collection
    /// conversation). Returned verbatim by the fetch tool.
    var content: String

    /// The personalization conversation this block was generated from.
    var sourceSessionID: UUID?

    /// When the block was created.
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        sourceSessionID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.sourceSessionID = sourceSessionID
        self.createdAt = createdAt
    }
}
