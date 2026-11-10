//
//  LMModel.swift
//  LLM Assistant
//
//  Describes a language model the app can load. Ported from the MLX chat
//  example and trimmed to the text-only models relevant to this assistant.
//

import MLXLMCommon

/// A selectable language model plus its MLX configuration.
struct LMModel: Identifiable, Hashable {
    /// Short display / storage name, e.g. "qwen2.5:1.5b".
    let name: String

    /// MLX configuration used to download and load the model.
    let configuration: ModelConfiguration

    /// LLM (text) vs VLM (vision). This assistant uses text models.
    let type: ModelType

    enum ModelType {
        case llm
        case vlm
    }

    var id: String { name }

    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    static func == (lhs: LMModel, rhs: LMModel) -> Bool { lhs.name == rhs.name }
}
