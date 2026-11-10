//
//  LLM_AssistantApp.swift
//  LLM Assistant
//
//  Created by Henri Lavikainen on 5.7.2026.
//

import SwiftUI

@main
struct LLM_AssistantApp: App {
    // One shared inference service so switching tabs/models unloads the previous
    // model and loads the next (only one resident at a time).
    @State private var assistant: ChatViewModel
    @State private var vision: ChatViewModel

    init() {
        let mlx = MLXService()
        _assistant = State(
            initialValue: ChatViewModel(
                mlxService: mlx,
                title: "Assistant",
                conversationFile: "conversation.json",
                summaryFile: "summary.json",
                useMemory: true,
                supportsImages: false,
                modelType: .llm,
                defaultModelName: "qwen3:4b",
                settingsKey: "assistant"
            ))
        _vision = State(
            initialValue: ChatViewModel(
                mlxService: mlx,
                title: "Vision",
                conversationFile: "vision-conversation.json",
                summaryFile: nil,
                useMemory: false,
                supportsImages: true,
                modelType: .vlm,
                defaultModelName: "gemma4:E2B",
                settingsKey: "vision"
            ))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView(viewModel: assistant)
                    .tabItem { Label("Assistant", systemImage: "bubble.left.and.bubble.right") }
                ChatView(viewModel: vision)
                    .tabItem { Label("Vision", systemImage: "photo") }
            }
        }
    }
}
