import SwiftUI

/// 设置窗:NavigationSplitView + List(.sidebar),跟 macOS 系统设置
/// 视觉一致。详情面板分发到 AppearancePane / ServerPane 等子 pane。
struct SettingsView: View {
    @ObservedObject var state: GlossaryState
    @ObservedObject var langConfig: LangConfig
    @ObservedObject var eventAgent: EventAgentState
    @ObservedObject var modelState: ModelState
    @ObservedObject var downloadState: ModelDownloadState
    @ObservedObject var overlayState: OverlayState

    enum Pane: String, CaseIterable, Identifiable {
        case appearance = "外观"
        case model  = "语音识别模型"
        case server = "翻译模型"
        case hermes = "Hermes"
        var id: String { rawValue }

        /// Sidebar 显示标题 — LocalizedStringKey 自动查表 + 走 i18n fallback:
        /// - zh 系统 → 查 zh-Hans.lproj (没) → fallback 到代码字面量 (中文)
        /// - en 系统 → 查 en.lproj (有, 见下面 en.lproj/Localizable.strings
        ///   "外观" = "Appearance" 等 4 条 key) → 显示英文
        /// rawValue 仍是 Pane 稳定 id (NavigationLink value + @State selection),
        /// 不要改。
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .appearance: return "外观"
            case .server:     return "翻译模型"
            case .model:      return "语音识别模型"
            case .hermes:     return "Hermes"
            }
        }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .server: return "network"
            case .model:  return "cpu"
            case .hermes: return "sparkles"
            }
        }
    }

    @State private var selection: Pane? = .server

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(Pane.allCases) { pane in
                        NavigationLink(value: pane) {
                            Label(pane.localizedTitle, systemImage: pane.icon)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            // 隐藏 window toolbar 背景,让 sidebar 的 .bar material 透出来,
            // traffic-light 行视觉上跟 sidebar 融成一片。
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(.visible, for: .windowToolbar)
            // sidebar 自己的折叠按钮 — 系统 chevron 在 sidebar 折叠时
            // 不可见,这里始终可点。
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSApp.sendAction(
                            #selector(NSSplitViewController.toggleSidebar(_:)),
                            to: nil, from: nil)
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("折叠侧边栏（⌃⌘S）")
                }
            }
        } detail: {
            switch selection ?? .server {
            case .appearance: AppearancePane(state: overlayState, langConfig: langConfig)
            case .server: ServerPane(langConfig: langConfig)
            case .model:  ModelPane(modelState: modelState, downloadState: downloadState, langConfig: langConfig)
            case .hermes: HermesPane(state: state, langConfig: langConfig, eventAgent: eventAgent)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 760, height: 580)
    }
}