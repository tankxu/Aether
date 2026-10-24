import SwiftUI

/// 地址栏输入时的内容
final class AddressSuggestModel: ObservableObject {
    /// 用户实际输入的内容；刚点开（还是当前网址）时为空，显示收藏和最近历史
    @Published var query = ""
}

/// 点地址栏时铺在背后的一页（学 Safari）：收藏（两行，可展开全部）+ 历史记录；输入时变成搜索 + 匹配的历史
struct AddressSuggestionsView: View {
    @ObservedObject var model: AddressSuggestModel
    var onOpen: (URL) -> Void
    var onSearch: (String) -> Void

    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var favicons = FaviconStore.shared
    @State private var showAllFavorites = false
    @State private var contentWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad 上内容限制在这个宽度内居中（横屏一排约 10 个收藏）；地址输入框窄一些
    static let maxContentWidth: CGFloat = 1000
    static let maxInputWidth: CGFloat = 720

    private let favorites = AppLibrary.shared.allApps
    /// 收藏图标：手机 56pt 一排 4 个；宽屏放大一点，一排放得下几个就放几个
    private var iconSize: CGFloat { sizeClass == .regular ? 64 : 56 }
    private var columnCount: Int { max(4, Int((contentWidth + 8) / (iconSize + 20 + 8))) }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount) }

    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var historyItems: [HistoryStore.Entry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(history.entries.prefix(30)) }
        return Array(history.entries.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }.prefix(50))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !query.isEmpty { searchRow }
                if query.isEmpty, !favorites.isEmpty { favoritesSection }
                if !historyItems.isEmpty { historySection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(maxWidth: Self.maxContentWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 36 } action: { contentWidth = $0 }
            .padding(.top, 12)
            // 底部让出地址输入框
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        // 没有收藏和历史时也铺满，避免毛玻璃背景收缩成中间的窄条。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var searchRow: some View {
        Button { onSearch(query) } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                Text(L("搜索“%@”", query)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("收藏")).font(.title3.bold())
                Spacer()
                if favorites.count > columnCount * 2 {
                    Button(showAllFavorites ? L("收起") : L("显示全部")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showAllFavorites.toggle() }
                    }
                    .font(.subheadline)
                }
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(showAllFavorites ? favorites : Array(favorites.prefix(columnCount * 2))) { app in
                    Button {
                        if let url = URL(string: app.url) { onOpen(url) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(uiImage: AppIconStore.shared.image(for: app))
                                .resizable()
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            Text(app.title).font(.caption).lineLimit(1).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("历史记录")).font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(historyItems) { entry in
                    Button {
                        if let url = URL(string: entry.url) { onOpen(url) }
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                    if entry.id != historyItems.last?.id { Divider().padding(.leading, 62) }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        let host: String = {
            let h = URL(string: entry.url)?.host() ?? entry.url
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }()
        let _ = favicons.revision
        return HStack(spacing: 12) {
            Group {
                if let icon = favicons.image(for: host) {
                    Image(uiImage: icon).resizable()
                } else {
                    Text(String(host.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hue: Double(host.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360, saturation: 0.45, brightness: 0.75))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).lineLimit(1)
                Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
