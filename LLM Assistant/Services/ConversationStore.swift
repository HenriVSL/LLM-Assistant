//
//  ConversationStore.swift
//  LLM Assistant
//
//  Persists the single continuous conversation to a JSON file in the app's
//  Documents directory. Everything stays on-device.
//

import Foundation

/// Loads and saves the whole conversation as one JSON file.
struct ConversationStore {
    /// Location of the conversation file: <Documents>/conversation.json
    private let fileURL: URL

    init(filename: String = "conversation.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documents.appending(path: filename)
    }

    /// Loads the saved conversation, or an empty array if none exists yet.
    func load() -> [Message] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([Message].self, from: data)
        } catch {
            // Corrupt or incompatible file: start fresh rather than crash.
            return []
        }
    }

    /// Writes the full conversation to disk atomically.
    func save(_ messages: [Message]) {
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Persistence is best-effort; a failed write shouldn't break the chat.
            print("ConversationStore: failed to save — \(error)")
        }
    }
}
