import SwiftUI
import AppKit

/// 模型管理 Pane。列出本地模型、显示元信息、允许分配到两个槽位。
///
/// 阶段 1+ 改进（按"第一性原理"重构）：
/// - **不**再有"设为默认"按钮（误导：让人以为是切 ASR 开关）
/// - 改为两个槽位：「中文 ASR」/「非中文 ASR」
/// - 用户点"作为中文 ASR" / "作为非中文 ASR" → 写 model_state.json
/// - 槽位是项目作者认为用户应该配置的两个独立维度（中英文场景是
///   不同的硬件/速度要求，用户分开选更合理）
///
/// 阶段 1 只做本地模型管理：
/// - 列出 ~/Library/Application Support/whicc/models/ 下的子目录
/// - 每个模型显示：名字、大小、backend 类型、已分配到哪个槽位
///
/// Python 端**不**读 chinese_asr / non_chinese_asr 字段（按用户
/// 2026-06-24 决定先不动 Python 端）；这两个槽位目前仅 macui 内部
/// 表示用户的"我希望中文用 X / 非中文用 Y"的意图。
///
/// 阶段 2/3 计划（不在这里实现）：
/// - Python 端按槽位选择模型
/// - 模型下载 UI（HF 模型 ID 输入框 + 进度条）
/// - 远程模型（OpenAI-compatible API）
struct ModelPane: View {
    @ObservedObject var modelState: ModelState
    @ObservedObject var downloadState: ModelDownloadState

    var body: some View {
        SettingsDetailContainer {
            SettingsSectionHeader(
                icon: "cpu",
                title: "本地模型管理",
                trailing: {
                    let asrCount = modelState.models.filter { $0.kind == .asr }.count
                    HStack(spacing: 8) {
                        Text("\(asrCount) 个语音识别 ASR 模型，共 \(Self.formatBytes(totalSize))，卸载后自动释放磁盘空间")
                            .font(.caption).foregroundColor(.secondary)
                        // 手动刷新按钮挪到这里：跟模型数量统计同框,
                        // 用户看 N 个模型时一眼能找到「刷新」入口。
                        // 后台轮询每 3 秒扫一次,这里是给用户「我刚下完/
                        // 刚改了目录,立刻帮我看下」的兜底入口。
                        Button(action: { modelState.requestReload() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("重扫模型目录")
                    }
                }
            )

            // 推荐搭配提示：项目作者根据经验给出"哪种场景用哪个模型"
            // 的指南,放在 header 下面、所有槽位卡片之上。用户进页面
            // 第一眼看到的是这个,再去下面选具体模型 ID。
            Text("推荐搭配：识别中文用 Qwen3-ASR,英文用 Nemotron 效果比较好")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            // 存储位置 + 在 Finder 中显示
            SettingsCard {
                Text("存储位置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack {
                    Text(modelState.modelsDir.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([modelState.modelsDir])
                    }
                    .controlSize(.small)
                }
            }

            // 槽位 1：中文识别
            // 按"第一性原理"：用户能配置的是「中文用 X / 非中文用 Y」两个独立
            // 槽位，不是"切 ASR 开关"。下拉只有 2 个选项：「推荐」（项目作者
            // 写死的 Qwen3-ASR ID）+「其他」（手动输入任意 HF ID）。
            SettingsCard {
                slotPicker(
                    title: "中文语音识别 ASR模型，次要模型，在识别为中文和方言时自动启用",
                    recommendedID: Self.recommendedChineseASR,
                    isRecommendedReady: isFullyDownloaded(Self.recommendedChineseASR),
                    currentValue: Binding(
                        get: { modelState.chineseASR },
                        set: { modelState.setChineseASR($0) }
                    ),
                    isCurrentReady: isFullyDownloaded(modelState.chineseASR),
                    onDownload: { downloadState.requestDownload(modelId: $0) }
                )
            }

            // 槽位 2：非中文识别
            SettingsCard {
                slotPicker(
                    title: "非中文语音识别 ASR模型，优先级最高，默认启用该模型",
                    recommendedID: Self.recommendedNonChineseASR,
                    isRecommendedReady: isFullyDownloaded(Self.recommendedNonChineseASR),
                    currentValue: Binding(
                        get: { modelState.nonChineseASR },
                        set: { modelState.setNonChineseASR($0) }
                    ),
                    isCurrentReady: isFullyDownloaded(modelState.nonChineseASR),
                    onDownload: { downloadState.requestDownload(modelId: $0) }
                )
            }

            // 下载进度条（统一展示，跟 model_state.json 槽位选择无关）
            // macOS HIG:
            // - 不要阻挡用户（不弹全屏 modal）
            // - 进度条 + 取消按钮 + 完成态保留 1-2 秒
            // - 失败态有清晰提示
            if !downloadState.downloads.isEmpty {
                SettingsCard {
                    downloadProgressList
                }
            }

            // 模型目录空态提示：用户首次启动、还没下载任何模型时显示。
            // 引导用户去 Finder 看模型目录路径。
            SettingsCard(padding: 0) {
                if modelState.models.isEmpty {
                    VStack(spacing: 8) {
                        Text("未找到本地模型")
                            .font(.callout).foregroundColor(.secondary)
                        Text(modelState.modelsDir.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    // 模型列表已被槽位下拉框替代（用户在槽位卡里选本地模型或
                    // 手动输入 HF ID），这里只展示辅助模型（如曾经的 ForcedAligner
                    // 之类不可分配的），让用户知道这些模型存在。
                    let auxModels = modelState.models.filter { $0.kind != .asr }
                    if !auxModels.isEmpty {
                        modelGroupSection(
                            title: "辅助模型",
                            subtitle: "对齐器等，不参与当前 ASR 槽位",
                            models: auxModels
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelState.ModelInfo) -> some View {
        let isChineseASR = model.id == modelState.chineseASR
        let isNonChineseASR = model.id == modelState.nonChineseASR
        let isCurrent = model.id == modelState.currentModel
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.id)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Text(model.backend)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                    Text(Self.formatBytes(model.sizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if isChineseASR || isNonChineseASR || isCurrent {
                        slotBadge(text: slotLabel(isChineseASR: isChineseASR, isNonChineseASR: isNonChineseASR, isCurrent: isCurrent))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                // 不再显示「作为 X」类按钮——槽位配置已迁移到上方两张卡
                // 里的下拉框 / 手动输入。这里只显示模型元信息相关操作。
                Text(" ")  // 占位让布局与之前一致（Finder 按钮仍对齐）
                    .font(.caption2)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.path])
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var currentModelDisplay: String {
        if modelState.currentModel.isEmpty {
            return "（未设置）"
        }
        return modelState.currentModel
    }

    /// 显示在模型行下方的槽位标签：哪个槽位占用了这个模型。
    /// 比如"中文 ASR · 当前"表示这个模型被分配到中文槽位并且在运行。
    private func slotLabel(
        isChineseASR: Bool,
        isNonChineseASR: Bool,
        isCurrent: Bool
    ) -> String {
        var parts: [String] = []
        if isChineseASR { parts.append("中文 ASR") }
        if isNonChineseASR { parts.append("非中文 ASR") }
        if isCurrent { parts.append("当前") }
        return parts.joined(separator: " · ")
    }

    /// 槽位占用标签（绿色文本，跟 backend badge 风格不同）
    @ViewBuilder
    private func slotBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.green)
    }

    /// 项目作者写死的「推荐 ASR」ID。
    /// 下拉的第一个选项就指向这两个值——保留向后兼容（项目作者觉得
    /// 当前 nemotron 1.5GB + qwen3 800MB 是最好的搭配）。
    /// 与 whicc.py:28 `DEFAULT_MODEL` + whicc.py:33 `QWEN3_MODEL` 对齐。
    private static let recommendedChineseASR = "mlx-community/Qwen3-ASR-0.6B-4bit"
    private static let recommendedNonChineseASR = "mlx-community/nemotron-3.5-asr-streaming-0.6b"

    /// 槽位选择器：下拉框只有 2 个选项 ——
    ///   - 「推荐」（项目作者写死的 ID，跟 whicc.py:QWEN3_MODEL / 默认 nemotron 对齐）
    ///   - 「其他」（手动输入任意 HF ID）
    /// 选「推荐」时不显示输入框（默认值就是它），选「其他」才显示输入框。
    /// 手动输入时输入框 placeholder 是 `mlx-community/`（MLX 官方组织前缀）。
    ///
    /// 注意：之前接受 `models: [ModelInfo]` 参数用来判断本地是否已下载、
    /// 给下拉加"已下载/未下载"后缀——已删除。模型是用户本地数据，仓库里
    /// 没有，下拉里加这种状态会让其他开发者误以为模型随代码打包。
    /// Python 端启动时自己判断本地有没有、必要时从 HuggingFace 下载。
    @ViewBuilder
    private func slotPicker(
        title: String,
        recommendedID: String,
        isRecommendedReady: Bool,
        currentValue: Binding<String>,
        isCurrentReady: Bool,
        onDownload: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                // 绿勾只在「当前值已下载到本地」时显示。
                // 之前只看 currentValue 非空就给绿勾,会误导用户——
                // 比如选了推荐 ID 但本地没下,或者手填了任意 HF ID,
                // 槽位看起来「配置完成」但 ASR 启动时找不到模型。
                // 校验通过 modelState.models.contains { $0.id == ... }。
                if !currentValue.wrappedValue.isEmpty && isCurrentReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                }
            }
            // 下拉框：两个选项
            //   - 推荐（项目作者写死的 ID，标签如 "Qwen3-ASR-0.6B-4bit (推荐)"）
            //   - 其他（手动输入）
            Picker(
                "",
                selection: Binding(
                    get: {
                        // 当前值 == 推荐 → 选"推荐"项
                        // 其他情况 → 选"其他"项
                        if currentValue.wrappedValue == recommendedID {
                            return recommendedID
                        }
                        return Self.otherOptionTag
                    },
                    set: { newValue in
                        if newValue == recommendedID {
                            currentValue.wrappedValue = recommendedID
                        } else if newValue == Self.otherOptionTag {
                            // 切到"其他"时：如果当前不是其他值，重置为空，
                            // 让用户输入；保持原值不变（让用户继续编辑）
                            if currentValue.wrappedValue == recommendedID {
                                currentValue.wrappedValue = ""
                            }
                        }
                    }
                )
            ) {
                Text(Self.optionLabel(for: recommendedID, isRecommended: true))
                    .tag(recommendedID)
                Text("其他…").tag(Self.otherOptionTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)

            // 选"其他"时才显示手动输入框
            if currentValue.wrappedValue != recommendedID {
                TextField("mlx-community/", text: currentValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            // 状态提示
            // 1. 空值 → "（未设置）"
            // 2. 推荐 ID 且本地有 → "切换后需重启app生效"
            // 3. 推荐 ID 且本地没有 → "本地未下载" + [下载] 按钮（手动触发，符合 macOS HIG）
            // 4. 其他（手输的 ID）→ "切换后需重启app生效"（不管本地有没有，逻辑同上）
            if currentValue.wrappedValue.isEmpty {
                Text("（未设置）")
                    .font(.caption).foregroundColor(.secondary)
            } else if currentValue.wrappedValue == recommendedID && !isRecommendedReady {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.orange)
                    Text("本地未下载")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("下载") {
                        onDownload(recommendedID)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("切换后需重启app生效")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// Picker 用「其他」选项的 tag（必须是稳定字符串）
    private static let otherOptionTag = "__other__"

    /// Picker 标签：如 "Qwen3-ASR-0.6B-4bit （推荐）"
    /// 不显示"已下载/未下载"——模型文件存在用户本地，仓库里没有，
    /// 显示这个会让其他开发者误以为模型随代码打包。
    /// Python 端启动时会自己判断本地有没有、必要时自动从 HuggingFace 下载。
    private static func optionLabel(
        for modelID: String,
        isRecommended: Bool
    ) -> String {
        let displayName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let prefix = isRecommended ? "（推荐）" : ""
        return "\(displayName) \(prefix)".trimmingCharacters(in: .whitespaces)
    }

    private var totalSize: Int64 {
        // 只统计 ASR 主模型的占用（辅助模型不参与 current_model，
        // 占用单独算更准确）
        modelState.models
            .filter { $0.kind == .asr }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// 下载进度列表：把 downloadState 里的下载项渲染成 macOS HIG 风格的
    /// 进度条 + 取消按钮 + 状态文本。
    /// 用 downloadsSorted（按 modelId 排序的稳定数组）+ Identifiable，
    /// 避免 reload 时「行变来变去」的视觉跳动。
    @ViewBuilder
    private var downloadProgressList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(downloadState.downloadsSorted) { dl in
                downloadRow(dl)
            }
        }
    }

    /// 单个下载项的视觉表示
    @ViewBuilder
    private func downloadRow(_ dl: ModelDownloadState.DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon(for: dl)
                Text(dl.modelId)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(progressText(for: dl))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: dl.pct, total: 1.0)
                .progressViewStyle(.linear)
                .tint(progressTint(for: dl))

            // 错误信息（如果失败）
            if let err = dl.error {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            // 取消按钮（只在 downloading 时显示，符合 HIG：进度可取消）
            if dl.status == .downloading {
                HStack {
                    Spacer()
                    Button("取消下载") {
                        downloadState.requestCancel(modelId: dl.modelId)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    /// 状态图标（download / checkmark / xmark）
    @ViewBuilder
    private func statusIcon(for dl: ModelDownloadState.DownloadState) -> some View {
        switch dl.status {
        case .downloading:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.secondary)
        }
    }

    /// 进度文本：下载中显示百分比 + 字节数，已完成显示 ✓ 大小
    private func progressText(for dl: ModelDownloadState.DownloadState) -> String {
        switch dl.status {
        case .downloading:
            if dl.totalBytes > 0 {
                let pct = Int(dl.pct * 100)
                let downloaded = Self.formatBytes(dl.downloadedBytes)
                let total = Self.formatBytes(dl.totalBytes)
                return "\(pct)%  \(downloaded) / \(total)"
            }
            return "准备中…"
        case .completed:
            return "✓ \(Self.formatBytes(dl.totalBytes))"
        case .failed:
            return "下载失败"
        case .cancelled:
            return "已取消"
        }
    }

    /// 进度条颜色（成功绿 / 失败红 / 默认）
    private func progressTint(for dl: ModelDownloadState.DownloadState) -> Color {
        switch dl.status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .downloading: return .accentColor
        }
    }

    /// 判定一个 modelId 是否「完整可用的下载完成态」。
    ///
    /// 之前两版都有缺陷:
    /// 1. 只看 `modelState.models.contains { $0.id == id }` ——
    ///    `scanModels` 是 `contentsOfDirectory` 扫目录,只要目录存在就算。
    ///    HuggingFace / mlx-audio 下载是先建目标目录再写文件,所以下载
    ///    启动后很快 poller 就看到这个目录,绿勾提前出。
    /// 2. 加上 `!downloadState.downloads[modelId].isActive` —— 覆盖
    ///    了"下载中"场景,但**冷启动**后(进程刚启动 downloadState 为空)
    ///    以及**下载失败 / 取消**残留半截目录的场景仍然误显绿勾。
    ///
    /// 现在依赖 `ModelInfo.isComplete`(由 scanModels 通过检查
    /// `<model_dir>/{id_safe}.complete` 标记文件得出)。Python 端的
    /// `model_downloader.py` 是在发 `completed` 事件**之后**立刻写
    /// 这个标记,所以:
    ///   - 下载中 → 标记不存在 → 绿勾 false
    ///   - 下载完成 → 标记存在 → 绿勾 true(冷启动仍然准)
    ///   - 下载失败 / 中断 → 标记不存在 → 绿勾 false(残留半截目录不再误显)
    ///   - 历史上下载好但 .complete 丢失(手动删了等)→ 绿勾 false
    ///     (保守策略,白嫖重下,而不是冒险启动失败)
    ///
    /// 唯一已知边缘:用户手动从 disk 删了 `.complete` 但保留了目录
    /// (例如调试场景),绿勾会消失但 ASR 仍能跑——这是用户主动行为,
    /// 跟"误显"性质不同,不算 bug。
    private func isFullyDownloaded(_ modelId: String) -> Bool {
        guard !modelId.isEmpty else { return false }
        return modelState.models.first { $0.id == modelId }?.isComplete ?? false
    }

    // MARK: - Helpers

    /// 按 kind 渲染一个分组（标题 + 子标题 + 该组的模型列表）
    @ViewBuilder
    private func modelGroupSection(
        title: String,
        subtitle: String,
        models: [ModelState.ModelInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { idx, model in
                    modelRow(model)
                    if idx < models.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    /// 把字节数格式化成 "1.2 GB" / "800 MB" 这种人类可读形式。
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIdx = 0
        while value >= 1024 && unitIdx < units.count - 1 {
            value /= 1024
            unitIdx += 1
        }
        if unitIdx == 0 {
            return "\(Int(value)) \(units[unitIdx])"
        }
        return String(format: "%.1f %@", value, units[unitIdx])
    }
}