//
//  ChatView.swift
//  LLM Assistant
//
//  One conversation tab: scrolling history, input field (with optional image
//  attachment), model picker, settings, memory editor, and download progress.
//

import PhotosUI
import SwiftUI

struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State private var showingMemoryEditor = false
    @State private var showingSettings = false
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                attachmentPreview
                inputBar
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingMemoryEditor) {
                MemoryEditorView(
                    initialText: viewModel.readMemory(),
                    onSave: { viewModel.writeMemory($0) }
                )
            }
            .sheet(isPresented: $showingSettings) {
                ModelSettingsView(viewModel: viewModel)
            }
            .safeAreaInset(edge: .top) { downloadBanner }
        }
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isGenerating, viewModel.messages.last?.content.isEmpty == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(viewModel.statusText ?? "Thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 40)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onChange(of: viewModel.messages.last?.content) { scrollToBottom(proxy) }
            .onChange(of: viewModel.messages.count) { scrollToBottom(proxy) }
            .onChange(of: viewModel.isGenerating) { scrollToBottom(proxy) }
            .onChange(of: viewModel.statusText) { scrollToBottom(proxy) }
        }
    }

    private static let bottomID = "chat-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    // MARK: Attachment preview

    @ViewBuilder
    private var attachmentPreview: some View {
        if let name = viewModel.attachedImageName {
            HStack {
                AsyncImage(url: AttachmentStore.url(for: name)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Image attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.clearAttachment()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if viewModel.supportsImages {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                }
                .onChange(of: photoItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self) {
                            viewModel.attachImage(data)
                        }
                        photoItem = nil
                    }
                }
            }

            TextField(
                viewModel.supportsImages ? "Message" : "Message · /wiki <topic>",
                text: $viewModel.prompt, axis: .vertical
            )
            .textFieldStyle(.plain)
            .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .lineLimit(1...6)

            if viewModel.isGenerating {
                Button(action: viewModel.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                }
            } else {
                Button(action: viewModel.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Download banner

    @ViewBuilder
    private var downloadBanner: some View {
        if let stats = viewModel.downloadStats, stats.fraction < 1 {
            VStack(spacing: 4) {
                Text("Downloading \(viewModel.selectedModel.name)…")
                    .font(.caption)
                ProgressView(value: stats.fraction)
                Text(statusLine(stats))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
        }
    }

    /// e.g. "1420 / 3600 MB · 4.2 MB/s"
    private func statusLine(_ stats: MLXService.DownloadStats) -> String {
        let mb = { (bytes: Int64) in Double(bytes) / 1_000_000 }
        let done = mb(stats.completedBytes)
        let total = mb(stats.totalBytes)
        let speed = stats.bytesPerSecond / 1_000_000
        if total > 0 {
            return String(format: "%.0f / %.0f MB · %.1f MB/s", done, total, speed)
        } else {
            return String(format: "%.0f MB · %.1f MB/s", done, speed)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Model", selection: $viewModel.selectedModel) {
                    ForEach(viewModel.onDeviceModels) { model in
                        Text(model.name).tag(model)
                    }
                }
            } label: {
                Label(viewModel.selectedModel.name, systemImage: "cpu")
                    .font(.caption)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingSettings = true
                } label: {
                    Label("Model settings", systemImage: "slider.horizontal.3")
                }
                if viewModel.useMemory {
                    Button {
                        showingMemoryEditor = true
                    } label: {
                        Label("Edit memory", systemImage: "brain")
                    }
                }
                Button(role: .destructive) {
                    viewModel.clearConversation()
                } label: {
                    Label("Clear conversation", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
