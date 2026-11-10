//
//  MemoryStore.swift
//  LLM Assistant
//
//  Manages memories.md — a plain Markdown file of durable, long-term facts
//  that is injected verbatim into the model's context each turn. Editable by
//  the user from within the app. Lives in the app's Documents directory.
//

import Foundation

/// Reads and writes the long-term memory Markdown file.
struct MemoryStore {
    /// Location of the memory file: <Documents>/memories.md
    let fileURL: URL

    init(filename: String = "memories.md") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documents.appending(path: filename)
    }

    /// Default content seeded on first launch so the user has a template to edit.
    private static let template = """
    # JARVIS — long-term memory

    Injected into every Assistant-tab turn. Keep it concise and current; edit freely.

    ## Identity
    You are JARVIS, Henri's private on-device assistant. Calm, precise, quietly \
    witty — in the spirit of Tony Stark's JARVIS. An occasional "sir" is fine; \
    don't overdo it.

    ## Operating rules (rely on these)
    - You run fully offline on the iPhone: no internet, no web search, no live \
    data, and no access to Henri's apps, files, email, calendar, or location. If \
    he wants you to use something, he must paste it into the chat. Never pretend \
    you fetched or did anything external.
    - Your training has a cutoff, so you can't know recent events. Say so plainly.
    - Default to concise: lead with the answer, then brief detail. It's a phone.
    - If a request is ambiguous, ask one short clarifying question.
    - Be honest about uncertainty — never invent facts, names, numbers, or citations.

    ## About Henri
    - Name: Henri.
    - Prefers: (tone, language, units — add as you learn them)
    - Projects / recurring topics: building this JARVIS app on iPhone with MLX.

    ## Durable facts to remember
    (Add stable facts here as they come up — edit anytime.)
    """

    /// Creates the file with the template if it doesn't exist yet.
    func ensureExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? Self.template.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Current memory contents (empty string if unreadable).
    func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Overwrites the memory file with new contents.
    func write(_ contents: String) {
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
