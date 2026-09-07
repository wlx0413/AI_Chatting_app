import Foundation

/// Persists knowledge blocks (named bundles of user/org facts) using
/// `UserDefaults`, mirroring the `SessionStore` pattern.
final class PersonalizationStore: ObservableObject {

    // MARK: - Constants

    /// `UserDefaults` key encoding all personalization blocks.
    private static let blocksKey = "personalizationBlocks"

    // MARK: - Published state

    /// All personalization blocks, most-recently-created first.
    @Published var blocks: [PersonalizationBlock] {
        didSet { persist() }
    }

    // MARK: - Initializers

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.blocksKey),
           let decoded = try? JSONDecoder().decode([PersonalizationBlock].self, from: data) {
            self.blocks = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            self.blocks = []
        }
    }

    // MARK: - Accessors

    /// The block with the exact given name (used by the fetch tool).
    func block(named name: String) -> PersonalizationBlock? {
        blocks.first { $0.name == name }
    }

    /// All block names (used to build the tool's "available" hint).
    func names() -> [String] {
        blocks.map { $0.name }
    }

    /// `true` when at least one block exists (drives whether the fetch tool is
    /// advertised to the model).
    var hasBlocks: Bool { !blocks.isEmpty }

    // MARK: - Mutations

    /// Adds (or replaces a block with the same name) and persists.
    func upsert(_ block: PersonalizationBlock) {
        blocks.removeAll { $0.name == block.name }
        blocks.insert(block, at: 0)
    }

    /// Deletes a block by id and persists.
    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(blocks) else { return }
        UserDefaults.standard.set(data, forKey: Self.blocksKey)
        UserDefaults.standard.synchronize()
    }
}
