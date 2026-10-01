import Foundation

/// 地区与语言：让网页按指定地区显示，而不是按 IP 所在地（比如人在泰国，想看新加坡/香港的结果）。
/// 1. 改写 App 的 AppleLanguages，WebKit 据此发送 Accept-Language、设置 navigator.language（对所有网站生效，重启 App 后生效）
/// 2. 搜索引擎、Google、YouTube 的网址补上地区/语言参数（gl / hl 等，立即生效）
enum RegionSettings {
    struct Region: Identifiable, Hashable {
        let code: String     // ISO 3166，如 SG
        let name: String
        var id: String { code }
    }

    static let regions: [Region] = [
        Region(code: "SG", name: "新加坡"), Region(code: "HK", name: "中国香港"), Region(code: "TW", name: "中国台湾"),
        Region(code: "MY", name: "马来西亚"), Region(code: "US", name: "美国"), Region(code: "GB", name: "英国"),
        Region(code: "JP", name: "日本"), Region(code: "TH", name: "泰国"), Region(code: "CN", name: "中国大陆"),
    ]

    /// 网页语言（BCP 47）；空字符串 = 跟随系统
    static let languages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"),
    ]

    static let regionKey = "region.code"
    static let languageKey = "region.language"
    private static let systemLanguagesKey = "region.systemLanguages"

    static var region: String? {
        let v = UserDefaults.standard.string(forKey: regionKey) ?? ""
        return v.isEmpty ? nil : v
    }

    static var language: String? {
        let v = UserDefaults.standard.string(forKey: languageKey) ?? ""
        return v.isEmpty ? nil : v
    }

    static var isActive: Bool { region != nil || language != nil }

    /// 系统原本的语言列表（启动时在覆盖之前记下）
    private static var systemLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: systemLanguagesKey) ?? Locale.preferredLanguages
    }

    /// 实际使用的语言（不带地区），如 zh-Hans
    static var effectiveLanguage: String {
        if let language { return language }
        let first = systemLanguages.first ?? "en"
        let parts = first.split(separator: "-")
        // zh-Hans-TH → zh-Hans；en-TH → en
        if parts.count >= 2, parts[1].count == 4 { return parts[0...1].joined(separator: "-") }
        return String(parts.first ?? "en")
    }

    /// 网页收到的语言偏好，如 ["zh-Hans-SG", "zh-Hans", "en-SG", "en"]
    static var preferredLanguages: [String]? {
        guard isActive else { return nil }
        let lang = effectiveLanguage
        var list: [String] = []
        if let region { list.append("\(lang)-\(region)") }
        list.append(lang)
        if !lang.hasPrefix("en") {
            if let region { list.append("en-\(region)") }
            list.append("en")
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// 必须在创建任何 WKWebView 之前调用（WebKit 启动时读取语言偏好）
    static func applyAtLaunch() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "AppleLanguages")
        defaults.set(Locale.preferredLanguages, forKey: systemLanguagesKey)
        if let langs = preferredLanguages {
            defaults.set(langs, forKey: "AppleLanguages")
        }
    }

    // MARK: - 网址参数

    /// Google 的界面语言
    static var googleHL: String {
        switch effectiveLanguage {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return region == "HK" ? "zh-HK" : "zh-TW"
        default: return effectiveLanguage
        }
    }

    /// DuckDuckGo 的地区代码，如 sg-en、hk-tzh
    static var duckDuckGoRegion: String? {
        guard let region else { return nil }
        let lang = effectiveLanguage
        switch region {
        case "HK", "TW": return "\(region.lowercased())-tzh"
        case "CN": return "cn-zh"
        case "JP": return "jp-jp"
        case "TH": return "th-th"
        case "GB": return "uk-en"
        default: return "\(region.lowercased())-\(lang.hasPrefix("zh") ? "zh" : "en")"
        }
    }

    /// 搜索网址要附加的参数
    static func searchParameters(for engine: SearchEngine) -> [URLQueryItem] {
        guard isActive else { return [] }
        switch engine {
        case .google:
            return [region.map { URLQueryItem(name: "gl", value: $0) }, URLQueryItem(name: "hl", value: googleHL)].compactMap { $0 }
        case .bing:
            return [region.map { URLQueryItem(name: "cc", value: $0) }, URLQueryItem(name: "setlang", value: effectiveLanguage)].compactMap { $0 }
        case .duckDuckGo:
            return [duckDuckGoRegion.map { URLQueryItem(name: "kl", value: $0) }].compactMap { $0 }
        case .baidu:
            return []
        }
    }

    /// 打开 Google / YouTube 时补上地区和语言参数；不需要改写返回 nil
    static func rewrite(_ url: URL) -> URL? {
        guard isActive, let host = url.host()?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let isGoogle = (host.hasPrefix("www.google.") || host.hasPrefix("google.")) &&
            ["/", "/search", "/webhp", "/imghp"].contains(where: { components.path == $0 || ($0 != "/" && components.path.hasPrefix($0)) })
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        guard isGoogle || isYouTube else { return nil }

        var items = components.queryItems ?? []
        var wanted: [URLQueryItem] = []
        if let region { wanted.append(URLQueryItem(name: "gl", value: region)) }
        wanted.append(URLQueryItem(name: "hl", value: googleHL))
        var changed = false
        for item in wanted where !items.contains(where: { $0.name == item.name }) {
            items.append(item)
            changed = true
        }
        guard changed else { return nil }
        components.queryItems = items
        return components.url
    }
}
