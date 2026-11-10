//
//  Message.swift
//  LLM Assistant
//
//  A single chat message in one conversation. Value type so it is trivially
//  Codable for on-device persistence and cheap to mutate during streaming.
//

import Foundation

/// The author of a message.
enum Role: String, Codable {
    case system
    case user
    case assistant
}

/// One message in the conversation.
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    /// Filenames of attached images (stored via `AttachmentStore`).
    var imagePaths: [String]

    init(
        id: UUID = UUID(), role: Role, content: String,
        timestamp: Date = .now, imagePaths: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.imagePaths = imagePaths
    }

    // Backward-compatible decoding: older saved messages have no imagePaths.
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, imagePaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
    }

    /// Attached images resolved to file URLs.
    var imageURLs: [URL] { imagePaths.map { AttachmentStore.url(for: $0) } }
}

extension Message {
    static func user(_ content: String, imagePaths: [String] = []) -> Message {
        Message(role: .user, content: content, imagePaths: imagePaths)
    }
    static func assistant(_ content: String) -> Message {
        Message(role: .assistant, content: content)
    }
    static func system(_ content: String) -> Message {
        Message(role: .system, content: content)
    }
}
