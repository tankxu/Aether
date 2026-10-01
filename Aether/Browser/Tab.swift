import UIKit
import WebKit

final class Tab: NSObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    let isIncognito: Bool
    var snapshot: UIImage?
    var prefersDesktop = false
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
        return isIncognito ? "无痕标签页" : "新标签页"
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
