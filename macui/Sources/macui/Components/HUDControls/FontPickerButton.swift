import SwiftUI

/// HUD control that cycles through the user's `SubtitleFont` choices.
/// Click to advance; the button label is a literal "A" rendered in
/// Times New Roman so the user can tell at a glance that this is
/// the font picker — even if the current font is SF Pro Rounded.
struct FontPickerButton: View {
    @ObservedObject var state: OverlayState
    /// `LangConfig` is the persistence seam — we keep a weak ref so
    /// we don't extend its lifetime just to write a string to disk.
    var langConfig: LangConfig?

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                state.cycleFont()
                langConfig?.setSubtitleFont(state.fontChoice.rawValue)
            }
        } label: {
            Text("A")
                .font(Font.custom("Times New Roman", size: 14, relativeTo: .body)
                    .weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 拆成"字体："前缀(本地化) + displayName verbatim + "（点击切换）"后缀(本地化)
        .help(Text("字体：") + Text(state.fontChoice.displayName) + Text("（点击切换）"))
        .hudControl()
    }
}