import UIKit
import WebKit

/// 收藏的网页 = 应用列表里的一个"应用"
struct WebApp: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
}

struct AppFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var apps: [WebApp]
}

enum HomeItem: Codable, Hashable, Identifiable {
    case app(WebApp)
    case folder(AppFolder)

    var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        }
    }

    var title: String {
        switch self {
        case .app(let a): a.title
        case .folder(let f): f.name
        }
    }
}

/// 应用列表：若干屏，每屏最多 capacity 个，存在 Application Support/apps.json
final class AppLibrary {
    static let shared = AppLibrary()
    /// 每屏容量：手机 4 × 5；iPad 30 个，竖屏 6 × 5、横屏 10 × 3（容量不变，转屏不用重新分屏）
    static var capacity: Int { UIDevice.current.userInterfaceIdiom == .pad ? 30 : 20 }

    static func grid(landscape: Bool) -> (columns: Int, rows: Int) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return (4, 5) }
        return landscape ? (10, 3) : (6, 5)
    }

    private(set) var pages: [[HomeItem]] = [[]]
    var onChange: (() -> Void)?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("apps.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([[HomeItem]].self, from: data) {
            pages = Self.normalized(saved)
        } else if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            // 只在尚未保存收藏时初始化；用户主动清空后不再补回。
            commit([[
                .app(WebApp(title: "Google", url: "https://www.google.com/")),
                .app(WebApp(title: "YouTube", url: "https://www.youtube.com/")),
                .app(WebApp(title: "Hacker News", url: "https://news.ycombinator.com/")),
                .app(WebApp(title: "Reddit", url: "https://www.reddit.com/")),
            ]])
        }
    }

    var allApps: [WebApp] {
        pages.flatMap { $0 }.flatMap { item -> [WebApp] in
            switch item {
            case .app(let a): [a]
            case .folder(let f): f.apps
            }
        }
    }

    func contains(url: URL) -> Bool {
        allApps.contains { Self.same($0.url, url.absoluteString) }
    }

    @discardableResult
    func add(title: String, url: URL) -> WebApp {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = WebApp(title: name.isEmpty || name == url.host() ? Self.shortName(declared: [], title: "", host: url.host() ?? "") : name,
                         url: url.absoluteString)
        var p = pages
        if p.isEmpty { p = [[]] }
        p[p.count - 1].append(.app(app))
        commit(p)
        return app
    }

    /// 移除所有指向这个网址的应用
    func remove(url: URL) {
        let removed = allApps.filter { Self.same($0.url, url.absoluteString) }
        let ids = Set(removed.map(\.id))
        commit(pages.map { page in
            page.compactMap { item -> HomeItem? in
                switch item {
                case .app(let a): return ids.contains(a.id) ? nil : item
                case .folder(var f):
                    f.apps.removeAll { ids.contains($0.id) }
                    return .folder(f)
                }
            }
        })
        removed.forEach { AppIconStore.shared.remove($0.id) }
    }

    func remove(id: UUID) {
        var removedApps: [WebApp] = []
        commit(pages.map { page in
            page.compactMap { item -> HomeItem? in
                switch item {
                case .app(let a):
                    if a.id == id { removedApps.append(a); return nil }
                    return item
                case .folder(var f):
                    if f.id == id { removedApps += f.apps; return nil }
                    removedApps += f.apps.filter { $0.id == id }
                    f.apps.removeAll { $0.id == id }
                    return .folder(f)
                }
            }
        })
        removedApps.forEach { AppIconStore.shared.remove($0.id) }
    }

    func rename(_ id: UUID, to title: String) {
        commit(pages.map { page in
            page.map { item in
                switch item {
                case .app(var a) where a.id == id:
                    a.title = title
                    return .app(a)
                case .folder(var f):
                    f.apps = f.apps.map { var a = $0; if a.id == id { a.title = title }; return a }
                    return .folder(f)
                default:
                    return item
                }
            }
        })
    }

    /// 和 iOS“添加到主屏幕”一样取短名：网站声明的应用名 → 站点名 → 从标题里拆出最像站名的一段
    static func shortName(declared: [String], title: String, host: String) -> String {
        if let name = declared.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty && $0.count <= 24 }) {
            return name
        }
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "-|·—–_:：,，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // 主域名那一段：en.wikipedia.org → wikipedia，bbc.co.uk → bbc
        let labels = host.lowercased().split(separator: ".").map(String.init)
        var site = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? host)
        if ["co", "com", "net", "org", "gov", "edu", "ac"].contains(site), labels.count >= 3 { site = labels[labels.count - 3] }
        if let match = parts.first(where: { $0.lowercased().replacingOccurrences(of: " ", with: "").contains(site) }) { return match }
        if parts.count > 1, let shortest = parts.min(by: { $0.count < $1.count }), shortest.count >= 2 { return shortest }
        // 标题为空时用域名主体，首字母大写
        return parts.first ?? (site.prefix(1).uppercased() + site.dropFirst())
    }

    func updateFolder(_ folder: AppFolder) {
        commit(pages.map { page in
            page.map { item in
                if case .folder(let f) = item, f.id == folder.id { return .folder(folder) }
                return item
            }
        })
    }

    /// 拖动结束后整体替换
    func setPages(_ newPages: [[HomeItem]]) {
        commit(newPages)
    }

    private func commit(_ newPages: [[HomeItem]]) {
        pages = Self.normalized(newPages)
        if let data = try? JSONEncoder().encode(pages) { try? data.write(to: Self.fileURL, options: .atomic) }
        onChange?()
    }

    /// 溢出的往后一屏挤、空文件夹解散、空屏移除（至少保留一屏）
    static func normalized(_ input: [[HomeItem]]) -> [[HomeItem]] {
        var pages = input.map { page in
            page.compactMap { item -> HomeItem? in
                if case .folder(let f) = item, f.apps.isEmpty { return nil }
                return item
            }
        }
        var i = 0
        while i < pages.count {
            if pages[i].count > capacity {
                let overflow = Array(pages[i][capacity...])
                pages[i].removeLast(pages[i].count - capacity)
                if i + 1 < pages.count { pages[i + 1].insert(contentsOf: overflow, at: 0) } else { pages.append(overflow) }
            }
            i += 1
        }
        pages.removeAll { $0.isEmpty }
        return pages.isEmpty ? [[]] : pages
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String {
            var t = s
            if t.hasSuffix("/") { t.removeLast() }
            return t.replacingOccurrences(of: "://www.", with: "://")
        }
        return strip(a) == strip(b)
    }
}

// MARK: - 应用图标

/// 应用图标：优先用网站的高清 apple-touch-icon 铺满；只有小图标时放在网站主色底板上；都没有用首字母
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()
    static let side: CGFloat = 180

    @Published private(set) var revision = 0
    private let memory = NSCache<NSString, UIImage>()

    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".png") }

    func image(for app: WebApp) -> UIImage {
        if let image = memory.object(forKey: app.id.uuidString as NSString) { return image }
        if let image = Self.bundledIcon(for: app) {
            memory.setObject(image, forKey: app.id.uuidString as NSString)
            return image
        }
        if let data = try? Data(contentsOf: Self.fileURL(app.id)), let image = UIImage(data: data) {
            memory.setObject(image, forKey: app.id.uuidString as NSString)
            return image
        }
        let letter = Self.letterIcon(for: app)
        memory.setObject(letter, forKey: app.id.uuidString as NSString)
        return letter
    }

    /// 默认站点的官方图标随应用提供，不依赖首启联网或网站的反爬限制。
    private static func bundledIcon(for app: WebApp) -> UIImage? {
        guard let host = URL(string: app.url)?.host()?.lowercased() else { return nil }
        let asset: String
        switch host {
        case "google.com", "www.google.com": asset = "DefaultGoogle"
        case "youtube.com", "www.youtube.com", "m.youtube.com": asset = "DefaultYouTube"
        case "news.ycombinator.com": asset = "DefaultHackerNews"
        case "reddit.com", "www.reddit.com", "m.reddit.com": asset = "DefaultReddit"
        default: return nil
        }
        guard let source = UIImage(named: asset) else { return nil }
        return compose(.init(image: source, kind: asset == "DefaultGoogle" ? .large : .appleTouch,
                             background: .white, name: nil), tint: .clear)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        memory.removeObject(forKey: id.uuidString as NSString)
    }

    /// 添加时从当前页面抓图标（DOM 里的 <link> 和 PWA 清单）
    func fetch(for app: WebApp, webView: WKWebView, tint: UIColor) {
        guard let page = webView.url else { return }
        let js = """
        const meta = (n) => (document.querySelector(`meta[name="${n}"], meta[property="${n}"]`) || {}).content || '';
        const manifest = document.querySelector('link[rel~="manifest"]');
        return {
            links: Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]'))
                .map(l => ({ href: l.href, rel: (l.rel || '').toLowerCase(), sizes: l.getAttribute('sizes') || '', type: l.type || '' })),
            manifest: manifest ? manifest.href : '',
            names: [meta('apple-mobile-web-app-title'), meta('application-name'), meta('og:site_name')],
            title: document.title || ''
        };
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: WebEnvironment.chromeWorld) { [weak self] result in
            let info = (try? result.get()) as? [String: Any] ?? [:]
            let name = AppLibrary.shortName(declared: info["names"] as? [String] ?? [], title: info["title"] as? String ?? app.title,
                                            host: page.host() ?? "")
            if name != app.title { AppLibrary.shared.rename(app.id, to: name) }
            let links: [AppIconFetcher.Link] = (info["links"] as? [[String: Any]] ?? []).compactMap { l in
                guard let href = (l["href"] as? String).flatMap(URL.init(string:)) else { return nil }
                return .init(href: href, rel: l["rel"] as? String ?? "", sizes: l["sizes"] as? String ?? "", type: l["type"] as? String ?? "")
            }
            let manifest = (info["manifest"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            Task { [weak self] in
                guard let result = await AppIconFetcher.fetch(page: page, links: links, manifest: manifest) else { return }
                self?.store(result, for: app, tint: tint)
            }
        }
    }

    /// 没打开网页时重新抓图标（升级图标规则后给已有收藏刷新一次）
    func refresh(_ app: WebApp) {
        guard let page = URL(string: app.url) else { return }
        Task { [weak self] in
            guard let result = await AppIconFetcher.fetch(page: page) else { return }
            self?.store(result, for: app, tint: .clear)
            // 名字还是从域名推出来的默认值时，换成清单里的正式简称（用户改过的名字不动）
            if let name = result.name, app.title == AppLibrary.shortName(declared: [], title: "", host: page.host() ?? "") {
                AppLibrary.shared.rename(app.id, to: name)
            }
        }
    }

    private static let iconRulesVersion = 2
    private static let iconRulesKey = "appIcons.rulesVersion"

    /// 图标规则改过之后，把已有收藏的图标全部重抓一遍
    func refreshAllIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.iconRulesKey) < Self.iconRulesVersion else { return }
        defaults.set(Self.iconRulesVersion, forKey: Self.iconRulesKey)
        AppLibrary.shared.allApps.forEach(refresh)
    }

    private func store(_ result: AppIconFetcher.Result, for app: WebApp, tint: UIColor) {
        let icon = Self.compose(result, tint: tint)
        guard let png = icon.pngData() else { return }
        try? png.write(to: Self.fileURL(app.id), options: .atomic)
        memory.setObject(icon, forKey: app.id.uuidString as NSString)
        revision += 1
    }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    }

    /// 不拉伸：满版图等比铺满（多余的裁掉），透明底 logo 等比缩小居中垫底色，小图标放在主色渐变底板上
    private static func compose(_ result: AppIconFetcher.Result, tint: UIColor) -> UIImage {
        let source = result.image
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let fullBleed = result.kind == .maskable || result.kind == .appleTouch || (result.kind == .large && isOpaqueEdges(source))
        return renderer().image { ctx in
            if fullBleed {
                UIColor.white.setFill()
                ctx.fill(rect)
                source.draw(in: aspectRect(source.size, in: rect, fill: true))
            } else if result.kind == .large {
                // 透明底 logo：清单背景色 → 白底；logo 本身很浅时改用主色底，免得看不见
                let light = (luminance(of: source) ?? 0) > 0.85
                let bg = light ? (usableTint(tint) ?? averageColor(source) ?? UIColor(white: 0.2, alpha: 1)) : (result.background ?? .white)
                bg.setFill()
                ctx.fill(rect)
                source.draw(in: aspectRect(source.size, in: rect.insetBy(dx: side * 0.15, dy: side * 0.15), fill: false))
            } else {
                let base = usableTint(tint) ?? averageColor(source) ?? UIColor(white: 0.95, alpha: 1)
                drawGradient(ctx.cgContext, base: base)
                source.draw(in: aspectRect(source.size, in: rect.insetBy(dx: side * 0.24, dy: side * 0.24), fill: false))
            }
        }
    }

    private static func aspectRect(_ size: CGSize, in rect: CGRect, fill: Bool) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = fill ? max(rect.width / size.width, rect.height / size.height) : min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// 四角和四边中点都不透明：当作满版图标
    private static func isOpaqueEdges(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let points = [(1, 1), (n - 2, 1), (1, n - 2), (n - 2, n - 2), (n / 2, 1), (n / 2, n - 2), (1, n / 2), (n - 2, n / 2)]
        return points.allSatisfy { px[($0.1 * n + $0.0) * 4 + 3] > 230 }
    }

    /// 不透明像素的平均亮度（判断 logo 是不是白色的）
    private static func luminance(of image: UIImage) -> CGFloat? {
        guard let cg = image.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard px[3] > 10 else { return nil }
        let a = CGFloat(px[3])
        return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / a
    }

    static func letterIcon(for app: WebApp) -> UIImage {
        let host = URL(string: app.url)?.host() ?? app.title
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let hue = CGFloat(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
        return renderer().image { ctx in
            drawGradient(ctx.cgContext, base: UIColor(hue: hue, saturation: 0.55, brightness: 0.78, alpha: 1))
            let letter = String((app.title.first ?? name.first ?? "?")).uppercased()
            let font = UIFont.systemFont(ofSize: side * 0.48, weight: .bold)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: UIColor.white]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        }
    }

    private static func drawGradient(_ cg: CGContext, base: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let top = UIColor(hue: h, saturation: s * 0.85, brightness: min(1, b * 1.12 + 0.04), alpha: 1)
        let bottom = UIColor(hue: h, saturation: min(1, s * 1.05), brightness: b * 0.9, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
    }

    /// 网站主色太接近纯白/纯黑时不用（图标会发灰或看不清）
    private static func usableTint(_ c: UIColor) -> UIColor? {
        var white: CGFloat = 0
        c.getWhite(&white, alpha: nil)
        return white > 0.92 || white < 0.06 ? nil : c
    }

    private static func averageColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard px[3] > 20 else { return nil }
        let a = CGFloat(px[3]) / 255
        let color = UIColor(red: CGFloat(px[0]) / 255 / a, green: CGFloat(px[1]) / 255 / a, blue: CGFloat(px[2]) / 255 / a, alpha: 1)
        // 图标平均色常偏灰，提一点饱和度做底板
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return UIColor(hue: h, saturation: min(1, s * 1.3), brightness: max(0.35, min(0.9, b)), alpha: 1)
    }
}
