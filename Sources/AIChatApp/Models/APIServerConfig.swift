import Foundation

/// Price for one model as reported by the relay (OpenRouter-style extension).
///
/// Many OpenAI-compatible relays (one-api / new-api / OpenRouter format)
/// include a `pricing` object on each model entry in `GET /v1/models`:
///   {"id":"gpt-4o-mini","pricing":{"prompt":0.15,"completion":0.6}}
/// OpenRouter-style relays additionally report `prompt_cache_read`, the
/// per-token price for input served from the prompt cache (DeepSeek exposes
/// the same cache-hit economics). Units are USD per 1M tokens.
struct ModelPrice: Codable, Hashable {
    /// USD per 1M input (prompt) tokens.
    var prompt: Double

    /// USD per 1M output (completion) tokens.
    var completion: Double

    /// USD per 1M cached-input tokens (`prompt_cache_read`); nil when the
    /// relay does not expose a cached rate.
    var cachedInput: Double?

    enum CodingKeys: String, CodingKey {
        case prompt
        case completion
        case cachedInput = "prompt_cache_read"
    }

    /// Whether the required prices are non-negative (sane).
    var isValid: Bool {
        prompt >= 0 && completion >= 0
    }
}

/// User-defined manual prices (USD per 1M tokens) for a profile.
///
/// Takes priority over relay-provided dynamic prices and the built-in price
/// table, so users can fill in prices for relays that do not expose
/// `pricing` on `GET /v1/models`.
struct CustomPrice: Codable, Hashable {

    /// USD per 1M input (prompt) tokens.
    var input: Double

    /// USD per 1M output (completion) tokens.
    var output: Double

    /// USD per 1M **cached** input tokens (optional; e.g. OpenRouter
    /// `prompt_cache_read`). When set, the cost estimate shows a second,
    /// cheaper figure assuming the whole input prefix hits the cache.
    var cachedInput: Double?

    /// Whether the required prices are non-negative (sane).
    var isValid: Bool {
        input >= 0 && output >= 0
    }
}

/// Represents a single OpenAI-compatible API relay server profile.
///
/// Stored in `UserDefaults` as JSON, so it conforms to `Codable` and
/// `Hashable`. It is identified by a stable `UUID`.
struct APIServerConfig: Identifiable, Codable, Hashable {

    // MARK: - Stored properties

    /// Stable identifier for this profile.
    var id: UUID

    /// Human-readable name for the profile (e.g. "Company Relay").
    var name: String

    /// The relay server root URL (e.g. `https://api.example.com`).
    ///
    /// The service layer normalizes trailing slashes and the `/v1` suffix.
    var baseURL: String

    /// Bearer token used to authenticate requests (`Authorization: Bearer ...`).
    var apiKey: String

    /// The model currently selected for this profile (e.g. `gpt-4o-mini`).
    var selectedModel: String

    /// Models reported by the relay's `GET /v1/models` endpoint.
    var availableModels: [String]

    /// Dynamic prices fetched from the relay (keyed by model id).
    /// Empty when the relay does not expose `pricing`.
    var modelPrices: [String: ModelPrice]

    /// Editable system prompt. Sent as the first `system` message on every
    /// request. The default preset tells the model Markdown is rendered.
    var systemPrompt: String

    /// Whether replies stream token-by-token (true) or return as a single
    /// response (false). Toggleable per profile.
    var streamEnabled: Bool

    /// Whether the current date/time is attached to the system prompt so the
    /// model is aware of "now" (time of day / day of week / date).
    var includeTimestamp: Bool

    /// Opt-in: expose the `compile_latex` tool (Agent mode) so the model can
    /// write a .tex file and compile it to PDF with the LOCAL TeX install.
    /// Also requires a detected toolchain — see `LaTeXService.isAvailable`.
    var latexEnabled: Bool

    /// Whether replies stream token-by-token (true) or return as a single
    /// response (false). Toggleable per profile.
    ///
    /// Agent mode (built-in tool calling: web_search / calc / get_time) only
    /// applies when `toolsEnabled` is on. It is **off by default** so normal
    /// chats keep a byte-identical, `tools`-free request body (prompt-cache
    /// friendly) and never break relays that do not support tool calling.
    var toolsEnabled: Bool

    /// User-defined manual prices (input / output / cached-input). Takes
    /// priority over relay dynamic prices and the built-in price table.
    var customPrice: CustomPrice?

    /// Multi-line text editor in settings; the default value helps the model
    /// produce nicely formatted Markdown the app will render.
    static let defaultSystemPrompt = """
    You are a helpful AI assistant.

    IMPORTANT: Always answer using Markdown formatting — headings, bold, \
    italic, bullet lists, numbered lists, code blocks (with language tags), \
    tables, and links. The user's app renders Markdown, so the better you \
    format, the clearer your answer.

    PERSONALIZATION: You know the user's profile prefs (KNOWLEDGE ABOUT THE USER) \
    and the user's current message. When the user clearly states a NEW preference \
    or characteristic (e.g. "I am left-handed", "I prefer short explanations", \
    "I live in Shanghai"), include an invisible note in your reply using EXACTLY \
    this format (a single line, no extra text):

    <!-- PERSONALIZATION: {"preferences": [{"category": "topic", "value": "..."}]} -->

    You may place the note AT THE VERY START of your reply (before the visible \
    answer) OR at the very end — both are detected and stripped automatically. \
    Emit it as soon as you know the preference; do not wait until the end, and \
    do not forget to emit it before your final message ends.

    Match your words' meaning, and use categories like: topic, language, \
    tone, format, location, accessibility, domain, tooling. Do NOT include \
    preferences the user has not actually stated. If nothing new was stated, \
    omit the note entirely.

    To DELETE an outdated preference, use "op": "remove" and the matching category:
    <!-- PERSONALIZATION: {"preferences": [{"op": "remove", "category": "location"}]} -->

    To UPDATE an existing preference, just send the same category with the new value:
    <!-- PERSONALIZATION: {"preferences": [{"category": "language", "value": "English"}]} -->

    TIME: The newest USER message may carry a leading timestamp in square \
    brackets, e.g. "[2026-08-19 01:02:03] ...". It is injected by the app \
    itself and represents the current time. Never fabricate, guess, or invent \
    a time — always treat the provided timestamp as ground truth.
    """

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        selectedModel: String = "",
        availableModels: [String] = [],
        modelPrices: [String: ModelPrice] = [:],
        systemPrompt: String = APIServerConfig.defaultSystemPrompt,
        streamEnabled: Bool = true,
        includeTimestamp: Bool = false,
        latexEnabled: Bool = false,
        toolsEnabled: Bool = false,
        customPrice: CustomPrice? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.modelPrices = modelPrices
        self.systemPrompt = systemPrompt
        self.streamEnabled = streamEnabled
        self.includeTimestamp = includeTimestamp
        self.latexEnabled = latexEnabled
        self.toolsEnabled = toolsEnabled
        self.customPrice = customPrice
    }

    /// A friendly display name for UI lists.
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unnamed profile"
            : name
    }

    // MARK: - Codable

    /// Custom decoding so profiles persisted before these fields existed
    /// still decode correctly with sensible defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        availableModels = try container.decode([String].self, forKey: .availableModels)
        modelPrices = try container.decodeIfPresent([String: ModelPrice].self, forKey: .modelPrices) ?? [:]
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? APIServerConfig.defaultSystemPrompt
        streamEnabled = try container.decodeIfPresent(Bool.self, forKey: .streamEnabled) ?? true
        // Cache-optimization: timestamps break DeepSeek's byte-identical prefix
        // matching (hit rate collapses to ~5%), so they default OFF.
        includeTimestamp = try container.decodeIfPresent(Bool.self, forKey: .includeTimestamp) ?? false
        latexEnabled = try container.decodeIfPresent(Bool.self, forKey: .latexEnabled) ?? false
        toolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? false
        customPrice = try container.decodeIfPresent(CustomPrice.self, forKey: .customPrice)
    }
}
