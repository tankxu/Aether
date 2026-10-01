import SwiftUI

struct AdBlockSettingsView: View {
    var onChange: () -> Void
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        Form {
            Section {
                Toggle("广告过滤", isOn: Binding(
                    get: { blocker.isEnabled },
                    set: { blocker.setEnabled($0); onChange() }
                ))
            } footer: {
                Text(statusText)
            }

            Section {
                ForEach(blocker.subscriptions) { sub in
                    Toggle(isOn: Binding(
                        get: { sub.enabled },
                        set: { blocker.setSubscription(sub.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                            Text(sub.detail).font(.caption).foregroundStyle(.secondary)
                            if let date = sub.lastFetched {
                                Text("更新于 \(date.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Button {
                    blocker.updateNow()
                } label: {
                    HStack {
                        Text("立即更新规则")
                        Spacer()
                        if blocker.status == .downloading || blocker.status == .compiling { ProgressView() }
                    }
                }
                .disabled(blocker.status == .downloading || blocker.status == .compiling)
            } header: {
                Text("规则订阅")
            } footer: {
                Text("规则每 4 天自动更新一次。只下载规则文本，在本机转换成 Safari 的内容拦截格式。")
            }

            Section {
                if blocker.whitelist.isEmpty {
                    Text("没有停用过滤的网站").foregroundStyle(.secondary)
                }
                ForEach(blocker.whitelist, id: \.self) { Text($0) }
                    .onDelete { blocker.removeWhitelist(at: $0); onChange() }
            } header: {
                Text("已停用过滤的网站")
            } footer: {
                Text("在工具栏菜单里选“在此网站停用广告过滤”添加。左滑删除。")
            }

            Section {
                if blocker.userRules.isEmpty {
                    Text("还没有手动屏蔽的元素").foregroundStyle(.secondary)
                }
                ForEach(blocker.userRules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.host)
                        Text(rule.selector).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .onDelete { blocker.removeUserRules(at: $0); onChange() }
            } header: {
                Text("我屏蔽的元素")
            } footer: {
                Text("在工具栏菜单里选“屏蔽页面元素”，点选页面上漏网的广告即可。")
            }
        }
        .navigationTitle("广告过滤")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch blocker.status {
        case .downloading: return "正在下载规则…"
        case .compiling: return "正在编译规则…"
        case .failed(let message): return message
        case .idle:
            guard blocker.ruleCount > 0 else { return "正在准备规则…" }
            return "已启用 \(blocker.ruleCount.formatted()) 条规则"
        }
    }
}
