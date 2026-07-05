import SwiftUI
import AppKit

/// Globe icon that opens an `NSMenu` of target languages grouped by region.
struct LanguageMenuButton: View {
    @ObservedObject var langConfig: LangConfig

    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        // 拆成本地化前缀 + verbatim 语言代码,前缀查表。
        // .help() 接受 Text,用 Text + Text 拼接。
        .help(Text("目标翻译语言：") + Text(LANG_SHORT_LABELS[langConfig.targetLang] ?? langConfig.targetLang))
        .hudControl()
    }

    private func showMenu() {
        let menu = NSMenu()

        for group in LANGUAGE_GROUPS {
            let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: group.name,
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            menu.addItem(header)

            for lang in group.langs {
                let item = NSMenuItem(
                    title: lang.label,
                    action: #selector(MenuActionHandler.langMenuClicked(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = lang.id
                item.target = MenuActionHandler.shared
                if langConfig.targetLang == lang.id { item.state = .on }
                menu.addItem(item)
            }
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(
                menu, with: event,
                for: NSApp.keyWindow?.contentView ?? NSView()
            )
        }
    }
}

/// `NSMenuItem` callbacks need a stable `NSObject` target. We park one
/// here and route through a closure that's set by `AppDelegate`.
@MainActor
final class MenuActionHandler: NSObject {
    static let shared = MenuActionHandler()
    var onLanguagePicked: ((String) -> Void)?

    @objc func langMenuClicked(_ sender: NSMenuItem) {
        guard let langId = sender.representedObject as? String else { return }
        onLanguagePicked?(langId)
    }
}
