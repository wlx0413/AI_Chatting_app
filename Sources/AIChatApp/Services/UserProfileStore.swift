import Foundation

/// A single learned or manually-added user preference.
struct UserPreference: Identifiable, Codable, Hashable {
    /// Stable id.
    var id: UUID

    /// Category/tag, e.g. "language", "tone", "topic", "location".
    var category: String

    /// The actual preference value, e.g. "简洁中文", "Python", "深度技术分析".
    var value: String

    init(id: UUID = UUID(), category: String = "", value: String = "") {
        self.id = id
        self.category = category
        self.value = value
    }
}

/// Parsed profile changes from a `<!-- PERSONALIZATION: ... -->` marker.
///
/// The model can request two kinds of changes:
/// - **upsert**: add or update a preference (matched by category+value).
/// - **remove**: delete every preference with the given category.
struct ProfileChanges {
    /// Preferences to add/update.
    var upserts: [UserPreference]

    /// Category names to remove (all matching preferences are deleted).
    var removes: [String]

    /// `true` when there is nothing to apply.
    var isEmpty: Bool {
        upserts.isEmpty && removes.isEmpty
    }
}

/// Persists the user's learned/edited profile (preferences) in `UserDefaults`,
/// and provides helpers to encode/decode it into the system prompt payload.
final class UserProfileStore: ObservableObject {

    // MARK: - Constants

    private static let key = "userProfile.preferences.v1"

    // MARK: - Published state

    /// All known preferences.
    @Published var preferences: [UserPreference] {
        didSet { persist() }
    }

    // MARK: - Initializers

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([UserPreference].self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = []
        }
    }

    // MARK: - CRUD

    /// Adds or updates a preference (matched by category+value).
    func upsert(category: String, value: String) {
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, !value.isEmpty else { return }

        if let idx = preferences.firstIndex(where: { $0.category == category && $0.value == value }) {
            preferences[idx].value = value
            return
        }
        preferences.append(UserPreference(category: category, value: value))
    }

    /// Removes a single preference.
    func remove(_ preference: UserPreference) {
        preferences.removeAll { $0.id == preference.id }
    }

    /// Removes every preference whose category matches (case-insensitive).
    func removeAll(category: String) {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        preferences.removeAll { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
    }

    /// Replaces the whole set (used when parsing a batch from the model).
    func replaceAll(with new: [UserPreference]) {
        preferences = new
    }

    // MARK: - Encoding for the prompt

    /// JSON snapshot of all preferences (or nil when empty).
    ///
    /// `.sortedKeys` makes the serialization deterministic: Swift Dictionary
    /// hash order is random per construction, so without it every request
    /// would send a slightly different profile JSON and break DeepSeek's
    /// byte-identical prefix cache.
    var jsonPayload: String? {
        guard !preferences.isEmpty else { return nil }

        let payload: [[String: String]] = preferences.map {
            ["category": $0.category, "value": $0.value]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ),
        let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// Deterministic fingerprint of the current profile payload (FNV-1a 64-bit).
    ///
    /// The profile message sits at index 1 of every request's byte-identical
    /// cache prefix, so ANY change to it invalidates the cache for the whole
    /// conversation history that follows. This fingerprint lets the UI detect
    /// the change and explain the resulting hit-rate drop instead of leaving it
    /// as a mysterious "why is my cache at 20%".
    var payloadHash: String {
        let json = jsonPayload ?? "nil"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in json.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Parses a `<!-- PERSONALIZATION: {...} -->` block from an assistant reply.
    ///
    /// Supported payload shapes:
    /// ```
    /// {"preferences":[{"category":"language","value":"Chinese"}]}          // upsert
    /// {"preferences":[{"op":"upsert","category":"tone","value":"formal"}]} // upsert (explicit)
    /// {"preferences":[{"op":"remove","category":"location"}]}              // remove by category
    /// ```
    ///
    /// - `op` is optional and defaults to `"upsert"`.
    /// - `"remove"` entries match by category (case-insensitive) and ignore value.
    ///
    /// Returns `nil` when the marker is absent or nothing usable is found.
    static func parse(from reply: String) -> ProfileChanges? {
        // Locate ANY marker: <!-- PERSONALIZATION: ... -->.
        // The model may place it at the start (leading instruction),
        // in the middle, or at the end of the reply.
        guard let lowerBound = reply.range(of: "<!-- PERSONALIZATION:") else { return nil }
        let afterWrapper = reply[lowerBound.upperBound...]
        guard let endOfBlock = afterWrapper.range(of: "-->") else { return nil }

        let jsonPart = afterWrapper[..<endOfBlock.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The payload may be JSON or JSON inside backticks.
        let cleaned = jsonPart
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = json["preferences"] as? [[String: Any]] else {
            return nil
        }

        var changes = ProfileChanges(upserts: [], removes: [])
        for item in prefs {
            guard let category = item["category"] as? String,
                  !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Operation: explicit "op" field, defaults to "upsert".
            let op = (item["op"] as? String)?.lowercased() ?? "upsert"

            if op == "remove" {
                changes.removes.append(category)
                continue
            }

            // Upsert: category + value required.
            guard let value = item["value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            changes.upserts.append(UserPreference(category: category, value: value))
        }
        return changes.isEmpty ? nil : changes
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
    }
}