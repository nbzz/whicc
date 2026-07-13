import Foundation

/// 后端进程编排:启动 whicc 后端进程组 (whicc.py + translate_stream +
/// glossary_refresher + model_downloader)。
///
/// 打包模式 (.app bundle 双击启动):Swift 启动后 fork 4 个 Python
/// 子进程,使用 .app/Contents/Resources/venv/bin/python3,并写 banner-shape
/// 启动 ping 让 macui 的 StartupBanner 正常推进 ("正在初始化 whicc…"
/// → "正在启动后端…" → "正在扫描模型…" → "正在聆听" → "准备就绪 · X.XXs")。
///
/// 开发模式 (`swift run` 或 `macui/.build/debug/whicc-macui`):不主动
/// 启动后端 — 用户自己跑 `swift run whicc.py` 等。
///
/// 并发:本类只做文件 IO / Process spawn / 日志轮询,不碰 UI,**不**标
/// @MainActor — launchBackendsIfNeeded 里的 waitForASRReady 会阻塞
/// 最长 10s,必须能在后台队列跑(main.swift 的启动链把它丢到
/// DispatchQueue.global,完成后 hop 回主线程写 pings)。静态可变状态
/// (_launchStartTime/_pendingPings) 的访问由调用方的串行时序保证:
/// BG 队列 launchBackendsIfNeeded 写 → main.async appendStartupPings 读,
/// dispatch 边界自带 happens-before。
final class BackendLauncher {
    private struct BackendProc {
        let script: String
        let args: [String]
        let logName: String
    }

    /// launchBackendsIfNeeded() 入口记录的启动时戳。appendStartupPings
    /// 用它算"打开 .app → ASR ready"的总耗时。class-level 静态属性 —
    /// 打包模式整个 app 生命周期只会调一次 launchBackendsIfNeeded +
    /// appendStartupPings,访问时序由启动链串行保证(见类注释)。
    private static var _launchStartTime: Date?

    /// 启动 4 个后端进程 + 启动计时。**不**直接写 init pings —
    /// 见 `appendStartupPings(afterLaunch:)` 的注释。
    /// - spawn 前先 pkill 清掉孤儿后端 (App 崩溃/旧版漏杀留下的 detached
    ///   进程会和新实例并发写 /tmp/whicc-out,下载互踩、字幕交错)
    /// - 启动失败不抛异常,只 stderr 输出 (避免 UI 启动被一个进程问题阻断)
    ///
    /// 时序原因:EventWatcher.start() 启动时 seek 到 translation_events.jsonl
    /// 文件尾,如果 BackendLauncher 写完 pings 才起 EventWatcher,4 条 init
    /// pings 永远不会被读 (seek end 跳过它们)。所以本方法只做耗时测量
    /// + spawn,真正写 pings 留给 EventWatcher 起来后调 appendStartupPings。
    static func launchBackendsIfNeeded() {
        let bundle = Bundle.main.bundlePath
        logAndStderr("[BackendLauncher] isBundled=\(AppPaths.isBundledApp) bundlePath=\(bundle)")

        guard AppPaths.isBundledApp else {
            logAndStderr("[BackendLauncher] dev mode, skip")
            return
        }

        // ── 启动计时:从这一刻到 ASR ready,即"打开 .app → 字幕可用"的总耗时 ──
        _launchStartTime = Date()
        logAndStderr("[BackendLauncher] launchBackendsIfNeeded ENTER runDir=\(AppPaths.runDir)")

        // 准备 .app 内嵌的目录
        let runDir = AppPaths.runDir
        try? FileManager.default.createDirectory(
            atPath: runDir, withIntermediateDirectories: true
        )
        let logDir = NSString(string: runDir).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true
        )

        // 准备 jsonl 占位文件 (避免后端 open() 时缺文件 + 让 EventWatcher 有 offset 起点)
        let eventsPath = runDir + "/events.jsonl"
        let transEventsPath = runDir + "/translation_events.jsonl"
        if !FileManager.default.fileExists(atPath: eventsPath) {
            try? Data().write(to: URL(fileURLWithPath: eventsPath))
        }
        if !FileManager.default.fileExists(atPath: transEventsPath) {
            try? Data().write(to: URL(fileURLWithPath: transEventsPath))
        }

        // lang_config.json 默认值:首次启动没有这文件 / 或没 translation_enabled
        // 字段时,默认 enable translation_enabled = true。
        // 这样 translate_stream 启动不会因 default-False 立即退出。
        // 用户在 macui 显式关掉 → LangConfig.save() 写 false → 后续保留
        // 用户的决定。
        ensureDefaultLangConfig(runDir: runDir)

        // 后端进程定义
        let python = AppPaths.pythonExecutable
        let src = AppPaths.srcDir
        let modelsDir = "\(NSHomeDirectory())/Library/Application Support/whicc/models"
        try? FileManager.default.createDirectory(
            atPath: modelsDir, withIntermediateDirectories: true
        )
        let modelStateFile = runDir + "/model_state.json"
        // audiotee 路径: src 是 .app/Contents/Resources/src/, audiotee 在
        // .app/Contents/Resources/bin/audiotee (preBuildScript 拷进去)。
        // 不能用 AppPaths.projectRoot — 打包模式下那是写死的开发机路径,
        // 别人电脑根本不存在。
        let audioteePath = (src as NSString).deletingLastPathComponent + "/bin/audiotee"

        // Nemotron 当默认 (Nemotron 英文准 + Qwen3 中文备用,跟 whicc.py --dual-model 默认一致)
        let defaultModel = "mlx-community/nemotron-3.5-asr-streaming-0.6b"
        let (modelShort, modelBackend) = parseModelDisplay(defaultModel)

        let backends: [BackendProc] = [
            BackendProc(
                script: "whicc.py",
                args: [
                    "--events-jsonl", eventsPath,
                    "--model-state", modelStateFile,
                    "--models-dir", modelsDir,
                    "--model", defaultModel,
                    "--language", "auto",
                    "--audio-source", "system",
                    "--audio-bin", audioteePath,
                ],
                logName: "whicc.log"
            ),
            BackendProc(
                script: "translate_stream.py",
                args: [
                    "--events", eventsPath,
                    "--out-dir", runDir,
                    // 调用可写词库路径：打包后不能写 Resources/src/glossary.json
                    "--glossary", AppPaths.glossaryPath,
                    // 翻译 URL 全部从 lang_config.json 读 (用户自己在 macui 设置里配)。
                    "--vllm-url", "",
                    "--vllm-fallback-url", "",
                    "--mode", "partial",
                    "--target-lang", "auto",
                    // 绕过 lang_config.json 的 translation_enabled 检查:
                    // 用户在 macui 设置里要主动开这个 toggle,但 .app
                    // 刚启动时 lang_config 可能还没被 UI 写过 → enabled=false
                    // → translate_stream 立即退。--force-enable 让打包模式
                    // 下默认就跑翻译,用户在 macui 关掉时再停。
                    "--force-enable",
                ],
                logName: "translate-stream.log"
            ),
            BackendProc(
                script: "glossary_refresher.py",
                // 调用同一可写 glossary：与 macui / translate_stream 共用
                args: ["--glossary", AppPaths.glossaryPath],
                logName: "glossary-refresher.log"
            ),
            BackendProc(
                script: "model_downloader.py",
                args: ["--out-dir", runDir, "--models-dir", modelsDir],
                logName: "model-downloader.log"
            ),
        ]

        // ── 启动前清场:杀掉孤儿后端进程 ──
        // App 崩溃/强退时 detached 子进程活下来;旧版 terminateBackends
        // 还漏杀 model_downloader,实测一台机器堆了 16 个下载守护进程,
        // 同时抢下同一个模型互相卡死。spawn 前统一清一次,顺带把存量
        // 僵尸也治了。同步等 pkill 完成(<100ms)再 spawn,避免旧进程
        // 还握着单实例锁/audiotee。
        let sweeper = Process()
        sweeper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweeper.arguments = ["-9", "-f", backendPkillPattern]
        sweeper.standardOutput = FileHandle.nullDevice
        sweeper.standardError = FileHandle.nullDevice
        try? sweeper.run()
        sweeper.waitUntilExit()

        _monitorLock.lock()
        _spawnContext = (python: python, src: src, logDir: logDir)
        _monitored.removeAll()
        _monitorLock.unlock()
        for backend in backends {
            if let proc = spawn(python: python, src: src, backend: backend,
                                logDir: logDir) {
                _monitorLock.lock()
                _monitored.append(MonitoredProc(backend: backend,
                                                process: proc, restarts: 0,
                                                lastRestartAt: nil))
                _monitorLock.unlock()
            }
        }
        // 存活监控:之前 spawn 完就不管了,whicc.py 崩掉后 UI 永远停在
        // "正在聆听"(launcher 只扫日志关键词,不看进程死活 — SOP.md
        // 记录过的盲点)。
        startProcessMonitor()

        // ── 等待 ASR ready → 算总耗时 → 准备 banner ping 文案 ──
        // ASR 启动后 stdout 会打 "模型就绪。启动系统音频捕获..." (whicc.py:885),
        // 扫描日志关键词。最多等 1s,1s 内没出现就用 launchEndTime 作为 fallback
        // (banner 立即收尾;ASR 实际上还要 1-3s 才真 ready,但 banner 已经显示,
        // 不阻塞 UI)。
        //
        // 4 条 init pings 留到 EventWatcher 起来后由 main.swift 调
        // appendStartupPings(afterLaunch:) 写 — 否则 EventWatcher 启动时
        // seekToEndOfFile() 会跳过我们刚写的 pings。
        let asrLogPath = logDir + "/whicc.log"
        let asrReadyTime = waitForASRReady(
            logPath: asrLogPath,
            deadline: _launchStartTime?.addingTimeInterval(10.0) ?? Date().addingTimeInterval(10.0)
        )
        let loadSeconds = String(format: "%.2f", asrReadyTime.timeIntervalSince(_launchStartTime ?? asrReadyTime))
        logAndStderr("[BackendLauncher] total startup \(loadSeconds)s, _launchStartTime=\(_launchStartTime != nil)")

        // 准备 init ping 文案 (留到 EventWatcher 起来后再写)
        let translationLabel = translationDisplayLabel(runDir: runDir)
        let asrLabel = "\(modelShort) (\(modelBackend))"
        _pendingPings = (runDir: runDir, asrLabel: asrLabel, translationLabel: translationLabel, loadSeconds: loadSeconds)
        logAndStderr("[BackendLauncher] ready to write pings: \(asrLabel) / \(translationLabel) / \(loadSeconds)s")
    }

    /// main.swift 在 EventWatcher 起来后调这个写 4 条 banner-shape init pings。
    ///
    /// 时序:EventWatcher.start() 调 seekToEndOfFile() → 把读 offset 锁在
    /// 文件尾 → DispatchSource 在 .write/.extend 时触发 readNewData。如果
    /// BackendLauncher 之前就写好了 pings,seek 跳过它们,pings 永远不被读。
    /// 调本方法时,EventWatcher 已经在文件尾,append 4 行后 DispatchSource
    /// 立刻触发 → 读 → banner 翻"准备就绪" → 1.8s 后 auto-dismiss。
    static func appendStartupPings(afterLaunch: Bool = true) {
        logAndStderr("[BackendLauncher] appendStartupPings(afterLaunch: \(afterLaunch)) _pendingPings=\(_pendingPings != nil)")
        guard afterLaunch else { return }  // 防御:误调直接 no-op
        guard let pings = _pendingPings else {
            logAndStderr("[BackendLauncher] appendStartupPings called with no _pendingPings (dev mode or no backends launched)")
            return
        }
        let transLogPath = pings.runDir + "/translation_events.jsonl"
        writeStartupPings(
            transLogPath: transLogPath,
            asrLabel: pings.asrLabel,
            translationLabel: pings.translationLabel,
            loadSeconds: pings.loadSeconds
        )
        logAndStderr("[BackendLauncher] wrote 4 startup pings to \(transLogPath)")
        _pendingPings = nil
    }

    /// 同时写 stderr 和 append 到 runDir/logs/whicc-launcher.log。
    /// 打包版 .app 默认 stderr 不重定向,纯 stderr 看不到;写文件方便诊断。
    private static func logAndStderr(_ msg: String) {
        fputs(msg + "\n", stderr)
        let logPath = AppPaths.runDir + "/logs/whicc-launcher.log"
        try? FileManager.default.createDirectory(
            atPath: (logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let line = "\(Date().timeIntervalSince1970) \(msg)\n"
        if let data = line.data(using: .utf8) {
            // H13 修:FileHandle(forWritingTo:) 默认 O_TRUNC,每次 open 都
            // 先清空文件 — 调试时 launcher.log 永远只剩最后一行的内容。
            // 改用 (forUpdatingAtPath:),append 模式保留历史内容。
            if let handle = FileHandle(forUpdatingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else if !FileManager.default.fileExists(atPath: logPath) {
                // 文件不存在,先创建空文件再开 append handle。
                if FileManager.default.createFile(atPath: logPath, contents: nil),
                   let handle = FileHandle(forUpdatingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            }
        }
    }

    /// 准备好的 init ping 文案,留到 appendStartupPings(afterLaunch:) 写。
    private static var _pendingPings: (runDir: String, asrLabel: String, translationLabel: String, loadSeconds: String)?

    /// Parse HF model id → "(short-name, backend-name)"
    /// - "mlx-community/nemotron-3.5-asr-streaming-0.6b" → ("nemotron-3.5-asr", "nemotron")
    /// - "mlx-community/Qwen3-ASR-0.6B-4bit"              → ("Qwen3-ASR-0.6B", "qwen3")
    private static func parseModelDisplay(_ modelId: String) -> (String, String) {
        let base = (modelId as NSString).lastPathComponent
        let lower = base.lowercased()
        let backend: String
        if lower.contains("qwen") { backend = "qwen3" }
        else if lower.contains("nemotron") || lower.contains("nemo") { backend = "nemotron" }
        else { backend = "auto" }
        return (base, backend)
    }

    /// 翻译状态 banner 文案 — 从 lang_config.json 读 URL,fallback 到 "(未配置)"
    /// 不展开成 "远端/本地" 等细分,UI 简洁优先;具体连通性由 translate_stream
    /// stderr 自行报。
    private static func translationDisplayLabel(runDir: String) -> String {
        let cfgPath = runDir + "/lang_config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Hy-MT2-7B (未配置)"
        }
        let url = (json["translation_url"] as? String) ?? ""
        let fallback = (json["translation_fallback_url"] as? String) ?? ""
        if url.isEmpty && fallback.isEmpty { return "Hy-MT2-7B (未配置)" }
        // 显示 host (去 http:// / https:// / 端口)
        let raw = url.isEmpty ? fallback : url
        if let host = URL(string: raw)?.host { return "Hy-MT2-7B (\(host))" }
        return "Hy-MT2-7B"
    }

    /// scan 日志等 "模型就绪" 关键词,带超时。返回 ready 时戳或 fallback 时戳。
    /// 跑在后台队列(调用方保证),阻塞最长 deadline-now。
    private static func waitForASRReady(logPath: String, deadline: Date) -> Date {
        let keywords = ["模型就绪", "启动系统音频"]
        let pollInterval: TimeInterval = 0.1
        let tailBytes: UInt64 = 4096  // 只读文件尾,不每 0.1s 重读整份日志
        while Date() < deadline {
            if let fh = FileHandle(forReadingAtPath: logPath) {
                let size = fh.seekToEndOfFile()
                fh.seek(toFileOffset: size > tailBytes ? size - tailBytes : 0)
                let data = fh.readDataToEndOfFile()
                fh.closeFile()
                if let tail = String(data: data, encoding: .utf8),
                   keywords.contains(where: tail.contains) {
                    return Date()
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return Date()  // 超时,用当前时间作 fallback
    }

    /// 写 4 条 banner-shape init pings 到 translation_events.jsonl。
    /// 格式跟 main.swift 旧版 `send_status` 同款 — 必须是 translation_final
    /// + source_key="init-<ts>",OverlayState.applyStartupPing 才认。
    private static func writeStartupPings(
        transLogPath: String,
        asrLabel: String,
        translationLabel: String,
        loadSeconds: String
    ) {
        let now = Date().timeIntervalSince1970
        let pings: [(String, String)] = [
            ("ASR: \(asrLabel)", "ASR: \(asrLabel)"),
            ("翻译: \(translationLabel)", "Translation: \(translationLabel)"),
            ("加载完成 | \(loadSeconds)s", "Startup complete | \(loadSeconds)s"),
            ("whicc 正在聆听", "whicc is listening"),
        ]
        // 用 FileManager 追加(O_APPEND 模式)— Foundation 的 write(to:) 默认是
        // truncate,会覆盖整个文件。FileHandle(forUpdatingAtPath:) 持有写句柄
        // 即可 append。
        guard let handle = FileHandle(forWritingAtPath: transLogPath) else {
            fputs("[BackendLauncher] FAILED to open \(transLogPath) for append\n", stderr)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()

        for (i, (zh, en)) in pings.enumerated() {
            // 每条 source_key 加 i 毫秒,避免 macui OverlayState.applyStartupPing
            // 视为同一条 (它用 sourceKey 做去重判断)
            let ts = Int((now + Double(i) * 0.001) * 1000)
            let entry: [String: Any] = [
                "event_type": "translation_final",
                "source_key": "init-\(ts)",
                "source_update_mode": "reset_full",
                "source_text": en,
                "translated_full_text": zh,
                "translate_ms": 0,
                "shared_prefix_len": 0,
                "glossary_hits": [],
                "retried": false,
                "fallback_reason": "",
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: entry, options: []
            ), var line = String(data: data, encoding: .utf8) else {
                continue
            }
            line += "\n"
            if let bytes = line.data(using: .utf8) {
                handle.write(bytes)
            }
        }
        // 强制 flush 到磁盘,EventWatcher 才能立刻读到
        try? handle.synchronize()
    }

    @discardableResult
    private static func spawn(python: String, src: String, backend: BackendProc,
                              logDir: String, truncateLogs: Bool = true) -> Process? {
        fputs("[BackendLauncher] spawn \(backend.script) log=\(logDir)/\(backend.logName)\n", stderr)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [src + "/" + backend.script] + backend.args
        process.currentDirectoryURL = URL(fileURLWithPath: src)

        let stdoutPath = logDir + "/" + backend.logName
        let stderrPath = stdoutPath.replacingOccurrences(of: ".log", with: ".err.log")
        // truncate 模式 — 每次启动清空旧 log。
        // 崩溃后的自动重启传 truncateLogs=false:保留崩溃现场日志,
        // 新输出 append 在后面。
        if truncateLogs {
            for path in [stdoutPath, stderrPath] {
                do {
                    let empty = Data()
                    try empty.write(to: URL(fileURLWithPath: path))
                } catch {
                    fputs("[BackendLauncher] WARN failed to create log \(path): \(error)\n", stderr)
                }
            }
        }
        // C6 修:stdout / stderr 用独立 FileHandle(独立 fd)。之前共用
        // 一个 fd 时,Python 缓冲下 stderr 一行可能被 stdout 写入从中间
        // 切开 — 日志可读性灾难,无法 grep 单独 ASR/translation 输出。
        // append 模式 (Foundation FileHandle(forWritingAtPath:) 默认)
        // — 多次 process 启动不会清彼此的 log(我们上面已经 truncate)。
        let stdoutHandle = FileHandle(forWritingAtPath: stdoutPath)
        let stderrHandle = FileHandle(forWritingAtPath: stderrPath)
        guard let out = stdoutHandle, let err = stderrHandle else {
            fputs("[BackendLauncher] FAILED to open log handles for \(stdoutPath) / \(stderrPath)\n", stderr)
            // 退路:用 Pipe() 否则 Swift 端崩溃
            process.standardOutput = Pipe().fileHandleForWriting
            process.standardError = Pipe().fileHandleForWriting
            do { try process.run() } catch { return nil }
            return process
        }
        if !truncateLogs {
            // append 模式(崩溃重启):FileHandle 默认 offset=0 会覆盖
            // 崩溃现场,seek 到尾部续写。
            out.seekToEndOfFile()
            err.seekToEndOfFile()
        }
        process.standardOutput = out
        process.standardError = err

        // 关键:start_new_session 把子进程从 Swift 的 process group 摘出,
        // 这样 Swift 退出时不会给子进程发 SIGHUP
        do {
            try process.run()
            fputs("[BackendLauncher] started \(backend.script) pid=\(process.processIdentifier)\n", stderr)
        } catch {
            fputs("[BackendLauncher] FAILED to start \(backend.script): \(error)\n", stderr)
            return nil
        }
        return process
    }

    /// 翻译节点总开关的默认值处理。
    ///
    /// 第一次启动打包版 .app 时,lang_config.json 不存在,translate_stream.py
    /// 读 translation_enabled 缺省为 False 直接退。为避免「双击 .app 没翻译」,
    /// 这里在没这字段时默认开。
    ///
    /// 用户后续在 macui 设置里改过 → LangConfig.save() 写盘 → 字段存在 →
    /// 这里跳过 (不覆盖用户的决定)。
    private static func ensureDefaultLangConfig(runDir: String) {
        let cfgPath = runDir + "/lang_config.json"
        fputs("[BackendLauncher] ensureDefaultLangConfig \(cfgPath)\n", stderr)
        let url = URL(fileURLWithPath: cfgPath)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
            fputs("[BackendLauncher]   read existing, keys=\(json.keys.sorted())\n", stderr)
        } else {
            fputs("[BackendLauncher]   no existing config (or unreadable)\n", stderr)
        }

        var modified = false

        // translation_enabled 缺省 → true
        // 关键:如果已经是 false 也保持 false,尊重用户在 macui 设置里
        // 显式关掉的决定。只有"完全没这字段"才设默认。
        if json["translation_enabled"] == nil {
            json["translation_enabled"] = true
            modified = true
            fputs("[BackendLauncher] default translation_enabled=true (no existing key)\n", stderr)
        } else if let v = json["translation_enabled"] as? Bool, !v {
            fputs("[BackendLauncher] translation_enabled=false (user disabled), keeping\n", stderr)
        } else {
            fputs("[BackendLauncher] translation_enabled=true (already set), keeping\n", stderr)
        }

        // translation_fallback_url 缺省 → 不写默认值。
        // 之前硬编码 "http://localhost:1234",然后 translate_stream 启动时
        // 把它当已知值处理 → 用户从来没机会在 UI 看到"翻译 URL 是空的"提示。
        // 现状: 缺省 = 字段不存在,translate_stream 看到空就退出 + 提示
        // 用户去 macui 设置里配翻译节点。
        if json["translation_fallback_url"] == nil {
            // 字段缺失,不主动设,等用户自己填
            fputs("[BackendLauncher] translation_fallback_url 缺省,跳过 (用户需在 macui 配)\n", stderr)
        }

        // audio_source / source_lang / target_lang 默认值
        if json["audio_source"] == nil {
            json["audio_source"] = "system"
            modified = true
        }
        if json["source_lang"] == nil {
            json["source_lang"] = "auto"
            modified = true
        }
        if json["target_lang"] == nil {
            json["target_lang"] = "auto"
            modified = true
        }

        if !modified { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted]
        ) else { return }
        try? data.write(to: url, options: .atomic)
        fputs("[BackendLauncher] wrote \(cfgPath)\n", stderr)
        // 写后立即读回,看是 macOS 立刻覆盖还是保留
        if let reread = try? Data(contentsOf: url) {
            fputs("[BackendLauncher]   reread size=\(reread.count)\n", stderr)
        } else {
            fputs("[BackendLauncher]   reread FAILED (file gone!)\n", stderr)
        }
    }

    /// Kill all backend processes — applicationWillTerminate 时调。
    /// 跟 BackendShutdown.terminateLocalBackend() 同款逻辑,但用 SIGKILL
    /// 而非 SIGTERM (macui 退出会彻底清场,不留尾巴)。
    ///
    /// 之前 4 次串行 pkill,主线程最长阻塞 ~400ms — applicationWillTerminate
    /// 在主线程调,会被系统判定为"未响应"。改成:1 次 pkill 正则匹配所有模式,
    /// 丢到后台 Task 不阻塞主线程。
    static func terminateBackends() {
        guard AppPaths.isBundledApp else { return }
        // 先停监控 — 不然它会把我们主动杀掉的进程又拉起来。
        _monitorTimer?.cancel()
        _monitorTimer = nil
        _monitorLock.lock()
        _monitored.removeAll()
        _monitorLock.unlock()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // model_downloader 必须在清单里:之前漏掉它,App 每退出一次就留
        // 一个永不退出的下载守护进程,堆积的多个实例同时抢下同一个模型
        // (huggingface_hub 文件锁互相卡死),表现为"模型永远下载不完"。
        task.arguments = ["-9", "-f", backendPkillPattern]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        // 不 waitUntilExit — applicationWillTerminate 在主线程,pkill 异步
        // 跑,SwiftUI 在 pkill 跑完前已经退到系统级清理流程。
    }

    /// 后端进程的 pkill -f 匹配模式 — terminateBackends(退出清场)和
    /// launchBackendsIfNeeded(启动前清孤儿)共用,避免两处清单不同步。
    private static let backendPkillPattern =
        "whicc-audio|glossary_refresher|translate_stream|model_downloader|whicc.py"

    // MARK: - 子进程存活监控

    private struct MonitoredProc {
        let backend: BackendProc
        var process: Process
        var restarts: Int
        var lastRestartAt: Date?
        /// "等配置/等模型"提示(exit 3)只发一次,避免每次重试都刷通知。
        var waitingNoticeShown = false
    }

    /// 后端"等待配置/资源"的约定退出码 — 配置性等待,不是故障:
    /// - whicc.py: ASR 模型未下载/残缺
    /// - translate_stream.py: 翻译服务 URL 未配置 / 翻译未启用
    private static let _exitWaitingConfig: Int32 = 3

    /// 音频自愈重启的约定退出码(恢复性,不是故障):whicc.py 检测到
    /// 音频源 12s 无数据(macOS process tap 对 respawn 的 audiotee 静默
    /// 拒绝授权)主动退出,由监控拉起新进程重新拿授权。给"正在自动
    /// 恢复"文案,别用"异常退出"吓用户。
    private static let _exitAudioRecover: Int32 = 4

    private static var _monitored: [MonitoredProc] = []
    private static let _monitorLock = NSLock()
    private static var _monitorTimer: DispatchSourceTimer?
    private static var _spawnContext: (python: String, src: String, logDir: String)?
    /// 快速重启上限 — 连续崩这么多次后退避到慢速重试(模型未下载等
    /// 持续性故障不值得每 5s 拉一次,但下载完成后慢速重试能自动恢复)。
    private static let _fastRestarts = 3
    private static let _slowRetryInterval: TimeInterval = 300

    private static func startProcessMonitor() {
        guard _monitorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { checkProcesses() }
        timer.resume()
        _monitorTimer = timer
        logAndStderr("[monitor] process liveness monitor started (5s interval)")
    }

    private static func checkProcesses() {
        guard let ctx = _spawnContext else { return }
        _monitorLock.lock()
        defer { _monitorLock.unlock() }
        let now = Date()
        for i in _monitored.indices {
            let m = _monitored[i]
            guard !m.process.isRunning else { continue }
            let code = m.process.terminationStatus
            let waiting = (code == _exitWaitingConfig)
            let audioRecover = (code == _exitAudioRecover)
            // 退避:快速重启次数耗尽后,每 _slowRetryInterval 才试一次。
            // 例外:"等配置"退出(code 3)时,对应资源一就绪就立即重启 —
            // whicc.py 等 models 目录出现新 .complete(模型下载完成),
            // translate_stream.py 等 lang_config.json 更新(用户填了
            // 服务地址,debounce 自动保存) — 秒恢复,不等慢速窗口。
            if m.restarts >= _fastRestarts,
               let last = m.lastRestartAt,
               now.timeIntervalSince(last) < _slowRetryInterval {
                if !(waiting && waitedResourceReady(script: m.backend.script, since: last)) {
                    continue
                }
                logAndStderr("[monitor] waited resource ready, restarting \(m.backend.script) immediately")
            }
            _monitored[i].restarts += 1
            _monitored[i].lastRestartAt = now
            let n = _monitored[i].restarts
            logAndStderr("[monitor] \(m.backend.script) exited (code \(code)), "
                         + "restart #\(n)\(n > _fastRestarts ? " (slow retry)" : "")")
            if waiting || audioRecover {
                // 配置性等待 / 音频自愈,不是故障 — 给指引而不是吓人的
                // "异常退出";只发一次,静默重试。
                if !m.waitingNoticeShown {
                    _monitored[i].waitingNoticeShown = true
                    let (zh, en) = audioRecover
                        ? ("🎧 系统音频捕获中断(输出设备切换/录音授权变化),正在自动恢复…",
                           "🎧 System audio capture interrupted (device switch / permission change); recovering automatically…")
                        : waitingNotice(script: m.backend.script)
                    appendBackendNotice(zh: zh, en: en)
                }
            } else {
                appendBackendNotice(
                    zh: "⚠️ 后端 \(m.backend.script) 异常退出(code \(code)),自动重启中 #\(n)",
                    en: "⚠️ Backend \(m.backend.script) exited (code \(code)); auto-restarting #\(n)")
            }
            if let p = spawn(python: ctx.python, src: ctx.src,
                             backend: m.backend, logDir: ctx.logDir,
                             truncateLogs: false) {
                _monitored[i].process = p
            }
        }
    }

    /// 用户主动重启某个后端(如 ServerPane 的"保存并重启翻译服务")的
    /// **统一通道** — 必须走这里而不是自行 pkill+spawn:监控 5s 内会把
    /// pkill 掉的进程当"死亡"再拉起一个,跟按钮自己 spawn 的撞成
    /// **双实例**,并发写 translation_events.jsonl → 字幕重复交错。
    /// 本方法持监控锁完成 杀旧+respawn+更新注册表,监控全程看到的是
    /// 一致状态;spawn 参数/日志路径与首次启动完全同款(含 --force-enable)。
    ///
    /// 返回 false = 打包模式未启动(dev 模式)或未知脚本,调用方可走
    /// dev 模式的兜底路径。
    @discardableResult
    static func restartBackend(script: String) -> Bool {
        _monitorLock.lock()
        defer { _monitorLock.unlock() }
        guard let ctx = _spawnContext,
              let i = _monitored.firstIndex(where: { $0.backend.script == script }) else {
            return false
        }
        let old = _monitored[i].process
        if old.isRunning {
            old.terminate()  // SIGTERM,让 Python 侧 flush 日志
            let deadline = Date().addingTimeInterval(2)
            while old.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if old.isRunning {
                kill(old.processIdentifier, SIGKILL)
            }
        }
        logAndStderr("[monitor] user-requested restart of \(script)")
        guard let p = spawn(python: ctx.python, src: ctx.src,
                            backend: _monitored[i].backend, logDir: ctx.logDir,
                            truncateLogs: true) else {
            return false
        }
        _monitored[i].process = p
        _monitored[i].restarts = 0            // 用户主动重启,计数清零
        _monitored[i].lastRestartAt = Date()
        _monitored[i].waitingNoticeShown = false
        return true
    }

    /// "等配置"退出(code 3)的字幕区指引文案,按脚本区分。
    private static func waitingNotice(script: String) -> (zh: String, en: String) {
        switch script {
        case "whicc.py":
            return ("⏳ 语音识别模型未就绪 — 请到 设置 → 模型 页下载;完成后自动开始识别",
                    "⏳ ASR model not ready — download it in Settings → Models; recognition starts automatically once done")
        case "translate_stream.py":
            return ("💬 翻译服务未配置 — 到 设置 → 服务配置 填写地址即可启用;不配置也能看原文字幕",
                    "💬 Translation not configured — set the service address in Settings → Server to enable; source-only captions work without it")
        default:
            return ("⏳ 后端 \(script) 等待配置中,就绪后自动启动",
                    "⏳ Backend \(script) waiting for configuration; starts automatically once ready")
        }
    }

    /// code 3 等待的资源是否已就绪(比 `since` 更新):
    /// - whicc.py: models 目录出现新 .complete 标记(模型下载完成)
    /// - translate_stream.py: lang_config.json 被更新(用户保存了配置)
    private static func waitedResourceReady(script: String, since: Date) -> Bool {
        let fm = FileManager.default
        switch script {
        case "whicc.py":
            let modelsDir = NSHomeDirectory() + "/Library/Application Support/whicc/models"
            guard let entries = try? fm.contentsOfDirectory(atPath: modelsDir) else { return false }
            for name in entries where name.hasSuffix(".complete") {
                if let attrs = try? fm.attributesOfItem(atPath: modelsDir + "/" + name),
                   let mtime = attrs[.modificationDate] as? Date,
                   mtime > since {
                    return true
                }
            }
            return false
        case "translate_stream.py":
            let cfgPath = AppPaths.runDir + "/lang_config.json"
            if let attrs = try? fm.attributesOfItem(atPath: cfgPath),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > since {
                return true
            }
            return false
        default:
            return false
        }
    }

    /// 往 translation_events.jsonl 追加一条通知(translation_final 事件),
    /// 走 EventWatcher → OverlayState 的既有链路显示在字幕区 — 用户
    /// 能直接看到"后端崩了/已重启",不用去翻日志。
    private static func appendBackendNotice(zh: String, en: String) {
        let transLogPath = AppPaths.runDir + "/translation_events.jsonl"
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let entry: [String: Any] = [
            "event_type": "translation_final",
            "source_key": "monitor-\(ts)",
            "source_update_mode": "reset_full",
            "source_text": en,
            "translated_full_text": zh,
            "translate_ms": 0,
            "shared_prefix_len": 0,
            "glossary_hits": [],
            "retried": false,
            "fallback_reason": "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8),
              let handle = FileHandle(forWritingAtPath: transLogPath) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        line += "\n"
        if let bytes = line.data(using: .utf8) {
            handle.write(bytes)
        }
    }
}