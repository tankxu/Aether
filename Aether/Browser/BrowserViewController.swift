import SwiftUI
import UIKit
import WebKit

final class BrowserViewController: UIViewController {
    private var environment: WebEnvironment!
    private var tabManager: TabManager!

    private let statusBackdrop = UIView()
    private let webContainer = UIView()
    private let loadingBar = LoadingBarView()
    private let startView = StartView()
    private let toolbar = BottomToolbarView()
    private let handle = EdgeHandleView()
    private var addressInput: AddressInputView?
    private var addressCatcher: UIControl?
    private var privacyCover: UIView?

    private var webTopToSafeArea: NSLayoutConstraint!
    private var webTopToView: NSLayoutConstraint!
    private var toolbarExpanded = false

    private var player: PlayerSession?
    /// 地区参数改写的防循环记录：网站跳转时去掉参数的话，不反复改写
    private var lastRegionRewrite: [ObjectIdentifier: (url: String, date: Date)] = [:]
    private var picker: ElementPicker?
    private var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    private var current: Tab? { tabManager.selected }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        environment = WebEnvironment(scriptHandler: self)
        tabManager = TabManager(environment: environment)
        tabManager.delegate = self
        setUpViews()

        tabManager.restoreSession()
        if current == nil { openNewTab(incognito: false, focusAddress: false) }
    }

    private func setUpViews() {
        for v in [statusBackdrop, webContainer, startView, loadingBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        webTopToSafeArea = webContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        webTopToView = webContainer.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            statusBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            statusBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            webTopToSafeArea,
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 首页背景铺到状态栏下面
            startView.topAnchor.constraint(equalTo: view.topAnchor),
            startView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            startView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            startView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            loadingBar.topAnchor.constraint(equalTo: webContainer.topAnchor),
            loadingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        startView.onSearch = { [weak self] in self?.showAddressInput() }
        startView.onModeChange = { [weak self] incognito in self?.switchStartMode(incognito: incognito) }
        startView.onHistory = { [weak self] in self?.showHistory() }

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        let fullWidth = toolbar.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        fullWidth.priority = .defaultHigh
        let onSafeBottom = toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2)
        onSafeBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            fullWidth,
            toolbar.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            toolbar.heightAnchor.constraint(equalToConstant: BottomToolbarView.height),
            onSafeBottom,
            toolbar.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
        ])
        toolbar.onBack = { [weak self] in
            guard let webView = self?.current?.webView else { return }
            if webView.canGoBack { webView.goBack() } else { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5) }
        }
        toolbar.onAddress = { [weak self] in self?.showAddressInput() }
        toolbar.onReload = { [weak self] in
            guard let webView = self?.current?.webView else { return }
            if webView.isLoading { webView.stopLoading() } else { webView.reload() }
        }
        toolbar.onTabs = { [weak self] in self?.showTabs() }
        toolbar.onSwitchTab = { [weak self] offset in self?.switchTab(by: offset) }
        toolbar.onCollapse = { [weak self] in self?.setToolbar(expanded: false) }
        toolbar.menuProvider = { [weak self] in self?.toolbarMenu() ?? [] }
        toolbar.backMenuProvider = { [weak self] in self?.backHistoryMenu() ?? [] }

        handle.onTap = { [weak self] in self?.setToolbar(expanded: true) }
        handle.onDrop = { [weak self] side, y in self?.handleDropped(side: side, y: y) }
        view.addSubview(handle)

        setToolbar(expanded: false, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHandle(animated: false)
    }

    // MARK: - 状态栏 / 方向

    override var prefersStatusBarHidden: Bool { player != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { player != nil }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { player != nil ? .all : [] }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let tab = current else { return .default }
        if tab.isBlank { return .lightContent }
        let color = statusBackdrop.backgroundColor?.resolvedColor(with: traitCollection) ?? .systemBackground
        var white: CGFloat = 1
        color.getWhite(&white, alpha: nil)
        return white > 0.6 ? .darkContent : .lightContent
    }

    private func updateSystemChrome() {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    private var interfaceIsLandscape: Bool {
        view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    private func setOrientation(_ mask: UIInterfaceOrientationMask, request: UIInterfaceOrientationMask?) {
        orientationMask = mask
        setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let request, let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: request)) { error in
            print("[Aether] 旋转失败: \(error)")
        }
    }

    // MARK: - 工具栏与竖线

    private func setToolbar(expanded: Bool, animated: Bool = true) {
        toolbarExpanded = expanded
        toolbar.isUserInteractionEnabled = expanded
        handle.isUserInteractionEnabled = !expanded
        if expanded { updateChrome() }
        let changes = {
            self.toolbar.alpha = expanded ? 1 : 0
            self.toolbar.transform = expanded ? .identity : CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.96, y: 0.96)
            self.handle.alpha = expanded ? 0 : 1
        }
        if animated {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
    }

    private func layoutHandle(animated: Bool) {
        guard !handle.isDragging else { return }
        let size = EdgeHandleView.size
        let guide = view.safeAreaLayoutGuide.layoutFrame
        let minY = guide.minY + size.height / 2
        let maxY = guide.maxY - size.height / 2 - 8
        let y = min(max(guide.minY + guide.height * Settings.handleY, minY), max(minY, maxY))
        handle.side = Settings.handleSide
        let x = Settings.handleSide == .left ? size.width / 2 : view.bounds.width - size.width / 2
        let apply = { self.handle.bounds = CGRect(origin: .zero, size: size); self.handle.center = CGPoint(x: x, y: y) }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3, animations: apply)
        } else {
            apply()
        }
    }

    private func handleDropped(side: Side, y: CGFloat) {
        let guide = view.safeAreaLayoutGuide.layoutFrame
        Settings.handleSide = side
        Settings.handleY = guide.height > 0 ? Double((y - guide.minY) / guide.height).clamped01 : 0.72
        layoutHandle(animated: true)
    }

    private func updateChrome() {
        let tab = current
        let incognito = tab?.isIncognito ?? false
        toolbar.update(tab: tab, tabCount: tabManager.tabs(incognito: incognito).count)
        handle.isIncognito = incognito || (tab?.isBlank ?? true)
        startView.setIncognito(incognito)
        startView.isHidden = !(tab?.isBlank ?? true) || player != nil
        loadingBar.set(progress: tab?.webView.estimatedProgress ?? 0, loading: tab?.webView.isLoading ?? false)
        if let tab, !tab.isBlank {
            statusBackdrop.backgroundColor = tab.chromeColor
        } else {
            statusBackdrop.backgroundColor = .black
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    /// ⋯ 菜单，分组顺序参照 Safari
    private func toolbarMenu() -> [UIMenuElement] {
        guard let tab = current else { return [] }
        let webView = tab.webView
        var groups: [UIMenu] = []

        // 菜单最下面一排小按钮：分享、查找、所有标签页（最右）
        let count = tabManager.tabs(incognito: tab.isIncognito).count
        var quickItems: [UIMenuElement] = []
        if let url = tab.url, !tab.isBlank {
            quickItems.append(UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(url)
            })
            quickItems.append(UIAction(title: "查找", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                self?.setToolbar(expanded: false)
                webView.findInteraction?.presentFindNavigator(showingReplace: false)
            })
        }
        quickItems.append(UIAction(title: "标签页（\(count)）", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            self?.showTabs()
        })
        let quick = UIMenu(options: .displayInline, children: quickItems)
        quick.preferredElementSize = .medium
        groups.append(quick)

        if webView.canGoForward {
            groups.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "前进", image: UIImage(systemName: "chevron.forward")) { _ in webView.goForward() },
            ]))
        }

        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "新建标签页", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.openNewTab(incognito: false, focusAddress: true)
            },
            UIAction(title: "新建无痕标签页", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                self?.openNewTab(incognito: true, focusAddress: true)
            },
            UIAction(title: "历史记录", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
                self?.showHistory()
            },
        ]))

        var page: [UIMenuElement] = []
        if !tab.isBlank {
            page.append(UIAction(
                title: tab.prefersDesktop ? "请求移动版网站" : "请求桌面版网站",
                image: UIImage(systemName: tab.prefersDesktop ? "iphone" : "desktopcomputer")
            ) { _ in
                tab.prefersDesktop.toggle()
                webView.reloadFromOrigin()
            })
        }
        if !tab.isBlank, let host = tab.url?.host() {
            let blocked = AppLinkPolicy.isBlocked(host)
            page.append(UIAction(title: "在此网站禁止跳转 App", image: UIImage(systemName: "arrow.up.forward.app"), state: blocked ? .on : .off) { _ in
                AppLinkPolicy.setBlocked(host, !blocked)
            })
        }
        let blocker = ContentBlocker.shared
        let adBlockOn = blocker.isEnabled
        page.append(UIAction(title: "广告过滤", image: UIImage(systemName: "shield.lefthalf.filled"), state: adBlockOn ? .on : .off) { _ in
            blocker.setEnabled(!adBlockOn)
            if !tab.isBlank { webView.reload() }
        })
        if adBlockOn, !tab.isBlank, let host = tab.url?.host() {
            let whitelisted = blocker.isWhitelisted(host)
            page.append(UIAction(title: "在此网站停用广告过滤", image: UIImage(systemName: "shield.slash"), state: whitelisted ? .on : .off) { _ in
                blocker.setWhitelisted(host, !whitelisted)
                webView.reload()
            })
            if !whitelisted {
                page.append(UIAction(title: "屏蔽页面元素", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                    self?.startPicker()
                })
            }
        }
        page.append(UIAction(title: "设置", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.showSettings()
        })
        groups.append(UIMenu(options: .displayInline, children: page))
        return groups
    }

    /// 长按后退按钮：后退历史
    private func backHistoryMenu() -> [UIMenuElement] {
        guard let webView = current?.webView else { return [] }
        return webView.backForwardList.backList.reversed().prefix(15).map { item in
            UIAction(title: item.title?.isEmpty == false ? item.title! : item.url.host() ?? item.url.absoluteString,
                     subtitle: item.url.host()) { _ in
                webView.go(to: item)
            }
        }
    }

    /// 在地址胶囊上左右滑：切到同模式的相邻标签页
    private func switchTab(by offset: Int) {
        guard let tab = current else { return }
        let tabs = tabManager.tabs(incognito: tab.isIncognito)
        guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + offset) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        tabManager.select(tabs[index + offset])
    }

    // MARK: - 导航

    func load(_ url: URL) {
        loadViewIfNeeded()
        if let tab = current {
            tab.load(url)
        } else {
            tabManager.open(url: url, incognito: false)
        }
        setToolbar(expanded: false)
    }

    /// 首页底部切换标准/无痕：空白标签页换成另一种模式的空白标签页
    private func switchStartMode(incognito: Bool) {
        guard let tab = current, tab.isBlank, tab.isIncognito != incognito else { return }
        UIView.transition(with: view, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            if let existing = self.tabManager.tabs(incognito: incognito).first(where: \.isBlank) {
                self.tabManager.select(existing)
            } else {
                self.tabManager.open(url: nil, incognito: incognito)
            }
            self.tabManager.close(tab)
        }
    }

    private func openNewTab(incognito: Bool, focusAddress: Bool) {
        tabManager.open(url: nil, incognito: incognito)
        setToolbar(expanded: false)
        if focusAddress { showAddressInput() }
    }

    private func tab(for webView: WKWebView) -> Tab? {
        tabManager.tabs.first { $0.webView === webView }
    }

    private func showAddressInput() {
        guard addressInput == nil, player == nil else { return }
        setToolbar(expanded: false)

        let catcher = UIControl(frame: view.bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        catcher.alpha = 0
        catcher.addAction(UIAction { [weak self] _ in self?.hideAddressInput() }, for: .touchUpInside)
        view.addSubview(catcher)

        let input = AddressInputView()
        input.setIncognito(current?.isIncognito ?? false || current?.isBlank ?? true)
        input.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            input.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        input.onCancel = { [weak self] in self?.hideAddressInput() }
        input.onSubmit = { [weak self] text in
            guard let url = URLResolver.resolve(text) else { return }
            self?.hideAddressInput()
            self?.load(url)
        }
        if let tab = current, !tab.isBlank { input.field.text = tab.url?.absoluteString }
        addressInput = input
        addressCatcher = catcher
        startView.isSearchButtonHidden = true
        input.field.becomeFirstResponder()
        UIView.animate(withDuration: 0.2) {
            catcher.alpha = 1
            self.handle.alpha = 0
        }
    }

    private func hideAddressInput() {
        guard let input = addressInput else { return }
        let catcher = addressCatcher
        addressInput = nil
        addressCatcher = nil
        startView.isSearchButtonHidden = false
        input.field.resignFirstResponder()
        UIView.animate(withDuration: 0.2, animations: {
            input.alpha = 0
            catcher?.alpha = 0
            if !self.toolbarExpanded { self.handle.alpha = 1 }
        }, completion: { _ in
            input.removeFromSuperview()
            catcher?.removeFromSuperview()
        })
    }

    private func showTabs() {
        setToolbar(expanded: false)
        let present = { [weak self] in
            guard let self else { return }
            let tabsView = TabsView(
                manager: tabManager,
                incognito: current?.isIncognito ?? false,
                onSelect: { [weak self] tab in
                    self?.tabManager.select(tab)
                    self?.dismiss(animated: true)
                },
                onNew: { [weak self] incognito in
                    self?.dismiss(animated: true) {
                        self?.openNewTab(incognito: incognito, focusAddress: true)
                    }
                },
                onClose: { [weak self] tab in self?.tabManager.close(tab) },
                onDone: { [weak self] in
                    guard let self else { return }
                    dismiss(animated: true)
                    if current == nil { openNewTab(incognito: false, focusAddress: false) }
                }
            )
            let host = UIHostingController(rootView: tabsView)
            host.modalPresentationStyle = .fullScreen
            self.present(host, animated: true)
        }
        if let tab = current, !tab.isBlank {
            tab.webView.takeSnapshot(with: nil) { image, _ in
                tab.snapshot = image
                present()
            }
        } else {
            present()
        }
    }

    private func showHistory() {
        setToolbar(expanded: false)
        let history = HistoryView(onOpen: { [weak self] url in self?.load(url) })
        present(UIHostingController(rootView: history), animated: true)
    }

    private func showSettings() {
        setToolbar(expanded: false)
        let settings = SettingsView(
            onAdBlockChange: { [weak self] in
                if let tab = self?.current, !tab.isBlank { tab.webView.reload() }
            },
            onClearData: {
                HistoryStore.shared.clear()
                FaviconStore.shared.clear()
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
                ) {}
            }
        )
        present(UIHostingController(rootView: settings), animated: true)
    }

    private func share(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = toolbar
        present(vc, animated: true)
    }

    private var topPresenter: UIViewController {
        var vc: UIViewController = self
        while let next = vc.presentedViewController { vc = next }
        return vc
    }

    #if DEBUG
    /// 调试截图用：-AetherDebugUI toolbar|address
    func debugShow(_ what: String) {
        print("[Aether] debugShow \(what) current=\(current?.url?.absoluteString ?? "nil") tabs=\(tabManager.tabs.count)")
        switch what {
        case "toolbar": setToolbar(expanded: true)
        case "address": showAddressInput()
        case "incognito": openNewTab(incognito: true, focusAddress: true)
        case "newtab": openNewTab(incognito: false, focusAddress: false)
        case "newtab-incognito": openNewTab(incognito: true, focusAddress: false)
        case "picker": startPicker()
        case "history": showHistory()
        case "whitelist":
            if let tab = current, let host = tab.url?.host() {
                ContentBlocker.shared.setWhitelisted(host, true)
                tab.webView.reload()
            }
        default: break
        }
    }
    #endif

    // MARK: - 手动屏蔽元素

    private func startPicker() {
        guard picker == nil, player == nil, let tab = current, let host = tab.url?.host() else { return }
        setToolbar(expanded: false)
        let picker = ElementPicker(webView: tab.webView, host: host)
        picker.onFinish = { [weak self] in self?.finishPicker() }
        let bar = picker.bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
        ])
        handle.isHidden = true
        self.picker = picker
        picker.start()
        bar.alpha = 0
        bar.transform = CGAffineTransform(translationX: 0, y: 30)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3) {
            bar.alpha = 1
            bar.transform = .identity
        }
    }

    private func finishPicker() {
        guard let picker else { return }
        self.picker = nil
        handle.isHidden = player != nil
        UIView.animate(withDuration: 0.2, animations: {
            picker.bar.alpha = 0
            picker.bar.transform = CGAffineTransform(translationX: 0, y: 30)
        }, completion: { _ in picker.bar.removeFromSuperview() })
    }

    // MARK: - 会话 / 隐私

    func saveSession() {
        tabManager.saveSession()
    }

    /// 切到后台时遮住无痕页面，避免出现在多任务快照里
    func setPrivacyCover(_ on: Bool) {
        if on, current?.isIncognito == true, privacyCover == nil {
            let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            cover.frame = view.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(cover)
            privacyCover = cover
        } else if !on {
            privacyCover?.removeFromSuperview()
            privacyCover = nil
        }
    }

    // MARK: - 全屏视频

    private final class PlayerSession {
        let webView: WKWebView
        var frame: WKFrameInfo
        let overlay: PlayerOverlayView
        let wasLandscape: Bool
        var orientationDecided = false

        init(webView: WKWebView, frame: WKFrameInfo, overlay: PlayerOverlayView, wasLandscape: Bool) {
            self.webView = webView
            self.frame = frame
            self.overlay = overlay
            self.wasLandscape = wasLandscape
        }
    }

    private func enterPlayer(webView: WKWebView, frame: WKFrameInfo, state: PlayerState) {
        guard webView === current?.webView, presentedViewController == nil else {
            webView.callAsyncJavaScript("window.__aether && window.__aether.cmd(c)", arguments: ["c": PlayerCommand.exit.payload],
                                        in: frame, in: .page, completionHandler: nil)
            return
        }
        if let player {
            player.frame = frame
            player.overlay.update(state)
            return
        }
        hideAddressInput()
        setToolbar(expanded: false, animated: false)
        webView.scrollView.setZoomScale(webView.scrollView.minimumZoomScale, animated: false)

        let overlay = PlayerOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onCommand = { [weak self] in self?.sendPlayerCommand($0) }
        overlay.onExit = { [weak self] in self?.exitPlayer(notifyPage: true) }
        overlay.onRotate = { [weak self] in self?.rotatePlayer() }
        view.addSubview(overlay)

        player = PlayerSession(webView: webView, frame: frame, overlay: overlay, wasLandscape: interfaceIsLandscape)
        view.backgroundColor = .black
        for v in [statusBackdrop, loadingBar, startView, toolbar, handle] as [UIView] { v.isHidden = true }
        webTopToSafeArea.isActive = false
        webTopToView.isActive = true
        updateSystemChrome()
        overlay.update(state)
        decidePlayerOrientation(state)
    }

    private func updatePlayer(webView: WKWebView, state: PlayerState) {
        guard let player, player.webView === webView else { return }
        player.overlay.update(state)
        decidePlayerOrientation(state)
    }

    /// 拿到视频尺寸后决定一次横竖屏
    private func decidePlayerOrientation(_ state: PlayerState) {
        guard let player, !player.orientationDecided, state.videoWidth > 0, state.videoHeight > 0 else { return }
        player.orientationDecided = true
        guard Settings.autoRotate else { return }
        if state.videoWidth > state.videoHeight * 1.05 {
            setOrientation(.landscape, request: .landscape)
        } else if state.videoHeight > state.videoWidth {
            setOrientation(.portrait, request: .portrait)
        }
    }

    private func rotatePlayer() {
        let target: UIInterfaceOrientationMask = interfaceIsLandscape ? .portrait : .landscape
        setOrientation(target, request: target)
    }

    private func sendPlayerCommand(_ command: PlayerCommand) {
        guard let player else { return }
        player.webView.callAsyncJavaScript("window.__aether && window.__aether.cmd(c)", arguments: ["c": command.payload],
                                           in: player.frame, in: .page, completionHandler: nil)
    }

    private func exitPlayer(notifyPage: Bool) {
        guard let player else { return }
        if notifyPage {
            sendPlayerCommand(.exit)
            // 嵌套 iframe 时父页面也铺满了承载它的 iframe，一并还原
            player.webView.callAsyncJavaScript("window.__aether && window.__aether.clear()", arguments: [:],
                                               in: nil, in: .page, completionHandler: nil)
        }
        self.player = nil
        player.overlay.removeFromSuperview()

        view.backgroundColor = .systemBackground
        for v in [statusBackdrop, loadingBar, toolbar, handle] as [UIView] { v.isHidden = false }
        webTopToView.isActive = false
        webTopToSafeArea.isActive = true
        updateChrome()
        updateSystemChrome()
        setOrientation(.allButUpsideDown, request: !player.wasLandscape && interfaceIsLandscape ? .portrait : nil)
    }

    // MARK: - 外部链接

    private func confirmOpenExternal(_ url: URL) {
        guard topPresenter === self else { return }
        let alert = UIAlertController(title: "在其他 App 中打开？", message: url.scheme.map { "\($0)://" }, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "打开", style: .default) { _ in
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }
}

// MARK: - TabManagerDelegate

extension BrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didCreate tab: Tab) {
        let webView = tab.webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 工具栏展开时：页面上的滑动、点击照常交给网页，同时收起工具栏
        for recognizer in [UIPanGestureRecognizer(), UITapGestureRecognizer()] as [UIGestureRecognizer] {
            recognizer.addTarget(self, action: #selector(pageTouched(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = self
            webView.addGestureRecognizer(recognizer)
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak webView] _ in webView?.reload() }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?) {
        if player != nil { exitPlayer(notifyPage: true) }
        picker?.cancel()
        previous?.webView.removeFromSuperview()
        if let webView = tab?.webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
        }
        updateChrome()
    }

    func tabManager(_ manager: TabManager, didUpdate tab: Tab) {
        if tab === current { updateChrome() }
        if !tab.isIncognito { HistoryStore.shared.updateTitle(url: tab.webView.url, title: tab.webView.title) }
    }
}

// MARK: - 页面手势（收起工具栏）

extension BrowserViewController: UIGestureRecognizerDelegate {
    @objc fileprivate func pageTouched(_ recognizer: UIGestureRecognizer) {
        guard toolbarExpanded else { return }
        if recognizer is UIPanGestureRecognizer, recognizer.state != .began { return }
        setToolbar(expanded: false)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        toolbarExpanded
    }
}

// MARK: - 视频脚本消息

extension BrowserViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == WebEnvironment.chromeMessageName {
            guard let body = message.body as? [String: Any], let webView = message.webView, let tab = tab(for: webView) else { return }
            func c(_ k: String) -> CGFloat { CGFloat((body[k] as? NSNumber)?.doubleValue ?? 255) / 255 }
            tab.sampledTopColor = UIColor(red: c("r"), green: c("g"), blue: c("b"), alpha: 1)
            if tab === current { updateChrome() }
            return
        }
        if message.name == ElementPicker.messageName {
            if let body = message.body as? [String: Any], message.webView === picker?.webView { picker?.handle(body) }
            return
        }
        guard message.name == WebEnvironment.messageName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let webView = message.webView else { return }
        switch type {
        case "enter":
            enterPlayer(webView: webView, frame: message.frameInfo, state: PlayerState(body))
        case "state":
            updatePlayer(webView: webView, state: PlayerState(body))
        case "exit":
            if player?.webView === webView { exitPlayer(notifyPage: false) }
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let tab = tab(for: webView) {
            preferences.preferredContentMode = tab.prefersDesktop ? .desktop : .mobile
        }
        // 主框架导航前按目标网站切换广告过滤（白名单）
        if navigationAction.targetFrame?.isMainFrame ?? true {
            ContentBlocker.shared.prepare(webView.configuration.userContentController, for: navigationAction.request.url)
            // Google / YouTube 补上地区和语言参数
            if navigationAction.request.httpMethod ?? "GET" == "GET", let url = navigationAction.request.url,
               let rewritten = RegionSettings.rewrite(url) {
                let key = ObjectIdentifier(webView)
                let recent = lastRegionRewrite[key].map { $0.url == url.absoluteString && Date().timeIntervalSince($0.date) < 5 } ?? false
                if !recent {
                    lastRegionRewrite[key] = (url.absoluteString, Date())
                    webView.load(URLRequest(url: rewritten))
                    return (.cancel, preferences)
                }
            }
        }
        // 当前网站或目标网站设置了禁止跳转 App
        let appLinksBlocked = AppLinkPolicy.isBlocked(webView.url?.host()) || AppLinkPolicy.isBlocked(navigationAction.request.url?.host())
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
              !Self.webSchemes.contains(scheme) else {
            // 通用链接（如 youtube.com）默认会被系统交给对应 App 打开；
            // WebKit 的 allow + 2 是“允许加载但不尝试打开 App”（Firefox iOS 也用这个值）
            if appLinksBlocked, let stayInBrowser = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) {
                return (stayInBrowser, preferences)
            }
            return (.allow, preferences)
        }
        // 唤起其他 App：只响应用户点击，并且先确认（屏蔽页面加载时自动跳 App）
        if navigationAction.navigationType == .linkActivated, !appLinksBlocked {
            confirmOpenExternal(url)
        }
        return (.cancel, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab(for: webView)?.sampledTopColor = nil
        if player?.webView === webView { exitPlayer(notifyPage: false) }
        if picker?.webView === webView { picker?.cancel() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        if let tab = tab(for: webView), !tab.isIncognito, let url = webView.url {
            HistoryStore.shared.record(url: url, title: webView.title)
            FaviconStore.shared.fetch(for: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if player?.webView === webView { exitPlayer(notifyPage: false) }
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard player == nil,
              !ContentBlocker.shared.shouldBlockPopup(to: navigationAction.request.url, from: webView.configuration.userContentController)
        else { return nil }
        let opener = tab(for: webView)
        let tab = tabManager.open(url: nil, incognito: opener?.isIncognito ?? false, configuration: configuration, after: opener)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        tabManager.close(tab)
        if current == nil { openNewTab(incognito: false, focusAddress: false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in done.resume() })
            topPresenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in done.resume(returning: true) })
            topPresenter.present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in
                done.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            topPresenter.present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else { return nil }
        let incognito = tab(for: webView)?.isIncognito ?? false
        let opener = tab(for: webView)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "在新标签页打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                self?.tabManager.open(url: url, incognito: incognito, after: opener)
            }
            let background = UIAction(title: "在后台打开", image: UIImage(systemName: "square.stack")) { _ in
                self?.tabManager.open(url: url, incognito: incognito, after: opener, select: false)
                self?.updateChrome()
            }
            let private_ = UIAction(title: "在无痕标签页打开", image: UIImage(systemName: "eyeglasses")) { _ in
                self?.tabManager.open(url: url, incognito: true)
            }
            let copy = UIAction(title: "拷贝链接", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            }
            let share = UIAction(title: "分享…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.share(url)
            }
            return UIMenu(title: url.absoluteString, children: [
                UIMenu(options: .displayInline, children: incognito ? [open, background] : [open, background, private_]),
                UIMenu(options: .displayInline, children: [copy, share]),
            ])
        }
    }
}
