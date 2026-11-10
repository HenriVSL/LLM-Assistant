//
//  ChatViewModel.swift
//  LLM Assistant
//
//  Coordinates one conversation tab: user input, streaming generation,
//  persistence, optional long-term memory + rolling summarization, optional
//  image input, and per-tab generation settings. Two instances back the
//  Assistant (text) and Vision (gemma4) tabs, sharing one MLXService.
//

import Foundation
import MLXLMCommon
import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    // MARK: Configuration (fixed per tab)

    let title: String
    /// Whether this tab offers image attachments (vision models).
    let supportsImages: Bool
    /// Whether this tab injects memories.md into context.
    let useMemory: Bool
    /// Which models this tab offers (text vs vision).
    private let modelType: LMModel.ModelType

    // MARK: Dependencies

    private let mlxService: MLXService
    private let conversationStore: ConversationStore
    private let memoryStore: MemoryStore
    /// Present only when this tab uses rolling summarization.
    private let summaryStore: SummaryStore?
    private let wikipedia = WikipediaService()

    // MARK: State

    private(set) var messages: [Message] = []
    var prompt: String = ""

    /// Filename (in AttachmentStore) of an image staged for the next message.
    private(set) var attachedImageName: String?

    var selectedModel: LMModel {
        didSet { UserDefaults.standard.set(selectedModel.name, forKey: modelKey) }
    }

    private(set) var isGenerating = false
    private(set) var isSummarizing = false
    var errorMessage: String?
    private(set) var tokensPerSecond: Double = 0
    /// Transient status shown while the assistant is working but hasn't produced
    /// visible text yet (e.g. "Searching Wikipedia…", "Reading the article…").
    /// Nil falls back to the generic "Thinking…" placeholder.
    private(set) var statusText: String?

    // Generation settings (persisted per tab).
    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: temperatureKey) }
    }
    var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: maxTokensKey) }
    }

    // Rolling-summary state.
    private var summary: String = ""
    private var summarizedCount: Int = 0

    // MARK: Config constants

    private let systemPrompt = """
    You are JARVIS — the user's private AI assistant, running entirely on his \
    iPhone: fully offline, on-device, and for him alone. His name is Henri. Be \
    concise, precise, and quietly witty, in the spirit of Tony Stark's JARVIS. \
    You have no internet, no web search, and no access to his apps, files, \
    location, or live data — never claim otherwise; say plainly what you can't \
    reach. Be honest when you're unsure rather than inventing facts.
    """
    private let keepRecent = 12
    private let summarizeBatch = 8
    /// Verbatim window when summarization is off (e.g. the Vision tab).
    private let plainWindow = 10

    private let modelKey: String
    private let temperatureKey: String
    private let maxTokensKey: String

    // MARK: Init

    init(
        mlxService: MLXService,
        title: String,
        conversationFile: String,
        summaryFile: String?,
        useMemory: Bool,
        supportsImages: Bool,
        modelType: LMModel.ModelType,
        defaultModelName: String,
        settingsKey: String
    ) {
        self.mlxService = mlxService
        self.title = title
        self.useMemory = useMemory
        self.supportsImages = supportsImages
        self.modelType = modelType
        self.conversationStore = ConversationStore(filename: conversationFile)
        self.memoryStore = MemoryStore()
        self.summaryStore = summaryFile.map { SummaryStore(filename: $0) }

        self.modelKey = settingsKey + ".model"
        self.temperatureKey = settingsKey + ".temperature"
        self.maxTokensKey = settingsKey + ".maxTokens"

        let defaults = UserDefaults.standard
        let candidates = MLXService.availableModels.filter { $0.type == modelType }
        let savedName = defaults.string(forKey: settingsKey + ".model")
        self.selectedModel =
            candidates.first { $0.name == savedName }
            ?? candidates.first { $0.name == defaultModelName }
            ?? candidates.first
            ?? MLXService.availableModels[0]

        self.temperature = defaults.object(forKey: settingsKey + ".temperature") as? Double ?? 0.7
        self.maxTokens = defaults.object(forKey: settingsKey + ".maxTokens") as? Int ?? 2048

        if useMemory { memoryStore.ensureExists() }
        self.messages = conversationStore.load()

        if let state = summaryStore?.load() {
            self.summary = state.summary
            self.summarizedCount = min(state.coveredCount, messages.count)
        }
    }

    // MARK: Passthrough

    var modelDownloadProgress: Progress? { mlxService.modelDownloadProgress }
    var downloadStats: MLXService.DownloadStats? { mlxService.downloadStats }

    func isOnDevice(_ model: LMModel) -> Bool {
        MLXService.localModelDirectory(for: model.configuration.name) != nil
    }

    /// Models for this tab that are present on the device.
    var onDeviceModels: [LMModel] {
        MLXService.availableModels.filter { $0.type == modelType && isOnDevice($0) }
    }

    // MARK: Memory file

    func readMemory() -> String { memoryStore.read() }
    func writeMemory(_ text: String) { memoryStore.write(text) }

    // MARK: Attachments

    func attachImage(_ data: Data) {
        if let old = attachedImageName {  // replace any prior staged image
            try? FileManager.default.removeItem(at: AttachmentStore.url(for: old))
        }
        attachedImageName = AttachmentStore.save(data)
    }

    func clearAttachment() {
        if let name = attachedImageName {
            try? FileManager.default.removeItem(at: AttachmentStore.url(for: name))
        }
        attachedImageName = nil
    }

    // MARK: Generation

    private var generateTask: Task<Void, Never>?

    var canSend: Bool {
        !isGenerating && !isSummarizing
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachedImageName != nil)
    }

    func send() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        // "/wiki <topic>" looks the topic up on Wikipedia and answers from it.
        if let topic = wikiTopic(trimmed) {
            startWikiTurn(topic: topic, raw: trimmed)
            return
        }

        let images = attachedImageName.map { [$0] } ?? []
        prompt = ""
        attachedImageName = nil
        errorMessage = nil
        isGenerating = true

        messages.append(.user(trimmed, imagePaths: images))
        messages.append(.assistant(""))
        let assistantIndex = messages.count - 1
        persist()

        let context = buildContext()
        let model = selectedModel
        let temp = Float(temperature)
        let maxTok = maxTokens

        generateTask = Task {
            var raw = ""
            do {
                for await generation in try await mlxService.generate(
                    messages: context, model: model, temperature: temp, maxTokens: maxTok)
                {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let text):
                        raw += text
                        messages[assistantIndex].content = Self.stripThinking(raw)
                    case .info(let info):
                        tokensPerSecond = info.tokensPerSecond
                    case .toolCall:
                        break
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                messages[assistantIndex].content += "\n\n_[Generation failed]_"
            }

            isGenerating = false
            generateTask = nil
            persist()
            await maybeSummarize()
        }
    }

    func stop() {
        generateTask?.cancel()
        generateTask = nil
        statusText = nil
        if isGenerating, let last = messages.indices.last {
            messages[last].content += "\n\n_[Stopped]_"
        }
        isGenerating = false
        persist()
    }

    func clearConversation() {
        stop()
        messages = []
        summary = ""
        summarizedCount = 0
        persist()
        summaryStore?.save(SummaryState())
    }

    // MARK: Context assembly

    /// System prompt + memories.md + running summary, assembled into one string.
    private func assembledSystem() -> String {
        var system = systemPrompt
        if useMemory {
            let memory = memoryStore.read().trimmingCharacters(in: .whitespacesAndNewlines)
            if !memory.isEmpty {
                system += "\n\n# Long-term memory\n\(memory)"
            }
        }
        if !summary.isEmpty {
            system += "\n\n# Summary of earlier conversation\n\(summary)"
        }
        return system
    }

    private func buildContext() -> [Message] {
        var context: [Message] = [.system(assembledSystem())]
        if summaryStore != nil {
            let start = min(summarizedCount, messages.count)
            context.append(contentsOf: messages[start...])
        } else {
            context.append(contentsOf: messages.suffix(plainWindow))
        }
        return context
    }

    // MARK: Wikipedia lookup (/wiki <topic>)

    /// Rough token count for a text (≈4 chars/token), formatted for display.
    private static func approxTokens(_ text: String) -> String {
        let t = max(1, text.count / 4)
        return t >= 1000 ? String(format: "~%.0fk tokens", Double(t) / 1000) : "~\(t) tokens"
    }

    /// Returns the topic if `text` is a "/wiki <topic>" command, else nil.
    private func wikiTopic(_ text: String) -> String? {
        guard text.lowercased().hasPrefix("/wiki ") else { return nil }
        let topic = String(text.dropFirst("/wiki ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return topic.isEmpty ? nil : topic
    }

    /// Fetches a Wikipedia extract for the topic and has the model answer from it.
    /// The first line after "/wiki" is the search topic; any further lines are
    /// treated as the user's question about it (so they don't pollute the search).
    private func startWikiTurn(topic: String, raw: String) {
        prompt = ""
        attachedImageName = nil
        errorMessage = nil
        isGenerating = true

        let lines = topic.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let searchQuery = lines.first ?? topic
        let question = lines.dropFirst().joined(separator: " ")

        messages.append(.user(raw))
        messages.append(.assistant(""))
        let idx = messages.count - 1
        persist()

        let model = selectedModel
        let temp = Float(temperature)
        let maxTok = maxTokens

        statusText = "Searching Wikipedia…"

        generateTask = Task {
            do {
                let result = try await wikipedia.lookup(query: searchQuery)
                statusText = "Reading “\(result.title)” (\(Self.approxTokens(result.extract)))…"

                let instruction =
                    question.isEmpty
                    ? "Give a concise overview of \"\(result.title)\"."
                    : "Answer this question: \(question)"

                // Single system + single user message keeps every chat template
                // happy (Gemma folds one leading system turn; Qwen is flexible).
                let userContent = """
                Reference from Wikipedia — article "\(result.title)":

                \(result.extract)

                Source: \(result.url)

                ---
                \(instruction) Base your answer only on the reference above, be \
                concise, and note that it's from Wikipedia.
                """
                let context: [Message] = [.system(assembledSystem()), .user(userContent)]

                var acc = ""
                for await generation in try await mlxService.generate(
                    messages: context, model: model, temperature: temp, maxTokens: maxTok)
                {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let text):
                        statusText = nil  // first tokens arrived; show the answer
                        acc += text
                        messages[idx].content = Self.stripThinking(acc)
                    case .info(let info):
                        tokensPerSecond = info.tokensPerSecond
                    case .toolCall:
                        break
                    }
                }
                if !messages[idx].content.isEmpty {
                    messages[idx].content += "\n\n[\(result.title) — Wikipedia](\(result.url))"
                }
            } catch is WikipediaError {
                messages[idx].content = "I couldn't find a Wikipedia article for \"\(topic)\"."
            } catch {
                messages[idx].content = "Wikipedia lookup failed: \(error.localizedDescription)"
            }

            statusText = nil
            isGenerating = false
            generateTask = nil
            persist()
        }
    }

    static func stripThinking(_ s: String) -> String {
        var text = s
        while let start = text.range(of: "<think>"),
            let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex)
        {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let dangling = text.range(of: "<think>") {
            text.removeSubrange(dangling.lowerBound..<text.endIndex)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Rolling summarization (v2)

    private func maybeSummarize() async {
        guard summaryStore != nil else { return }
        guard messages.count - summarizedCount > keepRecent + summarizeBatch else { return }
        let cutoff = messages.count - keepRecent
        let batch = Array(messages[summarizedCount..<cutoff])
        guard !batch.isEmpty else { return }

        isSummarizing = true
        defer { isSummarizing = false }

        let rendered = batch.map { m -> String in
            let who = m.role == .user ? "User" : (m.role == .assistant ? "Assistant" : "System")
            return "\(who): \(m.content)"
        }.joined(separator: "\n")

        let sys = """
        You maintain a running summary of a conversation between a user and an \
        assistant. Update the summary to incorporate the new messages. Preserve \
        durable facts about the user, decisions, tasks, preferences, and open \
        threads. Keep it concise — a few short paragraphs at most. Output ONLY \
        the updated summary text, with no preamble.
        """
        let usr = """
        CURRENT SUMMARY:
        \(summary.isEmpty ? "(none yet)" : summary)

        NEW MESSAGES:
        \(rendered)

        Updated summary:
        """

        do {
            var out = ""
            for await gen in try await mlxService.generate(
                messages: [.system(sys), .user(usr)], model: selectedModel,
                temperature: 0.3, maxTokens: 1024)
            {
                if case .chunk(let t) = gen { out += t }
            }
            let updated = Self.stripThinking(out)
            if !updated.isEmpty {
                summary = updated
                summarizedCount = cutoff
                summaryStore?.save(SummaryState(summary: summary, coveredCount: summarizedCount))
            }
        } catch {
            // Leave the summary unchanged; retried next turn.
        }
    }

    // MARK: Persistence

    private func persist() {
        conversationStore.save(messages)
    }

}
