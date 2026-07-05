import Foundation

/// Bridges the Swift overlay to the Python side via
/// `/tmp/whicc-out/lang_config.json`. The wire format and keys are the same
/// as the legacy overlay, so the Python daemon needs no change.
@MainActor
final class LangConfig: ObservableObject {

    @Published var targetLang: String = "auto"
    /// 源语言（原文识别目标）。默认 "auto" = 让 Python 后端自己检测。
    /// 切换后需重启 whicc.py + translate_stream.py 生效（同
    /// translation_url 的策略）—— ASR 模型加载后 --language 参数
    /// 是只读的,要重传只能在 whicc 重启时传入。
    /// 33 种语言（复用 LANGUAGE_GROUPS）+ "auto" 一项。
    @Published var sourceLang: String = "auto"
    @Published var translationUrl: String = ""
    /// 本机翻译回退地址 — 远端 translation_url 不可达时,translate_stream
    /// 自动按顺序探测 fallback 链 (远端 → 本机 → CLI 默认值)。空串 = 不配
    /// 本机 fallback,Python 端用 --vllm-fallback-url CLI 默认值
    /// (localhost:1234)。切换后需重启 translate_stream 生效。
    @Published var translationFallbackUrl: String = ""
    /// 远端翻译节点(vLLM/LM Studio)的模型名称,会作为
    /// `/v1/chat/completions` 请求体的 `"model"` 字段发出。空 = 用
    /// Python 端 `--model-id` 的默认值。切换后需重启 translate_stream
    /// 生效(同 ModelPane 本地模型槽位的策略)。
    @Published var translationModel: String = ""
    /// 本机翻译回退用的模型名 — 远端 translation_url 不可达时,fallback
    /// 链可指定本机用跟主 URL 不同的模型(比如远端跑 qwen2.5-32b-instruct,
    /// 空串 = 跟 translation_model 一样。切换后需重启 translate_stream 生效。
    @Published var translationFallbackModel: String = ""
    /// 翻译节点的总开关:关 = 翻译未启用(translate_stream 启动失败退出);
    /// 开 = 走远端 vLLM / LM Studio HTTP 后端。默认关 — 用户必须
    /// 显式开,即使填了 URL 也不自动启用。改完需重启 translate_stream 生效。
    @Published var translationEnabled: Bool = false
    @Published var hermesHost: String = ""
    /// Subtitle font choice — persisted but owned by `OverlayState`
    /// (UI binds to `state.fontChoice`). `LangConfig` just stores the
    /// raw string so we can round-trip the value through
    /// `lang_config.json` without bothering the Python side.
    @Published var subtitleFont: String = "rounded"
    /// 音频采集源（"system" = 系统声音， "mic" = 内置麦克风）。
    /// HUD ASR chip 的 speaker/mic icon 点击切这个字段，写盘后
    /// 给 whicc.py 发 SIGHUP 触发热切换（不重启后端）。
    @Published var audioSource: String = "system"
    /// 用户收藏的字体（rawValue 列表）。HUD 的 A 按钮在 [.rounded, .serif]
    /// + 用户收藏 的合集里循环——默认两个永远在合集里,确保 HUD
    /// 至少有 2 个可切项。空列表 = 仅循环两个默认。
    @Published var favoriteFonts: [String] = []
    /// Subtitle accent color (OverlayStyle raw value: theater/ice/gold
    /// /neon/coral/violet/cyan/clay/custom). Owned by `OverlayState`
    /// for the same reason as `subtitleFont` — `LangConfig` is just
    /// the persisted mirror so it survives a restart.
    @Published var subtitleColor: String = "white"
    /// 自定义颜色 (state.style == .custom 时用)。hex 字符串 (#RRGGBB 或
    /// #RRGGBBAA)，方便 lang_config.json 里人来读懂也方便 Python 端将来
    /// 解析。空 = 没自定义过，让 OverlayState 兜底成白色。
    @Published var customColorHex: String = ""
    /// Default size for the translation line (pt). Owned by
    /// `OverlayState.transFontSize`; `LangConfig` is the persisted
    /// default that `OverlayState.init` reads at startup.
    @Published var transFontSize: CGFloat = 32
    /// Default size for the source line (pt). Same pattern as
    /// `transFontSize`.
    @Published var srcFontSize: CGFloat = 18
    /// Default window background opacity (0.05–1.0). Owned by
    /// `OverlayState.bgOpacity`; `LangConfig` is the persisted default.
    @Published var bgOpacity: CGFloat = 0.85
    /// 文字描边 / 阴影参数（用户可调）。0~1 / 0~N 区间。
    @Published var strongShadowOpacity: Double = 0.70
    @Published var softShadowOpacity: Double = 0.40
    @Published var strongShadowRadius: CGFloat = 16
    @Published var softShadowRadius: CGFloat = 4

    /// nil = not checked, true = reachable, false = unreachable.
    @Published var translationReachable: Bool?
    @Published var translationFallbackReachable: Bool?
    @Published var hermesReachable: Bool?

    /// 远端翻译节点通过 GET /v1/models 返回的模型 id 列表。fetchRemoteModels
    /// 触发拉取；模型名输入框旁边的菜单按钮读这个字段渲染下拉。
    /// 不持久化——每次打开设置页点刷新就重新拉。
    @Published var remoteModels: [String] = []
    /// remoteModels 拉取状态:nil=未拉, true=成功, false=失败/超时。
    /// 让 UI 决定显示「获取列表」/loading/「拉取失败」三种态。
    @Published var remoteModelsFetched: Bool?
    /// 本机 fallback 翻译节点的 /v1/models 列表 — 跟 remoteModels 同款,
    /// 但数据源是 translationFallbackUrl。fetchRemoteModelsFallback 触发。
    @Published var remoteModelsFallback: [String] = []
    /// fallback 列表拉取状态,语义同 remoteModelsFetched。
    @Published var remoteModelsFallbackFetched: Bool?

    private let configPath: String
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var retryWatchWorkItem: DispatchWorkItem?
    private var fd: Int32 = -1

    init(outDir: String = AppPaths.runDir) {
        self.configPath = "\(outDir)/lang_config.json"
        // 启动时同步读一次：如果 Python 后端已经写好配置文件，
        // 字段立刻就有正确值，UI 不会先用默认值渲染再被异步更新覆盖。
        // loadSync() 只在 init 阶段用——监视器触发时还是走 load() 异步路径，
        // 避免阻塞主线程。
        loadSync()
        startWatching()
    }

    deinit {
        retryWatchWorkItem?.cancel()
        fileWatcher?.cancel()
        fd = -1
    }

    // MARK: - Mutators

    func setSubtitleFont(_ raw: String) {
        subtitleFont = raw
        save()
    }

    /// 收藏字体列表 setter。存 rawValue 数组,持久化到 lang_config.json
    /// 的 favorite_fonts 键 (JSON array of strings)。
    /// 重复值由调用方去重——这里只管替换整个数组。
    func setFavoriteFonts(_ raws: [String]) {
        favoriteFonts = raws
        save()
    }

    /// Audio source setter。macui HUD chip 点击切 source → 写这个键 →
    /// 给 whicc.py 发 SIGHUP → whicc 热切换 audio 采集源（不重启后端）。
    func setAudioSource(_ raw: String) {
        audioSource = raw
        save()
    }

    func setSubtitleColor(_ raw: String) {
        subtitleColor = raw
        save()
    }

    func setCustomColorHex(_ hex: String) {
        customColorHex = hex
        save()
    }

    func setLang(_ lang: String) {
        targetLang = lang
        save()
    }

    /// 源语言 setter — 跟 setLang 一样写 target_lang 键。保持单 setter
    /// 简化调用方,save() 一次写两个键。
    func setSourceLang(_ lang: String) {
        sourceLang = lang
        save()
    }

    func setTranslationUrl(_ url: String) {
        translationUrl = url
        save()
    }

    func setTranslationFallbackUrl(_ url: String) {
        translationFallbackUrl = url
        save()
    }

    func setTranslationModel(_ model: String) {
        translationModel = model
        save()
    }

    func setTranslationFallbackModel(_ model: String) {
        translationFallbackModel = model
        save()
    }

    func setTranslationEnabled(_ enabled: Bool) {
        translationEnabled = enabled
        save()
    }

    func setHermesHost(_ host: String) {
        hermesHost = host
        save()
    }

    // MARK: - Debounced setters (slider 频繁更新)
    //
    // bgOpacity / 字号 / shadow 参数都是 Slider 绑的,用户拖动时
    // 一次操作触发几十次 set。如果每次 set 都同步写盘:
    //   1. JSONSerialization + prettyPrinted 编码 (~700 字节)
    //   2. data.write(.atomic) 同步文件 I/O
    //   3. 主线程卡住,Slider thumb 跟手延迟明显
    //
    // Debounced set: 第一次 set 调度 0.5s 后的 Timer;期间再 set 重新调度。
    // 0.5s 是 stop-tolerance (用户停止拖动 ~半秒就触发写盘, 体感无延迟)。

    private var debouncedSaveWorkItem: DispatchWorkItem?

    /// 立即把内存里所有字段写到磁盘。debouncedSave() 会异步调用它。
    private func saveDebounced(after delay: TimeInterval = 0.5) {
        debouncedSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        debouncedSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func setBgOpacity(_ value: CGFloat) {
        bgOpacity = value
        saveDebounced()
    }

    func setStrongShadowOpacity(_ value: Double) {
        strongShadowOpacity = value
        saveDebounced()
    }

    func setSoftShadowOpacity(_ value: Double) {
        softShadowOpacity = value
        saveDebounced()
    }

    func setStrongShadowRadius(_ value: CGFloat) {
        strongShadowRadius = value
        saveDebounced()
    }

    func setSoftShadowRadius(_ value: CGFloat) {
        softShadowRadius = value
        saveDebounced()
    }

    func setTransFontSize(_ value: CGFloat) {
        transFontSize = value
        saveDebounced()
    }

    func setSrcFontSize(_ value: CGFloat) {
        srcFontSize = value
        saveDebounced()
    }

    // MARK: - Reachability

    func detectTranslation() {
        guard !translationUrl.isEmpty else {
            translationReachable = nil
            return
        }
        let url = translationUrl.hasPrefix("http") ? translationUrl : "http://\(translationUrl)"
        guard let endpoint = URL(string: "\(url)/health") else {
            translationReachable = false
            return
        }
        URLSession.shared.dataTask(with: endpoint) { [weak self] _, resp, err in
            Task { @MainActor in
                guard let self else { return }
                let wasReachable = self.translationReachable
                let nowReachable = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
                self.translationReachable = nowReachable
                // URL 联通后自动拉一次模型列表。触发条件：状态从不可达→可达
                // (用户刚填对 URL) 或 URL 没变但从未拉过 (nil→true)。
                // 用户手动点 refresh 按钮时不重复拉，因为 fetchRemoteModels
                // 会覆盖列表——但用户主动刷新显然是想要新数据,顺便再拉一次
                // 也不亏。直接调即可。
                if nowReachable && (wasReachable != true) {
                    self.fetchRemoteModels()
                }
            }
        }.resume()
    }

    /// GET <translationUrl>/v1models 拉远端已加载的模型列表。LM Studio /
    /// vLLM / Ollama(OpenAI 兼容模式)都返回 `{"data": [{"id": "..."}]}`。
    /// 成功时覆盖 `remoteModels` 并标 `remoteModelsFetched = true`。
    /// 注意：URL 为空、解析失败、HTTP 非 2xx 都标 `false` 而不是抛错——
    /// UI 用 `nil/false` 决定显示"获取列表"按钮或"拉取失败"重试提示。
    func fetchRemoteModels() {
        guard !translationUrl.isEmpty else {
            remoteModels = []
            remoteModelsFetched = nil
            return
        }
        let base = translationUrl.hasPrefix("http") ? translationUrl : "http://\(translationUrl)"
        guard let endpoint = URL(string: "\(base)/v1/models") else {
            remoteModels = []
            remoteModelsFetched = false
            return
        }
        URLSession.shared.dataTask(with: endpoint) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if err != nil || data == nil {
                    self.remoteModels = []
                    self.remoteModelsFetched = false
                    return
                }
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    self.remoteModels = []
                    self.remoteModelsFetched = false
                    return
                }
                // 用 JSONSerialization 而非 Decodable——payload 形状因
                // 后端略不同(Ollama 多 `object` 字段、vLLM 有 created)，
                // 但 `data[].id` 是 OpenAI 兼容标准。容错解析。
                guard let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                      let arr = json["data"] as? [[String: Any]] else {
                    self.remoteModels = []
                    self.remoteModelsFetched = false
                    return
                }
                let ids = arr.compactMap { $0["id"] as? String }
                self.remoteModels = ids
                self.remoteModelsFetched = true
            }
        }.resume()
    }

    /// GET <translationFallbackUrl>/v1/models 拉本机 fallback 已加载的模型列表。
    /// 跟 fetchRemoteModels 同结构(同一 OpenAI 兼容协议),区别只是 URL 来源
    /// 跟写入字段不同。两个方法独立,各自管各自的状态字段,
    /// UI 通过 ModelPickerMenu 渲染互不干扰。
    func fetchRemoteModelsFallback() {
        guard !translationFallbackUrl.isEmpty else {
            remoteModelsFallback = []
            remoteModelsFallbackFetched = nil
            return
        }
        let base = translationFallbackUrl.hasPrefix("http") ? translationFallbackUrl : "http://\(translationFallbackUrl)"
        guard let endpoint = URL(string: "\(base)/v1/models") else {
            remoteModelsFallback = []
            remoteModelsFallbackFetched = false
            return
        }
        URLSession.shared.dataTask(with: endpoint) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if err != nil || data == nil {
                    self.remoteModelsFallback = []
                    self.remoteModelsFallbackFetched = false
                    return
                }
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    self.remoteModelsFallback = []
                    self.remoteModelsFallbackFetched = false
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                      let arr = json["data"] as? [[String: Any]] else {
                    self.remoteModelsFallback = []
                    self.remoteModelsFallbackFetched = false
                    return
                }
                let ids = arr.compactMap { $0["id"] as? String }
                self.remoteModelsFallback = ids
                self.remoteModelsFallbackFetched = true
            }
        }.resume()
    }

    func detectHermes() {
        guard !hermesHost.isEmpty else {
            hermesReachable = nil
            return
        }
        // Capture the value on the main actor before crossing into the
        // background dispatch queue.
        let host = hermesHost
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-o", "ConnectTimeout=3",
                "-o", "StrictHostKeyChecking=no",
                host,
                "echo", "ok",
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            Task { @MainActor in
                self?.hermesReachable = proc.terminationStatus == 0
            }
        }
    }

    /// 探测本机翻译回退 URL 连通性，跟 detectTranslation 同结构。
    /// URL 为空时把 reachable 置 nil（避免误导用户看到红色 ✗）。
    func detectTranslationFallback() {
        guard !translationFallbackUrl.isEmpty else {
            translationFallbackReachable = nil
            return
        }
        let url = translationFallbackUrl.hasPrefix("http")
            ? translationFallbackUrl
            : "http://\(translationFallbackUrl)"
        guard let endpoint = URL(string: "\(url)/health") else {
            translationFallbackReachable = false
            return
        }
        URLSession.shared.dataTask(with: endpoint) { [weak self] _, resp, err in
            Task { @MainActor in
                guard let self else { return }
                let wasReachable = self.translationFallbackReachable
                let nowReachable = err == nil
                    && (resp as? HTTPURLResponse)?.statusCode == 200
                self.translationFallbackReachable = nowReachable
                // URL 联通后自动拉一次 fallback 模型列表(跟主 URL detectTranslation 同逻辑)
                if nowReachable && (wasReachable != true) {
                    self.fetchRemoteModelsFallback()
                }
            }
        }.resume()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Task { @MainActor in
            if let lang = json["target_lang"] as? String { self.targetLang = lang }
            // 旧配置文件无 source_lang 键,默认 "auto" (跟 Python 端
            // 行为一致,让 ASR 自己检测)。不覆盖已经设置过的 target_lang。
            if let lang = json["source_lang"] as? String { self.sourceLang = lang }
            self.translationUrl = (json["translation_url"] as? String) ?? ""
            self.translationFallbackUrl = (json["translation_fallback_url"] as? String) ?? ""
            self.translationModel = (json["translation_model"] as? String) ?? ""
            self.translationFallbackModel = (json["translation_fallback_model"] as? String) ?? ""
            // 旧配置文件没有 translation_enabled 键,默认为关(纯本地)。
            // 这样老用户升级后行为不会突变。
            self.translationEnabled = (json["translation_enabled"] as? Bool) ?? false
            self.hermesHost = (json["hermes_host"] as? String) ?? ""
            if let font = json["subtitle_font"] as? String { self.subtitleFont = font }
            if let fav = json["favorite_fonts"] as? [String] { self.favoriteFonts = fav }
            // audio_source: "system" | "mic"。旧配置无此键时默认 "system"。
            if let src = json["audio_source"] as? String { self.audioSource = src }
            // 下面 4 个字段都是「外观默认值」,老配置不存在时用上面的
            // hard-coded 默认值,不会让旧用户的样式突变。
            if let color = json["subtitle_color"] as? String { self.subtitleColor = color }
            if let hex = json["custom_color_hex"] as? String { self.customColorHex = hex }
            // `v >= 0` 接受合法的 0(用户明确想"不要阴影"或"完全透明")。
            // 之前用 `v > 0` 是 falsy-zero check,把 0 当成"未设置",用默认覆盖,
            // 用户手编 lang_config.json 设 0 就被静默丢弃。负数仍视为非法
            // (跟之前一样拒绝 — 负 size / opacity 渲染无意义)。
            if let v = json["trans_font_size"] as? Double, v >= 0 { self.transFontSize = CGFloat(v) }
            if let v = json["src_font_size"] as? Double, v >= 0 { self.srcFontSize = CGFloat(v) }
            if let v = json["bg_opacity"] as? Double, v >= 0 { self.bgOpacity = CGFloat(v) }
            if let v = json["strong_shadow_opacity"] as? Double, v >= 0 { self.strongShadowOpacity = v }
            if let v = json["soft_shadow_opacity"] as? Double, v >= 0 { self.softShadowOpacity = v }
            if let v = json["strong_shadow_radius"] as? Double, v >= 0 { self.strongShadowRadius = CGFloat(v) }
            if let v = json["soft_shadow_radius"] as? Double, v >= 0 { self.softShadowRadius = CGFloat(v) }
        }
    }

    /// 同步版本的 load：只在 init 阶段用，让字段在第一次 SwiftUI 渲染前就有值。
    /// 监视器触发还是走上面的 load() 异步版本，避免阻塞主线程。
    private func loadSync() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let lang = json["target_lang"] as? String { self.targetLang = lang }
        if let lang = json["source_lang"] as? String { self.sourceLang = lang }
        self.translationUrl = (json["translation_url"] as? String) ?? ""
        self.translationFallbackUrl = (json["translation_fallback_url"] as? String) ?? ""
        self.translationModel = (json["translation_model"] as? String) ?? ""
        self.translationFallbackModel = (json["translation_fallback_model"] as? String) ?? ""
        self.translationEnabled = (json["translation_enabled"] as? Bool) ?? false
        self.hermesHost = (json["hermes_host"] as? String) ?? ""
        if let font = json["subtitle_font"] as? String { self.subtitleFont = font }
        if let fav = json["favorite_fonts"] as? [String] { self.favoriteFonts = fav }
        if let src = json["audio_source"] as? String { self.audioSource = src }
        if let color = json["subtitle_color"] as? String { self.subtitleColor = color }
        if let hex = json["custom_color_hex"] as? String { self.customColorHex = hex }
        // 跟 load() 同款 `v >= 0`(接受合法的 0)
        if let v = json["trans_font_size"] as? Double, v >= 0 { self.transFontSize = CGFloat(v) }
        if let v = json["src_font_size"] as? Double, v >= 0 { self.srcFontSize = CGFloat(v) }
        if let v = json["bg_opacity"] as? Double, v >= 0 { self.bgOpacity = CGFloat(v) }
        if let v = json["strong_shadow_opacity"] as? Double, v >= 0 { self.strongShadowOpacity = v }
        if let v = json["soft_shadow_opacity"] as? Double, v >= 0 { self.softShadowOpacity = v }
        if let v = json["strong_shadow_radius"] as? Double, v >= 0 { self.strongShadowRadius = CGFloat(v) }
        if let v = json["soft_shadow_radius"] as? Double, v >= 0 { self.softShadowRadius = CGFloat(v) }
    }

    private func save() {
        // 先读出现有内容，把不属于 LangConfig 的字段（比如 ScenePane 写的
        // scene_text）保留下来，再覆盖 LangConfig 自己负责的 6 个键。
        // 之前是直接写一个 4 键的字典，会把文件里其他键全删掉。
        // 注：字典类型从 [String: String] 升级到 [String: Any]，因为
        // translation_enabled 是 Bool。读时尝试 Any，保留任何已有的
        // 异构字段（如果之前别处写过非 String 值）。
        var json: [String: Any] = [:]
        // 不要用 try? 把读盘错误吞掉。读盘失败时打印错误，
        // 否则会从空字典开始重写，把 Python 端写的字段全抹掉。
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            if let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            } else {
                logSave("file is not a JSON object; treating as empty")
            }
        } catch {
            logSave("read existing failed: \(error)")
        }
        json["target_lang"] = targetLang
        json["source_lang"] = sourceLang
        json["translation_url"] = translationUrl
        json["translation_fallback_url"] = translationFallbackUrl
        json["translation_model"] = translationModel
        json["translation_fallback_model"] = translationFallbackModel
        json["translation_enabled"] = translationEnabled
        json["hermes_host"] = hermesHost
        json["subtitle_font"] = subtitleFont
        json["favorite_fonts"] = favoriteFonts
        json["audio_source"] = audioSource
        json["subtitle_color"] = subtitleColor
        json["custom_color_hex"] = customColorHex
        json["trans_font_size"] = Double(transFontSize)
        json["src_font_size"] = Double(srcFontSize)
        json["bg_opacity"] = Double(bgOpacity)
        json["strong_shadow_opacity"] = strongShadowOpacity
        json["soft_shadow_opacity"] = softShadowOpacity
        json["strong_shadow_radius"] = Double(strongShadowRadius)
        json["soft_shadow_radius"] = Double(softShadowRadius)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        } catch {
            logSave("encode failed: \(error)")
            return
        }
        // 使用 .atomic 避免读到半截 JSON。atomic 写通常会 rename
        // 新文件，文件监视器在 .rename 后会重新 open 当前路径。
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            logSave("write failed: \(error)")
        }
    }

    private func logSave(_ msg: String) {
        FileHandle.standardError.write("[lang] save: \(msg)\n".data(using: .utf8) ?? Data())
    }

    private func startWatching() {
        // 如果文件还不存在（启动时 Python 后端还没写出来），
        // 就每秒试一次 open + load，直到成功为止。
        // 之前是「文件不存在就直接放弃」，导致监视器永远装不上，
        // 后续 Python 写入 Swift 这边收不到（详见 docs/ui-review-findings.md 第 1 条）。
        scheduleRetry()
    }

    /// 试图打开文件 + 注册监视器。失败时排下一次重试。
    private func attemptStartWatching() {
        guard fileWatcher == nil else { return }

        let newFD = open(configPath, O_EVTONLY)
        guard newFD >= 0 else {
            scheduleRetry()
            return
        }
        fd = newFD
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD, eventMask: [.write, .rename], queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            self?.load()
            if src?.data.contains(.rename) == true {
                self?.restartWatchingRenamedFile()
            }
        }
        src.setCancelHandler {
            close(newFD)
        }
        src.resume()
        fileWatcher = src
        // 监视器装上的瞬间，立刻读一次当前文件内容，
        // 把启动后到此刻之间 Python 写入的最新值捞回来。
        load()
    }

    private func scheduleRetry() {
        retryWatchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.retryWatchWorkItem = nil
            self?.attemptStartWatching()
        }
        retryWatchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func restartWatchingRenamedFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        fd = -1
        scheduleRetry()
    }
}

// MARK: - Language catalogue (33 languages)

struct LangGroup: Identifiable {
    let id = UUID()
    /// 组名(亚洲/欧洲/中东)走 LocalizedStringKey。NSMenu 中显示成 verbatim String,
    /// 在 LanguageMenuButton 里调 NSLocalizedString() 显式查表。
    let name: String
    let langs: [LangItem]
}

struct LangItem: Identifiable, Equatable {
    let id: String
    let label: String
}

let LANGUAGE_GROUPS: [LangGroup] = [
    // 注：第一组之前是 "自动 / 自动检测" LangItem。
    // 这个 LangItem 在 AppearancePane 重复出现 (Picker 顶部加了
    // "自动检测" 一项 + LANGUAGE_GROUPS 第一组又有一个) — 移除以免
    // 语言 picker 里显示两个 "自动检测"。
    // 现在 Picker 直接在顶部加 "自动检测" 作为独立项,
    // 然后从亚洲组开始 — 简化结构。
    LangGroup(name: "亚洲", langs: [
        LangItem(id: "zh-cn", label: "中文"),
        LangItem(id: "zh-tw", label: "繁體中文"),
        LangItem(id: "yue", label: "粤语"),
        LangItem(id: "ja", label: "日本語"),
        LangItem(id: "ko", label: "한국어"),
        LangItem(id: "hi", label: "हिन्दी"),
        LangItem(id: "vi", label: "Tiếng Việt"),
        LangItem(id: "th", label: "ไทย"),
        LangItem(id: "id", label: "Bahasa Indonesia"),
        LangItem(id: "ms", label: "Bahasa Melayu"),
        LangItem(id: "tl", label: "Filipino"),
        LangItem(id: "km", label: "ភាសាខ្មែរ"),
        LangItem(id: "my", label: "မြန်မာ"),
        LangItem(id: "ta", label: "தமிழ்"),
        LangItem(id: "te", label: "తెలుగు"),
        LangItem(id: "mr", label: "मराठी"),
        LangItem(id: "gu", label: "ગુજરાતી"),
        LangItem(id: "bn", label: "বাংলা"),
        LangItem(id: "bo", label: "བོད་སྐད"),
        LangItem(id: "mn", label: "Монгол"),
        LangItem(id: "ug", label: "ئۇيغۇرچە"),
    ]),
    LangGroup(name: "欧洲", langs: [
        LangItem(id: "en", label: "English"),
        LangItem(id: "fr", label: "Français"),
        LangItem(id: "de", label: "Deutsch"),
        LangItem(id: "es", label: "Español"),
        LangItem(id: "it", label: "Italiano"),
        LangItem(id: "pt", label: "Português"),
        LangItem(id: "ru", label: "Русский"),
        LangItem(id: "nl", label: "Nederlands"),
        LangItem(id: "pl", label: "Polski"),
        LangItem(id: "cs", label: "Čeština"),
        LangItem(id: "tr", label: "Türkçe"),
        LangItem(id: "uk", label: "Українська"),
    ]),
    LangGroup(name: "中东", langs: [
        LangItem(id: "ar", label: "العربية"),
        LangItem(id: "he", label: "עברית"),
        LangItem(id: "fa", label: "فارسی"),
        LangItem(id: "ur", label: "اردو"),
        LangItem(id: "kk", label: "Қазақ"),
    ]),
]

let LANG_SHORT_LABELS: [String: String] = [
    "auto": "自动",
    "zh-cn": "中", "zh-tw": "繁", "yue": "粤",
    "en": "EN", "ja": "JA", "ko": "KO", "fr": "FR", "de": "DE",
    "es": "ES", "it": "IT", "pt": "PT", "ru": "RU", "ar": "عر",
    "hi": "HI", "th": "TH", "vi": "VI", "nl": "NL", "pl": "PL",
    "tr": "TR", "id": "ID", "ms": "MS", "uk": "UA", "cs": "CS",
    "he": "עב", "tl": "TL", "km": "KM", "my": "MY", "fa": "FA",
    "bn": "BN", "ta": "த", "te": "TE", "mr": "MR", "gu": "GU",
    "ur": "UR", "bo": "藏", "kk": "KK", "mn": "MN", "ug": "UG",
]
