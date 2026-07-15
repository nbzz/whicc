# whicc

> **ASR model + translation model = real-time multilingual subtitle for any video.**
> 语言识别模型 + 翻译模型 = 全球多语种实时翻译字幕

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 15+](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4%2FM5-black.svg)](https://support.apple.com/en-us/116943)
[![Python 3.13](https://img.shields.io/badge/Python-3.13-blue.svg)](https://www.python.org/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://www.swift.org/)
[![CI](https://github.com/nbzz/whicc/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
[English](README.md) · [Docs](DEVELOPMENT.md)

<!-- 视觉资产 (文件说明见 docs/screenshots/README.md):
     1) docs/screenshots/icon.png   — 顶部 hero image, 应用图标
     2) docs/screenshots/demo.mov   — 38s 演示视频, 用 <video> 标签嵌入
     3) docs/screenshots/subtitle-*.png — 6 张实际效果截图, 2 行 3 列展示多语种字幕
-->
<p align="center">
  <img src="docs/screenshots/icon.png" alt="whicc app icon" width="240">
</p>

<p align="center">
  <video src="docs/screenshots/demo.mov" controls width="720" preload="metadata"></video>
</p>

<p align="center">
  <img src="docs/screenshots/subtitle-cn.png" width="32%" alt="英伟达黄仁勋访谈的中文字幕" />
  <img src="docs/screenshots/subtitle-es.png" width="32%" alt="西班牙语翻译成中文" />
  <img src="docs/screenshots/subtitle-ja.png" width="32%" alt="日语翻译成中文" />
  <br>
  <img src="docs/screenshots/subtitle-bilingual.png" width="32%" alt="英中双语字幕，带 YouTube 进度条" />
  <img src="docs/screenshots/subtitle-cn-stacked.png" width="32%" alt="多段堆叠的中文字幕" />
  <img src="docs/screenshots/subtitle-ar.png" width="32%" alt="阿拉伯语翻译成中文" />
</p>

**whicc** = **whi**(sper) + **cc**(closed captions) — 看外语视频时,屏幕上永远挂着一个本地算力撑起来的翻译字幕。

你不需要它完美。你只需要——**看不懂的时候,有个兜底**。
看任何语言的视频或直播,私有化的算力在为你实时翻译;
看 AI 访谈,术语可能时不时错一个,但整体跟得上;
噪声大的场景,识别会糊,翻译也会跟着糊——但**它一直在,不会消失**。

而且这套字幕会随着开源 ASR / 翻译模型的进化自动变强,模型越好,whicc 越好。

如果你在留学，上外语课，你可以使用麦克风模式，whicc 会把你听到的声音实时转成字幕，帮你跟上老师的讲课节奏。

---

## ✨ 核心特性

- **🛡️ 翻译兜底** — 看外语视频时,屏幕永远有字幕,心里永远有底，你本机/家中的算力永远在服务。
- **🖥️ 纯本地算力ASR和翻译 ** — Nemotron-3.5-ASR (非中文) + Qwen3-ASR (中文) 在 Apple Silicon (MLX) 上跑。**音频不出本机**,不依赖任何云端转写服务。
- **🌐 覆盖大多数语言** — 翻译后端用 Tencent Hy-MT2,支持中/英/日/德/法/西/俄/韩/阿/葡/意 等几十种语言任意互译,小语种也兜得住。
- **🔌 翻译服务由你提供** — whicc 自己不带翻译模型,你需要装 [LM Studio](https://lmstudio.ai/) 加载翻译模型(可以是本机 Mac、家里 Windows、局域网任何机器)。模型越大,翻译越好。
- **🪟 SwiftUI 浮岛字幕** — 浮窗自动隐藏/唤起,中英文自动切换。macOS 26 上是 Liquid Glass 液态玻璃,macOS 15 上退化为系统磨砂材质。
- **🤖 自学习术语库** — jieba 关键词抽取 + 场景检测 + Hermes Agent 术语搜索,术语自动沉淀到 glossary.json,下次翻译自动应用。
- **📈 模型越好它越好，世界越好它越好** — ASR 模型 / 翻译模型任一侧升级,whicc 字幕质量跟着提升。

---

## 📦 系统要求

| 类型 | 要求 |
|---|---|
| OS | **macOS 15+** (mlx 官方 wheel 提供 `macosx_15_0_arm64`;macOS 26 上有完整 Liquid Glass 视觉) |
| 芯片 | **Apple Silicon** (M1 / M2 / M3 / M4 / M5) |
| 磁盘 | 首次启动设置页下载 ASR 模型,约 **2 GB** |
| Python | 3.13 (用于源码开发模式,普通用户用 .app 无需) |

**翻译服务(必须 — 想要译文就必须装)**

whicc 自己不带翻译模型。翻译功能依赖外部 LM Studio / vLLM 节点提供 OpenAI 兼容 HTTP 接口。
没有它,屏幕上**只会一直显示 draft 字幕(滚动的部分识别结果),不会变成正式字幕,也不会进入历史列表**。

准备翻译服务(必须做这一步,否则没有翻译):

1. 装 [LM Studio](https://lmstudio.ai/) (本机或局域网任何一台机器都行,Windows / Mac / Linux 都支持)
2. 在 LM Studio 里加载翻译模型 — 推荐 `tencent/Hy-MT2-1.8B-GGUF`,机器够强就上 `Hy-MT2-7B-GGUF` 或更大,参数越大翻译越好
3. 在 LM Studio 启动 OpenAI 兼容 server (默认 `http://localhost:1234`)
4. 在 whicc 设置面板填这个 URL

翻译节点可以是你**本机的 Mac**,也可以是**家里另一台 Windows PC**、局域网里任何一台闲置机器、甚至外网云端 — 只要网络可达。

---

## 🚀 安装

### 普通用户(推荐)

1. 去 [Releases](../../releases) 下载最新的 `whicc-v1.0.0.dmg`
2. 双击 DMG 挂载,然后把 `whicc.app` 拖到 `/Applications/`
3. 首次启动时右键点击 `whicc.app`,选择“打开”

首次启动会自动打开设置面板(也可按 `⌘,` 或点齿轮):

1. **下载 ASR 模型** — HuggingFace 自动下载,需要通畅的网络环境
2. **准备翻译服务** — 在本机或局域网任何一台机器上装 [LM Studio](https://lmstudio.ai/),加载翻译模型(`tencent/Hy-MT2-1.8B-GGUF` 或更大),启动 OpenAI 兼容 server
3. **填翻译服务 URL** — 例 `http://192.168.1.10:1234`(本机填 `http://localhost:1234`),模型名填 LM Studio 实际加载的 ID
4. **开始看视频** — 打开任意外语视频/直播,字幕自动叠加

### 开发者(从源码跑)

看 [DEVELOPMENT.md](DEVELOPMENT.md) — 包含 CLI 参数、项目结构、核心机制、打包 `.app` 流程。

---

## 🏗️ 架构

```
系统音频 / 麦克风 (ScreenCaptureKit / mic)
        ↓  16kHz PCM chunks
   whicc.py (ASR)                    ← 本地 Apple Silicon MLX
   ├─ Qwen3-ASR-0.6B  (中文)
   └─ Nemotron-3.5-ASR (英文, two-pass correction)
        ↓  /tmp/whicc-out/events.jsonl        (partial + final 字幕事件)
   translate_stream.py               ← LM Studio / vLLM HTTP
        ↓  /tmp/whicc-out/translation_events.jsonl
   macui (SwiftUI 字幕浮岛)
        ↓
   glossary_refresher.py             ← jieba + Hermes Agent 自学习术语
```

**关键解耦**: ASR (重) 跑在本地 Mac,翻译 (HTTP 调用) 可以在任何有网络的机器。
翻译节点挂了不会影响 ASR 本地识别,字幕照样出原文。

详细架构图、打包模式、BackendLauncher 进程树见 [DEVELOPMENT.md](DEVELOPMENT.md#架构图-打包模式)。

---

## 🌍 支持的语言

| 用途 | 模型 | 支持 |
|---|---|---|
| ASR 识别 | Nemotron-3.5-ASR | 英文 + 自动检测 (中/日/韩/西/德/法 等) |
| ASR 识别 | Qwen3-ASR-0.6B | 中文 + 多种方言 |
| 翻译 | Tencent Hy-MT2 | **33 种语言任意互译** (中/英/日/德/法/西/俄/韩/阿/葡/意/荷/越/泰/印尼 等) |

默认以 Nemotron 启动,检测到 CJK 字符占比 >30% 时自动切到 Qwen3。

---

## ⚙️ 翻译配置

第一次启动翻译默认关闭。在 macui 设置面板(齿轮):

1. **服务配置 → 启用翻译** 打开
2. **主 URL** 填 LM Studio 地址(例 `http://192.168.1.10:1234`)
3. **备用 URL** 填本机 fallback(例 `http://localhost:1234`)
4. **模型名** 填 LM Studio 实际加载的模型 ID

配置文件 `/tmp/whicc-out/lang_config.json`:

```json
{
  "translation_enabled": true,
  "translation_url": "http://192.168.1.10:1234",
  "translation_fallback_url": "http://localhost:1234",
  "translation_model": "hy-mt2-7b"
}
```

主 URL 不通自动 fallback,全挂时字幕窗体显示"翻译服务不可用",draft 部分识别结果继续滚动(没有译文,也不会进历史列表)。

### 目标语言切换

macui 工具栏语言选择器实时切换,**无需重启**。
默认自动模式:中文↔英文互译。

### 场景 prompt 注入

设置面板填场景描述(例 `AI访谈` / `NBA总决赛`),会注入翻译 prompt 帮助模型理解上下文。

---

## 📺 字幕窗体

- **位置**: 屏幕顶部居中悬浮
- **自动隐藏**: 非焦点/非 hover 时整组 `opacity(0)` 不响应点击
- **双语字幕**: 现场切换"原文上 / 译文上"
- **7 个 accent 主题**: White / Ice / Gold / Neon / Coral / Violet / Cyan
- **液态玻璃**: macOS 26 上用 SwiftUI `GlassEffectContainer`,macOS 15 上退化为 `ultraThinMaterial` 磨砂兜底
- **中英文自动切换 ASR**: 标题栏左侧显示当前模型,3 秒自动消失

---

## 🛠️ 开发者

- 从源码运行: [DEVELOPMENT.md → 开发模式启动](DEVELOPMENT.md#开发模式启动)
- 完整 CLI 参数: [DEVELOPMENT.md → CLI 参考](DEVELOPMENT.md#cli-参数)
- 项目结构: [DEVELOPMENT.md → 项目结构](DEVELOPMENT.md#项目结构)
- 自己打包 `.app`: [DEVELOPMENT.md → 打包成 macOS .app](DEVELOPMENT.md#打包成-macos-app)
- 核心机制 (断句 / 翻译防护 / 术语库): [DEVELOPMENT.md → 核心机制](DEVELOPMENT.md#核心机制)

---

## 🗺️ 路线图

- [ ] **TTS 同声传译** — 翻译结果直接 TTS 播出来,形成完整同传闭环
- [ ] **外置 Agent 词库训练** — 优化hermes多语言术语库
- [ ] **优化 i18n** - 欢迎 PR,目前只支持中/英,其他语言界面未翻译

---

## ❓ 常见问题

| 现象 | 原因 | 修复 |
|---|---|---|
| 字幕窗体无任何字幕 | 语音识别模型异常 | 前往设置页检查配置 |
| 没有翻译的字幕 | LM Studio 未启动 / 网络不通 / 配置未启用 | 设置面板检查翻译模型配置 |

---

## 📄 许可证

MIT License — 见 [LICENSE](LICENSE)。

第三方组件(详见 [NOTICE](NOTICE)):
- **AudioTee** (MIT, by Nick Payne) — 编译进 `bin/audiotee` 的 macOS 系统音频采集
- **Qwen3-ASR** (Apache 2.0) — 中文 ASR 模型
- **Nemotron 3.5 ASR** (NVIDIA Open Model License) — 英文 ASR 模型
- **Tencent Hy-MT2** (Tencent Model License) — 翻译模型(在 LM Studio / vLLM 中加载)

---

<!-- CONTRIBUTING -->
## 顶级贡献者

[![Contributors](https://ghcontrib.pages.dev/image?repo=nbzz%2Fwhicc)](https://github.com/nbzz/whicc/graphs/contributors)

<p align="right">(<a href="#readme-top">回到顶部</a>)</p>

---

## 🙏 致谢

- [mlx-audio](https://github.com/Blaizzy/mlx-audio) — Apple Silicon MLX 推理框架
- [Tencent Hy-MT2](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF) — 翻译模型
- [NVIDIA Nemotron](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) — ASR 模型
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B-4bit) — ASR 模型
- [LM Studio](https://lmstudio.ai/) — 本地 LLM 运行器

---

> [LINUX DO](https://linux.do/) —— 新的理想型社区,技术爱好者的聚集地。
