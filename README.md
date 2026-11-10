# LLM Assistant

A private chat assistant for iPhone and iPad that runs language models
on-device with Apple's [MLX](https://github.com/ml-explore/mlx-swift) via
`mlx-swift-lm`. Conversations, long-term memory and attached images stay in
the app's Documents folder. No account or cloud service is involved.

## Features

| | |
|---|---|
| **On-device inference** | Runs 4-bit MLX models locally on the GPU, streaming the reply token by token |
| **Two chat tabs** | **Assistant** (text models, with memory and summarisation) and **Vision** (an image-capable model, with photo attachments) |
| **One continuous conversation per tab** | Each tab keeps a single ongoing chat that is saved after every message and reloaded on launch |
| **Long-term memory** | A `memories.md` Markdown file is injected into every Assistant turn. Edit it in the app (**... > Edit memory**) or in the Files app |
| **Rolling summary** | When the Assistant chat grows long, older messages are condensed into a running summary by the same model. The 12 most recent messages are always sent verbatim |
| **Image input** | The Vision tab attaches a photo from the library and sends it to the vision model |
| **Wikipedia lookup** | `/wiki <topic>` fetches the matching English Wikipedia article and answers from it, with a link to the source. Add a second line to ask a specific question about the topic |
| **Model picker** | Switch between models that are present on the device. Only one model is held in memory at a time |
| **Generation settings** | Per-tab temperature (0 to 1.5) and maximum output tokens (256 to 8192), remembered between launches |
| **Reasoning hidden** | `<think>...</think>` blocks from reasoning models such as Qwen3 are removed from the displayed reply |
| **Stop and clear** | Stop a reply mid-generation, or clear a tab's conversation |

### Supported models

These are the entries in `MLXService.availableModels`, all from the
[`mlx-community`](https://huggingface.co/mlx-community) organisation on
Hugging Face:

| Name in app | Hugging Face repo | Tab |
|---|---|---|
| `llama3.2:1b` | `mlx-community/Llama-3.2-1B-Instruct-4bit` | Assistant |
| `qwen2.5:1.5b` | `mlx-community/Qwen2.5-1.5B-Instruct-4bit` | Assistant |
| `qwen3:0.6b` | `mlx-community/Qwen3-0.6B-4bit` | Assistant |
| `qwen3:1.7b` | `mlx-community/Qwen3-1.7B-4bit` | Assistant |
| `qwen3:4b` (default) | `mlx-community/Qwen3-4B-4bit` | Assistant |
| `qwen3:8b` | `mlx-community/Qwen3-8B-4bit` | Assistant |
| `gemma4:E2B` (default) | `mlx-community/gemma-4-e2b-it-4bit` | Vision |

## Getting a model onto the device

The app does **not** ship with model weights, so the `.ipa` is small. It finds
a model in one of two ways.

### Option 1: copy the model folder over (recommended)

The app exposes its Documents folder to Finder and the Files app
(`UIFileSharingEnabled`). If a model folder sits there, the app loads it
directly and does not download anything.

1. On a Mac, download the model repo, for example with the Hugging Face CLI:

   ```sh
   hf download mlx-community/Qwen3-4B-4bit --local-dir Qwen3-4B-4bit
   ```

2. Connect the iPhone, open it in Finder, go to the **Files** tab and drag
   the `Qwen3-4B-4bit` folder onto **LLM Assistant**. You can also copy the
   folder into **On My iPhone > LLM Assistant** in the Files app.
3. Relaunch the app. The model now appears in the model menu (the CPU icon,
   top left).

The rules the app uses to detect a copied model
(`MLXService.localModelDirectory`):

- The folder must be at the top level of the app's Documents folder.
- The folder name must match the last part of the repo id: `Qwen3-4B-4bit`
  for `mlx-community/Qwen3-4B-4bit`, `gemma-4-e2b-it-4bit` for the Gemma
  model, and so on.
- It must contain `config.json` and a single `model.safetensors`, plus the
  tokenizer files from the repo. Sharded weights (`model-00001-of-…`) are
  not detected.

If a model ships its chat template only as `chat_template.jinja`, the app
copies it into `tokenizer_config.json` the first time it loads the folder.

### Option 2: let the app download it

If no copied folder exists for the tab's selected model, sending the first
message downloads that model from Hugging Face. A banner shows progress and
speed. With nothing copied over, the Assistant tab uses `qwen3:4b` and the
Vision tab uses `gemma4:E2B`. This is a single-stream download, so it can be
slow for multi-GB models.

The model menu only lists copied folders. A model fetched this way still
works as the default, but it does not appear in the menu.

## How it works

- **Inference.** `MLXService` loads models with `LLMModelFactory` (text) or
  `VLMModelFactory` (vision) from `mlx-swift-lm`. Loading a different model
  first releases the previous one and clears the MLX cache, so two multi-GB
  models are never resident together. The GPU cache limit is kept small to
  reduce memory pressure.
- **Prompt assembly.** Each Assistant turn sends a system prompt with
  `memories.md` and the running summary appended, followed by every
  message that has not been summarised yet. The Vision tab sends the system
  prompt plus the last 10 messages, without memory or summary. Only the
  most recent image is passed to the model, and images are resized to fit
  1024 x 1024.
- **Summarisation.** Once more than 20 messages are unsummarised, all but the
  newest 12 are folded into the summary (`summary.json`) with a separate
  low-temperature generation.
- **Storage.** Everything is in the app's Documents folder:
  `conversation.json`, `vision-conversation.json`, `summary.json`,
  `memories.md` and `images/`. Settings and the selected model live in
  `UserDefaults`.
- **Persona.** The system prompt (`ChatViewModel.systemPrompt`) and the
  starter `memories.md` template (`MemoryStore.template`) are written for the
  author. Edit them, or edit `memories.md` on the device, to make the
  assistant yours.

### Network use

Inference never uses the network. The app connects to the internet only to:

- download a model from Hugging Face when no copied folder is found, and
- run a `/wiki` lookup. Only the search topic is sent, to `en.wikipedia.org`.

## Requirements

- iOS / iPadOS 26.2 or later
- A physical device with an Apple GPU. MLX does not run in the Simulator.
- Plenty of free RAM and storage. For example, `Qwen3-4B-4bit` is about
  2.1 GB on disk. Larger models such as `qwen3:8b` need a device with a lot
  of memory.
- The app requests the `com.apple.developer.kernel.increased-memory-limit`
  entitlement. Whether it survives re-signing depends on your sideloading
  tool and Apple ID. Without it, iOS is more likely to stop the app when it
  loads larger models.

## Install

1. Download the unsigned `.ipa` from the
   [latest release](https://github.com/HenriVSL/LLM-Assistant/releases/latest).
2. Sideload it with a tool that re-signs it with your own Apple ID, such as
   [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
   [Sideloadly](https://sideloadly.io).
3. Copy a model onto the device as described above.

Apps signed with a free Apple ID expire after 7 days and need to be re-signed.

## Build from source

1. Open `LLM Assistant.xcodeproj` in Xcode 26.2 or later.
2. Select your team under **Signing & Capabilities** for the
   `LLM Assistant` target. Change the bundle identifier
   (`henril.LLM-Assistant`) if Xcode reports a conflict.
3. Build and run on a device. Xcode resolves the Swift packages on first open.

The `BundledModel/` folder is ignored by git and is not part of this
repository. It is only a local staging area for model folders.

## Third-party components

Swift packages used by the app (versions from `Package.resolved`):

| Package | Licence |
|---|---|
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache 2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [EventSource](https://github.com/mattt/EventSource) | MIT |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | Apache 2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics), [swift-collections](https://github.com/apple/swift-collections), [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1), [swift-nio](https://github.com/apple/swift-nio), [swift-atomics](https://github.com/apple/swift-atomics), [swift-system](https://github.com/apple/swift-system) | Apache 2.0 |

`MLXService` and `LMModel` are adapted from the chat example in
[mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) (MIT).

Model weights are not included. Each model has its own licence, which you can
find on its Hugging Face model card.

## License

MIT, see [LICENSE](LICENSE).
