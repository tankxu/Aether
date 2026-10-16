import UIKit

/// 标签页缩略图：普通标签页按网址存到 Caches/TabSnapshots（重启后恢复的标签页也有画面），无痕只放内存
enum SnapshotStore {
    private static var directory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileName(for url: URL) -> String {
        StableHash.hex(Data(url.absoluteString.utf8)) + ".jpg"
    }

    /// 同步截取当前显示的网页（必须还在窗口里）；缩到一半分辨率，省内存
    static func capture(_ tab: Tab) -> UIImage? {
        let view = tab.webView
        guard !tab.isBlank, view.window != nil, view.bounds.width > 0 else { return nil }
        // 页面还没怎么加载出来（比如重启后刚开始重新加载）时不截，免得白屏覆盖掉上次的好图
        if view.isLoading, view.estimatedProgress < 0.7 { return tab.snapshot }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        tab.snapshot = image
        if !tab.isIncognito, let url = tab.url {
            let file = directory.appendingPathComponent(fileName(for: url))
            if let data = image.jpegData(compressionQuality: 0.7) {
                DispatchQueue.global(qos: .utility).async { try? data.write(to: file, options: .atomic) }
            }
        }
        return image
    }

    static func load(for url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName(for: url))) else { return nil }
        return UIImage(data: data)
    }

    /// 删掉已经没有标签页引用的缩略图
    static func prune(keeping urls: [URL]) {
        let keep = Set(urls.map(fileName(for:)))
        let dir = directory
        DispatchQueue.global(qos: .utility).async {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
