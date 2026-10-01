import Foundation

/// 规则订阅：下载、缓存到 Application Support，ETag 增量更新
struct FilterSubscription: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let detail: String
    let url: URL
    /// 是否允许 trusted-* 脚本规则（只给 uBO 自家列表）
    let trusted: Bool
    var enabled: Bool
    var lastFetched: Date?
    var etag: String?
    var lastModified: String?

    static let catalog: [FilterSubscription] = [
        FilterSubscription(
            id: "easylist", name: "EasyList", detail: "国际通用广告规则",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!, trusted: false, enabled: true),
        FilterSubscription(
            id: "adguard-chinese", name: "AdGuard 中文过滤器", detail: "中文网站广告，已包含 EasyList China",
            url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/224.txt")!, trusted: false, enabled: true),
        FilterSubscription(
            id: "ublock", name: "uBlock filters", detail: "反广告检测、YouTube 等脚本规则",
            url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!, trusted: true, enabled: true),
        FilterSubscription(
            id: "easyprivacy", name: "EasyPrivacy", detail: "拦截跟踪和统计脚本（可能影响少数网站）",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, trusted: false, enabled: false),
    ]
}

enum FilterStorage {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdBlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func listURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).txt") }
    static var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    static var pageDataURL: URL { directory.appendingPathComponent("page-data.json") }
    static var hostsURL: URL { directory.appendingPathComponent("blocked-hosts.txt") }
}

enum FilterDownloader {
    static let updateInterval: TimeInterval = 4 * 24 * 3600

    enum Result {
        case updated(FilterSubscription)
        case unchanged(FilterSubscription)
        case failed(String)
    }

    static func fetch(_ sub: FilterSubscription) async -> Result {
        var request = URLRequest(url: sub.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let hasFile = FileManager.default.fileExists(atPath: FilterStorage.listURL(sub.id).path)
        if hasFile {
            if let etag = sub.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = sub.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("无效响应") }
            var updated = sub
            updated.lastFetched = Date()
            if http.statusCode == 304 { return .unchanged(updated) }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            // 防止把错误页当规则存下来
            let head = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard data.count > 1024, head.hasPrefix("[") || head.hasPrefix("!") else { return .failed("内容不是规则列表") }
            try data.write(to: FilterStorage.listURL(sub.id), options: .atomic)
            updated.etag = http.value(forHTTPHeaderField: "ETag")
            updated.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            return .updated(updated)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
