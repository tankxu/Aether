import UIKit
import WebKit

/// 网站图标缓存：按域名存成 64×64 PNG（Application Support/Favicons），内存里再缓存一份
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    /// 每次有新图标存好就加一，界面据此刷新
    @Published private(set) var revision = 0

    private let memory = NSCache<NSString, UIImage>()
    private var missing = Set<String>()
    private var inFlight = Set<String>()
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func key(for host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private static func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func image(for host: String) -> UIImage? {
        let key = Self.key(for: host)
        if let image = memory.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if let data = try? Data(contentsOf: Self.fileURL(for: key)), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        missing.insert(key)
        return nil
    }

    /// 页面加载完成后调用：从页面里找图标链接，下载、缩放、存盘
    func fetch(for webView: WKWebView) {
        guard let pageURL = webView.url, let host = pageURL.host(), ["http", "https"].contains(pageURL.scheme ?? "") else { return }
        let key = Self.key(for: host)
        let file = Self.fileURL(for: key)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < Self.maxAge { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let js = """
        return Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]'))
            .map(l => ({ href: l.href, rel: (l.rel || '').toLowerCase(), sizes: l.getAttribute('sizes') || '', type: l.type || '' }));
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: WebEnvironment.chromeWorld) { [weak self] result in
            let links = (try? result.get()) as? [[String: Any]] ?? []
            let candidates = Self.rank(links, page: pageURL)
            Task { [weak self] in
                await self?.download(candidates, key: key)
            }
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.directory)
        memory.removeAllObjects()
        missing.removeAll()
        revision += 1
    }

    /// apple-touch-icon（通常 180px）> 尺寸最大的 icon > 其他 icon > /favicon.ico；跳过 SVG
    static func rank(_ links: [[String: Any]], page: URL) -> [URL] {
        func size(_ s: String) -> Int {
            s.split(separator: " ").compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
        }
        let scored: [(URL, Int)] = links.compactMap { link in
            guard let href = link["href"] as? String, let url = URL(string: href),
                  ["http", "https"].contains(url.scheme ?? "") else { return nil }
            let rel = link["rel"] as? String ?? ""
            let type = link["type"] as? String ?? ""
            if type.contains("svg") || url.pathExtension.lowercased() == "svg" { return nil }
            let s = size(link["sizes"] as? String ?? "")
            let score = (rel.contains("apple-touch-icon") ? 10_000 : 0) + (s > 0 ? s : 16)
            return (url, score)
        }
        var urls = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { urls.append(fallback) }
        return urls
    }

    private func download(_ candidates: [URL], key: String) async {
        defer { inFlight.remove(key) }
        for url in candidates.prefix(4) {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width >= 8 else { continue }
            let resized = Self.resize(image, to: 64)
            guard let png = resized.pngData() else { continue }
            try? png.write(to: Self.fileURL(for: key), options: .atomic)
            memory.setObject(resized, forKey: key as NSString)
            missing.remove(key)
            revision += 1
            return
        }
    }

    private static func resize(_ image: UIImage, to side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}
