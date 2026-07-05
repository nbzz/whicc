import AppKit
import SwiftUI

/// Config parsed from CLI arguments. Same shape as the legacy overlay.
struct OverlayConfig {
    let eventsPath: String
    let transEventsPath: String?
    let glossaryDir: String
    let xPct: Double
    let yPct: Double
    let wPct: Double
    let hPct: Double

    static let defaults = Self(
        eventsPath: "",
        transEventsPath: nil,
        glossaryDir: AppPaths.srcDir,
        xPct: 15,
        yPct: 1,
        wPct: 70,
        hPct: 13
    )
}

enum ConfigError: LocalizedError {
    case missingEventsPath
    case missingValue(flag: String)
    case invalidNumber(flag: String, value: String)
    case outOfRange(flag: String, value: Double, allowed: ClosedRange<Double>)
    case unexpectedFlag(String)

    var errorDescription: String? {
        switch self {
        case .missingEventsPath:
            return """
            Missing events file path.

            Usage:
              whicc-macui <events-path> [--x N] [--y N] [--w N] [--h N] \
                          [--trans <path>] [--glossary <dir>]
            """
        case .missingValue(let flag):         return "Missing value for \(flag)."
        case .invalidNumber(let f, let v):    return "Invalid numeric value for \(f): \(v)"
        case .outOfRange(let f, let v, let r):return "Value out of range for \(f): \(v). Allowed: \(r.lowerBound)...\(r.upperBound)"
        case .unexpectedFlag(let flag):       return "Unknown flag: \(flag)"
        }
    }
}

func parseConfig(from args: [String]) throws -> OverlayConfig {
    var x = OverlayConfig.defaults.xPct
    var y = OverlayConfig.defaults.yPct
    var w = OverlayConfig.defaults.wPct
    var h = OverlayConfig.defaults.hPct
    var positional: [String] = []
    var transEventsPath: String?
    var glossaryDir = OverlayConfig.defaults.glossaryDir

    func parseDouble(args: [String], index: inout Int,
                     flag: String, range: ClosedRange<Double>) throws -> Double {
        index += 1
        guard index < args.count else { throw ConfigError.missingValue(flag: flag) }
        let raw = args[index]
        guard let value = Double(raw) else {
            throw ConfigError.invalidNumber(flag: flag, value: raw)
        }
        guard range.contains(value) else {
            throw ConfigError.outOfRange(flag: flag, value: value, allowed: range)
        }
        return value
    }

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--x":  x = try parseDouble(args: args, index: &i, flag: "--x",  range: 0...100)
        case "--y":  y = try parseDouble(args: args, index: &i, flag: "--y",  range: 0...100)
        case "--w":  w = try parseDouble(args: args, index: &i, flag: "--w",  range: 1...100)
        case "--h":  h = try parseDouble(args: args, index: &i, flag: "--h",  range: 1...100)
        case "--trans":
            i += 1
            guard i < args.count else { throw ConfigError.missingValue(flag: "--trans") }
            transEventsPath = args[i]
        case "--glossary":
            i += 1
            guard i < args.count else { throw ConfigError.missingValue(flag: "--glossary") }
            glossaryDir = args[i]
        default:
            if arg.hasPrefix("--") { throw ConfigError.unexpectedFlag(arg) }
            positional.append(arg)
        }
        i += 1
    }

    guard let eventsPath = positional.first, !eventsPath.isEmpty else {
        throw ConfigError.missingEventsPath
    }
    return OverlayConfig(
        eventsPath: eventsPath,
        transEventsPath: transEventsPath,
        glossaryDir: glossaryDir,
        xPct: x, yPct: y, wPct: w, hPct: h
    )
}

// MARK: - SettingsWindowCleaner
//
// 监听 settings 窗口关闭，触发 onClose 回调（典型用途：把持有该窗口
// 的变量设回 nil，避免下次 openSettings() 时旧窗口还活着导致泄漏）。
// 单独抽出来是为了避免 Swift 6 严格并发下闭包捕获 @MainActor 属性
// 和非 Sendable 的 observer token 时的报错——这里整个清理流程都在
// @MainActor 上，闭包只捕获 self（也是 @MainActor），符合规则。
@MainActor
private final class SettingsWindowCleaner {
    private weak var window: NSWindow?
    private let onClose: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(window: NSWindow, onClose: @escaping @MainActor () -> Void) {
        self.window = window
        self.onClose = onClose
    }

    func install() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter 闭包类型是 @Sendable，
            // 用 MainActor.assumeIsolated 切回主 actor 再调 self。
            MainActor.assumeIsolated {
                self?.handleClose()
            }
        }
    }

    private func handleClose() {
        onClose()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

// MARK: - AppDelegate

// AppKit invokes all NSApplicationDelegate callbacks on the main thread, so
// we keep this class non-isolated and use `@MainActor` only on the methods
// that touch our actor-isolated models. This avoids a top-level
// "call to main-actor-isolated initializer from synchronous nonisolated
// context" error in Swift 6.
final class AppDelegate: NSObject, NSApplicationDelegate {

    @MainActor private var state: OverlayState!

    @MainActor private var windowController: OverlayWindowController?
    private var watcher: EventWatcher?
    private var transWatcher: EventWatcher?
    @MainActor private var settingsWindow: NSWindow?
    @MainActor private var downloadState: ModelDownloadState?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // 打包模式 (.app bundle 双击启动) 下没有 CLI 参数 — 给个合理的默认
            // 让 macui 知道订阅哪个 JSONL。开发模式仍要求显式传参。
            var args = CommandLine.arguments
            if AppPaths.isBundledApp && args.count < 2 {
                let runDir = AppPaths.runDir
                try? FileManager.default.createDirectory(
                    atPath: runDir, withIntermediateDirectories: true
                )
                // 注:不要在这里创建 events.jsonl / translation_events.jsonl,
                // 让 whicc.py / translate_stream.py 自己 open() 时 create。
                // 原因:Data().write 创建空文件后,Swift 进程退出前 child
                // 进程的 open(O_APPEND) 在某些时序下会撞 macOS 的 inode
                // 缓存,导致 ls 看不到文件但 whicc.py 持有 fd 继续写。
                // 让后端自己创建文件,生命周期跟进程一致,更可靠。
                let eventsFile = runDir + "/events.jsonl"
                let transFile = runDir + "/translation_events.jsonl"
                // 数据流(writeStartupPings + translate_stream 写 translation_*
                // 到 translation_events.jsonl;whicc.py 写 ASR partial/final/status
                // 到 events.jsonl)。
                //
                // 订阅路径(parseConfig 把 positional.first → eventsPath,
                // --trans 值 → transEventsPath):
                // - eventsPath = translation_events.jsonl → watcher A → apply()
                //   apply() 处理 init-* pings (banner 工作 + 1.8s 自动 dismiss)
                //   和 translation_partial/final/reset (draft 累积 + 提交 caption
                //   带翻译)。apply() 里 case "partial"/"final"/"status" 分支
                //   是为历史 ASR 兼容留的 dead code,当前 args 下走不到。
                // - transEventsPath = events.jsonl → watcher B → applyTranscription()
                //   ASR-only fast path:partial 写 draftSourceText、status 触发
                //   状态更新。final 事件不 commit,由 translate_stream 消费后
                //   通过 translation_final 走 apply() 提交带翻译的 caption。
                //
                // 为什么 positional 是 translation_events.jsonl?
                // banner 工作依赖 watcher A 看到 init-* pings,而 init-*
                // pings 写在 translation_events.jsonl (BackendLauncher
                // .writeStartupPings,line 183) —— events.jsonl 不含
                // init-* pings。如果 positional 是 events.jsonl,
                // banner 永远不工作。
                args = [args[0], transFile, "--trans", eventsFile,
                        "--glossary", AppPaths.srcDir,
                        "--x", "15", "--y", "1", "--w", "70", "--h", "13"]
            }
            let config = try parseConfig(from: args)

            // Models (LangConfig 必读 lang_config.json,其他可后台)
            let langConfig = LangConfig()
            let glossaryState = GlossaryState(glossaryDir: config.glossaryDir)
            let eventAgentState = EventAgentState()
            state = OverlayState(langConfig: langConfig)

            // ---- 启动进度:让用户立刻看到 banner + Dock 图标 + 窗口 ----
            // 之前:applicationDidFinishLaunching 把所有重活(launchBackends
            // + ModelState 递归扫模型)同步塞在主线程,然后最后才调 controller.show。
            // 用户感知:点击 .app → 鼠标转圈 → 几秒后窗口突然出现。
            // 现在:先建 StartupSummary + 显 banner,再 show 窗口,重活丢后台
            // 按阶段更新 stage → banner 立刻显示 "正在初始化 whicc…" →
            // 用户在 Dock 图标和窗口里都看到进度。
            state.startupSummary = StartupSummary(stage: .initializing)
            state.startupBannerVisible = true

            // Window — 立刻显示,banner 跟着出来
            let modelState = ModelState(
                modelsDir: ModelState.defaultModelsDir(),
                stateFile: ModelState.defaultStateFile()
            )
            let controller = OverlayWindowController(
                state: state,
                langConfig: langConfig,
                glossaryState: glossaryState,
                eventAgentState: eventAgentState,
                modelState: modelState
            )
            controller.onOpenSettings = { [weak self] in self?.openSettings() }
            try controller.show(using: config)
            self.windowController = controller

            // ---- 后台跑重活 ----
            // 阶段 1:启动 4 个 Python 后端。阶段 2:扫模型目录算 size。
            // 完成后 banner 转 "正在聆听",真正的 listening 后端 ping 来了再
            // 由 OverlayState.applyStartupText 翻 listening=true → "准备就绪"。
            //
            // 注:BackendLauncher 是 @MainActor,必须在主线程调。后台 queue
            // 只用来做"短暂的 stage 过渡",让用户看到 banner 文本切换 —
            // 实际重活(BE launcher + polling)仍然在主线程跑,跟之前一样
            // 阻塞主线程。但 banner 已经先显示了,用户视觉上不再"卡死",
            // Dock 图标也已经出现,这是这次修复的核心。
            //
            // 进一步:把 ModelState init + BE launch 一起丢后台需要在更早
            // 时候就改 actor isolation(把 BackendLauncher 改成非 @MainActor
            // 或加 async 接口),改起来涉及面广,留到下次。
            //
            // 阶段间隔:每个 stage 至少停留 0.5s,用户能看清楚进度;
            // 实际主线程重活跑得更久(launchBackends ~100ms 但加上 model
            // scan 几百 ms),所以这里设最小停留不会拖慢整体完成时间。
            //
            // 打包模式:BackendLauncher 在 launchBackendsIfNeeded() 内部完成 spawn +
            // 等 ASR ready + 准备 banner ping 文案 (但不写文件 — 时序原因见
            // appendStartupPings 注释)。EventWatcher 起来后 main.swift 调
            // appendStartupPings(afterLaunch:) 才写 banner-shape init pings,
            // banner 立刻从 "正在聆听" → "准备就绪 · X.XXs" → 1.8s 后
            // auto-dismiss。
            func advanceStage(_ next: StartupStage) {
                let lastChange = Date()
                DispatchQueue.main.async { [weak state] in
                    state?.startupSummary?.stage = next
                }
                // 至少停留 0.5s,但如果主线程真的还在跑(下次 stage 切换被
                // 同步阻塞),这段 Thread.sleep 会自然让出实际时间。
                let elapsed = Date().timeIntervalSince(lastChange)
                let remaining = 0.5 - elapsed
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
            advanceStage(.launchingBackends)
            BackendLauncher.launchBackendsIfNeeded()
            advanceStage(.scanningModels)

            glossaryState.startPolling()
            eventAgentState.startPolling()
            modelState.startPolling()
            let downloadState = ModelDownloadState()
            downloadState.startPolling()
            self.downloadState = downloadState

            // banner 切到 listening。EventWatcher 起后由 appendStartupPings(afterLaunch:)
            // 写 4 条 init pings,banner 翻成 "准备就绪 · X.XXs" → 1.8s 后
            // auto-dismiss。
            advanceStage(.listening)

            // Wire the NSMenu language callback.
            MenuActionHandler.shared.onLanguagePicked = { [weak langConfig] langId in
                langConfig?.setLang(langId)
            }

            // JSONL watchers
            let watcher = EventWatcher(path: config.eventsPath) { [weak self] event in
                self?.state.apply(event)
            }
            watcher.start()
            self.watcher = watcher

            if let transPath = config.transEventsPath {
                let transWatcher = EventWatcher(path: transPath) { [weak self] event in
                    self?.state.applyTranscription(event)
                }
                transWatcher.start()
                self.transWatcher = transWatcher
            }

            // EventWatcher 已经在文件尾 (seekToEndOfFile),appendStartupPings
            // append 4 条 banner-shape init pings → DispatchSource 立刻触发
            // → banner 翻 "准备就绪 · X.XXs" → 1.8s 后 auto-dismiss。
            // 不在 launchBackendsIfNeeded 内部写是因为 EventWatcher 启动时
            // 会 seek 到文件尾,提前写会让 seek 跳过这 4 条。
            BackendLauncher.appendStartupPings(afterLaunch: true)

        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Settings window

    /// Exposed to ObjC for the menu `Preferences...` (⌘,) item.
    /// `@objc` so AppKit menu item can route the action through the
    /// responder chain to us; `@MainActor` because it touches @MainActor
    /// properties (settingsWindow).
    @MainActor
    @objc func openSettingsFromMenu() {
        openSettings()
    }

    /// ⌘W handler — close the key window.
    /// Subtitle panel → terminate app (same as ⌘Q / red button).
    /// Settings window → close just the window.
    @MainActor
    @objc func closeWindowFromMenu() {
        if let panel = windowController?.panel, panel.isKeyWindow {
            NSApp.terminate(nil)
        } else if let win = settingsWindow, win.isKeyWindow {
            win.close()
        }
    }

    @MainActor
    private func openSettings() {
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let controller = windowController else { return }

        let hosting = NSHostingView(
            rootView: SettingsView(
                state: controller.glossaryState,
                langConfig: controller.langConfig,
                eventAgent: controller.eventAgentState,
                modelState: controller.modelState,
                downloadState: downloadState ?? ModelDownloadState(),
                overlayState: controller.state
            )
        )
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            // `.fullSizeContentView` extends the content view under the
            // title bar so SwiftUI's `.toolbar` can host the traffic
            // lights inside the sidebar's chrome instead of letting
            // AppKit pin them to the very top of the window.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 窗口标题:Settings — 跟随系统 locale 自动切换中/英。
        // NSWindow.title 是 String,得显式走 NSLocalizedString。
        // 跟 SwiftUI 的 Text("...") 默认 LocalizedStringKey 不一样。
        win.title = NSLocalizedString("settings_window_title", value: "设置", comment: "Settings window title")
        win.titlebarAppearsTransparent = true
        // 注意：不要设 win.titleVisibility = .hidden——
        // "设置"字样是用户识别"我在设置窗口里"的视觉锚点，去掉反而突兀。
        // 它跟 traffic lights 共存于透明 titlebar 是 macOS 的标准做法。
        // OverlayWindowController 那边隐藏是因为 panel 类型窗口不需要 title，
        // 但 settings 是普通窗口，应该保留。
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win

        // 关掉窗口时把 settingsWindow 设回 nil，下次 openSettings() 就
        // 知道要新建一个（不然旧 NSWindow 还被持有，泄漏整个 view tree）。
        // 用辅助类持有清理逻辑 + observer，避免 Swift 6 严格并发下闭包
        // 捕获 @MainActor 属性和非 Sendable 的 observer token 时的报错。
        let cleaner = SettingsWindowCleaner(window: win) { [weak self] in
            self?.settingsWindow = nil
        }
        cleaner.install()
    }

    // MARK: - Lifecycle

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop();          watcher = nil
        transWatcher?.stop();     transWatcher = nil
        windowController?.close()
        windowController = nil
        settingsWindow?.close()
        settingsWindow = nil
        // Tear down the local backend alongside the UI. macui is
        // the only overlay now, so leaving the daemon running would
        // just leak GPU/Memory until the user remembers to
        // pkill them. SIGTERM (sent by BackendShutdown) lets the
        // Python side flush its logs and unload models cleanly.
        //
        // 打包模式:BackendLauncher 启的子进程用 SIGKILL 杀 (Swift
        // 退出 = 用户主动关闭,不留尾巴)
        // 开发模式:BackendShutdown.terminateLocalBackend() SIGTERM,
        // 跟之前行为一致
        if AppPaths.isBundledApp {
            BackendLauncher.terminateBackends()
        } else {
            BackendShutdown.terminateLocalBackend()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Main entry

let app = NSApplication.shared
// .regular: 有 Dock 图标 + ⌘Tab + 顶部菜单栏
// 之前是 .accessory (无 Dock 浮层模式),但用户希望在启动期间看到 Dock
// 图标作为"app 在跑"的视觉锚点。改成 .regular,banner 阶段文案照常
// 显示在窗口顶部。
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let delegate = AppDelegate()

// App menu (accessory apps have no default menu bar; build one with
// the standard macOS app menu items — Preferences... (⌘,) and Quit).
// The first menu in mainMenu becomes the "App menu" (named with the
// app's process name, in bold, with About / Hide / Quit items as
// macOS expects). We supply Preferences and Quit ourselves and let
// AppKit fill in the standard items via the responder chain.
let mainMenu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: NSLocalizedString("menu_preferences", value: "Preferences…", comment: "Preferences menu item"),
    action: #selector(AppDelegate.openSettingsFromMenu),
    keyEquivalent: ","
)
appMenu.items.last?.target = delegate
appMenu.addItem(.separator())
appMenu.addItem(
    withTitle: NSLocalizedString("menu_quit", value: "Quit whicc", comment: "Quit menu item"),
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// File menu — ⌘W closes the key window (or quits if it's the subtitle panel).
let fileMenu = NSMenu(title: NSLocalizedString("menu_file", value: "File", comment: "File menu title"))
fileMenu.addItem(
    withTitle: NSLocalizedString("menu_close", value: "Close", comment: "Close menu item"),
    action: #selector(AppDelegate.closeWindowFromMenu),
    keyEquivalent: "w"
)
fileMenu.items.last?.target = delegate
let fileMenuItem = NSMenuItem()
fileMenuItem.submenu = fileMenu
mainMenu.addItem(fileMenuItem)

// Edit menu (standard text-editing shortcuts — TextField/TextEditor
// inside the Settings window routes through these).
let editMenu = NSMenu(title: NSLocalizedString("menu_edit", value: "Edit", comment: "Edit menu title"))
editMenu.addItem(withTitle: NSLocalizedString("menu_edit_cut", value: "Cut", comment: ""),        action: #selector(NSText.cut(_:)),        keyEquivalent: "x")
editMenu.addItem(withTitle: NSLocalizedString("menu_edit_copy", value: "Copy", comment: ""),       action: #selector(NSText.copy(_:)),       keyEquivalent: "c")
editMenu.addItem(withTitle: NSLocalizedString("menu_edit_paste", value: "Paste", comment: ""),      action: #selector(NSText.paste(_:)),      keyEquivalent: "v")
editMenu.addItem(withTitle: NSLocalizedString("menu_edit_select_all", value: "Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editMenuItem = NSMenuItem()
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)
app.mainMenu = mainMenu

app.delegate = delegate
app.run()