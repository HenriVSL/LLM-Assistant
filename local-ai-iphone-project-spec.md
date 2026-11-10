# Project Spec: Private Local AI Assistant for iPhone

A handoff document for building a fully on-device, private AI assistant iOS app.
Hand this to Claude Code as the starting brief.

---

## 1. Goal

Build a **private, offline, single-user** AI assistant that runs entirely on my iPhone.

Core requirements:
- **Fully local inference** — no network calls for the model, nothing leaves the device.
- **One continuous conversation** — the app is a single ongoing chat (a "true personal assistant"), not a multi-chat app.
- **Persist everything** — every message saved locally and reloaded on launch.
- **Long-term memory via a Markdown file** — a `memories.md` file holds stable facts/preferences and is injected into the model's context each turn, so the assistant "remembers" things without keeping the entire history in the context window.
- Private, for my use only. Not for the App Store.

## 2. Hardware & environment (verified)

- **Device:** iPhone 17 Pro — **12 GB RAM** (confirmed; the Pro/Pro Max/Air all have 12 GB, base iPhone 17 has 8 GB). This is the most RAM any iPhone has had and is the best-case target.
- **Dev machine:** Mac with Xcode.
- **Coder:** Claude Code.
- **Framework:** Apple **MLX** (MLX Swift) — Apple-silicon-native, uses the Metal GPU, good iOS support.

## 3. Recommended starting point

Do **not** start from a macOS CLI project. Start from Apple's official examples repo:

- **`ml-explore/mlx-swift-examples`** (Apple's MLX Swift examples). It contains a **SwiftUI chat app that builds and runs on iPhone** and can load Gemma / Qwen-class models via `mlx-swift-lm`.
- Action for Claude Code: clone it, confirm the current example app name and structure (the repo evolves — verify rather than assume), get the stock chat example building and running on a connected iPhone 17 Pro **first**, before customizing anything.

Rationale: this gets a working on-device chat on the actual phone fast. The two features that make it *mine* (single-conversation persistence + memory-file injection) are then additive.

## 4. Model choice

Target a small model that fits comfortably in 12 GB with iOS overhead.

- **Primary candidate:** **Gemma E2B, 4-bit quantized** (~3.6 GB on disk). Fits with headroom.
- **Stretch:** Gemma E4B 4-bit (~5 GB) — borderline but possibly workable with the increased-memory entitlement (see §6).
- **Leaner alternative worth testing:** a plain small **text-only** model (e.g. Qwen2.5 3B Instruct 4-bit, Llama 3.2 3B 4-bit). The Gemma E-series are multimodal (vision/audio/video towers) — more machinery than a text assistant needs. A text-only model may be lighter and more stable. **Recommend benchmarking both** for speed and memory on-device.
- Use **4-bit quantization** as the default sweet spot for quality vs. RAM/speed.

## 5. Architecture

Three parts on top of the MLX chat example:

**a. Inference loop** (from the example)
- Load the quantized model once at launch; keep it resident.
- Stream tokens to the UI.

**b. Persistence layer**
- Save every user + assistant message locally. SQLite (via GRDB) or a simple JSON/plist file is fine for a single conversation.
- On launch, reload the full history and render it.
- Everything on-device only.

**c. Memory + context assembly** (the key custom piece)
Each turn, build the model's prompt as:
1. **System prompt** — assistant persona/instructions.
2. **`memories.md` contents** — injected verbatim as durable long-term memory (facts, preferences, context). Editable by me; optionally later auto-appended by the app.
3. **Recent conversation** — the last N messages that fit the context window.

Because small models have limited context (and long context costs RAM + speed), do **not** dump the entire history in. Strategy:
- v1: `memories.md` (static) + last N messages verbatim.
- v2 (later): **rolling summarization** — when the tail grows too long, summarize older messages and keep recent ones verbatim.
- v3 (optional, probably overkill): RAG — embed past messages, retrieve only relevant snippets per turn.

Start with v1.

## 6. iOS specifics & gotchas

- **Increased-memory entitlement:** request `com.apple.developer.kernel.increased-memory-limit`. The 17 Pro supports it; it lets the app use more RAM before iOS's jetsam killer terminates it. Important for larger models.
- **Bundle vs. download the model:** bundling inside the app makes the `.ipa` multi-GB. Simpler for a personal app is to **download the model on first launch** into app storage, then load locally forever after. Decide early.
- **Free Apple Developer account:** apps signed with a free account expire after **7 days** and must be re-deployed from Xcode. A paid account ($99/yr) gives 1-year signing. For personal use the free tier works if you don't mind re-signing.
- **Thermals/battery:** sustained generation is GPU-heavy. The 17 Pro's vapor chamber helps, but expect warmth and battery drain on long sessions.
- **Context window:** confirm the chosen model's context length and cap the recent-message window accordingly.

## 7. Suggested build order for Claude Code

1. Clone `ml-explore/mlx-swift-examples`; get the stock SwiftUI chat example running on the iPhone 17 Pro.
2. Swap in the target model (Gemma E2B 4-bit or a text-only 3B 4-bit); benchmark speed + peak memory on-device.
3. Add the increased-memory entitlement if needed.
4. Replace multi-chat UI with a **single persistent conversation**; add the persistence layer; reload history on launch.
5. Add `memories.md` loading + prompt assembly (system prompt + memories + recent window).
6. Add recent-window capping; then rolling summarization (v2).
7. Decide model bundling vs. first-launch download.

---

## 8. Fast model downloads via parallel range requests (design — not yet implemented)

### 8.1 Problem (measured)

The stock MLX/HuggingFace Swift downloader fetches each model file as a **single HTTP stream**. A model repo is dominated by one large `model.safetensors` (e.g. ~868 MB for Qwen2.5-1.5B-4bit) plus a few small files. The library downloads up to 8 files concurrently, but with only one large file that concurrency buys nothing — the bulk is a single stream.

HuggingFace serves these files from a **US-region CDN** (`us.aws.cdn.hf.co`, via a 302 redirect from `huggingface.co/.../resolve/main/...`). From the dev network (Europe, gigabit link) the throughput was measured as:

| Method | Throughput | Time for 828 MB |
|--------|-----------|-----------------|
| Single stream (what the app does today) | **~2.7 MB/s** | ~5 min |
| 8 parallel range streams | **~21 MB/s** | ~40 s |

So the slowness is **not** the iPhone, the app, the debugger, or Low Data Mode — it is a per-TCP-connection throughput cap on the long-haul path to the US CDN. Browsers and the `hf` CLI feel fast because they parallelize. The fix is to parallelize a single large file across multiple range requests.

### 8.2 Progress-reporting note (why the bar looks frozen)

Related but separate: the library's per-file byte progress does **not** propagate to the aggregate `Progress` for the large LFS file (its download uses `URLSession.download(for:delegate:)` but the incremental `didWriteData` updates don't reach the snapshot's parent progress). Net effect: the bar jumps to ~1–2% (small files finishing), sits frozen through the big file, then snaps to 100% on completion. Our own downloader (below) reports real cumulative bytes, so this goes away.

### 8.3 Approach

Replace the `#hubDownloader()` path with our own `ModelDownloader` that downloads a repo into a local directory using parallel range requests, then load the model from that directory. MLX already supports this cleanly:

- `ModelConfiguration` has a `.directory(URL)` identifier (`MLXLMCommon/ModelConfiguration.swift`).
- `ModelFactory` exposes `loadContainer(from directory: URL, using tokenizerLoader:)` — "No downloader is needed — the model and tokenizer are loaded from the given directory." So if we download **all** repo files (including `tokenizer.json`, `tokenizer_config.json`, `config.json`, `*.safetensors`, `*.safetensors.index.json`, `merges.txt`, `vocab.json`, etc.) into one folder, MLX loads everything locally.
- The repo id string is available from `LMModel.configuration.name` (for `.id` configs, `name` returns the repo id).

### 8.4 `ModelDownloader` design

**Storage location.** `Application Support/models/<repo-with-"/"-replaced-by-"_">/` (NOT Caches — iOS can purge Caches under storage pressure, and the spec wants the model kept "forever after first launch"). Set `isExcludedFromBackup = true` on the model dir so multi-GB weights don't bloat iCloud/iTunes backups.

**File enumeration.** `GET https://huggingface.co/api/models/{repo}/tree/main` → JSON array of `{ path, size, type }`. Keep `type == "file"`. Sum `size` for the total. (Verified: returns exact byte sizes.)

**Per-file download URL.** `https://huggingface.co/{repo}/resolve/main/{path}` (URLSession follows the 302 to the CDN automatically).

**Download strategy per file:**
- Small file (≤ chunk size, ~16 MB): single `URLSession.data(for:)`, write to disk.
- Large file: split into fixed-size chunks (~16 MB). Download chunks concurrently with a **global cap of ~8 in flight** (that's where the 8× win comes from). Each chunk = a `Range: bytes=<start>-<end>` request expecting `206 Partial Content`; write the returned data at its offset.
  - Use in-memory `data(for:)` per chunk (16 MB × 8 ≈ 128 MB peak — fine on a 12 GB phone, model not yet loaded). Avoid `URLSession.bytes` byte-by-byte iteration (per-byte overhead is very slow in Swift).
  - Write into a preallocated `<file>.part` (create file, `FileHandle.truncate(atOffset: size)`); each chunk task opens its own `FileHandle`, `seek(toOffset:)`, `write(contentsOf:)`, close. Disjoint ranges → concurrent writes are safe on Darwin.
  - On full success, atomically move `<file>.part` → `<file>`. Never size-check a `.part` as complete.

**Resume / caching across launches.** Before downloading, skip any file whose final path already exists **with the exact expected byte size** (count it as already-complete in the progress total). Interrupted large files leave only a `.part` (discarded and re-fetched) — no false "complete". Simple correctness over true byte-level resume for v1.

**Robustness.** Per-chunk retry (≈3 attempts, small backoff) for flaky mobile networks. `URLSessionConfiguration.default` with `waitsForConnectivity = true` and a per-request timeout (~60 s). Reject non-206/200 responses.

**Progress reporting.** Maintain a cumulative completed-byte counter (concurrency-safe via an `actor` counter or lock). Report `(completedBytes, totalBytes)` on each chunk completion. The existing `MLXService.DownloadStats` (bytes + EMA-smoothed MB/s) and the download banner in `ChatView` already consume this shape — they just get fed real numbers now. Granularity ≈ one update per 16 MB chunk, which is fine for the bar and the MB/s readout.

**Concurrency cap.** Process files sequentially; within the one big file, run its chunks through a `withThrowingTaskGroup` limited to ~8 concurrent. (The big file dominates, so per-file sequencing is fine.)

### 8.5 MLXService integration

In `MLXService.load(model:)`, replace the Hub-download + `loadContainer(configuration:)` call with:
1. `let repo = model.configuration.name`
2. `let dir = try await modelDownloader.download(repo: repo) { stats in /* feed DownloadStats */ }`
3. `let container = try await factory.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())`

Keep the existing `NSCache` of loaded containers. The tokenizer loader reads from `dir` (all tokenizer files are downloaded), so no network at load time.

### 8.6 Open questions / tunables

- **Chunk size & concurrency** (16 MB / 8) are guesses that matched the curl test — worth benchmarking 4 vs 8 vs 16 streams on-device; the CDN or network may cap aggregate throughput.
- **Does the CDN reliably honor `Range` for these Xet-bridge URLs?** curl `-r` worked; confirm URLSession gets `206` after the redirect.
- **Disk space guard:** check free space ≥ model size before starting; surface a clear error otherwise.
- **Revision pinning:** v1 uses `main`; consider pinning to a commit hash for reproducibility.
- Consider whether to also delete the old single-stream cache path / migrate any already-downloaded models.

### 8.7 Status

Investigated and measured 2026-07-05. Root cause confirmed (single-stream CDN cap). Design above is ready to implement; **not yet coded** pending review.

---

*Note: the MLX example repos change over time — verify current repo/app structure and model download APIs against the live source rather than assuming. RAM figure for iPhone 17 Pro (12 GB) verified as of July 2026.*
