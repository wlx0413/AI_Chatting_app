import Foundation

/// Helpers for identifying multimodal (vision-capable) models from a relay's
/// model list. Kept heuristic on purpose — different relays name models
/// differently, so we pattern-match on common vision suffixes / prefixes.
enum MultimodalSupport {

    /// Model-name substrings that strongly imply vision capability.
    private static let visionKeywords: [String] = [
        "gpt-4o",          // OpenAI GPT-4o (all variants are vision)
        "gpt-4.1",         // OpenAI GPT-4.1 / mini (vision)
        "gpt-4-turbo",     // OpenAI GPT-4 Turbo with vision
        "gpt-4v",          // Legacy OpenAI GPT-4V
        "claude-3-5",      // Anthropic Sonnet/Opus/Haiku (vision)
        "claude-3",        // Anthropic Claude 3 family (vision)
        "claude-3.7",      // Anthropic Claude 3.7 (vision)
        "gemini-1.5",      // Google Gemini 1.5 Pro/Flash (vision)
        "gemini-1.0",      // Google Gemini 1.0 Pro (vision)
        "gemini-2.0",      // Google Gemini 2.0 Flash (vision)
        "gemini-2.5",      // Google Gemini 2.5 (vision)
        "llava",           // LLaVA open models
        "qwen-vl",         // Qwen-VL vision models
        "qwen2-vl",        // Qwen2-VL
        "phi-3-vision",    // Microsoft Phi-3 Vision
        "phi-4-multimodal", // Microsoft Phi-4 multimodal
        "internvl",        // InternVL
        "glm-4v",          // Zhipu GLM-4V
        "minicpm-v",       // MiniCPM-V
        "moondream",       // Moondream
        "fuyu",            // Adept Fuyu
        "cogvlm",          // CogVLM
        "deepseek-vl",     // DeepSeek-VL
        "vision"           // catch-all (e.g. "vision-2", "xxx-vision")
    ]

    /// Returns `true` if the model id is (probably) multimodal.
    static func isMultimodal(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return visionKeywords.contains { lower.contains($0) }
    }

    /// Returns a display label: multimodal models get a subtle `photo` marker
    /// rendered by the UI (see the model pickers) — this just returns the name
    /// so the UI can compose an icon + name. Kept for callers that want a plain
    /// string (e.g. menus); no emoji is embedded.
    static func displayName(_ modelID: String) -> String {
        modelID
    }
}