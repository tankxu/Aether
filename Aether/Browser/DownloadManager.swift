import UIKit
import WebKit

/// 文件下载：WKDownload 负责传输（带网页的 Cookie），完成后放进 Documents/Downloads，
/// 在“文件”App 的“我的 iPhone › Aether”里也能看到。下载中的文件先写在 Caches，完成后再移过去。
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
    }

    final class Item: ObservableObject, Identifiable {
        let id = UUID()
        let sourceURL: URL?
        @Published var filename: String
        @Published var state: State = .downloading
        @Published var fraction: Double = 0
        @Published var received: Int64 = 0
        @Published var expected: Int64 = 0
        /// 完成后的文件位置
        @Published var fileURL: URL?
        let date: Date

        fileprivate weak var download: WKDownload?
        fileprivate var partialURL: URL?
        fileprivate var observations: [NSKeyValueObservation] = []

        init(sourceURL: URL?, filename: String, date: Date = Date()) {
            self.sourceURL = sourceURL
            self.filename = filename
            self.date = date
        }
    }

    /// 最新的在最前面
    @Published private(set) var items: [Item] = []

    /// 下载开始 / 完成时通知界面（弹提示）
    var onEvent: ((String) -> Void)?

    private var byDownload: [ObjectIdentifier: Item] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let partialDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloading", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)   // 上次没下完的残留
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override private init() {
        super.init()
        loadExisting()
    }

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    /// 已下载的文件（以目录内容为准，用户在“文件”App 里删掉的就不显示了）
    private func loadExisting() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let item = Item(sourceURL: nil, filename: url.lastPathComponent, date: values?.creationDate ?? .distantPast)
            item.state = .finished
            item.fileURL = url
            item.fraction = 1
            item.received = Int64(values?.fileSize ?? 0)
            item.expected = item.received
            return item
        }
        .sorted { $0.date > $1.date }
    }

    func refresh() {
        let active = items.filter { $0.state != .finished }
        loadExisting()
        items = active + items
    }

    // MARK: - 开始

    /// 用网页的会话下载（带 Cookie / 登录态）
    func start(_ url: URL, in webView: WKWebView) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.adopt(download)
        }
    }

    /// 导航变成下载时（服务器要求下载或网页显示不了）接手
    func adopt(_ download: WKDownload) {
        download.delegate = self
        let url = download.originalRequest?.url
        let item = Item(sourceURL: url, filename: Self.fallbackName(for: url))
        item.download = download
        let progress = download.progress
        item.observations = [
            progress.observe(\.fractionCompleted) { [weak item] p, _ in
                let fraction = p.fractionCompleted, done = p.completedUnitCount, total = p.totalUnitCount
                DispatchQueue.main.async {
                    item?.fraction = fraction
                    item?.received = done
                    item?.expected = total
                }
            },
        ]
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        beginBackgroundTask()
    }

    func cancel(_ item: Item) {
        item.download?.cancel { _ in }
        finish(item, state: .failed(L("已取消")))
    }

    func remove(_ item: Item) {
        if item.state == .downloading { cancel(item) }
        if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        for item in items where item.state != .downloading {
            if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll { $0.state != .downloading }
    }

    // MARK: - 内部

    private static func fallbackName(for url: URL?) -> String {
        let last = url?.lastPathComponent ?? ""
        return last.isEmpty || last == "/" ? (url?.host() ?? "download") : last
    }

    /// 同名文件加 (2)、(3)…
    private static func uniqueURL(for name: String) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = (cleaned as NSString).deletingPathExtension, ext = (cleaned as NSString).pathExtension
        var candidate = directory.appendingPathComponent(cleaned)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private func finish(_ item: Item, state: State) {
        guard item.state == .downloading else { return }
        objectWillChange.send()
        item.observations = []
        if case .finished = state, let partial = item.partialURL {
            let target = Self.uniqueURL(for: item.filename)
            do {
                try FileManager.default.moveItem(at: partial, to: target)
                item.fileURL = target
                item.filename = target.lastPathComponent
                item.fraction = 1
                item.state = .finished
                onEvent?(L("下载完成：%@", item.filename))
            } catch {
                item.state = .failed(error.localizedDescription)
            }
        } else {
            if let partial = item.partialURL { try? FileManager.default.removeItem(at: partial) }
            item.state = state
            if case .failed(let reason) = state, reason != L("已取消") { onEvent?(L("下载失败：%@", item.filename)) }
        }
        if let download = item.download { byDownload[ObjectIdentifier(download)] = nil }
        if activeCount == 0 { endBackgroundTask() }
    }

    /// 切到后台时多争取一点时间把文件下完
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "download") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = byDownload[ObjectIdentifier(download)] else { return nil }
        if !suggestedFilename.isEmpty { item.filename = suggestedFilename }
        if response.expectedContentLength > 0 { item.expected = response.expectedContentLength }
        let partial = Self.partialDirectory.appendingPathComponent(UUID().uuidString)
        item.partialURL = partial
        onEvent?(L("开始下载：%@", item.filename))
        return partial
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload[ObjectIdentifier(download)] else { return }
        finish(item, state: .finished)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload[ObjectIdentifier(download)] else { return }
        finish(item, state: .failed(error.localizedDescription))
    }
}
