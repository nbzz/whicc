# whicc — Development

这份文档面向开发者：从源码运行、改 Python / Swift 源码、自己打包 `.app`。

如果只是想用预编译好的 app，看 [README.md](README.md)。

## 目录

- [开发模式启动](#开发模式启动)
- [CLI 参数](#cli-参数)
- [项目结构](#项目结构)
- [依赖](#依赖)
- [日志与排查](#日志与排查)
- [核心机制](#核心机制)
- [路线图](#路线图)
- [本地化与翻译（i18n）](#本地化与翻译i18n)
- [CI / GitHub Actions](#ci--github-actions)
- [发布 Release](#发布-release)
- [打包成 macOS .app](#打包成-macos-app)
- [发布 SOP（给 AI / 协作者）](SOP.md)

## 开发模式启动

开发模式 = 自己起 Python 后端 + 自己 `swift run` 起 macui。适合改 Python 源码、调参数、看 stdout/stderr。

```bash
# 1. 启动 ASR 后端（whicc/ 根目录）
python3 src/whicc.py --events-jsonl /tmp/whicc-out/events.jsonl ... &

# 2. 启动翻译后端
python3 src/translate_stream.py \
    --events /tmp/whicc-out/events.jsonl \
    --out-dir /tmp/whicc-out ... &

# 3. 启动术语自学习（可选）
python3 src/glossary_refresher.py &

# 4. 启动字幕窗体（从 whicc/macui/ 跑）
cd whicc/macui
swift build
swift run whicc-macui /tmp/whicc-out/events.jsonl \
    --trans /tmp/whicc-out/translation_events.jsonl \
    --glossary /path/to/whicc/src --x 0 --y 1 --w 70 --h 13
```

**macui 二进制名**：开发模式叫 `whicc-macui`，打包后叫 `whicc`（`/Applications/whicc.app/Contents/MacOS/whicc`）。

**开发模式日志**（注意路径跟打包模式不一样，开发模式用 `/tmp/`）：

```bash
tail -f /tmp/whicc.log
tail -f /tmp/translate-stream.log
tail -f /tmp/macui.log           # 开发模式 macui 的 stderr
tail -f /tmp/glossary-refresher.log
```

> 打包版用户**用不到**开发模式——双击 `.app` 即可，Swift 启动时 `BackendLauncher` 自动 fork 4 个 Python 子进程 + 写 banner 启动 ping。

## CLI 参数

### whicc.py (ASR)

```
--model <id>              ASR 模型 ID 或本地路径
--mode streaming|batch    ASR 模式（默认 streaming）
--language auto|en|zh     语言（auto 启用自动检测）
--events-jsonl <file>     JSONL 事件输出路径（必须）
--min-chunk-sec 2.0       最小 chunk 时长
--max-chunk-sec 5.5       最大 chunk 时长
--dual-model              双模型预加载模式（秒切但耗内存）
--stats                   性能指标摘要
```

### translate_stream.py (翻译)

```
--events <file>           ASR 事件 JSONL 路径
--out-dir <dir>           翻译输出目录
--mode partial|final      partial=同声传译模式（推荐）
--target-lang <lang>      目标语言（auto / Japanese / de / ...）
--vllm-url <url>          主翻译节点 URL
--vllm-fallback-url <url> 远端不通时的本机 fallback (默认 http://localhost:1234)
--glossary <file>         术语表路径
--events-jsonl <file>     (旧) 输出事件文件，已弃用
```

翻译节点配置走 `lang_config.json`（macui 设置 → 服务配置），4 个键：
- `translation_url`：主 URL
- `translation_fallback_url`：本机 fallback URL
- `translation_enabled`：必须显式打开（默认 false）
- `translation_model`：远端 LM Studio 加载的模型名

### whicc-macui (字幕窗体)

```
whicc-macui <events-jsonl> [--trans <translation-jsonl>] [--glossary <dir>] [--x N] [--y N] [--w N] [--h N]
```

参数：
- `<events-jsonl>` (位置参数)：ASR 事件 JSONL 路径
- `--trans <file>`：翻译事件 JSONL 路径（可选）
- `--glossary <dir>`：术语表目录（包含 `glossary.json` 和 `_glossary_control.json`）
- `--x N --y N --w N --h N`：字幕窗体位置和大小

### model_downloader.py (模型下载守护进程)

`src/model_downloader.py` 是后台守护进程，由 BackendLauncher 启动。用户通过 macui UI
下载模型时，UI 写 `/tmp/whicc-out/model_download_request.json`，守护进程读请求后
调 `huggingface_hub.snapshot_download` 下载，进度写到 `model_download.jsonl` 供 UI
订阅。一般**不需要手动调用**。

如果需要手动管理本地模型（列出 / 清理），直接操作 `~/Library/Application Support/whicc/models/` 目录：

```bash
# 列出已下载
ls ~/Library/Application\ Support/whicc/models/

# 清理某个模型
rm -rf ~/Library/Application\ Support/whicc/models/mlx-community--Qwen3-ASR-0.6B-4bit
```

### event_agent.py (事件识别)

```bash
python3 src/event_agent.py              # 识别事件
python3 src/event_agent.py --confirm    # 用户确认后生成术语表
python3 src/event_agent.py --clear      # 清除事件，恢复用户场景
```

## 项目结构

```
whicc/
├── src/                       Python 后端
│   ├── whicc.py               ASR 转录引擎（多后端 + 软最大值断句 + VAD）
│   ├── translator_hy_mt2.py   翻译引擎（多语言 + 术语注入 + 防护 + 增量 + 观测）
│   ├── translate_stream.py    翻译消费流（JSONL 监听 + 语言热切换 + 场景热切换 + 临时词库合并）
│   ├── languages.py           33 种语言规范化（code / prompt_name / UI 标签）
│   ├── event_agent.py         事件识别 Agent（两阶段 Hermes，临时术语表 + 场景）
│   ├── glossary_refresher.py  自学习术语优化器（jieba + Hermes Agent）
│   ├── model_downloader.py    模型下载守护进程（macui 通信）
│   ├── model_state.py         模型状态兼容层（DEPRECATED_MODELS 修正老用户配置）
│   ├── audio.py               音频采集（mic 走 sounddevice，system 走 audiotee subprocess）
│   ├── config.py              共享配置（whicc.py / audio.py 协议常量）
│   └── glossary.json          永久术语表
│
├── macui/                     SwiftUI 字幕窗体
│   ├── Package.swift          Swift Package（macOS 26 SwiftUI）
│   ├── Info.plist             Bundle 配置
│   └── Sources/
│       ├── main.swift         App 入口 + NSPanel + 事件监听
│       ├── App/               窗口控制、快捷键监听、字幕面板
│       │   ├── OverlayWindowController.swift
│       │   ├── KeyMonitor.swift
│       │   └── SubtitlePanel.swift
│       ├── Models/            状态、事件、配置模型
│       │   ├── OverlayState.swift
│       │   ├── TranslationEvent.swift
│       │   ├── LangConfig.swift
│       │   ├── GlossaryState.swift
│       │   └── EventAgentState.swift
│       ├── Services/          后端服务封装
│       │   ├── EventWatcher.swift
│       │   ├── BackendShutdown.swift
│       │   └── CaptionClipboard.swift
│       ├── Components/        HUD、字幕、按钮、启动 banner 等
│       ├── Settings/          设置窗体（术语 / 场景 / 事件 / 服务）
│       ├── Theme/             颜色 / 字体 / 液态玻璃样式
│       └── Views/             顶层视图（ContentView / HUDView / SubtitleStageView）
│
├── tools/                     离线评估和参数扫描工具
│   ├── analyze_sweeps.py
│   ├── backtest.py
│   ├── latency_sweep.py
│   ├── prompt_sweep.sh
│   ├── sweep.py
│   └── whicc_file_audio.py
│
├── project.yml                xcodegen 项目定义（打包用）
├── whicc.xcodeproj            Xcode project（xcodegen 生成）
├── requirements.txt           Python 依赖清单
├── .vendor/audiotee           系统音频采集二进制（Swift）
└── bin/build_audiotee.sh      audiotee 编译脚本
```

### macui 设计要点

- macOS 26 SwiftUI：`Window` + `GlassEffectContainer` + `glassEffect()` + `ScrollPosition`
- HUD：顶部居中、悬浮；非焦点 / 非 hover 时整组 `opacity(0)` + 不响应点击
- 双语字幕：可现场切换"原文上 / 译文上"
- 7 个 accent 颜色（White / Ice / Gold / Neon / Coral / Violet / Cyan），应用于字幕文字
- 设置窗体：独立 `NSWindow`，macOS 26 `NavigationSplitView` 风格

### macui 实现要点

- **文件协议一致**：监听 `/tmp/whicc-out/events.jsonl` 和 `/tmp/whicc-out/*.json*`
- **Models 完全自写**：内部的 `OverlayState` / `LangConfig` / `GlossaryState` / `EventAgentState` / `EventWatcher`
- **Python 协议 0 改动**：macui 纯消费者，写 JSONL 由 Python 端决定
- **进程生命周期**：macui 退出时 `BackendShutdown` 自动 SIGTERM 所有后端子进程

## 依赖

**生产 venv ~325MB**（精简后）。清单锁定在 [`requirements.txt`](requirements.txt)，按业务分组。

### 装法

```bash
# 新机器
python3 -m venv venv
./venv/bin/pip install -r requirements.txt

# 系统音频源（macOS）
brew install portaudio

# 字幕窗体
cd macui && swift build
```

### 删除的依赖（1.2GB → 325MB，节省 73%）

本轮精简统一翻译后端到 HTTP（vLLM / LM Studio），删除本地 transformers 加载路径：
- `torch` (437MB) — 本地 transformers 翻译后端已删除，统一走 HTTP
- `transformers` (101MB) — 同上
- `sentencepiece` / `tokenizers` / `safetensors` / `numba` / `llvmlite` / `scipy` / `sympy` / `mpmath` / `networkx` — 间接依赖

翻译只走 vLLM / LM Studio HTTP 后端，不再保留本地加载模型的能力。

## 日志与排查

打包版（双击 `.app`）的日志统一在 `/tmp/whicc-out/logs/`：

```bash
tail -f /tmp/whicc-out/logs/whicc.log                  # ASR 转录
tail -f /tmp/whicc-out/logs/translate-stream.log       # 翻译
tail -f /tmp/whicc-out/logs/glossary-refresher.log     # 术语自学习
tail -f /tmp/whicc-out/logs/model-downloader.log       # 模型下载
```

macui 自身 stderr 写到 `/tmp/whicc-out/logs/whicc-stderr.log`。
GUI 启动信息看 **Console.app → 你的 Mac → "whicc"**。

### 翻译观测指标

翻译日志每条 final 都会输出：

```
[translate] en→Simplified Chinese bad=False retry=False leak=False boiler=False echo=False 515ms
[stream]    en→Simplified Chinese bad=False retry=False leak=False boiler=False echo=False 368ms
```

| 指标 | 含义 | 期望值 |
|------|------|--------|
| `bad` | 首轮输出是否异常（解释性前缀 / 脚本不匹配） | False |
| `retry` | 是否触发了重试 | False |
| `leak` | prompt 标签是否泄漏到输出（"待翻译文本"等） | False |
| `boiler` | 模板前缀是否需要清理（"根据背景信息"等） | False |
| `echo` | 上下文回显是否需要清理 | False |
| 数字 | 翻译耗时（毫秒） | <1000ms |

`bad=True` 超过 5% 说明需要调参；`leak=True` 频繁出现说明 prompt 要调整。

```bash
# 快速统计
grep -c 'retry=True' /tmp/whicc-out/logs/translate-stream.log
grep -c 'leak=True' /tmp/whicc-out/logs/translate-stream.log
grep -c 'bad=True'  /tmp/whicc-out/logs/translate-stream.log
grep -oP '\d+ms'    /tmp/whicc-out/logs/translate-stream.log | sort -n | tail -20
```

## 核心机制

### 软最大值断句（4.6s）

- 积累音频到 4.6s 时做一次快速 ASR
- 检测到句末标点（`。！？.!?`）→ 在 35 字之后的位置切割
- 没有句末标点但文字 > 35 字 → 用中间标点（`，、；：,;:`）切割（更严格：前半 ≥ 1.5s）
- 找不到好的切割点 → 每 0.6s 重试 ASR（音频在增长，可能识别出新标点）
- 没有标点 → 继续积累到 5.5s 硬切或静音提交
- 切割后剩余音频重新开始计时

### 自适应 chunk + 标点感知断句

- 能量 VAD 检测语音，静音 0.4s 后提交
- 上一句以句末标点结尾时，下一句 0.8s 就提交
- 超过 5.5s 强制提交

### 翻译防护

- **prompt 泄漏清理**: 去掉输出开头的 "待翻译文本"、"source text" 等标签
- **模板剥离**: 去掉 "根据背景信息，以下是翻译：" 等前缀
- **上下文回声检测**: 翻译与上一句 45%+ bigram 重叠 → 回退无上下文翻译
- **增量翻译**: 只翻译 ASR 新增的部分，不重翻整段
- **坏输出重试**: 检测到异常输出自动重试一次（用 extra_instruction 加强约束）

### 翻译 Prompt 架构

- 所有语言无 system prompt，纯 user message
- 中英互译用中文 prompt，其他语言用英文 prompt
- 上下文格式：原文 + 译文配对（不只传译文）
- 术语注入：官方示例格式（"A 翻译成 B"）
- 场景描述注入到 prompt

### 自学习术语库

- jieba 提取候选术语
- Hermes Agent 主动搜索术语
- 按来源质量自动过期（Hermes 7 天、web 3 天、lm 1 天）
- 用户可通过字幕窗体管理词库

### 系统音频看门狗

`whicc-audio` 进程 10 秒无数据自动重启。

### 模型 warmup

启动时对空音频推理一次，吸收 Metal kernel 编译延迟。

## 路线图

### P0 — 已完成

- **翻译输出防护**：模板前缀剥离 + 上下文回声检测（45% bigram）+ 坏输出重试
- **音频看门狗**：`whicc-audio` 10 秒无数据自动重启
- **模型 warmup**：启动时空音频推理，吸收 Metal kernel 编译延迟
- **标点感知断句**：句末标点结尾的句子 0.8s 就提交

### P1 — 部分完成

- ✅ **两遍校正**（Nemotron）：streaming + final 用 [56,13] 上下文窗口重新解码
- ⏳ **VAD gating**：计划用 Silero VAD (`mlx-community/silero-vad`) 替换能量阈值，对低信噪比音频更稳
- ⏳ **同声传译模式优化**：当前走 partial 增量翻译（边识别边译），后续基于 LLM 的语义断句替代标点断句，让中英交传 / 同传场景延迟更低、句意更连贯

### P2 — 长期方向

- **外置 Agent 词库优化**：把术语自学习能力外挂成独立 Agent，支持接入自己的 LLM（Claude / GPT / 本地模型）+ 自定义提取规则 + 对接外部知识库（Wikipedia / 公司 wiki）。当前 `glossary_refresher.py` 内置 Hermes Agent，会逐步把它做成可插拔
- **Push-style streaming encoder**：重写 mlx-audio 内部流式编码器，支持真正的实时麦克风输入（目前是基于 chunk 的）
- **Incremental mel spectrogram caching**：O(n²) → O(n)，长音频场景下延迟降一档
- **Speaker diarization**：NVIDIA Sortformer v2.1，多人对话场景区分发言人

## 本地化与翻译（i18n）

whicc UI 字符串走 SwiftUI 的 `LocalizedStringKey` + `Localizable.strings` 翻译表，**自动跟随 macOS 系统语言**。所有面向用户的字符串（包括 Settings 窗 + HUD 字幕栏）都通过这套机制本地化。

加新语言**不需要改任何 Swift 代码**——只用复制 + 翻译一个文件。

### 文件结构

```
macui/Sources/macui/Resources/
└── en.lproj/
    └── Localizable.strings   # 191 条 key，每条中文字面量 → 英文翻译
```

加新语言（以法语为例）就是新建 `fr.lproj/Localizable.strings`：

```bash
mkdir macui/Sources/macui/Resources/fr.lproj
cp macui/Sources/macui/Resources/en.lproj/Localizable.strings \
   macui/Sources/macui/Resources/fr.lproj/Localizable.strings
```

xcodegen 自动扫描所有 `*.lproj` 目录加入 Copy Bundle Resources build phase，**不需要改 `project.yml`**。`Package.swift` 也已声明 `defaultLocalization: "zh-Hans"`，SwiftPM 也认新目录。

### 翻译流程

打开新建的 `<lang>.lproj/Localizable.strings`，每行格式：

```
"<key>" = "<value>";
```

- **左边 `<key>` 不动** —— 它是 Swift 源码里的中文字面量，跟代码 1:1 对应。
- **只改右边 `<value>`**，填你目标语言的翻译。

例（en → fr）：

```
"字体" = "Font";                              → "字体" = "Police";
"保存并重启翻译服务" = "Save and restart..."; → "保存并重启翻译服务" = "Enregistrer et redémarrer...";
```

### Locale ID 选择

用 [BCP-47](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LanguageandLocaleIDs/LanguageandLocaleIDs.html) 标识符：

| 语言 | 目录名 |
|---|---|
| 英语（默认） | `en.lproj` |
| 法语 | `fr.lproj` |
| 日语 | `ja.lproj` |
| 德语 | `de.lproj` |
| 简体中文 | `zh-Hans.lproj`（**当前就是中文 fallback**，建了反而绕路，见下） |
| 繁体中文 | `zh-Hant.lproj` |
| 西班牙语 | `es.lproj` |
| 阿拉伯语 | `ar.lproj` |
| 葡萄牙语（巴西） | `pt-BR.lproj` |

### 关于中文 fallback

代码里所有 UI 字符串字面量是**中文**。SwiftUI 查表 fallback 链：

```
user locale → development region (en) → 代码字面量 (中文)
```

也就是说：
- zh-CN 系统 → 直接显示中文（代码字面量）
- en 系统 → 查 en.lproj 表
- fr 系统 → 查 fr.lproj 表
- fr 系统 + 某 key 漏翻译 → fallback 到 en.lproj；en 也漏 → fallback 中文

**所以不需要建 `zh-Hans.lproj`**。建了反而让 fallback 链变成「zh → en」绕远。

### 校验

```bash
# 1. plutil 语法校验（缺分号 / 引号不匹配会报错）
plutil -lint macui/Sources/macui/Resources/fr.lproj/Localizable.strings

# 2. 验证每个 key 在源码里有对应字面量（防拼写错误）
python3 -c "
import re, pathlib
keys = []
for line in pathlib.Path('macui/Sources/macui/Resources/fr.lproj/Localizable.strings').open():
    m = re.match(r'\"((?:[^\"\\\\]|\\\\.)*)\"\s*=\s*\"', line.strip())
    if m: keys.append(m.group(1))
src = list(pathlib.Path('macui/Sources/macui/').rglob('*.swift'))
unknown = [k for k in keys if not any(k in s.read_text() for s in src)]
print('Unknown keys:', unknown)
"

# 3. 构建 + 测试
xcodegen generate --spec project.yml --project .
xcodebuild -project whicc.xcodeproj -scheme whicc -configuration Release \
    -derivedDataPath build clean build
```

### 测试翻译

构建完后切换系统语言：

1. **系统设置 → 通用 → 语言与地区**
2. 把目标语言拖到「首选语言」列表顶部
3. **完全退出并重启 whicc.app**（应用启动时缓存 locale，重启前不会切换）
4. 打开 Settings 窗（⌘,）→ 看到对应翻译即成功

### 翻译时不要动的

- **品牌名**：`whicc` 本身、`Qwen3-ASR`、`Nemotron` 等模型 ID、`SF Pro Rounded` / `Times New Roman` 等字体名（这些都是 proper nouns）
- **`LangItem.label`**：33 种语言**自身**的名字（English / 中文 / 日本語 / हिन्दी / Tiếng Việt 等），按语言本身 native-script 写，不翻译成当地语言
- **左右大括号** `{}` 或 `%lld` 之类的占位符（如有）

### 复数语法（Phase 2，未上）

当前一些动态计数字符串（"5 entries"、"3 个 ASR 模型"）用 `Text + Text` 拼接，数字 verbatim，前后静态片段查表。**这意味着英文 locale 下 "1 entry" 也会显示成 "1 entries"**——因为我们没用 `.stringsdict` plural rule。

英文 en 复数形态（1 item vs 5 items）的正确处理要 `.stringsdict` + `String(format:)`，是 Phase 2 工作。如果你的语言复数语法复杂（阿拉伯语 6 种、波兰语 3 种），**强烈建议先开 issue 讨论**，再决定上不上 stringsdict。当前阶段：先做翻译，复数不一致可以接受。

### 维护者工具

合并 i18n PR 前，跑：

```bash
# 1. plutil 校验（CI 可加这一行）
plutil -lint macui/Sources/macui/Resources/<lang>.lproj/Localizable.strings

# 2. 自动验证所有 key 都有源字符串对应
# （脚本见上「校验」第 2 步）

# 3. 增量构建确认没破坏现有 en locale
xcodebuild -project whicc.xcodeproj -scheme whicc -configuration Release \
    -derivedDataPath build build
```

不要接受"PR 同时改了 Swift 代码"——i18n 翻译 PR 应当**只动 .strings 文件**，跨文件改动容易回归 en locale。

### 长期演进

- **5 个语种以内**：手工 PR 即可，无需翻译平台
- **5+ 个语种**：考虑接入 [Weblate](https://weblate.org/)（开源）或 Crowdin（商业）—— 翻译者用网页 UI 翻译，自动合并 PR，支持 plural rules
- **Phase 2**：`Localizable.stringsdict` 处理英文等复数语法 + Apple 推荐的 `Text("^[\(N) item](inflect: true)")` 形式，彻底消除 `Text + Text` deprecation warnings

### 截图与录屏规范

`docs/screenshots/` 放 README 顶部的视觉素材。具体规范、捕获方法、压缩命令见 [`docs/screenshots/README.md`](docs/screenshots/README.md)。

> **新 UI 改动前**：先想想这个改动能不能截图 / 录屏出来让人一眼看懂。如果能，给它补一张图，比 1000 字描述有效。

---

## CI / GitHub Actions

`.github/workflows/ci.yml` 在 push / PR 时跑：

1. **macOS 26 build** — `macos-15` runner + `xcodebuild -configuration Release` 完整 build，含 preBuildScripts 嵌入 Python 后端的步骤
2. **i18n syntax lint** — `plutil -lint` 校验每个 `*.lproj/Localizable.strings`（缺分号 / 引号不匹配会报错）
3. **i18n content check** — Python 脚本扫所有 key，确认每个 key 都对应 Swift 源码里的中文字面量，捕获"orphan key"（翻译 PR 引入了代码里不存在的 key）
4. **Artifact upload** — 构建好的 `whicc.app` 上传 7 天，可手动下载测试

CI 在 fresh macOS VM 上跑，**不依赖仓库里任何大文件**：`venv-standalone/` 是 `.gitignore` 的，CI 每次跑 `python3.13 -m venv` 重建然后软链接过去；`.xcodeproj` 也是 `.gitignore` 的，CI 跑 `xcodegen generate` 重新生成。

加 CI 状态徽章到 README：

```markdown
[![CI](https://github.com/OWNER/whicc/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)
```

`OWNER` 替换成你的 GitHub 用户名。

本地复现 CI 的 4 个步骤：

```bash
plutil -lint macui/Sources/macui/Resources/*.lproj/Localizable.strings

# python i18n key check
python3 - <<'PYEOF'
import re, pathlib
keys = []
for line in pathlib.Path("macui/Sources/macui/Resources/en.lproj/Localizable.strings").open():
    m = re.match(r'"((?:[^"\\]|\\.)*)"\s*=\s*"', line.strip())
    if m: keys.append(m.group(1))
src = list(pathlib.Path("macui/Sources/macui/").rglob("*.swift"))
orphan = [k for k in keys if not any(k in s.read_text() for s in src)]
print("orphan:", orphan or "none")
PYEOF

# 完整 build
xcodegen generate --spec project.yml --project .
xcodebuild -project whicc.xcodeproj -scheme whicc -configuration Release \
    -derivedDataPath build clean build
```

---

## 发布 Release

`.github/workflows/release.yml` 由 git tag 触发（`v*` 模式匹配 `v0.1.0` / `v1.2.3` 等），自动 build + 压缩 + 上传 GitHub Release。

### 发版流程

```bash
# 1. 准备 release commit (CHANGELOG / version bump / docs)
git checkout main
git pull
# ... 改代码、commit ...

# 2. 打 tag 并 push
git tag v0.1.0
git push origin v0.1.0

# 3. 等 ~5 分钟, GitHub Actions 跑完
#    - macos-15 runner 上 build Release
#    - ditto zip 出 whicc-v0.1.0.app.zip
#    - 生成 SHA256SUMS 校验文件
#    - 自动创建 GitHub Release v0.1.0 + 上传 zip
#    - 触发 softprops/action-gh-release 的 generate_release_notes
#      (从上一次 tag 到现在的 merged PR 列表自动生成发布说明)
```

用户在 GitHub Releases 页面下载 zip → 解压 → 拖到 `/Applications/` → 双击启动。

### ad-hoc 签名的限制

发布版用 ad-hoc 签名（跟 `xcodebuild` 本地 build 一样），不申请 Developer ID。这意味着：

- ✅ 不收费，不需 Apple Developer 账号
- ✅ 普通 Mac 用户能直接装
- ❌ **首次启动**要「右键 → 打开」绕过 Gatekeeper（不然 macOS 弹窗不让运行）
- ❌ 不会被 macOS 自动信任 / quarantine 标记为"安全"

适合个人项目 / 内测。要正式公开分发，再加：

```yaml
# 加到 release.yml 的 build 之后、zip 之前
- name: Sign with Developer ID
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    TEAM_ID: ${{ secrets.TEAM_ID }}
    NOTARYTOOL_PASSWORD: ${{ secrets.NOTARYTOOL_PASSWORD }}
  run: |
    codesign --deep --options=runtime --sign "Developer ID Application: $TEAM_ID" \
      build/Build/Products/Release/whicc.app
    xcrun notarytool submit build/Build/Products/Release/whicc.app \
      --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
      --password "$NOTARYTOOL_PASSWORD" --wait
    xcrun stapler staple build/Build/Products/Release/whicc.app
```

Apple Developer 账号年费 $99，公证（notarization）每个 release 几分钟。

### 不在 git 里的 release assets

13 MB `demo.mov` 当前进了 git（用户决定）。如果以后想给 release 瘦身：

- 把 `demo.mov` 加进 `.gitignore`
- 改 release.yml 上传前 step 用 `curl` 从外部拉（如 GitHub Release v0.0.x 的 asset）
- 仓库保持小，release 自带 demo

### 第一次 release

现在仓库是空的，**没有** `v0.0.x` tag。第一个 release 流程：

1. 第一次 push 到 GitHub（创建空 repo 之后）
2. CI 跑过 build（验证基础）
3. 手动打 `v0.1.0` tag
4. 等 release workflow
5. 第一次发版时 `whicc-v0.1.0.app.zip` 公开

不需要先发 beta —— 用户量小的话直发。

---

## 打包成 macOS .app

把整个 whicc 系统打包成单 `.app` bundle（含 Python 解释器 + 依赖 + 后端源码 + 图标），用户双击 `.app` 即可运行，无需先装 Python / venv / brew。

### 快速打包（5 行）

直接复制跑，xcodegen / venv-standalone 已 setup 过的话：

```bash
pkill -9 -f "Applications/whicc.app" 2>/dev/null
xcodegen generate --spec project.yml --project .
xcodebuild -project whicc.xcodeproj -scheme whicc -configuration Release -derivedDataPath build clean build
rm -rf /Applications/whicc.app && cp -R build/Build/Products/Release/whicc.app /Applications/whicc.app
open /Applications/whicc.app
```

> ⚠️ **xcodebuild 必须 `clean build`**，否则 preBuildScript 不重新跑，`.app` 里还是上次的旧 venv / 旧 `.icns`。
>
> 💡 **Dock 图标不刷新**：`killall Dock` 让 LaunchServices 重读 plist。
>
> 出问题再回来看下面"前置 / 一次性 setup / 每次打包"细节。

### 前置（一次性）

1. **Xcode 26**（macOS 26 SDK，MLX wheel 硬绑定 `macosx_26_0_arm64`）
2. **Python 3.13**（`/opt/homebrew/bin/python3.13` 或 `python3.13` 在 PATH）
3. **xcodegen**（`brew install xcodegen`）

### 一次性 setup

```bash
cd /path/to/whicc

# 1. 下载独立 Python 解释器 (25 MB, 无 homebrew 依赖 — 关键!)
#    这个解释器是 self-contained，不依赖系统 Python.framework，
#    打包出来的 .app 才能在没装 homebrew Python 的机器上跑。
curl -sL -o /tmp/cpython-standalone.tar.gz \
  "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.13.14+20260610-aarch64-apple-darwin-install_only_stripped.tar.gz"
mkdir -p /tmp/python-standalone
tar -xzf /tmp/cpython-standalone.tar.gz -C /tmp/python-standalone

# 2. 基于独立 Python 建 venv-standalone/ (打包用)
mkdir -p venv-standalone
cp -R /tmp/python-standalone/python/* venv-standalone/
./venv-standalone/bin/python3.13 -m ensurepip
./venv-standalone/bin/pip install --no-cache-dir -r requirements.txt   # ~556M slim, 不含 torch/whisper

# 3. 编译 audiotee (系统音频采集)
./bin/build_audiotee.sh
```

> ⚠️ **必须用 python-build-standalone**，**不能**用 `python3 -m venv`（系统 Python）。
> 后者会创建一个依赖 `/Library/Frameworks/Python.framework` 的 venv，
> 打包出来的 `.app` 在没装 homebrew Python 的机器上会 crash（动态链接
> Python framework 找不到）。
>
> 验证方法：`cat venv-standalone/pyvenv.cfg` 应该**没有** `home = /Library/Frameworks/...` 这行。

> **venv 用 slim 的好处**：torch / mlx-whisper / accelerate 已从
> `requirements.txt` 剔除（Nemotron ASR + Qwen3 走 mlx-lm，不需要它们）。venv-standalone
> ~556M vs 全装 1.3GB。

> **venv 已装过就不用重跑** — `pip install -r requirements.txt` 第二次跑会显示
> "Requirement already satisfied"，几秒结束。

### 每次打包（详细版）

跟"快速打包（5 行）"等价，只是多了 dev 残留清理 + 大小校验 + 后台启动备选：

```bash
cd /path/to/whicc

# 1. 杀掉之前所有 whicc 后端（开发模式可能残留），避免抢同一个 events.jsonl
pkill -9 -f "Applications/whicc.app\|whicc.py\|translate_stream.py\|glossary_refresher\|model_downloader\|audiotee" || true

# 2. 生成 Xcode project（project.yml → whicc.xcodeproj）
xcodegen generate

# 3. Clean + Build Release（preBuildScript 自动嵌入 venv + src + bin + AppIcon.icns）
xcodebuild -project whicc.xcodeproj -scheme whicc \
  -configuration Release -derivedDataPath build clean build

# 4. 装到 /Applications
rm -rf /Applications/whicc.app
cp -R build/Build/Products/Release/whicc.app /Applications/whicc.app
du -sh /Applications/whicc.app           # 应 ~566MB

# 5. 启动
open /Applications/whicc.app
# 或后台跑：
/Applications/whicc.app/Contents/MacOS/whicc &
```

### .app 内部结构

```
/Applications/whicc.app/
├── Contents/
│   ├── Info.plist              (com.whicc.app, CFBundleIconFile=AppIcon, macOS 26)
│   ├── MacOS/whicc             SwiftUI 字幕窗体二进制
│   ├── Resources/
│   │   ├── src/                Python 后端源码 (11 .py)
│   │   ├── venv/               独立 Python + 所有依赖 (~556MB slim)
│   │   ├── bin/audiotee        系统音频采集二进制
│   │   └── AppIcon.icns        App 图标 (1.8MB, 10 个尺寸 slot)
│   └── _CodeSignature/         Adhoc 签名
```

### 运行数据目录（macOS 26 行为）

- 运行时数据：`/tmp/whicc-out/`（避免 `~/Library/Application Support` 路径 lookup bug）
- 用户配置：macui 写到 `/tmp/whicc-out/lang_config.json` 等
- 日志：`/tmp/whicc-out/logs/{whicc,translate-stream,glossary-refresher,model-downloader}.log`

### 已知限制

- **Adhoc 签名** — 不能发布给其他 Mac。正式分发需 Developer ID + 公证。
- **MLX wheel 硬绑定** `macosx_26_0_arm64` — Intel Mac / 旧 macOS 不可用。
- **~566MB 安装包** — venv 装满所有依赖（slim 版）。已知间接依赖（~97MB scipy
  来自 mlx-audio）未剔除，需要时手动 delete。

### 架构图（打包模式）

```
用户双击 /Applications/whicc.app
  ↓
SwiftUI 字幕窗体 (LSUIElement=false, 有 Dock 图标)
  ↓ 启动 banner 显示 "正在初始化 whicc…" → … → "正在聆听" → "准备就绪 · X.XXs"
  ↓ BackendLauncher 启动 4 个 Python 子进程,等 ASR ready 后写 banner pings
┌─ whicc.py              ASR (Nemotron / Qwen3 / MLX)
├─ translate_stream.py   翻译 (远端 vLLM + fallback LM Studio)
├─ glossary_refresher.py 术语自学习
└─ model_downloader.py   模型下载守护进程
  ↓
所有进程用 .app/Contents/Resources/venv/bin/python3
  ↓
/tmp/whicc-out/{events,translation_events}.jsonl (流式字幕)
```