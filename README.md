# whicc

> **ASR model + translation model = real-time multilingual subtitle for any video.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 15+](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4%2FM5-black.svg)](https://support.apple.com/en-us/116943)
[![Python 3.13](https://img.shields.io/badge/Python-3.13-blue.svg)](https://www.python.org/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://www.swift.org/)
[![CI](https://github.com/nbzz/whicc/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
[中文 README](README.zh.md) · [Docs](DEVELOPMENT.md)

<!-- Visual assets (file description in docs/screenshots/README.md):
     1) docs/screenshots/icon.png   — Top hero image, app icon
     2) docs/screenshots/demo.mov   — 38s demo video, embedded via <video> tag
     3) docs/screenshots/subtitle-*.png — 6-shot gallery, 2 rows × 3 cols
-->
<p align="center">
  <img src="docs/screenshots/icon.png" alt="whicc app icon" width="240">
</p>

<p align="center">
  <video src="docs/screenshots/demo.mov" controls width="720" preload="metadata"></video>
</p>

<p align="center">
  <img src="docs/screenshots/subtitle-cn.png" width="32%" alt="Chinese subtitle over English interview" />
  <img src="docs/screenshots/subtitle-es.png" width="32%" alt="Spanish to Chinese translation" />
  <img src="docs/screenshots/subtitle-ja.png" width="32%" alt="Japanese to Chinese translation" />
  <br>
  <img src="docs/screenshots/subtitle-bilingual.png" width="32%" alt="English to Chinese bilingual subtitle" />
  <img src="docs/screenshots/subtitle-cn-stacked.png" width="32%" alt="Stacked multi-segment Chinese subtitle" />
  <img src="docs/screenshots/subtitle-ar.png" width="32%" alt="Arabic to Chinese translation" />
</p>

**whicc** = **whi**(sper) + **cc**(closed captions) — a real-time, locally-powered translation subtitle that always sits on top of any foreign-language video you're watching.

You don't need it to be perfect. You just need it to **catch you up when you don't understand**.
Watch a stream in any language — your own machine does the translation in real time.
Watch an AI interview — a term might slip every now and then, but you'll follow along.
A noisy scene will degrade the recognition and the translation — but **it's still there, it doesn't disappear**.

The subtitle gets better as open-source ASR and translation models evolve. The better the models get, the better whicc gets.

If you're studying abroad or in a foreign-language class, switch to microphone mode — whicc will transcribe the audio around you in real time, helping you keep up with the lecture.

---

## ✨ Core features

- **🛡️ Always-on translation safety net** — The subtitle is always on screen, never out of your mind. Not aiming for perfection — aiming for *always there*.
- **🖥️ Local ASR, end-to-end** — Nemotron-3.5-ASR (non-Chinese) + Qwen3-ASR (Chinese) running on Apple Silicon via MLX. **Audio never leaves your machine**, no cloud transcription service required.
- **🌐 Most languages covered** — The translation backend uses Tencent Hy-MT2, supporting dozens of languages in any combination (Chinese, English, Japanese, German, French, Spanish, Russian, Korean, Arabic, Portuguese, Italian, and more).
- **🔌 You bring the translation model** — whicc doesn't ship a translation model. You install [LM Studio](https://lmstudio.ai/) and load a translation model (on this Mac, a Windows PC on your home network, or any machine with network access). The bigger the model, the better the translation.
- **🪟 SwiftUI floating subtitle** — A floating panel that auto-hides when not focused and switches target/source layout on the fly. Liquid Glass on macOS 26, frosted material fallback on macOS 15.
- **🤖 Self-learning glossary** — jieba keyword extraction + scene detection + Hermes Agent terminology search. Terms accumulate in `glossary.json` and apply automatically next session.
- **📈 It gets better with the models** — Upgrade either the ASR or the translation model and whicc's quality follows.

---

## 📦 System requirements

| Type | Requirement |
|---|---|
| OS | **macOS 15+** (official mlx wheels ship `macosx_15_0_arm64`; full Liquid Glass visuals on macOS 26) |
| Chip | **Apple Silicon** (M1 / M2 / M3 / M4 / M5) |
| Disk | First-launch model download ≈ **2 GB** |
| Python | 3.13 (only for source-build development; not needed when using the .app) |

**Translation service (required for translated subtitles)**

whicc doesn't ship a translation model. Translation depends on an external LM Studio / vLLM node exposing an OpenAI-compatible HTTP API.
Without it, the on-screen **draft subtitle (the live partial recognition) keeps rolling but never becomes a final caption, and is never added to history**.

To set up the translation service (required, otherwise no translation):

1. Install [LM Studio](https://lmstudio.ai/) (on this Mac or any machine on your LAN — Windows / Mac / Linux all work)
2. Load a translation model in LM Studio — we recommend `tencent/Hy-MT2-1.8B-GGUF`. If your hardware can handle it, go with `Hy-MT2-7B-GGUF` or larger; bigger = better
3. Start the OpenAI-compatible server in LM Studio (default `http://localhost:1234`)
4. Fill in this URL in the whicc Settings panel

The translation node can be **this Mac**, **another Windows PC on your home network**, any idle machine on the LAN, or even a remote cloud — as long as it's reachable.

---

## 🚀 Installation

### Normal users (recommended)

1. Go to [Releases](../../releases) and download the latest `whicc.app.zip`
2. Unzip and drag `whicc.app` to `/Applications/`
3. Double-click to launch

On first launch the Settings panel will open automatically (or press `⌘,` or click the gear icon):

1. **Download ASR models** — HuggingFace downloads automatically; needs a working network
2. **Set up the translation service** — Install [LM Studio](https://lmstudio.ai/) on this Mac or any machine on your LAN, load a translation model (`tencent/Hy-MT2-1.8B-GGUF` or larger), and start the OpenAI-compatible server
3. **Fill in the translation service URL** — e.g. `http://192.168.1.10:1234` (use `http://localhost:1234` if LM Studio is on the same Mac); fill in the actual model ID LM Studio loaded
4. **Start watching** — Open any foreign-language video or live stream, subtitles overlay automatically

### Developers (running from source)

See [DEVELOPMENT.md](DEVELOPMENT.md) — covers CLI flags, project structure, core mechanisms, and packaging the `.app`.

---

## 🏗️ Architecture

```
System audio / microphone (ScreenCaptureKit / mic)
        ↓  16kHz PCM chunks
   whicc.py (ASR)                    ← Local Apple Silicon MLX
   ├─ Qwen3-ASR-0.6B  (Chinese)
   └─ Nemotron-3.5-ASR (English, two-pass correction)
        ↓  /tmp/whicc-out/events.jsonl        (partial + final subtitle events)
   translate_stream.py               ← LM Studio / vLLM HTTP
        ↓  /tmp/whicc-out/translation_events.jsonl
   macui (SwiftUI subtitle overlay)
        ↓
   glossary_refresher.py             ← jieba + Hermes Agent self-learning glossary
```

**Key decoupling**: ASR (heavy) runs on the local Mac; translation (HTTP call) can run on any machine with network access.
If the translation node is down, ASR keeps working locally — the subtitle still shows the source text.

For a fuller architecture diagram, the packaging-mode process tree, and the BackendLauncher design, see [DEVELOPMENT.md](DEVELOPMENT.md#架构图-打包模式).

---

## 🌍 Supported languages

| Use | Model | Coverage |
|---|---|---|
| ASR | Nemotron-3.5-ASR | English + auto-detect (zh / ja / ko / es / de / fr / …) |
| ASR | Qwen3-ASR-0.6B | Chinese + multiple dialects |
| Translation | Tencent Hy-MT2 | **33 languages, any-to-any** (zh, en, ja, de, fr, es, ru, ko, ar, pt, it, nl, vi, th, id, …) |

Default startup uses Nemotron. Switches to Qwen3 automatically when CJK character density crosses 30%.

---

## ⚙️ Translation configuration

Translation is **off** by default. In the macui Settings panel (gear icon):

1. **Service configuration → Enable translation** — turn on
2. **Main URL** — fill in your LM Studio address (e.g. `http://192.168.1.10:1234`)
3. **Fallback URL** — fill in a local fallback (e.g. `http://localhost:1234`)
4. **Model name** — fill in the actual model ID LM Studio loaded

Config file: `/tmp/whicc-out/lang_config.json`

```json
{
  "translation_enabled": true,
  "translation_url": "http://192.168.1.10:1234",
  "translation_fallback_url": "http://localhost:1234",
  "translation_model": "hy-mt2-7b"
}
```

If the main URL is unreachable, the fallback kicks in automatically. If both are down, the subtitle shows "Translation service unavailable" while the draft partial keeps rolling (no translation, no history commit).

### Target language switch

The macui toolbar language selector switches target language live — **no restart needed**.
Default is auto mode: Chinese ↔ English.

### Scene prompt injection

Fill in a scene description in Settings (e.g. `AI interview` / `NBA Finals`) to inject context into the translation prompt and help the model understand the topic.

---

## 📺 Subtitle window

- **Position**: Top-center floating
- **Auto-hide**: `opacity(0)` and click-through when the cursor isn't over it
- **Bilingual subtitle**: switch source-on-top / translation-on-top live
- **7 accent themes**: White / Ice / Gold / Neon / Coral / Violet / Cyan
- **Liquid Glass**: SwiftUI `GlassEffectContainer` on macOS 26, `ultraThinMaterial` frosted fallback on macOS 15
- **Auto-switching ASR**: current model name flashes in the title bar for 3 seconds when it changes

---

## 🛠️ Developers

- Run from source: [DEVELOPMENT.md → 开发模式启动](DEVELOPMENT.md#开发模式启动)
- Full CLI flags: [DEVELOPMENT.md → CLI 参考](DEVELOPMENT.md#cli-参数)
- Project structure: [DEVELOPMENT.md → 项目结构](DEVELOPMENT.md#项目结构)
- Build your own `.app`: [DEVELOPMENT.md → 打包成 macOS .app](DEVELOPMENT.md#打包成-macos-app)
- Core mechanisms (sentence boundary, translation guards, glossary): [DEVELOPMENT.md → 核心机制](DEVELOPMENT.md#核心机制)

---

## 🗺️ Roadmap

- [ ] **TTS simultaneous interpretation** — speak the translation out loud to close the simultaneous-interpretation loop
- [ ] **External agent glossary training** — improve the Hermes multi-language glossary
- [ ] **More i18n** — PRs welcome. Currently only Chinese and English UI; other languages untranslated.

> **Maintainers / AI agents**: For release process, see [SOP.md](SOP.md).

---

## ❓ FAQ

| Symptom | Cause | Fix |
|---|---|---|
| Subtitle window shows nothing | Speech recognition model misconfigured | Open Settings to check the ASR slot |
| Translation missing | LM Studio not running / network unreachable / translation disabled | Open Settings to check the translation model config |

---

## 📄 License

MIT License — see [LICENSE](LICENSE).

Third-party components (see [NOTICE](NOTICE)):
- **AudioTee** (MIT, by Nick Payne) — compiled into `bin/audiotee` for macOS system audio capture
- **Qwen3-ASR** (Apache 2.0) — Chinese ASR model
- **Nemotron 3.5 ASR** (NVIDIA Open Model License) — English ASR model
- **Tencent Hy-MT2** (Tencent Model License) — translation model (loaded via LM Studio / vLLM)

---

<!-- CONTRIBUTING -->
## Top contributors

[![Contributors](https://ghcontrib.pages.dev/image?repo=nbzz%2Fwhicc)](https://github.com/nbzz/whicc/graphs/contributors)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 🙏 Acknowledgements

- [mlx-audio](https://github.com/Blaizzy/mlx-audio) — Apple Silicon MLX inference framework
- [Tencent Hy-MT2](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF) — translation model
- [NVIDIA Nemotron](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) — ASR model
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B-4bit) — ASR model
- [LM Studio](https://lmstudio.ai/) — local LLM runner

---

> [LINUX DO](https://linux.do/) — a new kind of community, where tech enthusiasts gather.
