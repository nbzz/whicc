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

    /// 无外壳内容 — HermesPane 嵌入用（避免双 ScrollView）。
    var content: some View {
        GlossaryEditor(state: state)
    }
}

/// 词库编辑主体。
///
/// 不使用 `.sheet`：在 macOS 的 `NavigationSplitView` 详情列 + ScrollView
/// 里 sheet 经常点了无弹窗。改为页内展开表单，保证「添加术语」可见可点。
private struct GlossaryEditor: View {
    @ObservedObject var state: GlossaryState

    @State private var searchText = ""
    @State private var isAdding = false
    @State private var editingEntry: GlossaryEntry?
    @State private var draftZh = ""
    @State private var draftEn = ""
    @State private var showClearConfirm = false

    private var filteredEntries: [GlossaryEntry] {
        guard !searchText.isEmpty else { return state.entries }
        let q = searchText.lowercased()
        return state.entries.filter {
            $0.zh.lowercased().contains(q) || $0.en.lowercased().contains(q)
        }
    }

    private var isEditing: Bool { editingEntry != nil }

    private var canSaveDraft: Bool {
        !draftZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            searchBar
            if isAdding || isEditing {
                draftForm
            }
            if let err = state.lastWriteError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            entriesCard
            if !isAdding && !isEditing {
                addButton
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        SettingsSectionHeader(
            icon: "character.book.closed",
            title: "词库",
            trailing: {
                HStack(spacing: 10) {
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

    private var draftForm: some View {
        SettingsCard {
            Text(isEditing ? "编辑术语" : "添加术语")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("中文").frame(width: 40, alignment: .trailing)
                TextField("术语", text: $draftZh)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("英文").frame(width: 40, alignment: .trailing)
                TextField("translation", text: $draftEn)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("取消") { cancelDraft() }
                Spacer()
                Button("保存") { saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSaveDraft)
            }
        }
    }

    private var entriesCard: some View {
        SettingsCard(padding: 0) {
            if filteredEntries.isEmpty {
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
                // 调用取消编辑态：开始新增时清空草稿，展开页内表单（不用 sheet）
                editingEntry = nil
                draftZh = ""
                draftEn = ""
                isAdding = true
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
                    isAdding = false
                    draftZh = entry.zh
                    draftEn = entry.en
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

    private func cancelDraft() {
        isAdding = false
        editingEntry = nil
        draftZh = ""
        draftEn = ""
    }

    private func saveDraft() {
        let zh = draftZh.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = draftEn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zh.isEmpty, !en.isEmpty else { return }
        if let editing = editingEntry {
            // 调用更新：保存编辑后的中英对照
            state.updateEntry(oldZh: editing.zh, newZh: zh, newEn: en)
        } else {
            // 调用新增：写入 glossary.json（可写目录）
            state.addEntry(zh: zh, en: en)
        }
        if state.lastWriteError == nil {
            cancelDraft()
        }
    }
}
