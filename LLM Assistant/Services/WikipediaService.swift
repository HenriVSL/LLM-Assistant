//
//  WikipediaService.swift
//  LLM Assistant
//
//  Looks up a topic on Wikipedia (open API, no key). Only the topic string
//  leaves the device — sent to the Wikimedia Foundation. Returns a concise
//  intro extract to inject into the model's context.
//

import Foundation

struct WikiResult {
    let title: String
    let extract: String
    let url: String
}

enum WikipediaError: LocalizedError {
    case notFound
    var errorDescription: String? {
        switch self {
        case .notFound: return "No matching Wikipedia article."
        }
    }
}

struct WikipediaService {
    private let session: URLSession
    // Wikimedia asks clients to identify themselves; generic agents get blocked.
    private let userAgent = "LLM-Assistant-iOS/1.0 (https://github.com/HenriVSL/LLM-Assistant)"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    private func getData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Full lookup: search for the best article, then fetch its entire plain-text
    /// body (no truncation — relies on the model's large context window).
    func lookup(query: String) async throws -> WikiResult {
        let title = try await bestTitle(for: query)
        return try await article(title: title)
    }

    private func bestTitle(for query: String) async throws -> String {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query),
            .init(name: "srlimit", value: "1"),
            .init(name: "format", value: "json"),
        ]
        let data = try await getData(comps.url!)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let first = decoded.query.search.first else { throw WikipediaError.notFound }
        return first.title
    }

    private func article(title: String) async throws -> WikiResult {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "prop", value: "extracts"),
            .init(name: "explaintext", value: "1"),
            .init(name: "exsectionformat", value: "plain"),
            .init(name: "redirects", value: "1"),
            .init(name: "titles", value: title),
            .init(name: "format", value: "json"),
        ]
        let data = try await getData(comps.url!)
        let decoded = try JSONDecoder().decode(ExtractResponse.self, from: data)
        guard let page = decoded.query.pages.values.first,
            let extract = page.extract, !extract.isEmpty
        else { throw WikipediaError.notFound }

        // Feed the full article — Qwen3's 40K-token context fits any single one.
        let path =
            page.title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return WikiResult(
            title: page.title, extract: extract,
            url: "https://en.wikipedia.org/wiki/\(path)")
    }

    // MARK: Decodables

    private struct SearchResponse: Decodable {
        struct Query: Decodable { let search: [Hit] }
        struct Hit: Decodable { let title: String }
        let query: Query
    }

    private struct ExtractResponse: Decodable {
        struct Query: Decodable { let pages: [String: Page] }
        struct Page: Decodable {
            let title: String
            let extract: String?
        }
        let query: Query
    }
}
