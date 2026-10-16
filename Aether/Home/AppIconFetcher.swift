import UIKit

/// 给收藏的网站找一个像样的 App 图标。优先级：
/// 1. PWA 清单里的 maskable 图标（为 App 图标设计的满版方图）
/// 2. apple-touch-icon（iOS 主屏幕图标，满版方图）
/// 3. 清单里的普通图标 / 网页里的大图标（常是透明底 logo，要垫底色）
/// 4. 根目录 /apple-touch-icon.png
/// 5. 小 favicon
nonisolated enum AppIconFetcher {
    enum Kind: Int, Comparable {
        case maskable, appleTouch, large, small
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Candidate {
        let url: URL
        let kind: Kind
        let size: Int
    }

    struct Result {
        let image: UIImage
        let kind: Kind
        /// 清单里声明的背景色（透明 logo 垫底用）
        let background: UIColor?
        /// 清单里的 short_name / name
        let name: String?
    }

    /// 网页里的 <link> 信息（来自 DOM 或静态 HTML）
    struct Link {
        let href: URL
        let rel: String
        let sizes: String
        let type: String
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: - 入口

    /// 已有 DOM 里的链接（添加收藏时从网页里取）
    static func fetch(page: URL, links: [Link], manifest: URL?) async -> Result? {
        var candidates = linkCandidates(links)
        var background: UIColor?
        var name: String?
        if let manifest, let info = await loadManifest(manifest) {
            candidates += info.candidates
            background = info.background
            name = info.name
        }
        if let origin = URL(string: "/apple-touch-icon.png", relativeTo: page)?.absoluteURL {
            candidates.append(Candidate(url: origin, kind: .appleTouch, size: 1))
        }
        if let favicon = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            candidates.append(Candidate(url: favicon, kind: .small, size: 0))
        }
        return await download(ranked(candidates), background: background, name: name)
    }

    /// 没有打开网页时：直接请求网站首页，从 HTML 里找
    static func fetch(page: URL) async -> Result? {
        var request = URLRequest(url: page, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let base = response.url ?? page
        let html = String(decoding: data.prefix(600_000), as: UTF8.self)
        let (links, manifest) = parseHead(html, base: base)
        guard let result = await fetch(page: base, links: links, manifest: manifest) else { return nil }
        // 清单里没有名字时，用网页声明的站点名
        if result.name == nil, let declared = declaredName(html) {
            return Result(image: result.image, kind: result.kind, background: result.background, name: declared)
        }
        return result
    }

    /// <meta name="apple-mobile-web-app-title"> / application-name / og:site_name
    private static func declaredName(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        var found: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
            let tag = ns.substring(with: match.range)
            let key = (attribute("name", in: tag) ?? attribute("property", in: tag) ?? "").lowercased()
            guard ["apple-mobile-web-app-title", "application-name", "og:site_name"].contains(key),
                  let content = attribute("content", in: tag)?.trimmingCharacters(in: .whitespaces), !content.isEmpty else { continue }
            if found[key] == nil { found[key] = decodeEntities(content) }
        }
        return ["apple-mobile-web-app-title", "application-name", "og:site_name"].compactMap { found[$0] }.first { $0.count <= 16 }
    }

    // MARK: - 候选

    private static func maxSize(_ sizes: String) -> Int {
        if sizes.lowercased().contains("any") { return 512 }
        return sizes.split(separator: " ").compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
    }

    private static func isSVG(_ url: URL, type: String) -> Bool {
        type.contains("svg") || url.pathExtension.lowercased() == "svg"
    }

    private static func linkCandidates(_ links: [Link]) -> [Candidate] {
        links.compactMap { link in
            guard ["http", "https"].contains(link.href.scheme ?? ""), !isSVG(link.href, type: link.type) else { return nil }
            let size = maxSize(link.sizes)
            if link.rel.contains("apple-touch-icon") { return Candidate(url: link.href, kind: .appleTouch, size: max(size, 120)) }
            if link.rel.contains("icon") { return Candidate(url: link.href, kind: size >= 96 ? .large : .small, size: size) }
            return nil
        }
    }

    private static func ranked(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<URL>()
        return candidates
            .sorted { $0.kind != $1.kind ? $0.kind < $1.kind : $0.size > $1.size }
            .filter { seen.insert($0.url).inserted }
    }

    private static func loadManifest(_ url: URL) async -> (candidates: [Candidate], background: UIColor?, name: String?)? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let icons = json["icons"] as? [[String: Any]] ?? []
        let candidates: [Candidate] = icons.compactMap { icon in
            guard let src = icon["src"] as? String, let iconURL = URL(string: src, relativeTo: url)?.absoluteURL,
                  !isSVG(iconURL, type: icon["type"] as? String ?? "") else { return nil }
            let size = maxSize(icon["sizes"] as? String ?? "")
            let purpose = (icon["purpose"] as? String ?? "any").lowercased()
            // 太小的 maskable 不如 apple-touch-icon 清楚
            if purpose.contains("maskable"), size == 0 || size >= 144 { return Candidate(url: iconURL, kind: .maskable, size: size) }
            return Candidate(url: iconURL, kind: size >= 96 || size == 0 ? .large : .small, size: size)
        }
        let background = (json["background_color"] as? String).flatMap(parseHexColor)
        let name = [json["short_name"], json["name"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count <= 16 }
        return (candidates, background, name)
    }

    // MARK: - 下载

    private static func download(_ candidates: [Candidate], background: UIColor?, name: String?) async -> Result? {
        for candidate in candidates.prefix(8) {
            var request = URLRequest(url: candidate.url, timeoutInterval: 12)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width >= 8 else { continue }
            let pixels = image.size.width * image.scale
            // 声称是大图但实际很小：降级
            var kind = candidate.kind
            if kind != .small && pixels < 96 { kind = .small }
            return Result(image: image, kind: kind, background: background, name: name)
        }
        return nil
    }

    // MARK: - 解析静态 HTML

    static func parseHead(_ html: String, base: URL) -> (links: [Link], manifest: URL?) {
        var links: [Link] = []
        var manifest: URL?
        guard let tagRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return ([], nil) }
        let ns = html as NSString
        for match in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            guard let href = attribute("href", in: tag), let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL else { continue }
            if rel.split(separator: " ").contains("manifest") { manifest = url; continue }
            guard rel.contains("icon") else { continue }
            links.append(Link(href: url, rel: rel, sizes: attribute("sizes", in: tag) ?? "", type: attribute("type", in: tag) ?? ""))
        }
        return (links, manifest)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i))
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#47;", with: "/")
    }

    static func parseHexColor(_ s: String) -> UIColor? {
        var hex = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
