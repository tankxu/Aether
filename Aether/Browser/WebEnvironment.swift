import UIKit
import WebKit

/// 标签页的 WebKit 配置工厂。
/// 普通标签页用默认数据存储；无痕标签页共用一个内存存储，全部关闭后丢弃。
/// 每个标签页有自己的 WKUserContentController，这样广告过滤可以按网站单独开关（白名单）。
/// target=_blank 打开的新标签页沿用打开者的配置，也就共用它的 controller。
final class WebEnvironment {
    static let messageName = "aether"
    static let chromeMessageName = "aetherChrome"
    /// 状态栏取色脚本跑在独立的 world 里，网页脚本碰不到
    static let chromeWorld = WKContentWorld.world(name: "aether-chrome")

    private let playerScript: WKUserScript?
    private let chromeScript: WKUserScript?
    private weak var scriptHandler: WKScriptMessageHandler?
    private var incognitoStore: WKWebsiteDataStore?

    init(scriptHandler: WKScriptMessageHandler) {
        self.scriptHandler = scriptHandler
        if let url = Bundle.main.url(forResource: "aether-player", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            playerScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        } else {
            playerScript = nil
        }
        if let url = Bundle.main.url(forResource: "aether-chrome", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            chromeScript = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.chromeWorld)
        } else {
            chromeScript = nil
        }
    }

    func makeConfiguration(incognito: Bool) -> WKWebViewConfiguration {
        let controller = WKUserContentController()
        if let scriptHandler {
            controller.add(WeakScriptHandler(scriptHandler), contentWorld: .page, name: Self.messageName)
            controller.add(WeakScriptHandler(scriptHandler), contentWorld: ElementPicker.world, name: ElementPicker.messageName)
            controller.add(WeakScriptHandler(scriptHandler), contentWorld: Self.chromeWorld, name: Self.chromeMessageName)
        }
        ContentBlocker.shared.register(controller, baseScripts: [playerScript, chromeScript].compactMap { $0 })

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = incognito ? currentIncognitoStore() : .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.applicationNameForUserAgent = Self.safariUserAgentSuffix
        return config
    }

    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }

    func dropIncognitoStore() {
        incognitoStore = nil
    }

    private func currentIncognitoStore() -> WKWebsiteDataStore {
        if let incognitoStore { return incognitoStore }
        let store = WKWebsiteDataStore.nonPersistent()
        incognitoStore = store
        return store
    }

    /// 让网站把我们当作 Safari（否则部分站点会降级或提示“请用 Safari 打开”）
    private static var safariUserAgentSuffix: String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        return "Version/\(major).0 Mobile/15E148 Safari/604.1"
    }
}

/// WKUserContentController 强引用 handler，用弱代理打破循环
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
