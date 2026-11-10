//
//  ModelSettingsView.swift
//  LLM Assistant
//
//  Generation settings for a tab: sampling temperature and max output tokens.
//

import SwiftUI

struct ModelSettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    LabeledContent("Current", value: viewModel.selectedModel.name)
                }

                Section("Temperature") {
                    VStack(alignment: .leading) {
                        Slider(value: $viewModel.temperature, in: 0...1.5, step: 0.05)
                        Text(String(format: "%.2f — lower is more focused, higher more creative", viewModel.temperature))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Max output tokens") {
                    Stepper(value: $viewModel.maxTokens, in: 256...8192, step: 256) {
                        Text("\(viewModel.maxTokens) tokens")
                    }
                    Text("Caps how long a reply can get (includes hidden reasoning).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(viewModel.title) settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
