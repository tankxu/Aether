import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// 下载列表：下载中显示进度可取消；下完的点一下用快速查看预览，分享里可以“存储视频”到相册或存到“文件”
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if manager.items.isEmpty {
                    ContentUnavailableView(L("没有下载"), systemImage: "arrow.down.circle",
                                           description: Text(L("在 ⋯ 菜单里下载当前文件，或长按链接下载")))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item) {
                                if item.state == .finished { previewURL = item.fileURL }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { manager.items[$0] }.forEach { manager.remove($0) }
                        }
                    } footer: {
                        Text(L("文件保存在“文件”App › 我的 iPhone › Aether › Downloads"))
                    }
                }
            }
            .navigationTitle(L("下载"))
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .onAppear { manager.refresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("清除")) { confirmClear = true }
                        .disabled(!manager.items.contains { $0.state != .downloading })
                        .confirmationDialog(L("删除所有已下载的文件？"), isPresented: $confirmClear, titleVisibility: .visible) {
                            Button(L("删除"), role: .destructive) { manager.clearFinished() }
                        }
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadManager.Item
    var onTap: () -> Void

    private var symbol: String {
        let type = UTType(filenameExtension: (item.filename as NSString).pathExtension)
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }

    private var detail: String {
        let fmt = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch item.state {
        case .downloading:
            if item.received == 0 { return L("正在连接…") }
            return item.expected > 0 ? "\(fmt(item.received)) / \(fmt(item.expected))" : fmt(item.received)
        case .finished:
            return [fmt(item.received), item.date.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.locale))].joined(separator: " · ")
        case .failed(let reason):
            return reason
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: item.fraction).progressViewStyle(.linear)
                }
                Text(detail).font(.caption).foregroundStyle(item.state.isFailed ? .red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            switch item.state {
            case .downloading:
                Button { DownloadManager.shared.cancel(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            case .finished:
                if let url = item.fileURL {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.body) }
                        .buttonStyle(.borderless)
                }
            case .failed:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private extension DownloadManager.State {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}
