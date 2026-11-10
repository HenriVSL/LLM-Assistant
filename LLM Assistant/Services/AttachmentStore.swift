//
//  AttachmentStore.swift
//  LLM Assistant
//
//  Stores image attachments on disk (Documents/images) and resolves their
//  filenames back to file URLs for display and model input.
//

import Foundation

enum AttachmentStore {
    /// Directory holding attached images (created on demand).
    static var directory: URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves image data and returns the stored filename (nil on failure).
    static func save(_ data: Data, ext: String = "jpg") -> String? {
        let name = UUID().uuidString + "." + ext
        do {
            try data.write(to: directory.appending(path: name))
            return name
        } catch {
            return nil
        }
    }

    /// Resolves a stored filename back to its file URL.
    static func url(for name: String) -> URL {
        directory.appending(path: name)
    }
}
