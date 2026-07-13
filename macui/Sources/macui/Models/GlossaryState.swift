import Foundation

struct GlossaryChange: Identifiable {
    let id = UUID()
    let ts: String
    let added: [String: String]
    let removed: [String]
}

struct GlossaryEntry: Identifiable, Equatable {
    let id: String
    var zh: String
    var en: String
    var source: String
    var hits: Int
    var added: String
    var category: String
}

/// File-backed glossary state. Same 4 files as the legacy overlay; same
/// field names so the Python side is unchanged.
@MainActor
final class GlossaryState: ObservableObject {

    @Published var isPaused: Bool = false
    @Published var entries: [GlossaryEntry] = []
    @Published var changes: [GlossaryChange] = []
    /// 最近一次写 glossary.json 失败原因；成功时为 nil。UI 用来提示「点了保存但没落盘」。
    @Published var lastWriteError: String?

    let glossaryPath: String
    let eventGlossaryPath: String
    let controlPath: String
    let changesPath: String

    private var pollThread: Thread?
    private var lastGlossaryMtime: TimeInterval = 0
    private var lastEventGlossaryMtime: TimeInterval = 0
    private var lastChangesSize: UInt64 = 0
    private var lastControlMtime: TimeInterval = 0

    init(glossaryDir: String) {
        self.glossaryPath = (glossaryDir as NSString).appendingPathComponent("glossary.json")
        self.eventGlossaryPath = "\(AppPaths.runDir)/event_glossary.json"
        self.controlPath = (glossaryDir as NSString).appendingPathComponent("_glossary_control.json")
        self.changesPath = (glossaryDir as NSString).appendingPathComponent("_glossary_changes.jsonl")
    }

    // MARK: - Lifecycle

    func startPolling() {
        loadGlossary()
        loadControl()
        loadChanges(all: true)

        let thread = Thread { [weak self] in
            let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
                // poll() 是 @MainActor — Timer 闭包跑在 background runloop,
                // 用 Task hop 回主线程。Swift 6 strict 下直接 capture self
                // 编译错,先拷一份 weakSelf。
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.poll()
                }
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "GlossaryState.poll"
        thread.qualityOfService = .utility
        self.pollThread = thread
        thread.start()
    }

    func stopPolling() {
        pollThread?.cancel()
        pollThread = nil
    }

    // MARK: - Toggle

    func togglePause() {
        isPaused.toggle()
        writeControl()
    }

    // MARK: - CRUD

    func addEntry(zh: String, en: String) {
        guard !zh.isEmpty, !en.isEmpty else { return }
        var g = readGlossaryFile()
        var zh2en = g["zh2en"] as? [String: String] ?? [:]
        var en2zh = g["en2zh"] as? [String: String] ?? [:]
        var meta = g["_meta"] as? [String: Any] ?? [:]

        if zh2en[zh] != nil { return }
        zh2en[zh] = en
        en2zh[en] = zh
        meta[zh] = [
            "source": "manual",
            "added": Self.nowStr(),
            "last_used": Self.nowStr(),
            "hits": 0,
        ]
        g["zh2en"] = zh2en
        g["en2zh"] = en2zh
        g["_meta"] = meta
        writeGlossaryFile(g)
        loadGlossary()
    }

    func deleteEntry(zh: String) {
        var g = readGlossaryFile()
        var zh2en = g["zh2en"] as? [String: String] ?? [:]
        var en2zh = g["en2zh"] as? [String: String] ?? [:]
        var meta = g["_meta"] as? [String: Any] ?? [:]

        if let en = zh2en.removeValue(forKey: zh) {
            en2zh.removeValue(forKey: en)
        }
        meta.removeValue(forKey: zh)
        g["zh2en"] = zh2en
        g["en2zh"] = en2zh
        g["_meta"] = meta
        writeGlossaryFile(g)
        loadGlossary()
    }

    func updateEntry(oldZh: String, newZh: String, newEn: String) {
        guard !newZh.isEmpty, !newEn.isEmpty else { return }
        deleteEntry(zh: oldZh)
        addEntry(zh: newZh, en: newEn)
    }

    func clearGlossary() {
        let empty: [String: Any] = [
            "en2zh": [:] as [String: String],
            "zh2en": [:] as [String: String],
            "_meta": [:] as [String: String],
        ]
        writeGlossaryFile(empty)
        loadGlossary()
    }

    // MARK: - Polling

    private func poll() {
        var glossaryChanged = false
        var controlChanged = false
        var changesChanged = false

        if let mtime = fileMtime(glossaryPath), mtime > lastGlossaryMtime {
            lastGlossaryMtime = mtime
            glossaryChanged = true
        }
        if let mtime = fileMtime(eventGlossaryPath), mtime > lastEventGlossaryMtime {
            lastEventGlossaryMtime = mtime
            glossaryChanged = true
        }
        if let mtime = fileMtime(controlPath), mtime > lastControlMtime {
            lastControlMtime = mtime
            controlChanged = true
        }
        if let size = fileSize(changesPath), size > lastChangesSize {
            lastChangesSize = size
            changesChanged = true
        }

        guard glossaryChanged || controlChanged || changesChanged else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if glossaryChanged { self.loadGlossary() }
            if controlChanged  { self.loadControl() }
            if changesChanged  { self.loadChanges(all: false) }
        }
    }

    private func loadGlossary() {
        let g = readGlossaryFile()
        let zh2en = g["zh2en"] as? [String: String] ?? [:]
        let meta = g["_meta"] as? [String: Any] ?? [:]

        let eventG = readEventGlossaryFile()
        let eventZh2en = eventG["zh2en"] as? [String: Any] ?? [:]
        let eventEn2zh = eventG["en2zh"] as? [String: Any] ?? [:]

        var seen = Set<String>()
        var list: [GlossaryEntry] = []

        for (zh, en) in zh2en {
            let m = meta[zh] as? [String: Any]
            list.append(GlossaryEntry(
                id: zh, zh: zh, en: en,
                source: m?["source"] as? String ?? "?",
                hits: m?["hits"] as? Int ?? 0,
                added: m?["added"] as? String ?? "",
                category: ""
            ))
            seen.insert(zh)
        }

        for (zh, value) in eventZh2en where !seen.contains(zh) {
            let (en, category, added) = parseEventEntry(value)
            list.append(GlossaryEntry(
                id: zh, zh: zh, en: en,
                source: "event", hits: 0,
                added: added, category: category
            ))
            seen.insert(zh)
        }

        for (en, value) in eventEn2zh where !seen.contains(en) {
            let (zh, category, added) = parseEventEntry(value)
            list.append(GlossaryEntry(
                id: "en:\(en)", zh: en, en: zh,
                source: "event", hits: 0,
                added: added, category: category
            ))
        }

        list.sort { $0.hits > $1.hits || ($0.hits == $1.hits && $0.zh < $1.zh) }
        entries = list
    }

    private func readEventGlossaryFile() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: eventGlossaryPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func parseEventEntry(_ value: Any) -> (String, String, String) {
        if let dict = value as? [String: Any] {
            return (
                dict["translation"] as? String ?? "",
                dict["category"] as? String ?? "",
                dict["added"] as? String ?? ""
            )
        }
        if let str = value as? String { return (str, "", "") }
        return ("", "", "")
    }

    private func loadControl() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: controlPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if isPaused { isPaused = false }
            return
        }
        let paused = obj["paused"] as? Bool ?? false
        if isPaused != paused { isPaused = paused }
    }

    private func writeControl() {
        let obj: [String: Any] = ["paused": isPaused]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        try? data.write(to: URL(fileURLWithPath: controlPath), options: .atomic)
    }

    private func loadChanges(all: Bool) {
        guard let data = try? String(contentsOfFile: changesPath, encoding: .utf8) else { return }
        let lines = data.split(separator: "\n")
        let readFrom = all ? 0 : max(0, changes.count)
        var new: [GlossaryChange] = []

        for line in lines.dropFirst(readFrom) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let ts = obj["ts"] as? String ?? ""
            let added = obj["added"] as? [String: String] ?? [:]
            let removed = obj["removed"] as? [String] ?? []
            new.append(GlossaryChange(ts: ts, added: added, removed: removed))
        }

        if all {
            changes = new
        } else {
            changes.append(contentsOf: new)
        }
        if changes.count > 50 {
            changes = Array(changes.suffix(50))
        }
    }

    // MARK: - File helpers

    private func readGlossaryFile() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: glossaryPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeGlossaryFile(_ dict: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            let url = URL(fileURLWithPath: glossaryPath)
            let parent = url.deletingLastPathComponent()
            // 调用创建父目录：打包模式落到 Application Support 时目录可能尚不存在
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = "无法写入词库：\(error.localizedDescription)\n路径：\(glossaryPath)"
        }
    }

    private func fileMtime(_ path: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    private func fileSize(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.size] as? UInt64
    }

    static func nowStr() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
