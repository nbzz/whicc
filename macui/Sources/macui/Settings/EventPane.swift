import SwiftUI

/// Event recognition pane. Drives `event_agent.py` via the
/// `EventAgentState` model and renders every status the agent may
/// transition to.
struct EventPane: View {
    @ObservedObject var eventAgent: EventAgentState

    var body: some View {
        SettingsDetailContainer { content }
    }

    /// 抽出"无外壳"内容供 HermesPane 之类的容器复用。
    /// 跟 GlossaryPane.content 同样的设计:body 保留 SettingsDetailContainer
    /// 包装,content 暴露内部以便 HermesPane 垂直堆叠时共享一个 ScrollView。
    @ViewBuilder
    var content: some View {
        SettingsSectionHeader(
            icon: "target",
            title: "事件识别",
            trailing: {
                if eventAgent.status == "running" {
                    ProgressView().controlSize(.small)
                } else if eventAgent.status == "applied" || eventAgent.status == "high_confidence" {
                    Button {
                        eventAgent.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除事件")
                }
            }
        )

        switch eventAgent.status {
        case "idle", "no_match":
            idleBlock
        case "running":
            SettingsCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(eventAgent.progress.isEmpty ? "正在识别事件…" : eventAgent.progress)
                        .font(.callout).foregroundColor(.secondary)
                }
            }
        case "needs_confirmation":
            confirmationBlock
        case "applied", "high_confidence":
            appliedBlock
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var idleBlock: some View {
        SettingsCard {
            Text("用户提示")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("如：NBA季后赛、海贼王、WWDC…", text: $eventAgent.userHint)
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
            Button {
                eventAgent.trigger()
            } label: {
                Label("获取当前事件", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            if !eventAgent.reason.isEmpty {
                Text(eventAgent.reason).font(.callout).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var confirmationBlock: some View {
        SettingsCard {
            Text(eventAgent.questionForUser).font(.callout)
            HStack {
                Button {
                    eventAgent.confirm()
                } label: {
                    Label("确认", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    eventAgent.dismiss()
                } label: {
                    Label("不对", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            // 拆成 "置信度 " + 数字 + "%",让本地化片段走表。数字为 Int 百分比。
            (Text("置信度 ") + Text("\(Int(eventAgent.confidence * 100))") + Text("%"))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var appliedBlock: some View {
        SettingsCard {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text(eventAgent.eventName).fontWeight(.medium)
                    Text("临时术语已注入").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }
}