import UIKit
import WebKit

final class Tab: NSObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    let isIncognito: Bool
    var snapshot: UIImage?
    var prefersDesktop = false
    /// 用户在这个标签页里手动打开 / 关闭了翻译；nil 时跟随“自动翻译此网站”。导航后保持（和 Chrome 一样）
    var translationOverride: Bool?
    /// 主框架文档的 MIME 类型（记下对应网址：从缓存后退时不会重新收到响应）
    var mainMIME: (url: URL, type: String)?
    /// 用 Aether 页面代替媒体文档显示的文件地址（这次的 text/html 响应不覆盖 mainMIME）
    var mediaPageURL: URL?
    /// 打开视频文件之前所在的页面：退出播放器时回到这里（替换页面后 WebKit 的后退列表里没有它）
    var pageBeforeMedia: URL?
    /// 直接打开的是文件（mp4、pdf 等）而不是网页：⋯ 菜单里提供下载
    var isFileDocument: Bool {
        guard !isBlank, let url = webView.url else { return false }
        if let mainMIME, mainMIME.url == url {
            let mime = mainMIME.type.lowercased()
            return !(mime.hasPrefix("text/") || mime.contains("xhtml") || mime.contains("xml") || mime.contains("json"))
        }
        return Self.fileExtensions.contains(url.pathExtension.lowercased())
    }
    private static let fileExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
        "pdf", "jpg", "jpeg", "png", "gif", "webp", "heic", "zip", "apk", "ipa", "dmg", "epub",
    ]
    var onUpdate: ((Tab) -> Void)?

    /// 恢复会话时不立刻加载，等第一次切到这个标签页再加载
    private var pendingURL: URL?
    private var pendingTitle: String?
    private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView, incognito: Bool, pendingURL: URL? = nil, pendingTitle: String? = nil) {
        self.webView = webView
        self.isIncognito = incognito
        self.pendingURL = pendingURL
        self.pendingTitle = pendingTitle
        super.init()

        observations = [
            observe(\.title), observe(\.url), observe(\.estimatedProgress), observe(\.isLoading),
            observe(\.canGoBack), observe(\.canGoForward), observe(\.hasOnlySecureContent),
            observe(\.themeColor), observe(\.underPageBackgroundColor),
        ]
    }

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            // WKWebView 的 KVO 都在主线程触发
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onUpdate?(self)
            }
        }
    }

    var url: URL? { webView.url ?? pendingURL }

    var isBlank: Bool {
        guard let url else { return true }
        return url.absoluteString == "about:blank"
    }

    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        if let pendingTitle, !pendingTitle.isEmpty { return pendingTitle }
        if let host = url?.host { return host }
        return isIncognito ? L("无痕标签页") : L("新标签页")
    }

    /// 页面期望的状态栏底色：theme-color 优先，其次页面背景色
    /// 页面最顶部实际显示的颜色（aether-chrome.js 采样），导航后清空
    var sampledTopColor: UIColor?

    /// 状态栏底色，顺序和 iOS 26 Safari 一致：页面顶部采样色 → theme-color → 页面背景色
    var chromeColor: UIColor {
        sampledTopColor ?? webView.themeColor ?? webView.underPageBackgroundColor ?? .systemBackground
    }

    func activate() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        pendingURL = nil
        pendingTitle = nil
        webView.load(URLRequest(url: url))
    }
}
