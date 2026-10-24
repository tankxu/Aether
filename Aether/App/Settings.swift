import Foundation

enum Side: String {
    case left, right
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, bing, baidu, duckDuckGo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .baidu: L("百度")
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    func searchURL(for query: String) -> URL? {
        let (base, key): (String, String) = switch self {
        case .google: ("https://www.google.com/search", "q")
        case .bing: ("https://www.bing.com/search", "q")
        case .baidu: ("https://www.baidu.com/s", "wd")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        }
        // URLComponents 不会转义 "+"，搜 "c++" 会变成 "c  "
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        // 设置了地区/语言时附加 gl、hl 等参数
        let extra = RegionSettings.searchParameters(for: self)
            .compactMap { item in item.value.map { "&\(item.name)=\($0)" } }
            .joined()
        return URL(string: "\(base)?\(key)=\(encoded)\(extra)")
    }
}

enum SettingsKey {
    static let searchEngine = "searchEngine"
    static let adBlock = "adBlockEnabled"
    static let autoRotate = "autoRotate"
    static let alwaysShowProgress = "alwaysShowProgress"
    static let railSide = "playerRailSide"
    static let autoPiP = "autoPictureInPicture"
    static let handleSide = "handleSide"
    static let handleY = "handleY"
}

enum Settings {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.searchEngine: SearchEngine.google.rawValue,
            SettingsKey.adBlock: true,
            SettingsKey.autoRotate: true,
            SettingsKey.alwaysShowProgress: false,
            SettingsKey.railSide: Side.right.rawValue,
            SettingsKey.autoPiP: true,
            SettingsKey.handleSide: Side.right.rawValue,
            SettingsKey.handleY: 0.72,
        ])
    }

    static var searchEngine: SearchEngine {
        SearchEngine(rawValue: defaults.string(forKey: SettingsKey.searchEngine) ?? "") ?? .google
    }

    static var adBlockEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.adBlock) }
        set { defaults.set(newValue, forKey: SettingsKey.adBlock) }
    }

    static var autoRotate: Bool { defaults.bool(forKey: SettingsKey.autoRotate) }

    /// 全屏播放时离开 App 自动进入画中画
    static var autoPiP: Bool {
        get { defaults.bool(forKey: SettingsKey.autoPiP) }
        set { defaults.set(newValue, forKey: SettingsKey.autoPiP) }
    }

    static var alwaysShowProgress: Bool {
        get { defaults.bool(forKey: SettingsKey.alwaysShowProgress) }
        set { defaults.set(newValue, forKey: SettingsKey.alwaysShowProgress) }
    }

    static var railSide: Side {
        get { Side(rawValue: defaults.string(forKey: SettingsKey.railSide) ?? "") ?? .right }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.railSide) }
    }

    static var handleSide: Side {
        get { Side(rawValue: defaults.string(forKey: SettingsKey.handleSide) ?? "") ?? .right }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.handleSide) }
    }

    /// 边缘竖线在安全区内的纵向位置（0 顶部 … 1 底部）
    static var handleY: Double {
        get { defaults.double(forKey: SettingsKey.handleY) }
        set { defaults.set(newValue, forKey: SettingsKey.handleY) }
    }
}

/// 按网站禁止跳转其他 App（通用链接 + 自定义 scheme）
enum AppLinkPolicy {
    private static let key = "appLinks.blockedHosts"

    static var blockedHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    /// www. / m. 前缀不区分
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        for prefix in ["www.", "m."] where h.hasPrefix(prefix) { h.removeFirst(prefix.count) }
        return h
    }

    static func isBlocked(_ host: String?) -> Bool {
        guard let host else { return false }
        let h = host.lowercased()
        return blockedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func setBlocked(_ host: String, _ blocked: Bool) {
        let h = normalize(host)
        if blocked { blockedHosts.append(h) } else { blockedHosts.removeAll { $0 == h } }
    }
}

/// 按网站禁止自动弹出新标签页（window.open、target="_blank"）
enum PopupPolicy {
    private static let key = "popups.blockedHosts"

    static var blockedHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    static func isBlocked(_ host: String?) -> Bool {
        guard let host else { return false }
        let h = host.lowercased()
        return blockedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func setBlocked(_ host: String, _ blocked: Bool) {
        let h = AppLinkPolicy.normalize(host)
        if blocked { blockedHosts.append(h) } else { blockedHosts.removeAll { $0 == h } }
    }
}

enum URLResolver {
    /// 地址栏输入 → 网址；不像网址的按搜索处理
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if (scheme == "http" || scheme == "https"), url.host != nil { return url }
            if scheme == "about" { return url }
        }

        if !text.contains(" ") {
            let lower = text.lowercased()
            if lower.hasPrefix("localhost") || isIPv4Host(lower) {
                return URL(string: "http://" + text)
            }
            if let url = URL(string: "https://" + text), let host = url.host, looksLikeDomain(host) {
                return url
            }
        }
        return Settings.searchEngine.searchURL(for: text)
    }

    private static func looksLikeDomain(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), let tld = parts.last else { return false }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    private static func isIPv4Host(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map { $0.split(separator: ":").first ?? $0 } ?? ""
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
