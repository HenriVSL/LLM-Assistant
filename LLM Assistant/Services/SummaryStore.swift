//
//  SummaryStore.swift
//  LLM Assistant
//
//  Persists the rolling-summary state: a running summary of older messages plus
//  how many leading messages it covers. Kept in the app's Documents directory.
//

import Foundation

/// Rolling-summary state persisted between launches.
struct SummaryState: Codable {
    /// Condensed summary of the messages before `coveredCount`.
    var summary: String = ""
    /// Number of leading conversation messages folded into `summary`.
    var coveredCount: Int = 0
}

/// Loads and saves the rolling-summary state as one JSON file.
struct SummaryStore {
    private let fileURL: URL

    init(filename: String = "summary.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documents.appending(path: filename)
    }

    func load() -> SummaryState {
        guard let data = try? Data(contentsOf: fileURL),
            let state = try? JSONDecoder().decode(SummaryState.self, from: data)
        else { return SummaryState() }
        return state
    }

    func save(_ state: SummaryState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}
