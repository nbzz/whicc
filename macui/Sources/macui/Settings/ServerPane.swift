import SwiftUI

/// Translation host configuration. Renders translation URL + model name
/// + 自动翻译开关. Matches the 频道/配置 style — no inset
/// group chrome, just floating rounded cards on a white panel.
///
/// Hermes host is configured in HermesPane (跟事件流 / 词库同页)。
///
/// Adding a new configurable host is a 3-line job: drop a new
/// `SettingsCard { hostRow(..., debounce: true, ...) }`. The
/// hostRow handles draft state + 0.5s debounce internally so the
/// caller never has to manage `@State` or Task cancellation.
struct ServerPane: View {
    @ObservedObject var langConfig: LangConfig

    /// 进入页面时是否已经自动测过连通性。`@State` 保存在 view 生命周期内,
    /// 同一 view 实例下只触发一次 .onAppear 探测。如果用户离开设置再回来,
    /// view 重建 @State 重置 → 再测一次,这是符合直觉的(review #15
    /// 的反对意见是"每次切都发请求",而 view 重建不会很频繁)。
    @State private var didInitialDetect = false
    /// 「保存并重启」按钮状态: nil=空闲, true=重启中, false=失败
    @State private var restartInFlight = false
    /// 最近一次重启结果,nil=还没操作过
    @State private var restartResult: RestartResult?
    enum RestartResult {
        case success
        case failure(String)
    }

    var body: some View {
        SettingsDetailContainer {
            // 顶部 header + 说明文字打包成 VStack:开关在 header 右侧,
            // 说明紧贴在 header 下方,视觉上是一组"开关 + 解释"而不是
            // 散落在两处。说明要短——把"为什么开"写在最显眼的地方,
            // 算力释放是用户决定开的核心动机,跟技术细节(改完需重启)
            // 分开,后者已经有独立的 caption 在卡片底部。
            VStack(alignment: .leading, spacing: 4) {
                SettingsSectionHeader<EmptyView>(
                    icon: "network",
                    title: "服务配置"
                )
                // 翻译模式:跟字号行用同一套视觉 ——
                //   左 label "翻译模式" (固定宽度,跟"译文/源文"对齐)
                //   中 SwiftUI 原生 Slider (无 step,连续拖动)
                //   右 当前值 "本地" / "外置"
                //
                // 视觉一致性:用户进"设置 → 外观/服务",看到的滑动控件
                // 都是同一套 Slider + label + 值显示,而不是"字号是 Slider
                // / 翻译模式是分段控件"混搭。
                //
                // 行为:Slider 是连续的,但实际只有 2 个有效位置 (0=本地,
                // 1=外置)。拖动滑块到中点不会停 — 视觉上看起来是连续
                // 滑动,实际逻辑是 toggle。滑块停在哪一段取决于用户拖动
                // 距离:超过 track 中点 → 切到右段,反之左段。释放时吸附。
                TranslationModeRow(
                    isOn: langConfig.translationEnabled,
                    onChange: { langConfig.setTranslationEnabled($0) }
                )
                // 解释开关的实用价值:开=算力由远端节点承担,本机
                // 只做识别+渲染,CPU/GPU/内存压力大幅降低。明确 fallback 行为:
                // 远端不可达时自动回退本机 LM Studio,用户无需手动干预。
                Text("「外置算力优先」: 远端不可达时自动回退到下方配置的「本机翻译回退地址」,无需手动干预")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard {
                Text("翻译节点")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                // 本机翻译回退地址放在最前面 — 大多数用户场景下
                // 本机 LM Studio 才是实际承担翻译的角色(永远不会挂
                // 的兜底),应该最先看到。远端是"高级用户"的扩展。
                // icon 用 arrow.uturn.down 跟主 URL 的 book 图标区分。
                hostRow(
                    placeholder: "如 127.0.0.1:1234",
                    icon: "arrow.uturn.down",
                    text: Binding(
                        get: { langConfig.translationFallbackUrl },
                        set: { langConfig.setTranslationFallbackUrl($0) }
                    ),
                    reachable: langConfig.translationFallbackReachable,
                    refresh: { langConfig.detectTranslationFallback() },
                    help: "检测翻译回退节点",
                    debounce: true,
                    label: "本机翻译服务地址，如Lm studio:http://127.0.0.1:1234",
                )
                // 本机回退模型名称：fallback URL 上跑的模型。
                // 远端可部署更强模型(如 qwen2.5-32b),本机通常只跑得起
                // 1.8B,所以 fallback URL 用不同模型。留空 = 跟主 URL 同。
                // icon 用 shippingbox.fill 跟主模型的 shippingbox 区分。
                // 改成下拉框 — 用户输错模型名肯定用不了,只有 /v1/models
                // 拉下来的那几个能选,直接 Picker 形态更不容易错。
                // 触发:用户改完 fallback URL 失焦 → 自动 fetchRemoteModelsFallback。
                modelRow(
                    icon: "shippingbox.fill",
                    current: langConfig.translationFallbackModel,
                    fetched: langConfig.remoteModelsFallbackFetched,
                    models: langConfig.remoteModelsFallback,
                    onFetch: { langConfig.fetchRemoteModelsFallback() },
                    onPick: { langConfig.setTranslationFallbackModel($0) },
                    label: "本机模型名称",
                    urlIsEmpty: langConfig.translationFallbackUrl.isEmpty
                )
                hostRow(
                    placeholder: "如 192.168.1.5:1234",
                    icon: "text.book.closed",
                    text: Binding(
                        get: { langConfig.translationUrl },
                        set: { langConfig.setTranslationUrl($0) }
                    ),
                    reachable: langConfig.translationReachable,
                    refresh: { langConfig.detectTranslation() },
                    help: "检测翻译节点",
                    debounce: true,
                    label: "外置算力翻译模型服务地址",
                    onCommit: { langConfig.fetchRemoteModels() }
                )
                // 远端模型名称：发到 vLLM / LM Studio 的 /v1/chat/completions
                // 请求体的 "model" 字段。留空 = 让 Python 端用 --model-id
                // 默认值(tencent/Hy-MT2-1.8B)。改完需重启 translate_stream。
                // icon 用 shippingbox 跟 URL 的 book 图标做视觉区分。
                // 改成下拉框 — 理由同上 (用户输错模型名肯定用不了)。
                modelRow(
                    icon: "shippingbox",
                    current: langConfig.translationModel,
                    fetched: langConfig.remoteModelsFetched,
                    models: langConfig.remoteModels,
                    onFetch: { langConfig.fetchRemoteModels() },
                    onPick: { langConfig.setTranslationModel($0) },
                    label: "模型名称",
                    urlIsEmpty: langConfig.translationUrl.isEmpty
                )
                // fallback 链状态可视化：让用户一眼看到翻译服务当前实际
                // 在用哪个 URL。逻辑跟 Python 端 VLLMBackend._pick_healthy()
                // 对齐 — 首个可达 URL 胜出。
                //   - 主 URL 可达 → "当前生效：远端 X"
                //   - 主 URL 不可达 + fallback 可达 → "当前生效：本机回退 Y"
                //   - 主可达 + fallback 也探过 → 两个 dot 都显示,标注"未触发"
                //   - 都不可达 → 红色 "翻译服务全部不可用"
                //   - 都未探 → nil 态（默认显示）
                translationStatusRow
                Text("配置成功后，外置算力不可用时自动使用本地算力")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 「保存并重启」按钮 - 让用户改完 URL/model/开关后
                // 直接点按钮触发重启,不用手动命令行 pkill + 启动。
                // 行为:
                //   点击 → spinner + "重启中..."
                //   成功 → 绿色 "✓ 已重启" (2s 后回到"保存并重启")
                //   失败 → 红色 "重启失败: <原因>" (永久,等下次操作)
                HStack(spacing: 8) {
                    Button(action: { onSaveAndRestart() }) {
                        if restartInFlight {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("重启中…")
                            }
                        } else if case .success = restartResult {
                            Label("已重启", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if case .failure(let err) = restartResult {
                            // 拆成本地化前缀 + verbatim 错误文本,让"重启失败:"走本地化表
                            // 但 err (Python stderr 字符串) 保留原文。Label 的 builder init
                            // 允许拼多个 Text。
                            Label {
                                Text("重启失败: ") + Text("\(err)")
                            } icon: {
                                Image(systemName: "xmark.octagon.fill")
                            }
                            .foregroundColor(.red)
                        } else {
                            Label("保存并重启翻译服务", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(restartInFlight)
                }
            }

            // 语言(源 + 目标) — 从 AppearancePane 搬过来。源语言控制
            // ASR 识别目标,目标语言控制翻译输出,两者都跟翻译服务强相关,
            // 放在这一页让用户改完翻译服务 URL/模型后,顺手配语言。
            SettingsCard {
                SettingsSectionHeader(
                    icon: "globe",
                    title: "语言",
                    tint: .accentColor,
                    trailing: {
                        Button {
                            langConfig.setSourceLang("auto")
                            langConfig.setLang("auto")
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("恢复默认(源/目标都是自动检测)")
                    }
                )
                VStack(alignment: .leading, spacing: 10) {
                    // 源语言:原文识别目标。"auto" = Python 后端自己检测。
                    languagePickerRow(
                        label: "源语言",
                        binding: sourceLangBinding,
                        help: "原文语言(auto = ASR 自动检测;固定后跳过检测)"
                    )
                    // 目标语言:译文。"auto" = 根据源自动选。
                    languagePickerRow(
                        label: "目标语言",
                        binding: targetLangBinding,
                        help: "译文语言(auto = 按源选对:中文→英文,其他→中文)"
                    )
                }
                Text("切换后需重启后端(whicc.py / translate_stream)生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        // 进入外接翻译模型页面时,主动测连通性 + 拉模型列表 ——
        // 用户反馈"不点击刷新按钮就不显示当前生效那行"是反逻辑:
        // 想要常驻显示当前实际走的路线,所以 onAppear 时**主动**探测一次,
        // translationStatusRow 立即有数据可显示。
        //
        // didInitialDetect 守卫避免每次切走再回来都重打,view 重建
        // (@State 重置) 时才会再测。
        //
        // 主 URL + fallback URL 都要处理:
        //   - URL 非空 → detectTranslation 测连通性 + fetchRemoteModels 拉列表
        //   - URL 空 → 都不做 (下拉框显式显示"请先填写地址",status 行也隐藏)
        // refresh 按钮触发重测,保留给"我刚改完配置想再确认"场景。
        .onAppear {
            guard !didInitialDetect else { return }
            didInitialDetect = true
            if !langConfig.translationUrl.isEmpty {
                langConfig.detectTranslation()
                langConfig.fetchRemoteModels()
            }
            if !langConfig.translationFallbackUrl.isEmpty {
                langConfig.detectTranslationFallback()
                langConfig.fetchRemoteModelsFallback()
            }
        }
        // 注意:跟之前的版本比,这里不再"故意不带 .onAppear"。review #15
        // 的意见是不要在每次 onAppear 都打请求,所以加了 didInitialDetect
        // 守卫——只在 view 实例首次出现时打一次。view 重建(@State 重置)
        // 时才会再测,这正是用户预期的"刷新页面=重新探测"。
    }

    /// 显示 fallback 链当前实际生效的 URL，让用户一眼看到翻译服务的
    /// 健康状态。逻辑跟 Python VLLMBackend._pick_healthy() 对齐：
    /// 首个 reachable URL 胜出。
    ///
    /// **常驻显示** —— URL 已填后总是显示一行:
    ///   - **翻译未启用** (translationEnabled == false) → "当前生效:本地"
    ///     (不管 URL 可达性如何 — 既然关了翻译,可达性就无关)
    ///   - 翻译已启用 + 已探测 (main / fb 至少一个非 nil) → 显示具体状态
    ///     (绿勾/橙警示/红警示,跟 URL)
    ///   - 翻译已启用 + 未探测 (nil/nil,URL 已填但 onAppear detect 还没回来)
    ///     → "探测中"灰
    ///   - URL 全空 → 不显示 (避免满屏灰色 dot)
    /// 用户反馈:不点刷新按钮也常驻显示当前实际走的路线,所以 onAppear
    /// 会**主动**触发 detect — 不需要点 refresh。
    ///
    /// 之前 bug:translationEnabled == false 时仍显示 "外置算力 + 回退未触发"
    /// — 误导用户,因为翻译根本没在跑(translate_stream 启动时检查
    /// translation_enabled == false 会直接退出,无翻译事件流)。
    @ViewBuilder
    private var translationStatusRow: some View {
        // 翻译关闭 (slider 切到"本地算力") → 永远显示"当前生效:本地",
        // 不管 translation_url 可达性 — 既然翻译都没启用,
        // "外置"和"回退未触发"都是误导。SwiftUI 自动按 langConfig 变化
        // 重渲染,用户切 slider 立即看到状态切换。
        if !langConfig.translationEnabled {
            HStack(spacing: 6) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 11))
                Text("当前生效：本地算力")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("（翻译未启用，不走远端节点）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            let main = langConfig.translationReachable
            let fb = langConfig.translationFallbackReachable
            if main == true {
                // 远端可达 — 翻译走远端
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("当前生效：外置算力")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(langConfig.translationUrl)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                    // fallback 也探过且可达：提示"回退未触发"
                    if fb == true {
                        Text("· 回退未触发")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if main == false && fb == true {
                // 远端挂了 fallback 在 — 翻译走本机回退（红色警示"已触发"）
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.down.circle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("当前生效：本机回退 ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(langConfig.translationFallbackUrl)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("（外置算力不可达，已自动切换为本机地址）")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else if main == false && fb == false {
                // 都不可达 — 红色警示
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text("翻译服务全部不可用")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else if langConfig.translationUrl.isEmpty, fb == true {
                // 边界：用户只填了 fallback 没填主 URL，fallback 可达
                // → 翻译走本机
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.down.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("当前生效：本机回退 ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(langConfig.translationFallbackUrl)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                }
            } else if langConfig.translationUrl.isEmpty, fb == false {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text("翻译回退不可用")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                // main == nil && fb == nil → 还没探测完成,显示"探测中"
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted")
                        .foregroundColor(.gray)
                        .font(.system(size: 11))
                    Text("正在探测连通性...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// 「保存并重启」按钮触发函数。macui 调 BackendShutdown.restartTranslateStream
    /// 杀旧进程 + 拉新进程。UI 状态机:
    ///   - restartInFlight = true (期间按钮 disabled)
    ///   - restartResult = .success / .failure
    /// 成功提示 2 秒后自动清掉 (避免一直占着 UI 视觉空间)。
    private func onSaveAndRestart() {
        restartInFlight = true
        restartResult = nil
        // restartTranslateStream 内部有 pkill + Thread.sleep。放到 detached
        // task 里跑，避免按钮 spinner 刚出现就把 SwiftUI 主线程卡住。
        Task.detached(priority: .userInitiated) {
            let success = BackendShutdown.restartTranslateStream()
            await MainActor.run {
                restartInFlight = false
                restartResult = success
                    ? .success
                    : .failure("启动失败,看 /tmp/translate-stream.log")
                // 2s 后清掉成功提示 (失败保留,等下次操作覆盖)
                if success {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if case .success = restartResult {
                            restartResult = nil
                        }
                    }
                }
            }
        }
    }

    /// A host row with optional debounced commit. When `debounce` is
    /// true, TextField edits a local draft that auto-commits after
    /// 0.5s of inactivity; the LangConfig setter (which writes the
    /// file) only fires once per pause instead of once per keystroke.
    /// `placeholder` / `help` / `label` 走 LocalizedStringKey,中文字面量即自动本地化。
    @ViewBuilder
    private func hostRow(
        placeholder: LocalizedStringKey,
        icon: String,
        text: Binding<String>,
        reachable: Bool?,
        refresh: @escaping () -> Void,
        help: LocalizedStringKey,
        debounce: Bool,
        label: LocalizedStringKey? = nil,
        trailing: AnyView? = nil,
        onCommit: (() -> Void)? = nil
    ) -> some View {
        // 不传 label 时是原来的纯 row（向后兼容 Hermes 行）。
        if label == nil {
            if debounce {
                DebouncedHostRow(
                    placeholder: placeholder,
                    icon: icon,
                    modelText: text.wrappedValue,
                    modelSetter: text,
                    reachable: reachable,
                    refresh: refresh,
                    help: help,
                    trailing: trailing,
                    onCommit: onCommit
                )
            } else {
                PlainHostRow(
                    placeholder: placeholder,
                    icon: icon,
                    text: text,
                    reachable: reachable,
                    refresh: refresh,
                    help: help,
                    trailing: trailing,
                    onCommit: onCommit
                )
            }
        } else {
            // 传 label 时把 label 渲染在 row 上方。
            // 之前用 Group { if let label { Text... } Row } + VStack { rowContent }
            // 的写法在某些情况下 Group 把 Text 吃了——改成直接的 VStack
            // 嵌套能避免这个 SwiftUI view builder 的怪行为。
            VStack(alignment: .leading, spacing: 4) {
                Text(label ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if debounce {
                    DebouncedHostRow(
                        placeholder: placeholder,
                        icon: icon,
                        modelText: text.wrappedValue,
                        modelSetter: text,
                        reachable: reachable,
                        refresh: refresh,
                        help: help,
                        trailing: trailing,
                        onCommit: onCommit
                    )
                } else {
                    PlainHostRow(
                        placeholder: placeholder,
                        icon: icon,
                        text: text,
                        reachable: reachable,
                        refresh: refresh,
                        help: help,
                        trailing: trailing,
                        onCommit: onCommit
                    )
                }
            }
        }
    }

    // MARK: - 语言 picker (从 AppearancePane 搬过来)

    /// 通用语言 picker 行:左侧标签 + 右侧 menu picker。menu picker
    /// 按 LANGUAGE_GROUPS 自动分组。
    /// `label` / `help` 走 LocalizedStringKey,中文字面量即自动本地化。
    @ViewBuilder
    private func languagePickerRow(
        label: LocalizedStringKey,
        binding: Binding<String>,
        help: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .help(help)
            Picker(label, selection: binding) {
                Text("自动检测").tag("auto")
                ForEach(LANGUAGE_GROUPS) { group in
                    Section(group.name) {
                        ForEach(group.langs) { lang in
                            Text(lang.label).tag(lang.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// 源语言 binding——写 lang_config.json 的 source_lang 键。
    private var sourceLangBinding: Binding<String> {
        Binding(
            get: { langConfig.sourceLang },
            set: { langConfig.setSourceLang($0) }
        )
    }

    /// 目标语言 binding——跟 HermesPane / GlossaryPane 同路径。
    private var targetLangBinding: Binding<String> {
        Binding(
            get: { langConfig.targetLang },
            set: { langConfig.setLang($0) }
        )
    }

}

// MARK: - Plain row (every keystroke commits)

private struct PlainHostRow: View {
    let placeholder: LocalizedStringKey
    let icon: String
    @Binding var text: String
    let reachable: Bool?
    let refresh: () -> Void
    let help: LocalizedStringKey
    let trailing: AnyView?
    /// 用户回车提交时触发,用于「改完 URL 自动 fetch 模型列表」场景。
    /// PlainHostRow 每次按键立即写回,没有 debounce,所以 onSubmit 是
    /// 用户「停手」的合理代理。
    let onCommit: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .onSubmit { onCommit?() }
            // dot 已删:用户反馈 reachability dot 信息密度低 (绿/红/灰三态
            // 看不出当前翻译实际在用哪个 URL)。状态显示改由下方的
            // translationStatusRow 承担("当前生效: 远端 X / 本机回退 Y")。
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(help)
            // 远端模型行专用：把"获取列表"菜单挂在最右边。refresh 按钮
            // 对 model 行无意义（model 没有 reachability 概念），
            // 所以传 trailing 时不再显示 refresh 按钮。
            if let trailing { trailing }
        }
    }
}

// MARK: - Debounced row (commits 0.5s after last edit)
//
// Internal draft + Task lifecycle fully encapsulated. The caller
// passes the model-side Binding (`modelSetter`) and the current value
// (`modelText`) — we mirror it into a local @State on appear, edit
// that local state on each keystroke, and push back to the model
// via `modelSetter.wrappedValue = draft` after 0.5s of idle.
//
// Switching the model value from outside (e.g. file watcher reload)
// overwrites the draft so the field stays in sync with the source
// of truth.

private struct DebouncedHostRow: View {
    let placeholder: LocalizedStringKey
    let icon: String
    let modelText: String
    let modelSetter: Binding<String>
    let reachable: Bool?
    let refresh: () -> Void
    let help: LocalizedStringKey
    let trailing: AnyView?
    /// debounce 0.5s 写回 setter 之后触发,用于「改完 URL 自动 fetch 模型列表」。
    /// 注意:DebouncedHostRow 每个按键都不触发 commit (waiting 0.5s),
    /// 所以 onCommit 在用户停止输入后才触发,避免每键一次 fetch。
    let onCommit: (() -> Void)?

    @State private var draft: String = ""
    @State private var initialized: Bool = false
    @State private var pendingCommit: Task<Void, Never>?

    private static let debounceDuration: Duration = .milliseconds(500)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .onChange(of: draft) { _, newValue in
                    scheduleCommit(newValue)
                }
            // dot 已删:见 PlainHostRow 注释
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(help)
            if let trailing { trailing }
        }
        .task {
            // 首次出现时同步一次草稿。后续出现不再覆盖（在编辑中的草稿）。
            if !initialized {
                draft = modelText
                initialized = true
            }
        }
        .onChange(of: modelText) { _, newModelText in
            // 文件监视器触发 reload 时，modelText 会变。如果草稿跟之前
            // 的 model 一致（说明这次 reload 来自我们自己），跳过；否则
            // 用新 model 值覆盖草稿（用户在编辑中不要被打断，所以只在
            // 草稿未修改时同步——简化处理：如果不同就同步）。
            if newModelText != draft {
                draft = newModelText
            }
        }
        .onDisappear {
            // 切走时取消待执行的 commit task，立即 flush 当前草稿，
            // 避免用户输入到一半切走丢失。
            pendingCommit?.cancel()
            pendingCommit = nil
            if draft != modelText {
                modelSetter.wrappedValue = draft
                onCommit?()
            }
        }
    }

    private func scheduleCommit(_ value: String) {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: Self.debounceDuration)
            if Task.isCancelled { return }
            modelSetter.wrappedValue = value
            // 写回 setter 后(用户停手,新值已落 lang_config.json),
            // 触发 onCommit — 例:fetchRemoteModels() 拉新 URL 的模型列表。
            onCommit?()
        }
    }
}

// MARK: - Translation model dropdown (取代文本框 + 右边小菜单)
//
// 占满一行的下拉框 — 用户改完 URL 失焦后,自动 fetch 下来的模型列表
// 作为选项。点击展开 + 选中,跟 macOS 系统 Picker 视觉一致。
//
// 状态映射:
//   - fetched == nil           → 占位 "选择模型" (拉取中)
//   - fetched == false         → 占位 "拉取失败 — 点击重试" (点触发 fetch)
//   - fetched == true + 空     → 占位 "未找到模型" (但仍 trigger fetch 重试)
//   - fetched == true + 当前选中 → 显示当前模型名 + chevron
//   - fetched == true + 没选    → 占位 "选择模型"
//
// 设计取舍:跟 hostRow 一样要有 label (顶部字段名),但**没有文本框** —
// 只渲染一个跨满宽度的下拉按钮,视觉上比"文本框 + 旁边小菜单"更直白。
private struct TranslationModelMenu: View {
    let fetched: Bool?
    let models: [String]
    let current: String
    let onFetch: () -> Void
    let onPick: (String) -> Void
    /// URL 为空时直接显示「请先填写翻译服务地址」,不显示 spinner/不调 fetch。
    /// 避免「没填 URL 失焦 → fetched 跳 nil → 假 spinner 转」的误导。
    let urlIsEmpty: Bool

    var body: some View {
        Menu {
            if urlIsEmpty {
                // URL 为空 → 整个 dropdown 是 disabled 状态,无操作。
                // 让用户点也没反应(强制他们先填 URL),点不到才算干净。
                Text("请先填写翻译服务地址")
            } else if fetched != true {
                // 没拉过 / 拉失败 → 整个 dropdown 都是「重试」入口。
                // 用 let titleKey: LocalizedStringKey 让 Label 走本地化表;
                // 直接 Label(<ternary ? "a" : "b">, ...) 会推断成 String verbatim。
                let titleKey: LocalizedStringKey = fetched == false
                    ? "拉取失败 — 重试"
                    : "正在获取模型…"
                let iconName = fetched == false ? "arrow.clockwise" : "arrow.triangle.2.circlepath"
                Button {
                    onFetch()
                } label: {
                    Label(titleKey, systemImage: iconName)
                }
            } else if models.isEmpty {
                // 拉成功但该节点没暴露 /v1/models
                Button {
                    onFetch()
                } label: {
                    Label("未找到模型 — 重试", systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(models, id: \.self) { id in
                    Button {
                        onPick(id)
                    } label: {
                        if id == current {
                            Label(id, systemImage: "checkmark")
                        } else {
                            Text(id)
                        }
                    }
                }
                Divider()
                Button {
                    onFetch()
                } label: {
                    Label("刷新列表", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundColor(displayColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !urlIsEmpty && fetched == nil {
                    // 正在 fetch — 显示 spinner 让用户知道"在拉"
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)  // 自己画 chevron,避免系统重复
        .fixedSize(horizontal: false, vertical: true)
        .help(helpText)
    }

    /// 改成 LocalizedStringKey,让 Text(displayText) / .help(helpText) 走本地化表。
    /// 之前 String → Text(_:String) verbatim,中文 fallback 永远不变。
    private var displayText: LocalizedStringKey {
        if urlIsEmpty {
            return "请先填写翻译服务地址"
        }
        if fetched != true {
            return fetched == false ? "拉取失败 — 点击重试" : "正在获取模型列表…"
        }
        if models.isEmpty {
            return "未找到模型 — 点击重试"
        }
        if current.isEmpty {
            return "选择模型"
        }
        // current 是运行时模型 id (e.g. "mlx-community/Qwen3-ASR-0.6B-4bit") —
        // 不参与本地化表,直接返回 verbatim。LocalizedStringKey 也是 ExpressibleByStringLiteral,
        // 但这里强制用 Text(verbatim:) 走 verbatim 路径,避免被当 key 查表(查不到也只 fallback 到字面量)。
        // 实际:return current 走 LocalizedStringKey 路径,查表不命中 → fallback 字面量 = current,等价 verbatim。
        return LocalizedStringKey(stringLiteral: current)
    }

    private var displayColor: Color {
        if urlIsEmpty {
            return .secondary
        }
        if current.isEmpty && fetched == true && !models.isEmpty {
            return .secondary  // 没选 + 有可选 → 灰色 placeholder
        }
        if fetched != true {
            return .secondary
        }
        return .primary
    }

    /// 返回 Text 而非 LocalizedStringKey,因为最后一条带 models.count 插值需要拼接
    /// (verbatim 数字 + 本地化片段)。.help() 接收 Text 也 OK。
    private var helpText: Text {
        if urlIsEmpty {
            return Text("请先在上方填写翻译服务地址,失焦后会自动拉取该节点的模型列表")
        }
        if fetched != true {
            return Text("改完翻译服务地址后,失焦会自动拉取该节点的模型列表")
        }
        if models.isEmpty {
            return Text("该节点未通过 /v1/models 返回任何模型")
        }
        // 动态插值:数字 verbatim + 前缀/后缀本地化
        return Text("已从外接翻译服务加载 ") + Text("\(models.count)") + Text(" 个模型,点击切换")
    }
}

/// Translation model 行 — 取代 hostRow 在 model 行的角色。
/// 渲染 label (顶部字段名) + 占满宽度的下拉框。
/// urlIsEmpty:绑定的 URL 为空时,UI 显式显示「请先填写翻译服务地址」
/// (不让 fetched == nil 误显 spinner)。
/// `label` 走 LocalizedStringKey,中文字面量即自动本地化。
private func modelRow(
    icon: String,
    current: String,
    fetched: Bool?,
    models: [String],
    onFetch: @escaping () -> Void,
    onPick: @escaping (String) -> Void,
    label: LocalizedStringKey,
    urlIsEmpty: Bool
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            TranslationModelMenu(
                fetched: fetched,
                models: models,
                current: current,
                onFetch: onFetch,
                onPick: onPick,
                urlIsEmpty: urlIsEmpty
            )
        }
    }
}

// MARK: - Translation mode row (左端 label + 短 slider + 右端 label)
//
// 视觉:
//   [本地算力] ———————•——————— [外置算力优先]
//
// 行为:Slider 在 0 / 1 两个端点 (step: 1) — 严格的 bool 语义,没有
// "中间值"。拖动滑块只能停在两端,松手即生效,无需 snap 阈值。
// 端点 label 始终不变 (slider 端点标识),当前选中端 label 加粗 +
// accent color 高亮。
//
// 跟字号行的区别:字号行 slider 是连续 Double (18...52) — 字号
// 需要细调,所以有中间值;翻译模式只有 2 段 (本地/外置),slider
// step=1 强制离散化,行为等同 bool 切换。
private struct TranslationModeRow: View {
    private static let sliderWidth: CGFloat = 60

    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 左端点 label:始终 "本地算力"
            Text("本地算力")
                .font(.system(size: 11, weight: isOn ? .regular : .semibold))
                .foregroundStyle(isOn ? Color.secondary : Color.accentColor)
                .frame(minWidth: 60, alignment: .leading)
            // 短 Slider,严格 0 / 1 (step: 1 强制只有两端)
            Slider(
                value: Binding(
                    get: { isOn ? 1.0 : 0.0 },
                    // 拖动期间实时同步 — isOn 变,slider 立即跳到对应端
                    // (视觉上无"中点停留",因为只有 0 / 1 两档)。
                    set: { newValue in
                        // step: 1 让 newValue 只能是 0 或 1
                        let snap: Bool = newValue >= 0.5
                        if isOn != snap {
                            onChange(snap)
                        }
                    }
                ),
                in: 0...1,
                step: 1  // 强制离散 0 / 1,无中间值,等同 bool 切换
            )
            .frame(width: Self.sliderWidth)
            // 右端点 label:始终 "外置算力优先"
            Text("外置算力优先")
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(minWidth: 84, alignment: .trailing)
        }
        // 让组件在父容器中水平居中 — 父容器是 settings card,
        // 默认内容左对齐。Spacer(minLength:) 让 label+slider+label
        // 视觉上居中。
        .frame(maxWidth: .infinity)
    }
}
