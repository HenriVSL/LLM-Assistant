//
//  MemoryEditorView.swift
//  LLM Assistant
//
//  A simple editor for memories.md — the durable long-term memory injected
//  into every conversation turn.
//

import SwiftUI

struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    private let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .navigationTitle("Long-term memory")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
        }
    }
}
