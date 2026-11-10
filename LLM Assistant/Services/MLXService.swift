//
//  MLXService.swift
//  LLM Assistant
//
//  Loads and runs on-device MLX language models. Adapted from Apple's
//  MLXChatExample (Services/MLXService.swift), trimmed to the text-only
//  models this assistant uses. All inference is local; nothing leaves the device.
//

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Manages model download, caching, and streaming text generation.
@Observable
class MLXService {
    /// Text models available to load. All are 4-bit quantized to fit comfortably
    /// in the iPhone's RAM. Names mirror the MLX example's registry entries.
    static let availableModels: [LMModel] = [
        LMModel(name: "llama3.2:1b", configuration: LLMRegistry.llama3_2_1B_4bit, type: .llm),
        LMModel(name: "qwen2.5:1.5b", configuration: LLMRegistry.qwen2_5_1_5b, type: .llm),
        LMModel(name: "qwen3:0.6b", configuration: LLMRegistry.qwen3_0_6b_4bit, type: .llm),
        LMModel(name: "qwen3:1.7b", configuration: LLMRegistry.qwen3_1_7b_4bit, type: .llm),
        LMModel(name: "qwen3:4b", configuration: LLMRegistry.qwen3_4b_4bit, type: .llm),
        LMModel(name: "qwen3:8b", configuration: LLMRegistry.qwen3_8b_4bit, type: .llm),
        // Multimodal Gemma (run text-only here). ~3.6 GB. Works well on device.
        // NOTE: the gemma3n E-series (MatFormer architecture) produces garbage
        // output in this MLX build, so it is intentionally omitted.
        LMModel(name: "gemma4:E2B", configuration: VLMRegistry.gemma4_E2B_it_4bit, type: .vlm),
    ]

    /// Default model. qwen3:4b is a newer, strong text model that's side-loaded
    /// into Documents, so it loads locally with no download.
    static let defaultModel =
        availableModels.first { $0.name == "qwen3:4b" } ?? availableModels[0]

    /// Returns a side-loaded model directory in the app's Documents folder, if
    /// present. Users push a model folder (e.g. "gemma-3n-E2B-it-lm-4bit") over
    /// USB via Finder file sharing; when found we load from it and skip the
    /// network download entirely.
    static func localModelDirectory(for repo: String) -> URL? {
        let folderName = (repo as NSString).lastPathComponent
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appending(path: folderName)
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: dir.appending(path: "config.json").path)
        let hasWeights = fm.fileExists(atPath: dir.appending(path: "model.safetensors").path)
        return (hasConfig && hasWeights) ? dir : nil
    }

    /// swift-transformers only reads a chat template from `tokenizer_config.json`'s
    /// `chat_template` field — it ignores the separate `chat_template.jinja` that
    /// Gemma (and others) ship. Without the template the model gets no turn markers
    /// and produces garbage. If the config lacks a template but a `.jinja` file is
    /// present, merge it in. Idempotent; writes only once.
    static func ensureChatTemplate(in dir: URL) {
        let configURL = dir.appending(path: "tokenizer_config.json")
        let jinjaURL = dir.appending(path: "chat_template.jinja")

        guard
            let jinja = try? String(contentsOf: jinjaURL, encoding: .utf8),
            !jinja.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = try? Data(contentsOf: configURL),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        guard json["chat_template"] == nil else { return }  // already has one

        json["chat_template"] = jinja
        if let out = try? JSONSerialization.data(
            withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        {
            try? out.write(to: configURL, options: [.atomic])
        }
    }

    /// The single resident model. Only one model is kept in memory at a time —
    /// switching models evicts the previous one to avoid stacking multiple
    /// multi-GB models in RAM.
    private var loadedContainer: ModelContainer?
    private var loadedModelName: String?

    /// Progress of an in-flight model download, observed by the UI.
    @MainActor
    private(set) var modelDownloadProgress: Progress?

    /// Live download stats (bytes + smoothed speed) for the UI. Nil when idle.
    @MainActor
    private(set) var downloadStats: DownloadStats?

    /// Snapshot of an in-flight download, computed from the byte-based Progress.
    struct DownloadStats {
        var completedBytes: Int64
        var totalBytes: Int64
        /// Exponentially smoothed transfer rate in bytes/second.
        var bytesPerSecond: Double

        var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    // Sampling state for computing MB/s from successive progress callbacks.
    @MainActor private var lastSampleTime: Date?
    @MainActor private var lastSampleBytes: Int64 = 0

    /// Updates `downloadStats` from a progress callback, smoothing the rate.
    @MainActor
    private func recordProgress(_ progress: Progress) {
        modelDownloadProgress = progress

        let now = Date()
        let bytes = progress.completedUnitCount
        let total = progress.totalUnitCount

        var rate = downloadStats?.bytesPerSecond ?? 0
        if let last = lastSampleTime {
            let dt = now.timeIntervalSince(last)
            if dt > 0.05 {
                let instantaneous = Double(bytes - lastSampleBytes) / dt
                // Exponential moving average to steady the number for display.
                rate = rate == 0 ? instantaneous : (rate * 0.7 + instantaneous * 0.3)
                lastSampleTime = now
                lastSampleBytes = bytes
            }
        } else {
            lastSampleTime = now
            lastSampleBytes = bytes
        }

        downloadStats = DownloadStats(
            completedBytes: bytes, totalBytes: total, bytesPerSecond: max(0, rate))
    }

    @MainActor
    private func clearDownloadStats() {
        modelDownloadProgress = nil
        downloadStats = nil
        lastSampleTime = nil
        lastSampleBytes = 0
    }

    /// Loads a model (downloading on first use), or returns the resident one.
    private func load(model: LMModel) async throws -> ModelContainer {
        // Keep the GPU cache modest to avoid memory pressure on device.
        Memory.cacheLimit = 20 * 1024 * 1024

        if loadedModelName == model.name, let container = loadedContainer {
            return container
        }

        // Switching models: release the previous one and free its GPU buffers
        // before loading the next, so we never hold two multi-GB models at once.
        loadedContainer = nil
        loadedModelName = nil
        Memory.clearCache()

        let factory: ModelFactory =
            switch model.type {
            case .llm: LLMModelFactory.shared
            case .vlm: VLMModelFactory.shared
            }

        let loader = #huggingFaceTokenizerLoader()
        let container: ModelContainer

        // Prefer a side-loaded model directory (pushed via Finder) — no download.
        if let localDir = Self.localModelDirectory(for: model.configuration.name) {
            Self.ensureChatTemplate(in: localDir)
            container = try await factory.loadContainer(from: localDir, using: loader)
        } else {
            // Otherwise download from the Hub on first use.
            let downloader = #hubDownloader()
            container = try await factory.loadContainer(
                from: downloader,
                using: loader,
                configuration: model.configuration
            ) { progress in
                Task { @MainActor in
                    self.recordProgress(progress)
                }
            }
            await clearDownloadStats()
        }

        loadedContainer = container
        loadedModelName = model.name
        return container
    }

    /// Streams generated tokens for the given (already-assembled) message list.
    /// - Parameters:
    ///   - messages: system + recent conversation, in order. Any `imagePaths`
    ///     on a message are passed to vision models.
    ///   - model: the model to run.
    ///   - temperature: sampling temperature.
    ///   - maxTokens: cap on generated tokens (nil = until end-of-turn).
    func generate(
        messages: [Message], model: LMModel,
        temperature: Float = 0.7, maxTokens: Int? = nil
    ) async throws -> AsyncStream<Generation> {
        let modelContainer = try await load(model: model)

        // Drop a trailing empty assistant message so the chat template leaves
        // the assistant turn open for generation.
        var inputMessages = messages
        if let last = inputMessages.last, last.role == .assistant, last.content.isEmpty {
            inputMessages.removeLast()
        }

        // MLX's Gemma4 VLM path miscounts image tokens when more than one image
        // is present (it doesn't flatten per-image vision features before the
        // count check → imageTokenCountMismatch). Keep the image(s) only on the
        // most recent image-bearing message; older images contribute text only.
        if let lastImageIdx = inputMessages.lastIndex(where: { !$0.imagePaths.isEmpty }) {
            for i in inputMessages.indices where i != lastImageIdx {
                inputMessages[i].imagePaths = []
            }
        }

        let chat = inputMessages.map { message in
            let role: Chat.Message.Role =
                switch message.role {
                case .assistant: .assistant
                case .user: .user
                case .system: .system
                }
            let images = message.imageURLs.map { UserInput.Image.url($0) }
            return Chat.Message(role: role, content: message.content, images: images)
        }

        let userInput = UserInput(
            chat: chat, processing: .init(resize: CGSize(width: 1024, height: 1024)))

        return try await modelContainer.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
        }
    }
}
