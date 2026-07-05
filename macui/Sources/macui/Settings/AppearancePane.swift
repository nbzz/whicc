import SwiftUI

/// 字幕外观默认值设置:字体、字号、颜色、窗体透明度、目标语言。
///
/// 控件双写:`OverlayState`(HUD 立刻看到)+ `LangConfig`(持久化)。
/// HUD 不写 LangConfig — 那是会话级,关掉即丢。
struct AppearancePane: View {
    @ObservedObject var state: OverlayState
    @ObservedObject var langConfig: LangConfig

    // MARK: - Hard-coded defaults（"恢复默认"按钮回到这里）

    private static let defaultFont: SubtitleFont = .rounded
    private static let defaultTransFontSize: CGFloat = 32
    private static let defaultSrcFontSize: CGFloat = 18
    private static let defaultStyle: OverlayStyle = .white
    private static let defaultBgOpacity: CGFloat = 0.85

    var body: some View {
        SettingsDetailContainer {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部说明
                SettingsCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认主题设置")
                                .font(.system(size: 12, weight: .semibold))
                            Text("这里改的是默认值 —— 重启 app 后仍然保留。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // 字体
                fontCard

                // 字号（译文 + 源文）
                fontSizeCard

                // 颜色
                colorCard

                // 阴影（描边 + 阴影）
                shadowCard

                // 窗体透明度
                opacityCard
            }
        }
    }

    // MARK: - 通用：section header 右侧的"恢复默认"按钮

    /// 小图标按钮 ↺，hover 时显示 tooltip。点击 → 执行 `reset` 闭包。
    /// `help` 走 LocalizedStringKey,传入中文字面量即自动本地化。
    @ViewBuilder
    private func resetButton(help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 用户调节任何外观参数 → ping 5s 预览。让 idle 字幕区显示
    /// 项目简介作为视觉参考。setter 里都调用 `mutate { ... }`：
    /// mutate 闭包内部所有 state 改动都会自动 ping。
    private func mutate(_ changes: () -> Void) {
        state.pingIdlePreview()
        changes()
    }

    /// 通用 slider row：左侧标签 + slider + 右侧读数。读数格式根据
    /// `valueKind` 自动选 0.00 / 0pt / 0%。
    private enum ValueKind { case opacity, radius, percent }
    /// `label` / `help` 走 LocalizedStringKey,所以传入中文字面量即可自动本地化。
    /// 之前都是 String,Text(label) / .help(help) 是 verbatim,本地化失效。
    @ViewBuilder
    private func valueRow(
        label: LocalizedStringKey,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        kind: ValueKind,
        help: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .help(help)
            Slider(
                value: Binding(
                    get: { binding.wrappedValue },
                    set: { binding.wrappedValue = $0 }
                ),
                in: range, step: step
            )
            Text(formattedValue(binding.wrappedValue, kind: kind))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func formattedValue(_ v: Double, kind: ValueKind) -> String {
        switch kind {
        case .opacity: return String(format: "%.2f", v)
        case .radius:  return String(format: "%.0fpt", v)
        case .percent: return "\(Int(v * 100))%"
        }
    }

    // MARK: - 字体

    private var fontCard: some View {
        SettingsCard {
            SettingsSectionHeader(
                icon: "textformat",
                title: "字体",
                tint: .accentColor,
                trailing: {
                    resetButton(help: "恢复默认字体（默认）") {
                        mutate {
                            state.fontChoice = Self.defaultFont
                            langConfig.setSubtitleFont(Self.defaultFont.rawValue)
                        }
                    }
                }
            )
            // 自渲染字体列表 — Picker(.menu) 不支持每行内嵌交互控件
            // (五角星 / 选中勾),换成 ScrollView + LazyVStack。
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    // 当前选中字体名（用作"列表太长时知道自己选谁"的反馈）
                    Text(state.fontChoice.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        cycleFont(direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("上一字体")

                    Button {
                        cycleFont(direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("下一字体")
                }

                // 推荐 + 系统 两段。ScrollViewReader 让上下按钮滚到
                // 选中行(列表 200+ 项时选中可能滚出可视区)。
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // 收藏字体放最上面,避免在 200+ 系统字体里翻。
                            fontListSection(
                                title: "我的收藏",
                                fonts: state.favoriteFonts
                            )
                            fontListSection(
                                title: "推荐字体",
                                fonts: recommendedSubtitleFonts
                            )
                            fontListSection(
                                title: "系统字体",
                                fonts: availableSystemFontNames().map { SubtitleFont.systemFont(name: $0) }
                            )
                        }
                    }
                    .frame(maxHeight: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    )
                    // fontChoice 变化时滚到对应行。async 等当前 runloop
                    // 跑完再 scrollTo,避免 id 还没挂上。
                    .onChange(of: state.fontChoice) { _, newFont in
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(newFont.rawValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 双写：state.fontChoice (立即生效) + langConfig.subtitleFont (持久化)
    private var fontChoiceBinding: Binding<SubtitleFont> {
        Binding(
            get: { state.fontChoice },
            set: { newValue in
                mutate {
                    state.fontChoice = newValue
                    langConfig.setSubtitleFont(newValue.rawValue)
                }
            }
        )
    }

    /// 系统字体列表(~250 项,~ms 级排序,不缓存)。
    /// 用户选中的系统字体若被移除,SubtitleFont.font() nil 检查
    /// 会 fall back 到默认 rounded。
    private var systemFontsForPicker: [String] {
        availableSystemFontNames()
    }

    /// 全部字体的单一序列:推荐 (rounded, serif) + 系统字体 (字母序)。
    /// 给上下按钮循环用 — 视觉上是两段 section,但循环列表是单一序列,
    /// 避免在"推荐"边界产生奇怪跳变。
    private var allFontsInOrder: [SubtitleFont] {
        var arr: [SubtitleFont] = []
        arr.append(contentsOf: recommendedSubtitleFonts)
        arr.append(contentsOf: availableSystemFontNames().map { SubtitleFont.systemFont(name: $0) })
        return arr
    }

    /// 找到当前字体在 allFontsInOrder 里的索引。找不到时返回 0
    /// (rounded)，这样 ↑↓ 按钮从 rounded 起步。
    private func currentFontIndex() -> Int {
        let all = allFontsInOrder
        if let i = all.firstIndex(of: state.fontChoice) {
            return i
        }
        return 0
    }

    /// "下一字体"——上下按钮共用逻辑。direction +1 (下) / -1 (上)。
    /// 走到末尾循环回 0。
    private func cycleFont(direction: Int) {
        let all = allFontsInOrder
        guard !all.isEmpty else { return }
        let i = currentFontIndex()
        let next = (i + direction + all.count) % all.count
        let newFont = all[next]
        mutate {
            state.fontChoice = newFont
            langConfig.setSubtitleFont(newFont.rawValue)
        }
    }

    // MARK: - 字体列表 section (推荐 / 系统)

    /// 字体列表 section: 段标题 + 该段所有字体行。section 之间由
    /// 段标题自然分隔,无需额外 Divider。
    @ViewBuilder
    private func fontListSection(title: String, fonts: [SubtitleFont]) -> some View {
        if !fonts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
                ForEach(fonts, id: \.self) { font in
                    fontListRow(font: font)
                }
            }
        }
    }

    /// 字体列表单行：五角星（收藏） + 字体名（点击选中） + 选中勾。
    /// 整行 22pt 高,跟 macOS 系统设置列表的 row 高度一致。
    @ViewBuilder
    private func fontListRow(font: SubtitleFont) -> some View {
        let isSelected = state.fontChoice == font
        let isFavorite = isFavoriteFont(font)
        HStack(spacing: 6) {
            // 五角星：实心=已收藏，空心=未收藏。点击 toggle。
            // 默认字体 (.rounded / .serif) 总是已收藏,显示实心星
            // 但点击不响应 (toggleFavorite 内部 guard 掉)。
            Button {
                toggleFavorite(font)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFavorite ? LocalizedStringKey("默认收藏") : LocalizedStringKey("加入收藏（HUD 循环）"))

            // 字体名(点击 = 选中)。收藏是五角星独立按钮管的 —
            // 用户反馈"选中 ≠ 收藏"才符合预期。
            Button {
                selectFont(font)
            } label: {
                HStack {
                    Text(font.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // id 用于 ScrollViewReader.scrollTo 定位。SubtitleFont.id 已经
        // 返回 rawValue(唯一),直接用。HUD 改了 fontChoice 时列表跟着
        // 滚 — 通过 .onChange(state.fontChoice) 触发。
        .id(font.rawValue)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    /// 判断一个字体是否在用户的收藏列表里(决定五角星是否亮起)。
    /// 默认字体永远 true — HUD 循环的基线,不能让用户取消。
    private func isFavoriteFont(_ font: SubtitleFont) -> Bool {
        switch font {
        case .rounded, .serif:
            return true
        case .systemFont:
            return state.favoriteFonts.contains(font)
        }
    }

    /// 切换字体的收藏状态。系统字体加进 / 移出 favoriteFonts;
    /// 默认字体 (.rounded / .serif) 不响应(永远在循环里)。
    /// 同步写 lang_config.json 持久化 (favorite_fonts 键)。
    private func toggleFavorite(_ font: SubtitleFont) {
        guard case .systemFont = font else { return }  // 默认字体不可取消收藏
        var arr = state.favoriteFonts
        if let i = arr.firstIndex(of: font) {
            arr.remove(at: i)
        } else {
            arr.append(font)
        }
        let raws = arr.map { $0.rawValue }
        mutate {
            state.favoriteFonts = arr
            langConfig.setFavoriteFonts(raws)
        }
    }

    /// 点击字体行 = 选中 + 自动加入收藏(仅系统字体)。
    /// 让"当前选中"这个隐含状态显式持久化:重启 app 后 HUD 循环仍包含
    /// 这个字体,不需要重新手动加星。默认字体不需要这步(永远在循环里)。
    private func selectFont(_ font: SubtitleFont) {
        // 只更新选中,不维护 favoriteFonts。HUD 循环 (cycleFont) 自己会
        // 处理 fontChoice,favoriteFonts 只作为显式扩展列表。
        mutate {
            state.fontChoice = font
            langConfig.setSubtitleFont(font.rawValue)
        }
    }

    // MARK: - 字号

    private var fontSizeCard: some View {
        SettingsCard {
            SettingsSectionHeader(
                icon: "textformat.size",
                title: "字号",
                tint: .accentColor,
                trailing: {
                    resetButton(help: "恢复默认字号（译文 32pt / 源文 18pt）") {
                        mutate {
                            state.transFontSize = Self.defaultTransFontSize
                            state.srcFontSize = Self.defaultSrcFontSize
                            langConfig.setTransFontSize(Self.defaultTransFontSize)
                            langConfig.setSrcFontSize(Self.defaultSrcFontSize)
                        }
                    }
                }
            )
            VStack(alignment: .leading, spacing: 12) {
                fontSizeRow(
                    label: "译文",
                    binding: transFontSizeBinding,
                    range: 18...52,
                    step: 1
                )
                fontSizeRow(
                    label: "源文",
                    binding: srcFontSizeBinding,
                    range: 12...36,
                    step: 1
                )
            }
        }
    }

    /// `label` 走 LocalizedStringKey,传入中文字面量即自动本地化。
    /// 之前是 String → Text(label) 是 verbatim,本地化失效。
    private func fontSizeRow(
        label: LocalizedStringKey,
        binding: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Slider(value: binding, in: range, step: step)
            Text("\(Int(binding.wrappedValue))pt")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var transFontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { state.transFontSize },
            set: { newValue in
                mutate {
                    state.transFontSize = newValue
                    langConfig.setTransFontSize(newValue)
                }
            }
        )
    }

    private var srcFontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { state.srcFontSize },
            set: { newValue in
                mutate {
                    state.srcFontSize = newValue
                    langConfig.setSrcFontSize(newValue)
                }
            }
        )
    }

    // MARK: - 颜色

    private var colorCard: some View {
        SettingsCard {
            SettingsSectionHeader(
                icon: "paintpalette",
                title: "颜色",
                tint: .accentColor,
                trailing: {
                    resetButton(help: "恢复默认颜色（白色）") {
                        mutate {
                            state.style = Self.defaultStyle
                            state.customColor = nil
                            langConfig.setSubtitleColor(Self.defaultStyle.rawValue)
                            langConfig.setCustomColorHex("")
                        }
                    }
                }
            )
            // 8 预设 swatch 行 + ColorPicker。第 8 颗是 ColorPicker，
            // 视觉上跟其它 7 颗一致（26pt 圆 + 选中态 2pt stroke），
            // 但 fill 是当前自定义色（没选自定义时 fallback 到当前预设）。
            HStack(spacing: 8) {
                ForEach(OverlayStyle.allCases.filter { $0 != .custom }) { style in
                    colorSwatch(style: style)
                }
                customColorButton
            }
            // 自定义色色值预览 + 提示
            if state.style == .custom {
                HStack(spacing: 8) {
                    Text("自定色：")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(langConfig.customColorHex.isEmpty ? "#FFFFFF" : langConfig.customColorHex)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func colorSwatch(style: OverlayStyle) -> some View {
        let isSelected = state.style == style
        return Button {
            mutate {
                state.style = style
                state.customColor = nil  // 选了预设就清掉自定义
                langConfig.setSubtitleColor(style.rawValue)
                langConfig.setCustomColorHex("")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(style.accent)
                    .frame(width: 26, height: 26)
                    // 0.5pt #E6E6E6 hairline 描边：所有色都加，让浅色
                    // (theater 白 / ice 浅蓝 / cyan 浅蓝) 在浅色背景下
                    // 也能看见。非选中态固定 0.5pt；选中态换成 2pt accent。
                    .overlay(
                        Circle()
                            .strokeBorder(Color(red: 0.902, green: 0.902, blue: 0.902),
                                          lineWidth: 0.5)
                    )
                if isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .buttonStyle(.plain)
        .help(style.label)
    }

/// 自定色按钮:SwiftUI ColorPicker 自渲染圆角矩形,我们的 Circle 盖上面
/// 会被 NSColorWell 边缘露出来。scaleEffect(0.85) 跟其它 swatch 对齐。
private var customColorButton: some View {
    let binding = Binding<Color>(
        get: {
            state.customColor ?? state.style.accent
        },
        set: { newColor in
            mutate {
                state.style = .custom
                state.customColor = newColor
                if let hex = OverlayState.hexFromColor(newColor) {
                    langConfig.setCustomColorHex(hex)
                    langConfig.setSubtitleColor(OverlayStyle.custom.rawValue)
                }
            }
        }
    )
    return ColorPicker("", selection: binding, supportsOpacity: false)
        .labelsHidden()
        .frame(width: 30, height: 30)
        .scaleEffect(0.85)
        .help("自定义颜色（系统色环）")
}

    // MARK: - 阴影

    private static let defaultStrongShadowOpacity: Double = 0.70
    private static let defaultSoftShadowOpacity: Double = 0.40
    private static let defaultStrongShadowRadius: CGFloat = 16
    private static let defaultSoftShadowRadius: CGFloat = 4

    private var shadowCard: some View {
        SettingsCard {
            SettingsSectionHeader(
                icon: "drop.halffull",
                title: "描边与阴影",
                tint: .accentColor,
                trailing: {
                    resetButton(help: "恢复默认阴影（强 0.70/16pt + 软 0.40/4pt）") {
                        mutate {
                            state.strongShadowOpacity = Self.defaultStrongShadowOpacity
                            state.softShadowOpacity = Self.defaultSoftShadowOpacity
                            state.strongShadowRadius = Self.defaultStrongShadowRadius
                            state.softShadowRadius = Self.defaultSoftShadowRadius
                            langConfig.setStrongShadowOpacity(Self.defaultStrongShadowOpacity)
                            langConfig.setSoftShadowOpacity(Self.defaultSoftShadowOpacity)
                            langConfig.setStrongShadowRadius(Self.defaultStrongShadowRadius)
                            langConfig.setSoftShadowRadius(Self.defaultSoftShadowRadius)
                        }
                    }
                }
            )
            VStack(alignment: .leading, spacing: 10) {
                valueRow(
                    label: "主描边透明度半径",
                    binding: strongShadowOpacityBinding,
                    range: 0.0...1.0,
                    step: 0.05,
                    kind: .opacity,
                    help: "主描边透明度（大模糊半径，保证低对比度背景可读）"
                )
                valueRow(
                    label: "主描边模糊半径",
                    binding: strongShadowRadiusBinding,
                    range: 0.0...40.0,
                    step: 1.0,
                    kind: .radius,
                    help: "主描边模糊半径"
                )
                valueRow(
                    label: "弱描边透明度半径",
                    binding: softShadowOpacityBinding,
                    range: 0.0...1.0,
                    step: 0.05,
                    kind: .opacity,
                    help: "次描边透明度（小模糊半径，增强边缘锐度）"
                )
                valueRow(
                    label: "弱描边模糊半径",
                    binding: softShadowRadiusBinding,
                    range: 0.0...16.0,
                    step: 1.0,
                    kind: .radius,
                    help: "次描边模糊半径"
                )
            }
        }
    }

    private var strongShadowOpacityBinding: Binding<Double> {
        Binding(
            get: { state.strongShadowOpacity },
            set: { newValue in
                mutate {
                    state.strongShadowOpacity = newValue
                    langConfig.setStrongShadowOpacity(newValue)
                }
            }
        )
    }
    private var softShadowOpacityBinding: Binding<Double> {
        Binding(
            get: { state.softShadowOpacity },
            set: { newValue in
                mutate {
                    state.softShadowOpacity = newValue
                    langConfig.setSoftShadowOpacity(newValue)
                }
            }
        )
    }
    private var strongShadowRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(state.strongShadowRadius) },
            set: { newValue in
                mutate {
                    state.strongShadowRadius = CGFloat(newValue)
                    langConfig.setStrongShadowRadius(CGFloat(newValue))
                }
            }
        )
    }
    private var softShadowRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(state.softShadowRadius) },
            set: { newValue in
                mutate {
                    state.softShadowRadius = CGFloat(newValue)
                    langConfig.setSoftShadowRadius(CGFloat(newValue))
                }
            }
        )
    }

    // MARK: - 透明度

    private var opacityCard: some View {
        SettingsCard {
            SettingsSectionHeader(
                icon: "circle.lefthalf.filled",
                title: "窗体透明度",
                tint: .accentColor,
                trailing: {
                    resetButton(help: "恢复默认透明度（85%）") {
                        mutate {
                            state.bgOpacity = Self.defaultBgOpacity
                            langConfig.setBgOpacity(Self.defaultBgOpacity)
                        }
                    }
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    // 范围 0.05~1.0 — 0% 这端 macOS SwiftUI Slider 有 thumb
                    // 截断视觉 bug,所以起点挪到 0.05 让 thumb 不卡边。
                    // 刻度 stop 跟范围同步从 0.05 起,按比例映射到 tick 位置。
                    Slider(value: bgOpacityBinding, in: 0.05...1.0)
                    Text("\(Int(state.bgOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                opacityTicks
            }
        }
    }

        /// 透明度 slider 刻度行 — 5 个视觉等距 tick,数字标签对应真实透明度:
    /// visual 0% → 0.05 / 25% → 0.2875 / 50% → 0.525 / 75% → 0.7625 / 100% → 1.0
    /// (slider 范围 0.05~1.0 避开 macOS Slider 0 位置 thumb 截断 bug)
    private var opacityTicks: some View {
    HStack(spacing: 12) {
        GeometryReader { geo in
            let trackW = geo.size.width
            // 5 个视觉等距位置 (0, 0.25, 0.5, 0.75, 1.0)
            let visualStops: [Double] = [0.00, 0.25, 0.50, 0.75, 1.00]
            // 每个视觉位置对应的 slider 实际值（5% ~ 100% 线性映射）
            let rangeLo: Double = 0.05
            let rangeHi: Double = 1.0
            let valueForVisual: (Double) -> Double = { visual in
                rangeLo + (rangeHi - rangeLo) * visual
            }
            ZStack(alignment: .topLeading) {
                ForEach(visualStops.indices, id: \.self) { idx in
                    let visual = visualStops[idx]
                    let value = valueForVisual(visual)
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 6)
                        Text("\(Int(value * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .position(x: visual * trackW, y: 11)
                }
            }
            .frame(width: trackW, height: 22, alignment: .topLeading)
        }
        .frame(height: 22)
        // 占位对齐 slider 行右边的 42pt 读数框
        Color.clear.frame(width: 42)
    }
}

    private var bgOpacityBinding: Binding<CGFloat> {
        Binding(
            get: { state.bgOpacity },
            set: { newValue in
                mutate {
                    state.bgOpacity = newValue
                    langConfig.setBgOpacity(newValue)
                }
            }
        )
    }

}