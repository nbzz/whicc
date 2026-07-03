import Foundation
import SwiftUI

// MARK: - Caption

/// A committed subtitle. Source key is the identity; everything else is
/// presentation.
struct OverlayCaption: Identifiable, Equatable {
    let id: String          // source_key from event
    var sourceText: String
    var translatedText: String
    var mode: String        // append_only / small_rewrite_tail / reset_full / partial_cache_hit
    var translateMs: Double
}

// MARK: - Bilingual layout

/// Which language sits on top.
enum BilingualLayout: String, CaseIterable, Identifiable {
    case translationTop   // 译文上 / 原文下
    case sourceTop        // 原文上 / 译文下
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .translationTop: return "arrow.down.to.line"
        case .sourceTop:      return "arrow.up.to.line"
        }
    }

    var help: String {
        switch self {
        case .translationTop: return "译文在上"
        case .sourceTop:      return "原文在上"
        }
    }
}

// MARK: - Audio source

/// HUD ASR chip 显示的音频采集源。
///  - `.system`: 系统声音（audiotee + ScreenCaptureKit）
///  - `.mic`: 内置麦克风（sounddevice + PortAudio）
/// 持久化在 lang_config.json 的 audio_source 键；macui chip 点击切这个
/// 字段 + 发 SIGHUP 给 whicc.py 触发热切换。
enum AudioSource: String, CaseIterable, Identifiable, Sendable {
    case system
    case mic

    var id: String { rawValue }

    /// SF Symbol 名给 StatusChips asrChip 的 icon。
    /// 跟 feat/mic-source-toggle 分支的 AudioSourceController 同款命名。
    var icon: String {
        switch self {
        case .system: return "speaker.wave.2.fill"
        case .mic:    return "mic.fill"
        }
    }

    /// HUD chip 上显示的简短名（i18n 暂时 hardcode 中文）。
    var displayName: String {
        switch self {
        case .system: return "系统"
        case .mic:    return "麦克"
        }
    }
}

// MARK: - Tunable bounds

private enum FontLimit {
    static let transMin: CGFloat = 12
    static let transMax: CGFloat = 48
    static let transStep: CGFloat = 2

    static let srcMin: CGFloat = 9
    static let srcMax: CGFloat = 36
    static let srcStep: CGFloat = 1.5
}

// MARK: - Startup summary
//
// BackendLauncher 在 .app 启动时写一组 "init-…" translation_final
// events 作为 banner 启动 ping
// ("ASR: …", "Translation: …", "Loading complete | 3.2s",
// "whicc is listening")。这些是 caption-shape 的 events,但不是真
// 字幕 — 是状态 ping。我们按 `source_key` 前缀抓,不让它们进 `history`,
// 拼成 macOS 风格 Liquid Glass banner。

struct StartupSummary: Equatable {
    /// macOS 启动阶段进度:UI 用它显示"正在初始化 whicc…" / "正在启动
    /// 后端…" / "正在扫描模型…" / "正在聆听" 等。
    /// 后端 (whicc.py 等) 完成初始化前,Swift 端主动设置这些阶段,
    /// 让用户在 Dock 图标 + banner 都出现之前看到进度。
    var stage: StartupStage = .initializing
    var asr: String?
    var translation: String?
    var hermes: String?
    var loadSeconds: String?
    /// Set to `true` when we see the final "whicc is listening" ping.
    /// The banner stays in the "ready" state until either this flips
    /// or a real subtitle arrives.
    var listening: Bool = false

    var isEmpty: Bool {
        asr == nil && translation == nil && hermes == nil && loadSeconds == nil
    }
}

/// Swift 端启动进度阶段。
/// main.swift 在 applicationDidFinishLaunching 中按顺序推进:
///   .initializing     - 解析 CLI / 建模型
///   .launchingBackends - 启动 4 个 Python 子进程
///   .scanningModels   - ModelState 递归扫描模型目录
///   .listening        - 就绪 (由后端 ping 或 backend spawn 全完成后设置)
enum StartupStage: String, Equatable {
    case initializing
    case launchingBackends
    case scanningModels
    case listening

    /// 显示文案。listening 后会被 banner 的"准备就绪"覆盖。
    var displayText: String {
        switch self {
        case .initializing:      return "正在初始化 whicc…"
        case .launchingBackends: return "正在启动后端…"
        case .scanningModels:    return "正在扫描模型…"
        case .listening:         return "正在聆听"
        }
    }
}

private enum BannerText {
    static let asrPrefix        = "ASR: "
    static let translationPrefix = "Translation: "  // English-side
    static let translationZhPrefix = "翻译: "
    static let hermesAccessible = "Glossary: Hermes accessible"
    static let hermesUnreachable = "Glossary: Hermes unreachable"
    static let hermesZhAccessible = "术语: Hermes 可访问"
    static let hermesZhUnreachable = "术语: Hermes 不可达"
    static let loadPrefix = "Startup complete | "
    static let loadZhPrefix = "加载完成 | "
    static let listening = "whicc is listening"
    static let listeningZh = "whicc 正在聆听"

    /// Initial banner ping from the loader, before the ASR even
    /// finishes warming up. We just absorb it; the banner is already
    /// showing "loading".
    static let warming = "Model warming up"
    static let warmingZh = "模型预热中"
}

// MARK: - Overlay state

@MainActor
final class OverlayState: ObservableObject {

    // MARK: Published state

    @Published var committed: OverlayCaption?

    /// Partial ASR text — shown below committed (or above, see bilingualLayout)
    @Published var draftSourceText: String?
    @Published var draftTranslatedText: String?
    @Published var draftStablePrefixLen: Int = 0

    /// History (most-recent last), capped at 80.
    @Published var history: [OverlayCaption] = []
    let maxHistory = 80

    /// Startup banner — assembled from the `init-…` events emitted by
    /// `BackendLauncher` (打包模式启动时写)。`nil` once the first real
    /// subtitle arrives (or after 6 seconds of silence past the last
    /// init ping).
    @Published var startupSummary: StartupSummary?
    @Published var startupBannerVisible: Bool = false

    // Counters
    @Published var totalTranslated: Int = 0
    @Published var totalErrors: Int = 0

    // ASR status banner (transient)
    @Published var statusText: String?
    @Published var statusColor: Color = .white.opacity(0.40)
    private var statusExpireTime: Date = .distantPast

    // ASR backend name (parsed from `status` events)
    @Published var asrBackend: String = "nemotron"

    // Lost drafts log
    private static var lostDraftsPath: String { AppPaths.runDir + "/lost_drafts.jsonl" }
    private var pendingDraftSrc: String?
    private var pendingDraftTrans: String?
    private var pendingDraftTs: Double = 0

    // Font sizes
    @Published var transFontSize: CGFloat = 32
    @Published var srcFontSize: CGFloat = 18

    // Visibility / layout
    @Published var showSource: Bool = true
    @Published var showHistory: Bool = true
    @Published var bilingualLayout: BilingualLayout = .translationTop
    /// Remember the user's manual preference for source visibility.
    @Published var userWantsSource: Bool = true

    // Subtitle typeface (user-pickable from the HUD)
    @Published var fontChoice: SubtitleFont = .rounded

    /// 用户收藏的字体——HUD A 按钮在 [.rounded, .serif] + 收藏集合
    /// 之间循环。AppearancePane 里的五角星按钮 toggle 这个列表。
    /// 同步存到 LangConfig.favoriteFonts (持久化),这里只是运行时
    /// 镜像,cycleFont 读这个字段。
    @Published var favoriteFonts: [SubtitleFont] = []


    // Subtitle accent color. Used to live in `ContentView` as @State
    // and was never persisted — moving it here so the Settings pane
    // can read/write it through the same path as `fontChoice`.
    @Published var style: OverlayStyle = .white
    /// 自定义色（`style == .custom` 时使用）。默认 nil = 没自定义过。
    /// 渲染字幕时，`OverlayState.resolvedAccent` 优先用 customColor，
    /// 否则 fallback 到 style.accent。
    @Published var customColor: Color? = nil

    // Background opacity
    @Published var bgOpacity: CGFloat = 0.85

    /// 音频采集源——HUD ASR chip 的 icon (speaker / mic) 跟它绑定。
    /// 点击 chip 切换 → state.audioSource 立即改 → 写 lang_config.json
    /// → 给 whicc.py 发 SIGHUP 触发热切换。读 langConfig.audioSource
    /// 解析；非法值 fall back 到 .system。
    @Published var audioSource: AudioSource = .system

    // 文字描边 / 阴影强度（用户可调）。SubtitleCaption 内部
    // 用 .shadow() 渲染，跟 Palette.textShadowRadius 一起用。
    // strong = 大模糊半径的主描边（保证低对比度背景可读）
    // soft = 小模糊半径的次描边（增强边缘锐度）
    @Published var strongShadowOpacity: Double = 0.70
    @Published var softShadowOpacity: Double = 0.40
    @Published var strongShadowRadius: CGFloat = 16
    @Published var softShadowRadius: CGFloat = 4

    /// 用户在 AppearancePane 里调节外观时 → true（持续 5s）。
    /// 让没字幕时显示项目简介作为"调节中的视觉参考"。关掉 Pane / 不
    /// 操作 5s 后自动重置为 false，字幕区恢复空白。
    /// 这样保证字幕区平时是干净的，不会被一个常驻的占位卡打扰。
    @Published var showIdlePreview: Bool = false
    private var idlePreviewExpire: Date = .distantPast

    func pingIdlePreview() {
        showIdlePreview = true
        idlePreviewExpire = Date().addingTimeInterval(5.0)
    }

    /// 在 timer tick 里跑——检查 5s 过期。
    func tickIdlePreview() {
        if showIdlePreview, Date() >= idlePreviewExpire {
            showIdlePreview = false
        }
    }

    // HUD chrome (driven by hover / key window). Default-visible so
    // the user sees controls immediately on launch; hover still
    // toggles fade for a clean look during drag-select.
    @Published var isChromeVisible: Bool = true
    @Published var isWindowActive: Bool = true

    // Measured HUD plate height, reported up via `HUDHeightKey` from
    // `ContentView`. `SubtitleStageView` reads this to keep the
    // committed caption clear of the HUD's footprint.
    @Published var hudHeight: CGFloat = 0

    // MARK: - Init

    /// We don't keep a strong reference to `LangConfig` — the
    /// settings window owns that. We just borrow it once at init
    /// time to seed the persisted appearance defaults.
    ///
    /// Five appearance fields are restored here:
    /// - `fontChoice` (SubtitleFont raw value)
    /// - `style` (OverlayStyle raw value, the accent color)
    /// - `transFontSize` / `srcFontSize` (caption line heights)
    /// - `bgOpacity` (window background opacity)
    ///
    /// Unknown / missing keys fall back to the hard-coded default
    /// above so a stale `lang_config.json` never bricks the UI.
    init(langConfig: LangConfig? = nil) {
        guard let langConfig else { return }
        if let restored = SubtitleFont(rawValue: langConfig.subtitleFont) {
            fontChoice = restored
        }
        // 收藏字体：解析 rawValue 列表 → SubtitleFont。失败的 rawValue
        // 跳过（旧配置文件里手工塞的脏数据不会让 UI 崩溃）。
        // 空数组 = HUD 仅循环两个默认(.rounded + .serif)。
        favoriteFonts = langConfig.favoriteFonts.compactMap { SubtitleFont(rawValue: $0) }
        if let restored = OverlayStyle(rawValue: langConfig.subtitleColor) {
            style = restored
        } else {
            // 旧 rawValue (theater / ice / gold / neon / coral / violet /
            // cyan / clay) 兼容 — 颜色系统升级后旧配置不识别。
            style = OverlayStyle.fromRaw(langConfig.subtitleColor)
        }
        // 解析 custom_color_hex（#RRGGBB 或 #RRGGBBAA）。空字符串或解析失败
        // → nil（让渲染端 fallback 到 style.accent）。失败的 hex 不抛错，
        // 老配置文件里如果有手工塞的脏数据也不会让 UI 崩溃。
        if !langConfig.customColorHex.isEmpty,
           let parsed = Self.colorFromHex(langConfig.customColorHex) {
            customColor = parsed
        }
        if langConfig.transFontSize > 0 {
            transFontSize = langConfig.transFontSize
        }
        if langConfig.srcFontSize > 0 {
            srcFontSize = langConfig.srcFontSize
        }
        if langConfig.bgOpacity > 0 {
            bgOpacity = langConfig.bgOpacity
        }
        // audio_source: 非法/空 rawValue 解析失败 → 保持默认 .system。
        // macui Settings 里改这个键 → SIGHUP whicc.py 热切换。
        if let parsed = AudioSource(rawValue: langConfig.audioSource) {
            audioSource = parsed
        }
        // 阴影参数——存 0~1 / 0~N。strongShadow 默认 0.7 跟 Palette 之前
        // hard-coded 一致，softShadow 默认 0.4 同。radius 默认 16/4
        // 跟 Palette.textShadowRadius/textShadowSoftRadius 一致。
        // LangConfig 没这 4 键时用 default；0 或负值视为未设。
        if langConfig.strongShadowOpacity > 0 {
            strongShadowOpacity = langConfig.strongShadowOpacity
        }
        if langConfig.softShadowOpacity > 0 {
            softShadowOpacity = langConfig.softShadowOpacity
        }
        if langConfig.strongShadowRadius > 0 {
            strongShadowRadius = langConfig.strongShadowRadius
        }
        if langConfig.softShadowRadius > 0 {
            softShadowRadius = langConfig.softShadowRadius
        }
    }

    // MARK: - Event dispatch

    /// Apply a translation event from `translation_events.jsonl`.
    /// 这个 watcher 处理的事件类型(由 translate_stream.py 写入):
    /// - translation_partial (含 streaming token)
    /// - translation_final / translation_reset
    /// - translation_error
    /// - init-* (启动 banner ping,见 BackendLauncher.writeStartupPings)
    ///
    /// 下面 switch 里的 `case "partial"` / `case "final"` / `case "status"`
    /// 分支是为兼容历史 whicc.py 已经合并的事件流写的,当前 main.swift args
    /// 下走不到(events.jsonl 走 applyTranscription),但留着不影响行为 —
    /// 改 args 时不需要同时改这段。
    func apply(_ event: TranslationEvent) {
        // Startup banner pings:BackendLauncher 在 .app 启动时写 init-…
        // caption events 跟用户对话。我们把它们挡在这,不进 `history`,
        // 不显示成真字幕。 The
        // first non-init event closes the banner.
        if let key = event.sourceKey, key.hasPrefix("init-") {
            applyStartupPing(translated: event.translatedFullText,
                             source: event.sourceText)
            return
        }

        switch event.eventType {
        case "translation_final", "translation_reset":
            applyFinal(event)
        case "translation_partial":
            // Streaming-token events carry the cumulative translation
            // in `translatedFullText`. Skip the stable-prefix /
            // deduplication machinery in applyPartial — the caller
            // wants the latest cumulative verbatim, not the
            // partial diff against an earlier snapshot. Legacy
            // (non-streaming) partials still go through the
            // diff-based path.
            if event.isStreamingToken == true,
               let full = event.translatedFullText {
                draftTranslatedText = full
                // draftStablePrefixLen is intentionally left alone —
                // streaming tokens are append-only, so the "stable"
                // prefix is whatever was stable before the stream
                // started.
            } else {
                applyPartial(event)
            }
        case "translation_error":
            totalErrors += 1

        // Whicc transcription events (already-merged pipeline)
        case "partial":
            if let text = event.text, !text.isEmpty {
                draftSourceText = Self.deduplicateRepeated(text)
                draftStablePrefixLen = 0
                draftTranslatedText = nil
            }
        case "final":
            if let text = event.text, !text.isEmpty {
                let key = event.sourceKey ?? UUID().uuidString
                let caption = OverlayCaption(
                    id: key,
                    sourceText: text,
                    translatedText: "",
                    mode: "final",
                    translateMs: event.translateMs ?? 0
                )
                withAnimation(.easeOut(duration: 0.18)) {
                    if let current = committed {
                        history.append(current)
                        if history.count > maxHistory {
                            history.removeFirst(history.count - maxHistory)
                        }
                    }
                    committed = caption
                }
                clearDraft()
                totalTranslated += 1
            }
        case "status":
            handleStatus(event.status ?? "", colorKey: event.statusColor)

        default:
            break
        }
    }

    /// Fast path: ASR-only events from the secondary transcription file
    /// (events.jsonl, written by whicc.py)。状态/部分识别走这条路。
    /// 字幕最终提交走 apply() 那条 (translation_final 带翻译) — 详见下。
    ///
    /// 历史:之前一度让这里 commit ASR final,但导致翻译模式下 UI 抖一下
    /// (commit 一个"无翻译"caption → 紧接着 apply 的 translation_final 再
    /// commit 一个"有翻译"caption 顶掉它,正式字幕先显示原文 → 闪现翻译)。
    ///
    /// 那次引入的理由是"修纯 ASR 模式下字幕卡 draft",但忘了:
    /// - 打包模式 BackendLauncher 用 --force-enable 启动 translate_stream,
    ///   即使 lang_config.translationEnabled=False,translate_stream 也跑。
    /// - translate_stream 总是消费 ASR final 后发 translation_final。
    /// - apply() 的 applyFinal 处理 translation_final — caption 由这里 commit。
    /// 所以"纯 ASR 模式字幕卡 draft"在打包版本不成立,字幕永远由 apply() 走。
    ///
    /// dev mode (用户自己用 swift run) 下 lang_config.translationEnabled=False
    /// 时 translate_stream 会 sys.exit(1) 退出,不参与转写。翻译流不在了
    /// → ASR final 没人接 → 字幕卡 draft。这是 dev mode 期望行为还是 bug,
    /// 留给 P0 #5 决定;此处不动避免误改产品语义。
    ///
    /// draft 清理:draftTranslatedText 可能在翻译模式残留(用户切回纯 ASR)。
    /// partial 来时只在残留非 nil 时清,纯 ASR 模式下 draftTranslatedText
    /// 始终 nil,跳过无意义的写。
    func applyTranscription(_ event: TranslationEvent) {
        switch event.eventType {
        case "partial":
            if let text = event.text, !text.isEmpty {
                draftSourceText = Self.deduplicateRepeated(text)
                draftStablePrefixLen = 0
                if draftTranslatedText != nil {
                    draftTranslatedText = nil
                }
            }
        case "status":
            handleStatus(event.status ?? "", colorKey: event.statusColor)
        default:
            // events.jsonl 的 "final" 事件(纯 ASR final)走这里 ——
            // 字幕最终提交由 apply() 的 translation_final 路径负责,不在这里。
            break
        }
    }

    // MARK: - Draft → Final

    private func applyPartial(_ event: TranslationEvent) {
        let src = event.sourceText ?? event.deltaSourceText ?? ""
        let trans = event.translatedDeltaText ?? event.translatedFullText

        // Log only "complete" drafts that get replaced before becoming final.
        if let oldSrc = pendingDraftSrc, let oldTrans = pendingDraftTrans,
           !oldSrc.isEmpty, !oldTrans.isEmpty,
           oldSrc != src,
           Self.isCompleteSentence(oldTrans) {
            logLostDraft(src: oldSrc, trans: oldTrans, reason: "complete_sentence_replaced")
        }

        if !src.isEmpty { draftSourceText = Self.deduplicateRepeated(src) }
        draftTranslatedText = trans.map { Self.deduplicateRepeated($0) }
        draftStablePrefixLen = event.sharedPrefixLen ?? 0

        if let t = trans, !t.isEmpty {
            pendingDraftSrc = src
            pendingDraftTrans = t
            pendingDraftTs = Date().timeIntervalSince1970
        }
    }

    private func applyFinal(_ event: TranslationEvent) {
        guard let sourceText = event.sourceText,
              let translatedText = event.translatedFullText else { return }

        let key = event.sourceKey ?? UUID().uuidString
        let caption = OverlayCaption(
            id: key,
            sourceText: sourceText,
            translatedText: translatedText,
            mode: event.sourceUpdateMode ?? "unknown",
            translateMs: event.translateMs ?? 0
        )

        withAnimation(.easeOut(duration: 0.18)) {
            if let current = committed, current.id != caption.id {
                history.append(current)
                if history.count > maxHistory {
                    history.removeFirst(history.count - maxHistory)
                }
            }
            committed = caption
        }
        clearDraft()
        pendingDraftSrc = nil
        pendingDraftTrans = nil
        totalTranslated += 1
        // Real subtitle arrived — dismiss the startup banner.
        dismissStartupBanner(animated: true)
    }

    // MARK: - Startup banner

    private func applyStartupPing(translated: String?, source: String?) {
        // The translated text is the authoritative form (the shell always
        // sends both, but the translated one is what the user would
        // actually see). The source side is only used as a fallback.
        let text = (translated?.isEmpty == false ? translated : source) ?? ""
        guard !text.isEmpty else { return }

        if var summary = startupSummary {
            applyStartupText(text, into: &summary)
            startupSummary = summary
        } else {
            var summary = StartupSummary()
            applyStartupText(text, into: &summary)
            startupSummary = summary
            // First non-empty ping — show the banner.
            withAnimation(.easeOut(duration: 0.32)) {
                startupBannerVisible = true
            }
        }

        // If we see "listening", the banner becomes a quieter "ready"
        // state. We keep it visible briefly so the user can read it,
        // then auto-dismiss. 1.8s 够读一行 banner 内容(ASR · 翻译 · Hermes ·
        // load time)但不会挡住字幕太长时间——启动阶段过去后立刻让位。
        if let s = startupSummary, s.listening {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                self?.dismissStartupBanner(animated: true)
            }
        }
    }

    private func applyStartupText(_ text: String, into summary: inout StartupSummary) {
        if text.hasPrefix(BannerText.asrPrefix) {
            summary.asr = String(text.dropFirst(BannerText.asrPrefix.count))
        } else if text.hasPrefix(BannerText.translationZhPrefix) {
            summary.translation = String(text.dropFirst(BannerText.translationZhPrefix.count))
        } else if text.hasPrefix(BannerText.translationPrefix) {
            summary.translation = String(text.dropFirst(BannerText.translationPrefix.count))
        } else if text == BannerText.hermesAccessible || text == BannerText.hermesZhAccessible {
            summary.hermes = "✓"
        } else if text == BannerText.hermesUnreachable || text == BannerText.hermesZhUnreachable {
            summary.hermes = "✗"
        } else if text.hasPrefix(BannerText.loadPrefix) {
            summary.loadSeconds = String(text.dropFirst(BannerText.loadPrefix.count))
        } else if text.hasPrefix(BannerText.loadZhPrefix) {
            summary.loadSeconds = String(text.dropFirst(BannerText.loadZhPrefix.count))
        } else if text == BannerText.listening || text == BannerText.listeningZh {
            summary.listening = true
        }
        // "Model warming up" / "模型预热中" — implicitly absorbed: we
        // don't have anything to record yet, the banner just stays
        // blank until ASR/translation pings land.
    }

    func dismissStartupBanner(animated: Bool) {
        guard startupBannerVisible else { return }
        if animated {
            withAnimation(.easeIn(duration: 0.22)) {
                startupBannerVisible = false
            }
        } else {
            startupBannerVisible = false
        }
    }

    func clearDraft() {
        draftSourceText = nil
        draftTranslatedText = nil
        draftStablePrefixLen = 0
    }

    // MARK: - Visibility controls

    func toggleSourceVisibility() {
        showSource.toggle()
        userWantsSource = showSource
    }

    func cycleBilingualLayout() {
        bilingualLayout = (bilingualLayout == .translationTop) ? .sourceTop : .translationTop
    }

    /// HUD 字体循环按钮：在 [.rounded, .serif] + 用户收藏 (`favoriteFonts`)
    /// 的合集里循环。
    ///
    /// 设计: HUD 循环是"用户快速切到自己关心的字体"的快捷列表,
    /// 跟"当前在用哪个字体" (`fontChoice`) 解耦。
    ///
    /// - 默认两个 (.rounded / .serif) 永远在合集里,保证 HUD 至少有
    ///   2 项可切。
    /// - favoriteFonts 里的字体是用户显式收藏的(点击五角星 toggle),
    ///   HUD 循环里也包含。
    /// - **不**自动包含 fontChoice — 之前这么写导致用户从列表选了
    ///   一个字体就被加进循环,跟"点击五角星才收藏"的预期不符
    ///   (见 commit 2a108e0 的同款解耦修复)。
    /// - 用户选了一个非收藏字体后,按 HUD A 按钮会跳到收藏字体 /
    ///   默认字体,这是预期行为 — 用户的"快速切"快捷列表由收藏按钮
    ///   显式控制。
    /// - 去重:rounded/serif/favoriteFonts 可能重复添加,保留首次
    ///   出现的顺序。
    func cycleFont() {
        var hudCycle: [SubtitleFont] = [.rounded, .serif]
        for fav in favoriteFonts {
            if !hudCycle.contains(fav) {
                hudCycle.append(fav)
            }
        }
        guard !hudCycle.isEmpty else {
            // 防御:合集总为空(不该发生,默认 2 项永远在)
            fontChoice = .rounded
            return
        }
        if let i = hudCycle.firstIndex(of: fontChoice) {
            fontChoice = hudCycle[(i + 1) % hudCycle.count]
        } else {
            // 当前字体不在循环里(用户选了非收藏的系统字体):
            // 跳到第一个收藏/默认字体。这是预期行为 — HUD 不会丢
            // fontChoice(只是当前循环不在它上面)。
            fontChoice = hudCycle[0]
        }
    }

    // MARK: - Font & opacity

    func increaseFontSize() {
        transFontSize = min(transFontSize + FontLimit.transStep, FontLimit.transMax)
    }

    func decreaseFontSize() {
        transFontSize = max(transFontSize - FontLimit.transStep, FontLimit.transMin)
    }

    func adjustBgOpacity(delta: CGFloat) {
        // 0.075 (almost transparent) ↔ 1.0 (opaque) ↔ 2.0 (pitch black)
        // 三档循环,跨档时跳到下一档的端点。
        let minOpacity: CGFloat = 0.075
        var next = bgOpacity + delta
        if bgOpacity >= 1.99 && delta > 0 {
            // 在 2.0 端再加 → 跳到 0.075 重新开始循环
            next = minOpacity
        } else if bgOpacity <= 0.08 && delta < 0 {
            // 已经在最透明档(0.075)还想再减 → 跳到 2.0 纯黑
            next = 2.0
        } else if next > 1.01 && bgOpacity < 1.99 {
            // 跨过 1.0 → 跳到 2.0 纯黑档
            next = 2.0
        } else if next < minOpacity - 0.01 {
            // 算上 delta 后低于下限 → 钳到 floor
            next = minOpacity
        }
        bgOpacity = next
    }

    // MARK: - Status mapping

    func tickStatus() {
        if statusText != nil && Date() > statusExpireTime {
            statusText = nil
        }
    }

    private func mapStatusText(_ status: String) -> String {
        switch status {
        case "loading_model": return "正在加载模型…"
        case "ready":         return "模型就绪，等待音频…"
        case "listening":     return "正在聆听…"
        case "crash_recover": return "音频恢复中…"
        default:              return status
        }
    }

    private func colorFromString(_ s: String?) -> Color {
        switch s {
        case "orange": return .orange
        case "green":  return .green
        default:       return .white.opacity(0.40)
        }
    }

    private func setStatus(_ text: String, color: Color, duration: TimeInterval = 3.0) {
        statusText = text
        statusColor = color
        statusExpireTime = Date().addingTimeInterval(duration)
    }

    /// Public entry for callers that set status text directly (e.g. audio source switch).
    /// Ensures `statusExpireTime` is set so `tickStatus()` can clear it after `duration` seconds.
    func setTransientStatus(_ text: String, color: Color, duration: TimeInterval = 3.0) {
        setStatus(text, color: color, duration: duration)
    }

    private func handleStatus(_ status: String, colorKey: String?) {
        let color = colorFromString(colorKey)

        // Always update the active backend (the status event names it).
        if status.contains("Qwen3") {
            asrBackend = "qwen3"
        } else if status.contains("Nemotron") {
            asrBackend = "nemotron"
        }

        // Green "done" events update the backend but leave the orange
        // loading text to its natural expiry.
        if color == .green { return }
        setStatus(mapStatusText(status), color: color)
    }

    // MARK: - Lost drafts

    private func logLostDraft(src: String, trans: String, reason: String) {
        let entry: [String: Any] = [
            "ts": Self.nowStr(),
            "source_text": src,
            "translated_text": trans,
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = line + "\n"
        if let fh = FileHandle(forWritingAtPath: Self.lostDraftsPath) {
            fh.seekToEndOfFile()
            fh.write(lineWithNewline.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            try? lineWithNewline.write(toFile: Self.lostDraftsPath, atomically: false, encoding: .utf8)
        }
    }

    private static func isCompleteSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10, let last = trimmed.last else { return false }
        return "。！.!?".contains(last)
    }

    // MARK: - Whisper hallucination loop collapse

    /// Collapse "ABCABCABC" → "ABC", "你好你好" → "你好". Returns text
    /// unchanged when no obvious repetition is detected.
    static func deduplicateRepeated(_ text: String) -> String {
        let count = text.count
        guard count > 6 else { return text }
        let maxSeg = min(20, count / 3)
        let chars = Array(text)

        let firstChar = chars[0]
        let isSingleCharPattern = chars.allSatisfy { $0 == firstChar }

        for segLen in 1...maxSeg where count % segLen == 0 {
            let reps = count / segLen
            guard reps >= (isSingleCharPattern ? 10 : 3) else { continue }
            let first = Array(chars[0..<segLen])
            var dominated = true
            for rep in 1..<min(reps, 4) {
                let offset = rep * segLen
                for i in 0..<segLen where chars[offset + i] != first[i] {
                    dominated = false
                    break
                }
                if !dominated { break }
            }
            if dominated {
                return String(chars[0..<segLen])
            }
        }
        return text
    }

private static func nowStr() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Hex parsing for customColor

    /// `#RRGGBB` / `#RRGGBBAA` / `RRGGBB` / `RRGGBBAA` → `Color`。
    /// 解析失败返回 nil（让 OverlayState.customColor 保持 nil，
    /// 渲染端 fallback 到 style.accent）。
    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        // 不支持 #RGB / #RGBA 短形式——ColorPicker 给的是长形式，简化解析路径。
        guard s.count == 6 || s.count == 8 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { return nil }
        if s.count == 6 {
            let r = Double((v >> 16) & 0xFF) / 255.0
            let g = Double((v >> 8) & 0xFF) / 255.0
            let b = Double(v & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        } else {
            let r = Double((v >> 24) & 0xFF) / 255.0
            let g = Double((v >> 16) & 0xFF) / 255.0
            let b = Double((v >> 8) & 0xFF) / 255.0
            let a = Double(v & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b, opacity: a)
        }
    }

    /// `Color` → `#RRGGBB`（不含 alpha — ColorPicker 给的就是不透明的，
    /// 我们也不主动存 alpha）。失败时返回 nil。
    static func hexFromColor(_ color: Color) -> String? {
        // NSColor 转换在 macOS 上稳定；iOS 上 #if 可以换成 UIColor。
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB)
        guard let c = nsColor else { return nil }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 渲染端使用的颜色：自定义色优先，否则用预设 accent。
    var resolvedAccent: Color {
        customColor ?? style.accent
    }
}
