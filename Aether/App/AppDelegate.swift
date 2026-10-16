import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 地区与语言要在创建任何 WKWebView 之前设好
        RegionSettings.applyAtLaunch()
        Settings.registerDefaults()
        DebugLog.trim()
        // 网页视频不受静音键影响，和 Safari 一致
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        ContentBlocker.shared.prepare()
        // 图标规则更新后给已有收藏重新抓一次图标
        AppIconStore.shared.refreshAllIfNeeded()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: BrowserViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let browser = BrowserViewController()
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser

        #if DEBUG
        // 调试入口：-AetherOpenURL <url> 启动即打开指定页面
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-AetherOpenURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            browser.load(url)
        }
        if args.contains("-AetherLandscape") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { browser.debugShow("landscape") }
        }
        if let i = args.firstIndex(of: "-AetherDebugUI"), i + 1 < args.count {
            let what = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { browser.debugShow(what) }
        }
        #endif
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser?.sceneWillResignActive()
        browser?.setPrivacyCover(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        browser?.setPrivacyCover(false)
        browser?.sceneDidBecomeActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browser?.sceneDidEnterBackground()
        browser?.saveSession()
    }
}
