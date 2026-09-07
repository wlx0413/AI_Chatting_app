import Foundation

/// Persists chat sessions (title + full message history) using `UserDefaults`
/// with a JSON-encoded array.
final class SessionStore: ObservableObject {

    // MARK: - Constants

    /// `UserDefaults` key encoding all sessions.
    private static let sessionsKey = "chatSessions"

    /// `UserDefaults` key recording the selected session UUID string.
    private static let activeIDKey = "activeSessionID"

    // MARK: - Published state

    /// When true, persist() is a no-op. Set while the streaming pipeline
    /// repeatedly updates the assistant message so we don't JSON-encode +
    /// disk-write on every 50–100 ms flush (which stalls the main thread).
    var persistPaused = false

    /// All saved sessions, most-recently-created first.
    @Published var sessions: [ChatSession] {
        didSet { persist() }
    }

    /// The session currently open in the chat view.
    @Published var activeSessionID: UUID? {
        didSet {
            UserDefaults.standard.set(
                activeSessionID?.uuidString,
                forKey: Self.activeIDKey
            )
        }
    }

    /// Convenience accessor for the active session object.
    var activeSession: ChatSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Initializers

    init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.sessionsKey),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            // Sort newest first by creation date.
            self.sessions = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            self.sessions = []
        }

        if let stored = defaults.string(forKey: Self.activeIDKey),
           let id = UUID(uuidString: stored),
           self.sessions.contains(where: { $0.id == id }) {
            self.activeSessionID = id
        } else {
            self.activeSessionID = self.sessions.first?.id
        }
    }

    // MARK: - Session management

    /// Creates a new empty session and makes it active.
    @discardableResult
    func newSession() -> ChatSession {
        let session = ChatSession()
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        return session
    }

    /// Creates a new personalization-collection session (dedicated collector prompt,
    /// can be turned into a personalization block) and makes it active.
    @discardableResult
    func newPersonalizationCollectionSession() -> ChatSession {
        let session = ChatSession(
            title: "个性化块采集",
            isPersonalizationCollection: true
        )
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        return session
    }

    /// Deletes a session (by id).
    func delete(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }

        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    /// Deletes all sessions.
    func deleteAll() {
        sessions.removeAll()
        activeSessionID = nil
    }

    /// Replaces the entire session list (used when importing a backup).
    func replaceAll(with new: [ChatSession]) {
        cancelPersistPause()
        sessions = new.sorted { $0.createdAt > $1.createdAt }
        activeSessionID = sessions.first?.id
        persistPaused = false
    }

    /// Cancels any active persistence pause and forces a write.
    private func cancelPersistPause() {
        persistPaused = false
    }

    /// Appends a message to the given session and persists it.
    func appendMessage(_ message: ChatMessage, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].autoTitle()
    }

    /// Applies AI-chosen session metadata (first-round `set_session_metadata`
    /// tool): a short title and/or an emoji shown in the sidebar.
    func updateSessionMetadata(emoji: String?, title: String?, in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let emoji, !emoji.isEmpty {
            sessions[index].emoji = emoji
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[index].title = title
        }
    }

    /// Updates the content of the last assistant message in a session.
    ///
    /// Used by the streaming pipeline to accumulate deltas into the
    /// in-flight assistant reply.
    func updateLastAssistantContent(_ content: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].content = content
    }

    /// Attaches source references to the last assistant message in a session
    /// (web tools' URLs rendered as the "Sources" card under the reply).
    func updateLastAssistantSources(_ sources: [ChatSource], in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].sources = sources
    }

    /// Records the model that produced the last assistant message (info popover).
    func updateLastAssistantModel(_ model: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].model = model
    }

    /// Records the relay-reported token usage for the last assistant message.
    func updateLastAssistantUsage(_ usage: MessageUsage, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].usage = usage
    }

    /// Records the tool-call flow executed while producing the last assistant
    /// message (Agent mode / get_time), for the message-info popover.
    func updateLastAssistantToolFlow(_ flow: [MessageToolCallRecord], in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].toolFlow = flow
    }

    /// Records the DeepSeek `reasoning_content` ("thinking") of the last
    /// assistant message so the next request can pass it back (required by
    /// DeepSeek reasoning models for tool-call rounds).
    func updateLastAssistantReasoning(_ reasoning: String, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant else {
            return
        }
        sessions[sessionIndex].messages[msgIndex].reasoningContent = reasoning
    }

    /// Deletes a single message (by id) from the given session.
    func deleteMessage(_ message: ChatMessage, in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.removeAll { $0.id == message.id }
    }

    /// Removes a partially-received assistant message (used when a stream fails
    /// before yielding anything useful).
    func removeLastAssistantMessage(in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[sessionIndex].messages.indices.last,
              sessions[sessionIndex].messages[msgIndex].role == .assistant,
              sessions[sessionIndex].messages[msgIndex].content.isEmpty else {
            return
        }
        sessions[sessionIndex].messages.remove(at: msgIndex)
    }

    // MARK: - Persistence

    private func persist() {
        guard !persistPaused else { return }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.sessionsKey)
        // Synchronous flush so chats survive an immediate quit / power loss.
        defaults.synchronize()
    }

    /// Writes once even if persistence was paused (called when streaming ends).
    func forcePersist() {
        persistPaused = false
        persist()
    }
}
