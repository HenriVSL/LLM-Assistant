//
//  MessageBubble.swift
//  LLM Assistant
//
//  Renders a single message. User messages align right in a tinted bubble;
//  assistant messages align left with basic Markdown rendering.
//

import SwiftUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        // An empty assistant message means generation is underway but no visible
        // text yet — the working status is shown by ChatView, so render nothing.
        if message.role == .assistant && message.content.isEmpty {
            EmptyView()
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 40) }

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    ForEach(message.imageURLs, id: \.self) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.tertiarySystemFill)
                        }
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if !message.content.isEmpty {
                        Text(markdown)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(background, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(message.role == .user ? .white : .primary)
                    }
                }

                if message.role == .assistant { Spacer(minLength: 40) }
            }
        }
    }

    /// Render content as Markdown when possible, falling back to plain text.
    private var markdown: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.content)
    }

    private var background: Color {
        message.role == .user ? .accentColor : Color(.secondarySystemBackground)
    }
}
