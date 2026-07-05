import Foundation
import AppKit

/// macui 端的模型状态管理。
///
/// 关注两件事：
/// 1. `models_dir` 下的本地模型清单（扫描目录，每个子目录 = 一个模型）
/// 2. 用户配置的「中文 ASR / 非中文 ASR」槽位（`model_state.json` 里的
///    `chinese_asr` / `non_chinese_asr` 字段）— 这是按"第一性原理"设计
///    的槽位：项目作者认为"中英文"是用户应该配置的两个独立槽位，不是
///    "切 default ASR"。所以 UI 上不再有"设为默认"按钮，只有"作为中文 ASR"
///    和"作为非中文 ASR"两个按钮。
///
/// 数据流（与 LangConfig / GlossaryState 同款）：
/// - 定时轮询（3 秒一次）扫描 models_dir + 读 model_state.json
/// - 用户在 UI 点按钮 → `setChineseASR` / `setNonChineseASR` 原子写 model_state.json
/// - 监视器下次轮询读到新值，UI 自动刷新
///
/// 并发模型：
/// - 类**不**标记 @MainActor（保持跟 GlossaryState 同款非隔离风格）
/// - 轮询线程读 / 写磁盘是同步阻塞调用（macOS 文件系统 API 都是 Sendable）
/// - 修改 @Published 属性前用 Task { @MainActor } 切到主线程，
///   保证 SwiftUI 在主线程读到更新（避免 "Publishing changes from background threads"）
///
/// 存储路径遵循 macOS 最佳实践（与 plan 一致）：
/// - `models_dir`: `~/Library/Application Support/whicc/models/`
/// - `model_state.json`: `/tmp/whicc-out/model_state.json`
///   （与 lang_config.json 同款：共享给 Python 端）
///
/// Python 端暂时**不**读 chinese_asr / non_chinese_asr 字段（按用户
/// 2026-06-24 决定先不动 Python 端）；这两个字段目前是 macui 内部状态。
final class ModelState: ObservableObject {

    struct ModelInfo: Identifiable, Equatable {
        let id: String
        let displayName: String
        // 跟 whicc.py:_detect_backend 同款:实际只输出 "qwen3" / "nemotron" 两个值。
        // 之前注释说 "whisper" 是历史遗留 — Python 端 2026-06 删了 whisper 路径,
        // Swift 端默认值 "whisper" 没人看但留着是个坑(任何不匹配 qwen/nemotron
        // 的模型都会被标成 "whisper",误导 UI)。改成跟 Python 对齐:不匹配时
        // 退回 "qwen3"(跟 whicc.py:_detect_backend line 65 同款兜底)。
        let backend: String   // "qwen3" | "nemotron"
        let kind: Kind        // 区分 ASR 主模型 vs 辅助模型
        let sizeBytes: Int64
        let path: URL
        /// 下载完整性来源:`true` 表示 Python 端已成功完成下载并写了
        /// `<model_dir>/{id_safe}.complete` 标记文件;`false` 表示目录
        /// 存在但没有完成标记(典型:下载中断后留下的半截目录)。
        ///
        /// 这个标记由 `model_downloader.py` 在发 `completed` 事件**之后**
        /// 立刻写入,所以它比 downloadState 内部的 `.status == .completed`
        /// 更权威——即使 macui 重启、Python download process 退出、
        /// downloadState entries 被 cleanup,只要 `.complete` 文件还在,
        /// 完整性判定就仍然准确。
        let isComplete: Bool

        /// 模型类型。决定 UI 分组和"设为默认"按钮是否显示。
        ///
        /// 第一性原理（review 时用户反馈）：
        /// - `asr` 是主 ASR 模型，可作为 current_model 候选
        /// - `aligner` 是辅助对齐器（曾经的 ForcedAligner），不是 ASR ，
        ///   不能作为 current_model
        /// - `other` 是其他无法识别的模型，仅展示
        enum Kind: String {
            case asr
            case aligner
            case other
        }

        /// 跟 `whicc.py:_detect_backend` 同款逻辑——保持 Swift 端和
        /// Python 端对 backend 的判断一致。Python 端 (whicc.py:60-65)
        /// 只输出 "nemotron" / "qwen3" 两个值,Swift 端兜底也用 "qwen3"。
        static func detectBackend(_ id: String) -> String {
            let lower = id.lowercased()
            if lower.contains("nemotron") { return "nemotron" }
            return "qwen3"
        }

        /// 模型类型判断：按模型名关键字识别
        /// - "forced-aligner" / "aligner" / "forced_aligner" → aligner
        /// - 其他 → asr（保守策略：宁可多列也不漏）
        static func detectKind(_ id: String) -> Kind {
            let lower = id.lowercased()
            if lower.contains("forced-aligner")
                || lower.contains("forced_aligner")
                || lower.contains("aligner") {
                return .aligner
            }
            return .asr
        }
    }

    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var currentModel: String = ""
    /// 「中文 ASR」槽位（用户配置：处理中文时用哪个模型）。
    /// 「非中文 ASR」槽位（用户配置：处理英文/外文时用哪个模型）。
    /// 翻译模型槽位已于 commit c5eb354 删除 — 翻译统一走 lang_config.json
    /// 的 translation_model 键（远端 LM Studio 模型名）。
    /// 旧字段 `current_model` 还在用，但 UI 不再把它当"切 default"用。
    /// Python 端暂不读这三个字段（按你 2026-06-24 决定先不动 Python 端），
    /// 但 macui UI 先把概念摆对——让用户看到的是"中文用 X / 非中文用 Y"，
    /// 不是"切 default"。
    @Published private(set) var chineseASR: String = ""
    @Published private(set) var nonChineseASR: String = ""
    @Published private(set) var modelsDir: URL

    private let stateFileURL: URL
    private var pollThread: Thread?
    private var isPolling: Bool = false

    init(modelsDir: URL, stateFile: URL) {
        self.modelsDir = modelsDir
        self.stateFileURL = stateFile
        // 启动时同步读一次，避免 UI 先用空状态渲染再被异步更新覆盖
        // （review #db17ff2 同样的修法）。
        // 在主线程同步执行扫描 + 读，不走 Task。
        let scanned = Self.scanModels(in: modelsDir)
        let loaded = Self.readState(from: stateFile)
        self.models = scanned
        self.currentModel = loaded.currentModel
        self.chineseASR = loaded.chineseASR
        self.nonChineseASR = loaded.nonChineseASR
    }

    deinit {
        // Thread 不能直接 .cancel()，靠 polling 循环里检查 isPolling 退出
        // 显式 stopPolling 需要 @MainActor，不能在 deinit 里调。
        // 让 thread 跑完最后一次 poll 后自然退出。
        isPolling = false
    }

    /// 启动后台轮询线程。每 3 秒扫描 models_dir + 读 model_state.json。
    /// 跟 GlossaryState.startPolling() 同款模式。
    func startPolling() {
        guard pollThread == nil else { return }
        isPolling = true
        let thread = Thread { [weak self] in
            let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.reload()
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "ModelState.poll"
        thread.qualityOfService = .utility
        pollThread = thread
        thread.start()
    }

    func stopPolling() {
        isPolling = false
        pollThread?.cancel()
        pollThread = nil
    }

    /// 重新加载：扫 models_dir + 读 model_state.json。
    /// 从轮询线程（非主线程）调用，磁盘 IO 是阻塞的同步操作，
    /// 但修改 @Published 属性必须切到主线程（避免 SwiftUI 警告）。
    private func reload() {
        let newModels = Self.scanModels(in: modelsDir)
        let loaded = Self.readState(from: stateFileURL)
        // 切回主线程触发 @Published 变更，SwiftUI 才能更新 UI
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.models = newModels
            self.currentModel = loaded.currentModel
            self.chineseASR = loaded.chineseASR
            self.nonChineseASR = loaded.nonChineseASR
        }
    }

    /// 用户手动触发刷新。ModelPane 右上角的 🔄 按钮调用。
    /// 后台轮询本来就每 3 秒扫一次,这个方法只是给用户一个「我刚刚
    /// 下载完了 / 我改了目录,帮我立刻看下」的入口。底层直接走
    /// reload(),不绕轮询线程——磁盘 IO 在主线程外做,SwiftUI 不会卡。
    func requestReload() {
        reload()
    }

    /// 用户在 UI 点「作为中文 ASR」时调。原子写 model_state.json。
    func setChineseASR(_ modelId: String) {
        writeField("chinese_asr", value: modelId)
    }

    /// 用户在 UI 点「作为非中文 ASR」时调。
    func setNonChineseASR(_ modelId: String) {
        writeField("non_chinese_asr", value: modelId)
    }

    /// 把单个字段写入 model_state.json，保留其他键（不破坏共享文件的
    /// read-modify-write 模式）。与 setCurrentModel 用同一套原子写逻辑。
    private func writeField(_ key: String, value: String) {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateFileURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }
        dict["models_dir"] = modelsDir.path
        dict[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else {
            return
        }
        try? data.write(to: stateFileURL, options: .atomic)
        reload()
    }

    /// 扫描 models_dir 下的子目录，每个子目录 = 一个本地模型。
    /// 目录名格式约定：HF ID 的 "/" 替换为 "--"
    /// （与 whicc.py:778 同款：`local_model = os.path.join(MODEL_DIR, args.model.replace("/", "--"))`）
    private static func scanModels(in dir: URL) -> [ModelInfo] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [ModelInfo] = []
        for url in contents {
            // 跳过非目录
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // 计算目录大小（递归）
            let size = Self.directorySize(at: url)
            let dirName = url.lastPathComponent
            let id = dirName.replacingOccurrences(of: "--", with: "/")
            let displayName = id.split(separator: "/").last.map(String.init) ?? id
            let backend = ModelInfo.detectBackend(id)
            let kind = ModelInfo.detectKind(id)
            // Python 端的 model_downloader.py:_model_local_path 把 "/" 换成
            // "--" 作为子目录名,完成的标记文件放在目录同级,文件名是
            // `<dirName>.complete`(见 model_downloader.py:286 / 379)。
            // 标记文件不存在 = 这个目录要么下载中断要么刚开始下载,
            // 完整性未知 → 留给上层不当作"绿勾"判定。
            let completeMarker = url.appendingPathExtension("complete")
            let isComplete = fm.fileExists(atPath: completeMarker.path)
            results.append(ModelInfo(
                id: id,
                displayName: displayName,
                backend: backend,
                kind: kind,
                sizeBytes: size,
                path: url,
                isComplete: isComplete
            ))
        }
        // 默认按 size 降序（用户一般关心大模型）
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 递归计算目录占用字节数。只算 regular file 的大小，跳过 symlink。
    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            guard values.isRegularFile == true else { continue }
            // 优先用占用大小（更接近用户磁盘上的实际占用）
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// 读 model_state.json 的所有相关字段。文件不存在/解析失败时所有字段返回空。
    /// 字段：
    /// - current_model: 旧字段（保留兼容；以后 stage 2 移除）
    /// - chinese_asr / non_chinese_asr: 新字段（macui UI 槽位）
    private static func readState(from url: URL) -> (
        currentModel: String,
        chineseASR: String,
        nonChineseASR: String
    ) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ("", "", "")
        }
        return (
            currentModel: json["current_model"] ?? "",
            chineseASR: json["chinese_asr"] ?? "",
            nonChineseASR: json["non_chinese_asr"] ?? ""
        )
    }
}

// MARK: - App Support 路径辅助
extension ModelState {
    /// macOS 最佳实践：用 FileManager 拿 app-owned Application Support 目录。
    /// 沙盒模式下 `~` 不可靠（指向 container），所以走 API 拿正确路径。
    static func defaultModelsDir() -> URL {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = appSupport ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("whicc", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// `model_state.json`——与 lang_config.json 同目录 (AppPaths.runDir)。
    static func defaultStateFile() -> URL {
        URL(fileURLWithPath: AppPaths.runDir + "/model_state.json")
    }
}