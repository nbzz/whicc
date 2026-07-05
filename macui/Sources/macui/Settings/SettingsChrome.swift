import SwiftUI

/// 设置卡片:浮起 rounded 卡片,白底 + hairline 描边。
/// content 在 init 时捕获一次,不用 @ViewBuilder 闭包(后者每次
/// body 重新求值,破坏 SwiftUI diffing 稳定 identity)。
struct SettingsCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

/// Section header:icon + title,可选 trailing slot。
/// Generic over Trailing 保类型(避免 AnyView erasure),无 trailing 时
/// 不强制包 AnyView(EmptyView)。
///
/// `title` 接受 `LocalizedStringKey`,所以调用方直接传中文 literal 即可,
/// 系统 locale=en 时自动查 en.lproj/Localizable.strings 替换为英文;
/// locale=zh 时 fallback 到代码字面量(中文)。
struct SettingsSectionHeader<Trailing: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let tint: Color
    let trailing: Trailing?

    init(icon: String, title: LocalizedStringKey, tint: Color = .accentColor,
         @ViewBuilder trailing: () -> Trailing? = { nil }) {
        self.icon = icon
        self.title = title
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
    }
}

/// Standard scrollable container for a detail pane — vertical padding
/// inside the white content area, generous spacing between cards.
struct SettingsDetailContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}