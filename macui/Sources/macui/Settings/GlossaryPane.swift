import SwiftUI

/// Glossary CRUD pane. Search, add, edit, delete. Same wire format as the
/// legacy overlay — `glossary.json`, `event_glossary.json`.
struct GlossaryPane: View {
    @ObservedObject var state: GlossaryState

    var body: some View {
        SettingsDetailContainer {
            GlossaryEditor(state: state)
        }
    }

    /// 无外壳内容 — HermesPane 把它跟事件流纵向堆在同一 ScrollView,
    /// 不嵌套两层 ScrollView。必须返回带 @State / .sheet 的编辑器本体,
    /// 不能只抽 UI 而把 sheet 留在 body 上,否则「添加术语」点了无弹窗。
    var content: some View {
        GlossaryEditor(state: state)
    }
}

/// 词库编辑主体。@State 与 sheet 必须挂在实际进入视图树的 View 上:
/// HermesPane 嵌入的是 GlossaryPane.content,若 State/sheet 只挂在
/// GlossaryPane.body,按钮会改 flag 却永远弹不出表单。
private struct GlossaryEditor: View {
    @ObservedObject var state: GlossaryState

    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var editingEntry: GlossaryEntry?
    @State private var editingZh = ""
    @State private var editingEn = ""
    @State private var showClearConfirm = false

    private var filteredEntries: [GlossaryEntry] {
        guard !searchText.isEmpty else { return state.entries }
        let q = searchText.lowercased()
        return state.entries.filter {
            $0.zh.lowercased().contains(q) || $0.en.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            searchBar
            entriesCard
            addButton
        }
        .sheet(isPresented: $showAddSheet) {
            entrySheet(
                title: "添加术语", zh: "", en: "",
                onSave: { zh, en in state.addEntry(zh: zh, en: en) },
                onDismiss: { showAddSheet = false }
            )
        }
        .sheet(item: $editingEntry) { entry in
            entrySheet(
                title: "编辑术语", zh: entry.zh, en: entry.en,
                onSave: { zh, en in
                    state.updateEntry(oldZh: entry.zh, newZh: zh, newEn: en)
                },
                onDismiss: { editingEntry = nil }
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        SettingsSectionHeader(
            icon: "character.book.closed",
            title: "词库",
            trailing: {
                HStack(spacing: 10) {
                    // 拆成 "数字 + 条" 两段 Text 拼接,让 "条" 后缀走本地化表。
                    (Text("\(state.entries.count)") + Text(" 条"))
                        .font(.caption).foregroundColor(.secondary)
                    if !state.entries.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清空词库")
                        .alert("确认清空？", isPresented: $showClearConfirm) {
                            Button("取消", role: .cancel) {}
                            Button("清空", role: .destructive) { state.clearGlossary() }
                        } message: {
                            // "删除全部 X 条术语" 拆成 "删除全部 " + 数字 + " 条术语",
                            // 让数字前后两段本地化片段都走 .strings 表。
                            (Text("删除全部 ") + Text("\(state.entries.count)") + Text(" 条术语"))
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { !state.isPaused },
                        set: { _ in state.togglePause() }
                    )) {
                        EmptyView()
                    }
                    .toggleStyle(.switch)
                    .help(state.isPaused ? LocalizedStringKey("自学习已暂停") : LocalizedStringKey("自学习 (Hermes Agent) 运行中"))
                }
            }
        )
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索术语…", text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var entriesCard: some View {
        SettingsCard(padding: 0) {
            if filteredEntries.isEmpty {
                // 用显式 LocalizedStringKey,避免 ternary 推断成 String verbatim
                let key: LocalizedStringKey = state.entries.isEmpty
                    ? "词库为空，点右下角添加术语。"
                    : "没有匹配的术语"
                Text(key)
                    .font(.callout).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                        row(entry)
                        if idx < filteredEntries.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var addButton: some View {
        HStack {
            Spacer()
            Button {
                // 调用清空编辑缓存：避免上次编辑残留进「添加」表单
                editingZh = ""
                editingEn = ""
                showAddSheet = true
            } label: {
                Label("添加术语", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func row(_ entry: GlossaryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.zh).font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(entry.en).font(.system(size: 12)).foregroundColor(.secondary)
                    if !entry.added.isEmpty {
                        Text(entry.added)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Text(entry.source)
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(sourceColor(entry.source).opacity(0.15))
                    .cornerRadius(3)
                if entry.hits > 0 {
                    Text("\(entry.hits)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button {
                    editingZh = entry.zh
                    editingEn = entry.en
                    editingEntry = entry
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    state.deleteEntry(zh: entry.zh)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "hermes": return .blue
        case "web":    return .green
        case "lm":     return .orange
        case "manual": return .purple
        default:       return .gray
        }
    }

    private func entrySheet(title: String, zh: String, en: String,
                            onSave: @escaping (String, String) -> Void,
                            onDismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            HStack {
                Text("中文").frame(width: 40, alignment: .trailing)
                TextField("术语", text: $editingZh)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("英文").frame(width: 40, alignment: .trailing)
                TextField("translation", text: $editingEn)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("取消") {
                    editingZh = ""
                    editingEn = ""
                    onDismiss()
                }
                Spacer()
                Button("保存") {
                    onSave(editingZh, editingEn)
                    editingZh = ""
                    editingEn = ""
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editingZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || editingEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            editingZh = zh
            editingEn = en
        }
    }
}
