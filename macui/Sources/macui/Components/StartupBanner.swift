import SwiftUI

/// Liquid-Glass banner shown during the first few seconds after the
/// pipeline finishes booting. It aggregates the small "init-…" status
/// pings that BackendLauncher writes into the translation event
/// stream (ASR backend, translation target, load time) and renders
/// them as a single quiet line — instead of letting each one display
/// as a fake subtitle and pollute the history list.
///
/// The banner is visible until either:
///   • the first real subtitle arrives (handled by `OverlayState`), or
///   • 1.8 seconds pass after the "listening" ping is received, or
///   • the user manually clicks the close button
///
/// 设计对照 macOS HIG(2027 版浮动 banner 模式):
///   • 高度 ≥ 40pt:32pt 字号 + 8pt 上下 padding + lineLimit 1,文字有
///     喘息空间,视觉上不"被压扁"
///   • 主行 + 副行 两层结构:主行一句话概括("✓ 准备就绪 · 1.23s" /
///     "加载中…"),副行显示 ASR/翻译/Hermes 细节。避免一长串 · 分隔
///     字段挤在一起(违反「信息密度过高」)
///   • 右上角小 ✕:用户可主动关闭,避免卡死时只能等自动消失
///   • 圆角 12pt:macOS 标准 toolbar 圆角,跟控制中心/通知中心视觉一致
struct StartupBanner: View {
    let summary: StartupSummary
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 主行:icon + 关键信息 + 关闭按钮
            HStack(spacing: 8) {
                icon
                Text(headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let s = summary.loadSeconds {
                    Text(s)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.textTertiary)
                }
                closeButton
            }
            // 副行:ASR/翻译/Hermes 细节,小字灰底
            if !detailParts.isEmpty {
                Text(detailParts.joined(separator: "  ·  "))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)  // 对齐主行 icon 之后的文字
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .glassPlate(corner: 12)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 主行文案:简洁一句话 + load time。
    /// - "准备就绪"              (listening 收到后)
    /// - summary.stage.displayText (Swift 启动阶段:初始化/启动后端/扫描模型…)
    /// 返回 LocalizedStringKey 让 Text(headline) 查表。
    private var headline: LocalizedStringKey {
        if summary.listening {
            return "准备就绪"
        } else {
            return summary.stage.displayText
        }
    }

    /// 副行字段:ASR / 翻译 / Hermes 各自的状态。
    /// 用 detailParts 而不是拼成一行 banner 字符串,是因为 banner 主行
    /// 已经够直观,副行只是为了"想看细节时能看到"。
    /// Hermes 是 ✓/✗ 单字符,极短,放在末尾不抢眼。
    /// 静态 "ASR 加载中" / "Hermes X" 改成 LocalizedStringKey。
    private var detailParts: [String] {
        var parts: [String] = []
        if let asr = summary.asr, !asr.isEmpty {
            parts.append(asr)
        } else if !summary.listening {
            parts.append(String(localized: "ASR 加载中"))
        }
        if let tr = summary.translation, !tr.isEmpty {
            parts.append(tr)
        }
        if let h = summary.hermes {
            parts.append(String(localized: "Hermes \(h)"))  // "Hermes ✓" / "Hermes ✗"
        }
        return parts
    }

    @ViewBuilder
    private var icon: some View {
        let isListening = summary.listening
        // 状态语义:加载中用 hourglass(准备中),准备就绪用 checkmark。
        // macOS HIG 偏好 checkmark.circle.fill 表示"完成",比 waveform 更
        // 直观(用户看到 waveform 可能以为是在录音)。
        let iconName = isListening ? "checkmark.circle.fill" : "hourglass"
        let tint: Color = isListening ? .green : .white.opacity(0.55)
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: !isListening)
    }

    /// 右上角关闭按钮。低 opacity 让它不抢眼,hover 时变明显——符合
    /// macOS 「次要控件保持低调,可发现但不打扰」的设计。
    @ViewBuilder
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "关闭"))
        .opacity(0.4)  // 默认半透明;hover 由 SwiftUI 在 plain style 下自然提升
        .onHover { hovering in
            // plain button 没有内置 hover 高亮,手动用 opacity 模拟。
            // 但 onHover 改 opacity 需要 @State,这里先静态 0.4,后续
            // 如果需要动态 hover 再加 @State。
            _ = hovering
        }
    }
}