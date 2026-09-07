import Foundation

/// Errors thrown by `OpenAIService`.
enum OpenAIServiceError: LocalizedError, Equatable {
    /// The base URL string could not be parsed into a URL.
    case invalidBaseURL(String)

    /// The required API key is missing or empty.
    case missingAPIKey

    /// The HTTP response was not a 2xx status code.
    case httpError(statusCode: Int, message: String)

    /// The response body could not be decoded as JSON.
    case decodingFailed(String)

    /// The stream ended before any content was received.
    case emptyStream

    /// A transport-level error occurred (timeout, no network, etc.).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid base URL: \(url)"
        case .missingAPIKey:
            return "Missing API key. Add one in the profile settings."
        case .httpError(let statusCode, let message):
            let preview = message.count > 300 ? String(message.prefix(300)) + "…" : message
            return "Server returned HTTP \(statusCode). \(preview)"
        case .decodingFailed(let detail):
            return "Failed to decode server response: \(detail)"
        case .emptyStream:
            return "The model returned an empty response."
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}

// MARK: - Deterministic payload encoding
//
// CRITICAL CACHE NOTE:
// Cloud prompt caches (DeepSeek) hash the exact request bytes. Foundation's
// JSONEncoder stores keyed-container fields in an internal hash table and —
// WITHOUT `.sortedKeys` — iterates it in hash order, which is randomized per
// process launch. So even Codable structs emit their fields in a DIFFERENT
// order on every app restart; the whole request looks "new" and the prompt
// cache NEVER hits again.
//
// Fix: `.sortedKeys` on the shared `chatPayloadEncoder` (plus explicitly
// sorted tool-schema dictionaries in `PayloadJSON`) makes the request bytes
// byte-identical across runs and across restarts.

/// JSONEncoder for the chat request body. `.sortedKeys` is mandatory for
/// byte-stable payloads across process launches (see note above).
private let chatPayloadEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

/// Top-level `/v1/chat/completions` request body with stable field order.
private struct ChatPayload: Encodable {
    let model: String
    let messages: [PayloadItem]
    let stream: Bool

    /// DeepSeek-reasoner-compatible relays require `enable_thinking: false`
    /// for non-streaming; nil omits the field entirely (streaming path).
    var enable_thinking: Bool?

    /// Optional `tools` (function calling). nil omits the field so tool-less
    /// requests stay byte-identical to a standard OpenAI request.
    var tools: [PayloadTool]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case enable_thinking
        case tools
    }

    /// Custom encode: optional fields are emitted ONLY when non-nil so the
    /// payload stays byte-identical to a standard OpenAI request (no
    /// `"field": null` pollution that breaks cache matches or strict backends).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        if let enable_thinking {
            try container.encode(enable_thinking, forKey: .enable_thinking)
        }
        if let tools {
            try container.encode(tools, forKey: .tools)
        }
    }
}

/// One entry of the `messages` array: a regular chat message, an assistant
/// message carrying `tool_calls`, or a `role: tool` result message.
private enum PayloadItem: Encodable {
    case message(PayloadMessage)
    case toolCall(PayloadToolCallMessage)
    case toolResult(PayloadToolResultMessage)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .message(let message):
            try container.encode(message)
        case .toolCall(let message):
            try container.encode(message)
        case .toolResult(let message):
            try container.encode(message)
        }
    }
}

/// Assistant message that carries tool-call requests (inside the tool loop).
private struct PayloadToolCallMessage: Encodable {
    let role = "assistant"
    let content: String?
    let tool_calls: [ToolCall]

    /// DeepSeek reasoning models REQUIRE passing back the previous round's
    /// `reasoning_content` when following up on a tool call.
    let reasoning_content: String?

    init(content: String?, tool_calls: [ToolCall], reasoning_content: String? = nil) {
        self.content = content
        self.tool_calls = tool_calls
        self.reasoning_content = reasoning_content
    }

    enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, reasoning_content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(tool_calls, forKey: .tool_calls)
        // Only emit reasoning_content when present (keeps payloads byte-identical
        // for non-reasoning models and avoids "reasoning_content": null).
        if let reasoning_content {
            try container.encode(reasoning_content, forKey: .reasoning_content)
        }
    }

    struct ToolCall: Encodable {
        let id: String
        let type = "function"

        struct Function: Encodable {
            let name: String
            let arguments: String
        }

        let function: Function

        enum CodingKeys: String, CodingKey {
            case id, type, function
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encode(function, forKey: .function)
        }
    }
}

/// `role: tool` message appended after a tool finishes executing.
private struct PayloadToolResultMessage: Encodable {
    let role = "tool"
    let tool_call_id: String
    let content: String
}

/// `tools[].function` wrapper.
private struct PayloadTool: Encodable {
    let type = "function"
    let function: PayloadToolFunction
}

/// The `function` object of a tool definition.
private struct PayloadToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: PayloadJSON

    init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = PayloadJSON(fromAny: parameters)
    }
}

/// Recursive JSON value that can be encoded into a tool schema.
///
/// Dictionaries are encoded with SORTED keys: Swift `Dictionary` iteration
/// order is randomized per process (per-run hash seed), so without sorting the
/// `tools[].function.parameters` bytes change every app launch — and since
/// `tools` precedes `messages` in the payload, DeepSeek's byte-identical
/// prompt-cache prefix NEVER matches after a restart (hit rate collapses).
private enum PayloadJSON: Encodable {
    case object([String: PayloadJSON])
    case array([PayloadJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(fromAny value: Any) {
        if let bool = value as? Bool {
            self = .bool(bool)
        } else if let number = value as? NSNumber {
            self = .number(number.doubleValue)
        } else if let string = value as? String {
            self = .string(string)
        } else if let array = value as? [Any] {
            self = .array(array.map { PayloadJSON(fromAny: $0) })
        } else if let dict = value as? [String: Any] {
            self = .object(dict.mapValues { PayloadJSON(fromAny: $0) })
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let dict):
            // Deterministic key order for the tool schema (see type doc above).
            var keyed = encoder.container(keyedBy: SortedCodingKey.self)
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                try keyed.encode(value, forKey: SortedCodingKey(stringValue: key))
            }
        case .array(let array):
            var container = encoder.singleValueContainer()
            try container.encode(array)
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

/// `CodingKey` backed by a string, used to emit sorted JSON object keys.
private struct SortedCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// A single message in the payload (`role` + `content`).
private struct PayloadMessage: Encodable {
    let role: String
    let content: PayloadContent

    /// DeepSeek reasoning models require passing back the previous
    /// `reasoning_content` on assistant messages. Only emitted when non-nil so
    /// non-reasoning relays/models see byte-identical payloads as before.
    let reasoning_content: String?

    init(role: String, content: PayloadContent, reasoning_content: String? = nil) {
        self.role = role
        self.content = content
        self.reasoning_content = reasoning_content
    }

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning_content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if let reasoning_content {
            try container.encode(reasoning_content, forKey: .reasoning_content)
        }
    }
}

/// Message content: either a plain string or an array of content parts
/// (text / image_url for multimodal requests).
private enum PayloadContent: Encodable {
    case text(String)
    case parts([PayloadContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

/// One entry of a multimodal content array.
private struct PayloadContentPart: Encodable {
    let type: String
    let text: String?
    let image_url: PayloadImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case image_url
    }

    /// Only non-nil fields are emitted (keeps the bytes minimal + stable).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text {
            try container.encode(text, forKey: .text)
        }
        if let image_url {
            try container.encode(image_url, forKey: .image_url)
        }
    }
}

/// `image_url` part body.
private struct PayloadImageURL: Encodable {
    let url: String
}

/// A lightweight, actor-isolated client for OpenAI-compatible relay servers.
///
/// All network work uses `URLSession` with the modern async/await APIs:
/// - Base URL normalization (trailing slashes, missing `/v1`)
/// - `GET /v1/models` (returns model list **and** dynamic prices, if any)
/// - `POST /v1/chat/completions` with **SSE streaming** exposed via
///   `AsyncThrowingStream<String, Error>`.
/// Token usage reported by the relay on the final stream chunk (DeepSeek
/// extends the standard `usage` with `prompt_cache_hit_tokens` /
/// `prompt_cache_miss_tokens`). All fields are optional because different
/// relays / models report different subsets.
struct StreamUsage: Sendable, Equatable {
    /// Total input tokens for this request (nil when the relay omits it).
    var promptTokens: Int?

    /// Total output tokens (nil when the relay omits it).
    var completionTokens: Int?

    /// Input tokens served from DeepSeek's disk prefix cache.
    var cacheHitTokens: Int?

    /// Input tokens that had to be processed (cache miss).
    var cacheMissTokens: Int?

    /// Cache hit ratio when the cache split is reported.
    var cacheHitRatio: Double? {
        guard let hit = cacheHitTokens, let miss = cacheMissTokens else { return nil }
        let total = hit + miss
        return total > 0 ? Double(hit) / Double(total) : nil
    }
}

/// Events yielded by `streamChatWithTools` (function calling).
enum ChatStreamEvent: Sendable {
    /// A text delta of the final answer.
    case text(String)

    /// The model asked to run a tool (shown in the placeholder bubble).
    case toolActivity(String)

    /// A tool finished executing.
    case toolFinished(String)

    /// Source references collected from web tools (rendered below the answer).
    case sources([ChatSource])

    /// Token usage from the relay's final chunk (cache hit/miss included).
    case usage(StreamUsage)

    /// A completed tool call, recorded for the message-info popover.
    case toolRecord(MessageToolCallRecord)

    /// Reasoning ("thinking") text for the final answer (DeepSeek).
    case reasoning(String)
}

/// Accumulates fragmented streaming tool-call deltas for one index.
private struct ToolRoundOutcome {
    var toolCalls: [Int: ToolCallAccumulator] = [:]
    var yieldedText = false

    /// DeepSeek reasoning text accumulated during this round (must be passed
    /// back on the follow-up tool round).
    var reasoning = ""
}

private struct ToolCallAccumulator {
    var id = ""
    var name = ""
    var arguments = ""
}

actor OpenAIService {

    // MARK: - Nested response types

    /// JSON body returned by `GET /v1/models`.
    private struct ModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
            struct Pricing: Decodable {
                let prompt: Double?
                let completion: Double?
            }
            let pricing: Pricing?
        }
        let data: [ModelItem]
    }

    /// A single SSE `data:` chunk from a streaming response.
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?

                /// DeepSeek reasoning models stream their "thinking" here.
                let reasoning_content: String?

                /// Streaming tool-call fragments (one per index).
                struct ToolCallDelta: Decodable {
                    let index: Int?
                    let id: String?
                    struct FunctionDelta: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let function: FunctionDelta?
                }

                let tool_calls: [ToolCallDelta]?
            }

            let delta: Delta?
            let finish_reason: String?
        }

        let choices: [Choice]?

        /// Token usage reported on the final chunk. DeepSeek extends the
        /// standard fields with `prompt_cache_hit_tokens` and
        /// `prompt_cache_miss_tokens`.
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let prompt_cache_hit_tokens: Int?
            let prompt_cache_miss_tokens: Int?
        }

        let usage: Usage?

        /// Extracts the delta text for this chunk, if any.
        var contentDelta: String? {
            choices?.first?.delta?.content
        }

        /// Extracts the reasoning ("thinking") delta, if any (DeepSeek).
        var reasoningDelta: String? {
            choices?.first?.delta?.reasoning_content
        }

        /// Extracts tool-call fragments for this chunk, if any.
        var toolCallDeltas: [Choice.Delta.ToolCallDelta]? {
            choices?.first?.delta?.tool_calls
        }
    }

    /// JSON error body returned by the relay on non-2xx responses.
    private struct APIErrorBody: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }
        let error: ErrorDetail?
    }

    // MARK: - Private state

    /// Ephemeral session that does not persist cookies across launches.
    private let session: URLSession

    // MARK: - Initializers

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - PDF preparation cache
    //
    // Rendering PDF pages / extracting text is CPU-heavy, so results are
    // memoized per attachment. This lets Retry and subsequent requests reuse
    // the work instead of re-processing the whole document every time.

    private actor PDFPrepCache {
        static let shared = PDFPrepCache()

        /// "attachmentID:maxPages" → base64 PNG page images (vision models)。
        /// key 带页数：改「最多渲染页数」设置后缓存不会复用旧页数结果。
        private var pages: [String: [String]] = [:]

        /// attachment id → extracted text (text-only models).
        private var texts: [UUID: String] = [:]

        static func pageKey(_ id: UUID, _ maxPages: Int) -> String {
            "\(id.uuidString):\(maxPages)"
        }

        func pages(for id: UUID, maxPages: Int) -> [String]? { pages[Self.pageKey(id, maxPages)] }
        func setPages(_ value: [String], for id: UUID, maxPages: Int) {
            if pages.count > 24 { pages.removeAll() }
            pages[Self.pageKey(id, maxPages)] = value
        }
        func text(for id: UUID) -> String? { texts[id] }
        func setText(_ value: String, for id: UUID) {
            if texts.count > 24 { texts.removeAll() }
            texts[id] = value
        }
    }

    /// Renders a PDF into base64 PNG pages (memoized), off the main thread.
    /// 页数上限读用户可调参数 `PDFProcessor.maxRenderPages`（0 = 全部页）。
    private static func pdfPageImages(for document: DocumentAttachment) async -> [String] {
        let limit = PDFProcessor.maxRenderPages
        if let cached = await PDFPrepCache.shared.pages(for: document.id, maxPages: limit), !cached.isEmpty {
            return cached
        }
        guard let data = document.decodedData, !data.isEmpty else { return [] }
        let images = await Task.detached(priority: .userInitiated) {
            PDFProcessor.renderPages(from: data, maxPages: limit).map { $0.base64EncodedString() }
        }.value
        await PDFPrepCache.shared.setPages(images, for: document.id, maxPages: limit)
        return images
    }

    /// Extracts a PDF's text layer (memoized), off the main thread.
    private static func pdfText(for document: DocumentAttachment) async -> String {
        if let cached = await PDFPrepCache.shared.text(for: document.id) {
            return cached
        }
        guard let data = document.decodedData, !data.isEmpty else { return "" }
        let text = await Task.detached(priority: .userInitiated) {
            PDFProcessor.extractText(from: data)
        }.value
        await PDFPrepCache.shared.setText(text, for: document.id)
        return text
    }

    /// Formats extracted PDF text for inclusion as a content part.
    private static func pdfTextPart(_ document: DocumentAttachment, _ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.count > 20000 ? String(trimmed.prefix(20000)) + "\n…[内容过长已截断]" : trimmed
        return "[📄 文档：\(document.filename)]\n\(body)"
    }

    /// Builds the wire-format `messages` array.
    ///
    /// Model-switch safety: when the current model is NOT multimodal, any
    /// image attachments in history are downgraded to plain text so the
    /// request never fails AND the giant base64 never participates in the
    /// prompt prefix (which would wreck upstream caching for everyone).
    ///   - text + images  → keep the text, drop the images
    ///   - images only    → replace with a short placeholder
    ///
    /// PDF documents are processed according to the model:
    ///   - vision    → page images (`image_url` parts, first N pages)
    ///   - text-only → extracted text as a content part
    private static func payloadMessages(
        from messages: [ChatMessage],
        model: String
    ) async -> [PayloadItem] {
        let isVision = MultimodalSupport.isMultimodal(model)
        var result: [PayloadItem] = []

        for message in messages {
            // ---- No documents: keep the pre-existing wire format untouched
            // ---- (byte-stable prompt prefix for upstream caching).
            if message.documentAttachments.isEmpty {
                if !message.attachments.isEmpty && isVision {
                    var parts: [PayloadContentPart] = []
                    if !message.content.isEmpty {
                        parts.append(PayloadContentPart(
                            type: "text",
                            text: message.content,
                            image_url: nil
                        ))
                    }
                    for attachment in message.attachments {
                        parts.append(PayloadContentPart(
                            type: "image_url",
                            text: nil,
                            image_url: PayloadImageURL(url: attachment.dataURI)
                        ))
                    }
                    result.append(.message(PayloadMessage(role: message.role.rawValue, content: .parts(parts), reasoning_content: message.reasoningContent)))
                } else if !message.attachments.isEmpty && !isVision {
                    let note = "[图片已附加但当前模型不支持视觉，已忽略]"
                    let content = message.content.isEmpty
                        ? note
                        : message.content + "\n\n" + note
                    result.append(.message(PayloadMessage(role: message.role.rawValue, content: .text(content), reasoning_content: message.reasoningContent)))
                } else {
                    result.append(.message(PayloadMessage(role: message.role.rawValue, content: .text(message.content), reasoning_content: message.reasoningContent)))
                }
                continue
            }

            // ---- Messages carrying PDF document(s).
            var parts: [PayloadContentPart] = []
            if !message.content.isEmpty {
                parts.append(PayloadContentPart(type: "text", text: message.content, image_url: nil))
            }

            if isVision {
                // 视觉模型：按每个 PDF 的 sendMode 发送（图片 / 文字 / 都发）。
                for document in message.documentAttachments {
                    switch document.sendMode {
                    case .text:
                        let text = await pdfText(for: document)
                        if !text.isEmpty {
                            parts.append(PayloadContentPart(
                                type: "text",
                                text: pdfTextPart(document, text),
                                image_url: nil
                            ))
                        }
                    case .images, .both:
                        let pages = await pdfPageImages(for: document)
                        if pages.isEmpty {
                            // Render failed (scanned/encrypted PDF): best-effort
                            // text fallback so the document still reaches the model.
                            let text = await pdfText(for: document)
                            if !text.isEmpty {
                                parts.append(PayloadContentPart(
                                    type: "text",
                                    text: pdfTextPart(document, text),
                                    image_url: nil
                                ))
                            }
                        } else {
                            for base64 in pages {
                                parts.append(PayloadContentPart(
                                    type: "image_url",
                                    text: nil,
                                    image_url: PayloadImageURL(url: "data:image/png;base64,\(base64)")
                                ))
                            }
                            if document.sendMode == .both {
                                let text = await pdfText(for: document)
                                if !text.isEmpty {
                                    parts.append(PayloadContentPart(
                                        type: "text",
                                        text: pdfTextPart(document, text),
                                        image_url: nil
                                    ))
                                }
                            }
                        }
                    }
                }
                // Regular image attachments still apply for vision models.
                for attachment in message.attachments {
                    parts.append(PayloadContentPart(
                        type: "image_url",
                        text: nil,
                        image_url: PayloadImageURL(url: attachment.dataURI)
                    ))
                }
            } else {
                // 文本模型：图片发不了，任何 sendMode 都退化为提取文字。
                for document in message.documentAttachments {
                    let text = await pdfText(for: document)
                    if !text.isEmpty {
                        parts.append(PayloadContentPart(
                            type: "text",
                            text: pdfTextPart(document, text),
                            image_url: nil
                        ))
                    }
                }
                if !message.attachments.isEmpty {
                    parts.append(PayloadContentPart(
                        type: "text",
                        text: "[图片已附加但当前模型不支持视觉，已忽略]",
                        image_url: nil
                    ))
                }
            }

            if parts.isEmpty {
                // Nothing usable (e.g. encrypted PDF): fall back to raw content.
                result.append(.message(PayloadMessage(role: message.role.rawValue, content: .text(message.content), reasoning_content: message.reasoningContent)))
            } else {
                result.append(.message(PayloadMessage(role: message.role.rawValue, content: .parts(parts), reasoning_content: message.reasoningContent)))
            }
        }
        return result
    }

    // MARK: - URL normalization

    /// Normalizes a user-supplied base URL string.
    ///
    /// Rules:
    /// 1. Trim whitespace and trailing slashes.
    /// 2. If no scheme is present, default to `https://`.
    /// 3. If the path does not already end in `/v1`, append it.
    ///
    /// Examples:
    /// - `api.example.com`            → `https://api.example.com/v1`
    /// - `https://api.example.com/`   → `https://api.example.com/v1`
    /// - `https://api.example.com/v1` → unchanged
    func normalizedBaseURL(from raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing slashes.
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw OpenAIServiceError.invalidBaseURL(raw)
        }

        // Default to https when no scheme is provided.
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }

        guard let candidate = URL(string: trimmed),
              let scheme = candidate.scheme,
              let host = candidate.host else {
            throw OpenAIServiceError.invalidBaseURL(raw)
        }

        var url = candidate
        let pathIsV1 = candidate.path == "/v1" || candidate.path.hasPrefix("/v1/")
        if !pathIsV1 {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = candidate.port

            var newPath = candidate.path
            if !newPath.hasSuffix("/") {
                newPath += "/"
            }
            newPath += "v1"
            components.path = newPath
            components.query = candidate.query
            components.fragment = candidate.fragment

            guard let rebuilt = components.url else {
                throw OpenAIServiceError.invalidBaseURL(raw)
            }
            url = rebuilt
        }

        return url
    }

    // MARK: - Fetch models

    /// Fetches the model list (and relay-provided dynamic prices) for a profile.
    ///
    /// - Parameter config: The relay profile to query.
    /// - Returns: Sorted model ids and a dictionary of model-id → price.
    func fetchModels(
        config: APIServerConfig
    ) async throws -> ([String], [String: ModelPrice]) {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAIServiceError.transport("Request timed out.")
        } catch {
            throw OpenAIServiceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.transport("Invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.decodeErrorMessage(from: data)
            throw OpenAIServiceError.httpError(
                statusCode: http.statusCode,
                message: message
            )
        }

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let models = Array(Set(decoded.data.map { $0.id })).sorted()
            var prices: [String: ModelPrice] = [:]
            for item in decoded.data {
                guard let pricing = item.pricing,
                      let prompt = pricing.prompt,
                      let completion = pricing.completion,
                      prompt >= 0, completion >= 0 else { continue }
                prices[item.id] = ModelPrice(prompt: prompt, completion: completion)
            }
            return (models, prices)
        } catch {
            throw OpenAIServiceError.decodingFailed(
                "Expected {\"data\":[{\"id\":\"model\"}]}. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Streaming chat completion with tools (function calling)

    /// Streams a chat completion **with built-in tool calling** (Agent mode).
    ///
    /// Runs the full tool loop internally: sends the request with `tools`,
    /// streams text deltas, and when the model asks to call a tool, executes
    /// it (off the main thread), appends the `assistant(tool_calls)` + `tool`
    /// result messages, and sends the next round — up to `maxRounds` times.
    /// The caller sees only `ChatStreamEvent`s, so the UI stays streaming.
    func streamChatWithTools(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage],
        tools toolsOverride: [BuiltinTool]? = nil,
        usageHandler: ((StreamUsage) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.transport("No model selected.")
        }

        let url = baseURL.appendingPathComponent("chat/completions")
        // nil = full built-in set (agent mode); non-nil = custom subset
        // (e.g. just `get_time` for non-agent chats that still want the time).
        let tools: [PayloadTool] = (toolsOverride ?? ChatTools.all).map { tool in
            PayloadTool(function: PayloadToolFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            ))
        }
        let maxRounds = 8

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var history = await Self.payloadMessages(from: messages, model: model)
                    var round = 0
                    var gotFinalAnswer = false
                    var collectedSources: [ChatSource] = []

                    while round < maxRounds {
                        round += 1
                        let outcome = try await performToolRound(
                            url: url,
                            model: model,
                            apiKey: config.apiKey,
                            history: history,
                            tools: tools,
                            continuation: continuation,
                            usageHandler: usageHandler
                        )

                        // 本轮模型直接给出文本答案 → 完成。
                        if outcome.toolCalls.isEmpty {
                            // DeepSeek reasoning models: hand the final answer's
                            // thinking text to the caller so it can be persisted.
                            if !outcome.reasoning.isEmpty {
                                continuation.yield(.reasoning(outcome.reasoning))
                            }
                            if !outcome.yieldedText {
                                throw OpenAIServiceError.emptyStream
                            }
                            gotFinalAnswer = true
                            break
                        }

                        // 执行工具（容错：失败也返回错误文本让模型调整），
                        // 追加 assistant(tool_calls) + tool 结果后继续下一轮。
                        let sorted = outcome.toolCalls.sorted { $0.key < $1.key }
                        let assistantMessage = PayloadToolCallMessage(
                            content: nil,
                            tool_calls: sorted.map { _, acc in
                                PayloadToolCallMessage.ToolCall(
                                    id: acc.id.isEmpty ? "call_\(acc.name)" : acc.id,
                                    function: .init(name: acc.name, arguments: acc.arguments)
                                )
                            },
                            // DeepSeek reasoning models require passing the
                            // previous round's thinking text back.
                            reasoning_content: outcome.reasoning.isEmpty ? nil : outcome.reasoning
                        )
                        history.append(.toolCall(assistantMessage))

                        for (_, acc) in sorted {
                            let toolName = acc.name.isEmpty ? "unknown" : acc.name
                            continuation.yield(.toolActivity(toolName))
                            let result: String
                            do {
                                result = try await ChatTools.execute(
                                    name: acc.name,
                                    argumentsJSON: acc.arguments
                                )
                            } catch {
                                result = "Error executing tool \(toolName): \(error.localizedDescription)"
                            }
                            continuation.yield(.toolFinished(toolName))
                            continuation.yield(.toolRecord(MessageToolCallRecord(
                                name: toolName,
                                arguments: acc.arguments,
                                resultPreview: String(result.prefix(140))
                            )))
                            collectedSources.append(contentsOf: ChatTools.sources(for: acc.name, result: result))
                            history.append(.toolResult(PayloadToolResultMessage(
                                tool_call_id: acc.id.isEmpty ? "call_\(toolName)" : acc.id,
                                content: result
                            )))
                        }
                    }

        // 循环耗尽仍无文本答案（模型每轮都只返回 tool_calls）：
        // 追加一轮**不带 tools** 的收尾请求，强制模型基于已执行
        // 的工具结果整理出最终答案，避免"工具用完就静默结束"。
        //
        // 关键：必须显式告知模型工具预算已耗尽、禁止再调用工具，且
        // 严禁把工具调用写成 XML 标记（<tool_calls>/<invoke>/<parameter>）
        // 混进回复文本——否则 DeepSeek 会在"还想继续搜索但 tools 已被
        // 摘除"时把训练中学到的 Claude 风格 XML 调用原样吐给用户。
        if !gotFinalAnswer {
            history.append(.message(PayloadMessage(
                role: "system",
                content: .text(
                    "You have used all your tool calls for this request. "
                    + "Compose your final answer NOW using the tool results already returned above. "
                    + "Do NOT call any more tools. "
                    + "Do NOT output any XML tool-call markup such as <tool_calls>, <invoke>, "
                    + "or <parameter> tags in your reply — output only the final answer text."
                )
            )))
            let outcome = try await performToolRound(
                url: url,
                model: model,
                apiKey: config.apiKey,
                history: history,
                tools: nil,
                continuation: continuation,
                usageHandler: usageHandler
            )
            if !outcome.yieldedText {
                throw OpenAIServiceError.emptyStream
            }
        }

                    // Deliver collected sources (web references) before finishing.
                    if !collectedSources.isEmpty {
                        continuation.yield(.sources(collectedSources))
                    }

                    continuation.finish()

                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport("Request timed out.")
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as OpenAIServiceError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport(error.localizedDescription)
                    )
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// One round of the tool loop: streams a chat completion, yields text
    /// deltas, and returns any tool-call fragments the model requested.
    ///
    /// `tools` is optional: pass `nil` for the final answer round after the
    /// tool budget is exhausted — the model then has to respond in plain text.
    private func performToolRound(
        url: URL,
        model: String,
        apiKey: String,
        history: [PayloadItem],
        tools: [PayloadTool]?,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation,
        usageHandler: ((StreamUsage) -> Void)?
    ) async throws -> ToolRoundOutcome {
        let payload = ChatPayload(
            model: model,
            messages: history,
            stream: true,
            tools: tools
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try chatPayloadEncoder.encode(payload)
        } catch {
            throw OpenAIServiceError.transport(
                "Failed to encode request body: \(error.localizedDescription)"
            )
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.transport("Invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 8192 { break }
            }
            throw OpenAIServiceError.httpError(
                statusCode: http.statusCode,
                message: Self.decodeErrorMessage(from: errorData)
            )
        }

        var outcome = ToolRoundOutcome()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }
            guard trimmed.hasPrefix("data:") else { continue }

            let data = String(trimmed.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if data == "[DONE]" || data.uppercased().contains("[DONE]") {
                break
            }
            guard let chunkData = data.data(using: .utf8) else { continue }
            do {
                let chunk = try JSONDecoder().decode(StreamChunk.self, from: chunkData)
                if let u = chunk.usage,
                   let hit = u.prompt_cache_hit_tokens,
                   let miss = u.prompt_cache_miss_tokens {
                    usageHandler?(StreamUsage(
                        promptTokens: u.prompt_tokens,
                        completionTokens: u.completion_tokens,
                        cacheHitTokens: hit,
                        cacheMissTokens: miss
                    ))
                }
                if let delta = chunk.contentDelta, !delta.isEmpty {
                    outcome.yieldedText = true
                    continuation.yield(.text(delta))
                }
                if let r = chunk.reasoningDelta, !r.isEmpty {
                    outcome.reasoning += r
                }
                if let deltas = chunk.toolCallDeltas {
                    for delta in deltas {
                        let index = delta.index ?? 0
                        var acc = outcome.toolCalls[index] ?? ToolCallAccumulator()
                        if let id = delta.id, !id.isEmpty { acc.id = id }
                        if let name = delta.function?.name, !name.isEmpty {
                            acc.name += name
                        }
                        if let arguments = delta.function?.arguments, !arguments.isEmpty {
                            acc.arguments += arguments
                        }
                        outcome.toolCalls[index] = acc
                    }
                }
            } catch {
                // Skip malformed chunks (keep-alive / metadata).
                continue
            }
        }

        return outcome
    }


    // MARK: - Streaming chat completion

    /// Streams a chat completion for the given profile and message history.
    ///
    /// - Parameters:
    ///   - config: Relay profile to use.
    ///   - model: Model identifier to chat with.
    ///   - messages: Full message history (text + optional image attachments).
    /// - Returns: An `AsyncThrowingStream` yielding incremental text deltas.
    ///
    /// The stream completes gracefully on `data: [DONE]` (or when the HTTP
    /// body ends — some relays omit the DONE marker) and propagates HTTP /
    /// decoding / cancellation errors to the consumer.
    func streamChat(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage],
        usageHandler: ((StreamUsage) -> Void)? = nil,
        reasoningHandler: ((String) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.transport("No model selected.")
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Deterministic body: field order is fixed by the Codable structs so
        // identical payloads produce byte-identical requests → cloud cache works.
        let payload = ChatPayload(
            model: model,
            messages: await Self.payloadMessages(from: messages, model: model),
            stream: true
        )

        do {
            request.httpBody = try chatPayloadEncoder.encode(payload)
        } catch {
            throw OpenAIServiceError.transport(
                "Failed to encode request body: \(error.localizedDescription)"
            )
        }

        return AsyncThrowingStream { continuation in
            // Run network work in a child task so the stream is returned
            // to the caller immediately.
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAIServiceError.transport("Invalid HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count > 8192 { break }
                        }
                        throw OpenAIServiceError.httpError(
                            statusCode: http.statusCode,
                            message: Self.decodeErrorMessage(from: errorData)
                        )
                    }

                    var yieldedAnyContent = false
                    var accumulatedReasoning = ""

                    for try await line in bytes.lines {
                        // Honour cancellation while streaming.
                        try Task.checkCancellation()

                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }
                        guard trimmed.hasPrefix("data:") else { continue }

                        let payload = String(trimmed.dropFirst("data:".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        // Graceful termination marker (with tolerance to
                        // relays that append extra whitespace / casing).
                        if payload == "[DONE]" || payload.uppercased().contains("[DONE]") {
                            break
                        }

                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        do {
                            let chunk = try JSONDecoder().decode(StreamChunk.self, from: chunkData)
                            if let u = chunk.usage,
                               let hit = u.prompt_cache_hit_tokens,
                               let miss = u.prompt_cache_miss_tokens {
                                usageHandler?(StreamUsage(
                                    promptTokens: u.prompt_tokens,
                                    completionTokens: u.completion_tokens,
                                    cacheHitTokens: hit,
                                    cacheMissTokens: miss
                                ))
                            }
                            if let delta = chunk.contentDelta, !delta.isEmpty {
                                yieldedAnyContent = true
                                continuation.yield(delta)
                            }
                            if let r = chunk.reasoningDelta, !r.isEmpty {
                                accumulatedReasoning += r
                            }
                        } catch {
                            // Skip malformed chunks (keep-alive / metadata).
                            continue
                        }
                    }

                    if !yieldedAnyContent {
                        throw OpenAIServiceError.emptyStream
                    }
                    // Hand the reasoning text (DeepSeek) to the caller for
                    // persistence / next-request pass-back.
                    if !accumulatedReasoning.isEmpty {
                        reasoningHandler?(accumulatedReasoning)
                    }
                    continuation.finish()

                } catch let error as URLError where error.code == .cancelled {
                    // User cancelled streaming — treat as a clean finish.
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport("Request timed out.")
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as OpenAIServiceError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport(error.localizedDescription)
                    )
                }
            }

            // When the consumer stops iterating, cancel the network work.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Non-streaming chat completion

    /// Sends a chat completion with `stream: false` and returns the full text
    /// once. Used when the user disables streaming in a profile.
    func chatOnce(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.transport("No model selected.")
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Deterministic body with `enable_thinking: false` for non-streaming
        // DeepSeek-reasoner-compatible relays (thinking needs streaming).
        let payload = ChatPayload(
            model: model,
            messages: await Self.payloadMessages(from: messages, model: model),
            stream: false,
            enable_thinking: false
        )

        do {
            request.httpBody = try chatPayloadEncoder.encode(payload)
        } catch {
            throw OpenAIServiceError.transport("Failed to encode body: \(error.localizedDescription)")
        }

        // Decode a full (non-stream) completion response.
        struct CompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message?
            }
            let choices: [Choice]?
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAIServiceError.transport("Request timed out.")
        } catch {
            throw OpenAIServiceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.transport("Invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIServiceError.httpError(
                statusCode: http.statusCode,
                message: Self.decodeErrorMessage(from: data)
            )
        }

        do {
            let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
            if let content = decoded.choices?.first?.message?.content, !content.isEmpty {
                return content
            }
            throw OpenAIServiceError.emptyStream
        } catch let error as OpenAIServiceError {
            throw error
        } catch {
            throw OpenAIServiceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Extracts a human-readable message from a non-2xx JSON error body.
    private static func decodeErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "Unknown server error."
    }
}