import UIKit

/// 全屏播放时控制层所在的独立窗口，盖在浏览器和 WebKit 元素全屏窗口之上。
/// 由它决定状态栏、Home 条和屏幕方向——WebKit 全屏窗口自带的那一套不受我们控制。
final class PlayerWindow: UIWindow {
    let host = PlayerHostController()

    init(scene: UIWindowScene, overlay: PlayerOverlayView) {
        super.init(windowScene: scene)
        windowLevel = .normal + 10
        backgroundColor = .clear
        rootViewController = host
        overlay.frame = host.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(overlay)
        isHidden = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class PlayerHostController: UIViewController {
    var orientations: () -> UIInterfaceOrientationMask = { .allButUpsideDown }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientations() }
}
