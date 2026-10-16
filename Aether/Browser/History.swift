import SwiftUI

/// 浏览历史（只记普通标签页）。存在 Application Support/history.json
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: String
        var title: String
        var date: Date
    }

    @Published private(set) var entries: [Entry] = []

    private static let limit = 3000
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func record(url: URL, title: String?) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let s = url.absoluteString
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? s
        // 同一网址半小时内只记一条（刷新、前进后退不重复）
        if let i = entries.firstIndex(where: { $0.url == s }), Date().timeIntervalSince(entries[i].date) < 1800 {
            var e = entries.remove(at: i)
            e.date = Date()
            e.title = title
            entries.insert(e, at: 0)
        } else {
            entries.insert(Entry(url: s, title: title, date: Date()), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        scheduleSave()
    }

    /// 页面标题常常在加载完之后才出来
    func updateTitle(url: URL?, title: String?) {
        guard let s = url?.absoluteString, let title, !title.isEmpty,
              let first = entries.first, first.url == s, first.title != title else { return }
        entries[0].title = title
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear(since date: Date = .distantPast) {
        entries.removeAll { $0.date >= date }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder().encode(snapshot)
            try? data?.write(to: Self.fileURL, options: .atomic)
        }
    }
}

struct HistoryView: View {
    var onOpen: (URL) -> Void

    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private var sections: [(String, [HistoryStore.Entry])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? store.entries : store.entries.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
        let calendar = Calendar.current
        var result: [(String, [HistoryStore.Entry])] = []
        for entry in filtered {
            let day: String
            if calendar.isDateInToday(entry.date) { day = L("今天") }
            else if calendar.isDateInYesterday(entry.date) { day = L("昨天") }
            else { day = entry.date.formatted(.dateTime.month().day().weekday().locale(AppLanguage.locale)) }
            if result.last?.0 == day { result[result.count - 1].1.append(entry) } else { result.append((day, [entry])) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    ContentUnavailableView(L("没有浏览记录"), systemImage: "clock", description: Text(L("无痕标签页不会留下记录")))
                        .listRowBackground(Color.clear)
                }
                ForEach(sections, id: \.0) { day, items in
                    Section(day) {
                        ForEach(items) { entry in
                            Button {
                                if let url = URL(string: entry.url) { onOpen(url) }
                                dismiss()
                            } label: {
                                HistoryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(L("拷贝链接"), systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.url }
                            }
                        }
                        .onDelete { offsets in store.remove(Set(offsets.map { items[$0].id })) }
                    }
                }
            }
            .searchable(text: $query, prompt: L("搜索历史记录"))
            .navigationTitle(L("历史记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 弹窗挂在按钮上：iOS 26 的确认弹窗是气泡，箭头会指向这个按钮
                    Button(L("清除")) { confirmClear = true }
                        .disabled(store.entries.isEmpty)
                        .confirmationDialog(L("清除历史记录"), isPresented: $confirmClear, titleVisibility: .visible) {
                            Button(L("最近一小时"), role: .destructive) { store.clear(since: Date().addingTimeInterval(-3600)) }
                            Button(L("今天"), role: .destructive) { store.clear(since: Calendar.current.startOfDay(for: Date())) }
                            Button(L("全部"), role: .destructive) { store.clear() }
                        }
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    @ObservedObject private var favicons = FaviconStore.shared

    private var host: String {
        let h = URL(string: entry.url)?.host() ?? entry.url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// 有缓存的网站图标就用图标，没有就用首字母
    @ViewBuilder private var icon: some View {
        let _ = favicons.revision
        if let image = favicons.image(for: host) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .background(Color(uiColor: .secondarySystemBackground))
        } else {
            Text(String(host.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hue: Double(host.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360, saturation: 0.45, brightness: 0.75))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
