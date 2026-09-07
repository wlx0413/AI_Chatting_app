import Foundation

/// The role a `ChatMessage` plays in a conversation.
///
/// Mirrors the OpenAI Chat Completions `role` field.
enum ChatMessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
}

/// A single image attachment embedded in a user message.
///
/// The image is stored as base64 data; the request body converts it to an
/// OpenAI-compatible `image_url` block:
/// `{"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}`
struct ImageAttachment: Identifiable, Codable, Hashable {

    /// Stable identifier for this attachment.
    var id: UUID

    /// Original file name (for display / saving).
    var filename: String

    /// MIME type, e.g. `image/png`, `image/jpeg`, `image/gif`, `image/webp`.
    var mimeType: String

    /// Base64-encoded image bytes (no `data:` prefix).
    var base64Data: String

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        base64Data: String
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    /// Full `data:` URI used in the API request.
    var dataURI: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    /// Decodes the base64 payload back into `Data` (for preview rendering).
    var decodedData: Data? {
        Data(base64Encoded: base64Data)
    }
}

/// 上传 PDF 的发送方式（用户在上传后、发送前选择，随消息持久化）。
///
/// 默认 `.both`（图片 + 文字都发），对视觉模型最完整；文字层为空（扫描版）
/// 或渲染失败时各自优雅回退。
enum PDFSendMode: String, Codable, CaseIterable, Identifiable {
    /// 全部转成 PNG 图片发送（视觉模型逐页渲染）。
    case images = "images"
    /// 提取文字发送（任何模型都适用）。
    case text = "text"
    /// 图片 + 文字都发送。
    case both = "both"

    var id: String { rawValue }
}

/// A single document (PDF) attachment embedded in a user message.
///
/// The file bytes are stored base64-encoded; at request time the service
/// either renders its pages into vision-model images (`image_url` parts) or
/// extracts its text for text-only models, according to `sendMode`.
struct DocumentAttachment: Identifiable, Codable, Hashable {

    /// Stable identifier for this attachment.
    var id: UUID

    /// Original file name (for display / saving).
    var filename: String

    /// MIME type, e.g. `application/pdf`.
    var mimeType: String

    /// Base64-encoded file bytes (no `data:` prefix).
    var base64Data: String

    /// Number of pages (computed at attach time; 0 when unknown).
    var pageCount: Int

    /// 发送方式（图片 / 文字 / 都发），默认两个都发。
    var sendMode: PDFSendMode = .both

    // MARK: - Coding (旧消息没有 sendMode 字段，需容错解码)

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, base64Data, pageCount, sendMode
    }

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        base64Data: String,
        pageCount: Int = 0,
        sendMode: PDFSendMode = .both
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.pageCount = pageCount
        self.sendMode = sendMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        base64Data = try c.decode(String.self, forKey: .base64Data)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        sendMode = try c.decodeIfPresent(PDFSendMode.self, forKey: .sendMode) ?? .both
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(base64Data, forKey: .base64Data)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(sendMode, forKey: .sendMode)
    }

    /// Decodes the base64 payload back into `Data` (for preview / processing).
    var decodedData: Data? {
        Data(base64Encoded: base64Data)
    }
}

/// A clickable source reference (web_search / web_fetch result) attached to an
/// assistant reply in Agent mode. Rendered as a "Sources" card under the bubble.
struct ChatSource: Identifiable, Codable, Hashable {
    /// Display title (page title for search hits, host for fetched pages).
    var title: String

    /// Absolute http(s) URL.
    var url: String

    /// Identity = URL so duplicates collapse across tool calls.
    var id: String { url }
}

/// One tool call executed while producing an assistant reply.
///
/// Recorded for the message-info popover; persisted with the message but
/// NEVER sent to the API (the `PayloadMessage` wire type only carries
/// `role` + `content`, so prompt-cache prefixes are unaffected).
struct MessageToolCallRecord: Codable, Hashable {
    /// Tool name, e.g. `web_search`.
    var name: String

    /// The JSON arguments the model passed to the tool.
    var arguments: String

    /// A short preview of the tool's result (truncated for display).
    var resultPreview: String
}

/// Token usage for a single assistant message as reported by the relay
/// (DeepSeek extends the standard fields with cache hit/miss counters).
///
/// Persisted with the message for the info popover; never sent to the API.
struct MessageUsage: Codable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheHitTokens: Int?
    var cacheMissTokens: Int?
}

/// A single message within a `ChatSession`.
///
/// Content is the fully accumulated text. When streaming, the assistant
/// message's content is updated incrementally as `delta` chunks arrive.
/// User messages may carry image attachments for multimodal models.
struct ChatMessage: Identifiable, Codable, Hashable {

    /// Stable identifier for this message.
    var id: UUID

    /// The speaker (user / assistant / system instruction).
    var role: ChatMessageRole

    /// Full message text.
    var content: String

    /// Image attachments (user messages only; multimodal models).
    var attachments: [ImageAttachment]

    /// Document (PDF) attachments (user messages only).
    var documentAttachments: [DocumentAttachment]

    /// When the message was created.
    var timestamp: Date

    /// Source references (web tools) rendered below assistant replies.
    var sources: [ChatSource]

    /// Model that generated this assistant message (nil for user/system).
    /// Persisted for the info popover; never sent to the API.
    var model: String?

    /// Relay-reported token usage for this assistant message.
    var usage: MessageUsage?

    /// Tool-call flow executed while generating this assistant reply.
    var toolFlow: [MessageToolCallRecord]

    /// DeepSeek reasoning models emit `reasoning_content` (the "thinking").
    /// Persisted so the next request can pass it back (DeepSeek requires it
    /// for tool-call rounds); never shown in the bubble.
    var reasoningContent: String?

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        attachments: [ImageAttachment] = [],
        documentAttachments: [DocumentAttachment] = [],
        timestamp: Date = Date(),
        sources: [ChatSource] = [],
        model: String? = nil,
        usage: MessageUsage? = nil,
        toolFlow: [MessageToolCallRecord] = [],
        reasoningContent: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.documentAttachments = documentAttachments
        self.timestamp = timestamp
        self.sources = sources
        self.model = model
        self.usage = usage
        self.toolFlow = toolFlow
        self.reasoningContent = reasoningContent
    }

    /// Convenience factory for user messages (with optional image attachments).
    static func user(
        _ content: String,
        attachments: [ImageAttachment] = [],
        documents: [DocumentAttachment] = []
    ) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: content,
            attachments: attachments,
            documentAttachments: documents
        )
    }

    /// Convenience factory for assistant messages.
    static func assistant(_ content: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    /// Convenience factory for system messages.
    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    // MARK: - Codable

    /// Custom decoding so messages persisted *before* multimodal support
    /// (without an `attachments` key) still decode correctly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([ImageAttachment].self, forKey: .attachments) ?? []
        documentAttachments = try container.decodeIfPresent([DocumentAttachment].self, forKey: .documentAttachments) ?? []
        // Fall back to "now" for very old archives persisted before timestamps.
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        sources = try container.decodeIfPresent([ChatSource].self, forKey: .sources) ?? []
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(MessageUsage.self, forKey: .usage)
        toolFlow = try container.decodeIfPresent([MessageToolCallRecord].self, forKey: .toolFlow) ?? []
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
    }
}
