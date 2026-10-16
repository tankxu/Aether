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
    /// 地址输入时铺在背后的一页：收藏 + 历史记录（学 Safari）
    private var addressBackdrop: UIViewController?
    private var privacyCover: UIView?

    private var webTopToSafeArea: NSLayoutConstraint!
    private var webTopToView: NSLayoutConstraint!
    private var toolbarMaxWidth: NSLayoutConstraint!
    /// 竖屏工具栏居中；横屏同样的布局靠到竖线那一侧（不进两侧安全区）
    private var toolbarCenter: NSLayoutConstraint!
    private var toolbarLeading: NSLayoutConstraint!
    private var toolbarTrailing: NSLayoutConstraint!
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
        startView.onOpenApp = { [weak self] url in self?.load(url) }
        startView.presenter = self

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        let fullWidth = toolbar.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        fullWidth.priority = .defaultHigh
        toolbarMaxWidth = toolbar.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        let onSafeBottom = toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2)
        onSafeBottom.priority = .defaultHigh
        toolbarCenter = toolbar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor)
        toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        toolbarTrailing = toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        NSLayoutConstraint.activate([
            toolbarCenter,
            fullWidth,
            toolbarMaxWidth,
            toolbar.heightAnchor.constraint(equalToConstant: BottomToolbarView.totalHeight),
            onSafeBottom,
            toolbar.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
        ])
        toolbar.onBack = { [weak self] in
            guard let webView = self?.current?.webView else { return }
            if webView.canGoBack { webView.goBack() } else { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5) }
        }
        toolbar.onAddress = { [weak self] in self?.showAddressInput() }
        toolbar.onHome = { [weak self] in self?.goHome() }
        toolbar.onNewTab = { [weak self] in
            guard let self else { return }
            self.openNewTab(incognito: self.current?.isIncognito ?? false, focusAddress: true)
        }
        toolbar.onReload = { [weak self] in
            guard let webView = self?.current?.webView else { return }
            if webView.isLoading { webView.stopLoading() } else { webView.reload() }
        }
        toolbar.onTabs = { [weak self] in self?.showTabs() }
        toolbar.onSwitchTab = { [weak self] offset in self?.switchTab(by: offset) }
        toolbar.onCollapse = { [weak self] in self?.setToolbar(expanded: false) }
        toolbar.menuProvider = { [weak self] in self?.toolbarMenu() ?? [] }
        DownloadManager.shared.onEvent = { [weak self] text in self?.showToast(text) }
        toolbar.backMenuProvider = { [weak self] in self?.backHistoryMenu() ?? [] }

        // 竖线是工具栏的开关：点一下展开，再点一下收起
        handle.onTap = { [weak self] in
            guard let self else { return }
            self.setToolbar(expanded: !self.toolbarExpanded)
        }
        handle.onDrop = { [weak self] side, y in self?.handleDropped(side: side, y: y) }
        // 放在工具栏下层：和按钮重叠的地方优先响应按钮
        view.insertSubview(handle, belowSubview: toolbar)

        setToolbar(expanded: false, animated: false)
    }

    /// 启动时如果停在网页上，先把工具栏展开；用户在页面上滑动或点一下再收起
    private var didShowLaunchToolbar = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didShowLaunchToolbar else { return }
        didShowLaunchToolbar = true
        if let tab = current, !tab.isBlank, player == nil { setToolbar(expanded: true) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHandle(animated: false)
        updateToolbarPlacement()
    }

    // MARK: - 状态栏 / 方向

    override var prefersStatusBarHidden: Bool { player != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { player != nil }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { player != nil ? .all : [] }
    /// 只有网页（和全屏弹出的标签页列表，它自己决定）能横屏；首页、设置、历史、下载等都是竖屏
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if player != nil { return orientationMask }
        if let presented = presentedViewController, presented.modalPresentationStyle != .fullScreen,
           String(describing: type(of: presented)).hasPrefix("UIHostingController") {
            return .portrait
        }
        if current?.isBlank ?? true { return .portrait }
        return orientationMask
    }

    /// 页面切换后让系统重新读取支持的方向；当前方向不再支持时会自动转回竖屏
    private func updateOrientationSupport() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        // 全屏播放时（视频文件页的 ⋯ 菜单）弹窗要盖在播放器窗口上面
        if let host = player?.window?.host, !(player?.window?.isHidden ?? true), host.presentedViewController == nil {
            host.present(viewControllerToPresent, animated: flag, completion: completion)
            return
        }
        super.present(viewControllerToPresent, animated: flag) { [weak self] in
            self?.updateOrientationSupport()
            completion?()
        }
        updateOrientationSupport()
    }

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
        player?.window?.host.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let request, let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: request)) { error in
            print("[Aether] 旋转失败: \(error)")
        }
    }

    // MARK: - 工具栏与竖线

    /// 横屏时工具栏靠竖线一侧的安全区边缘，竖屏居中
    private func updateToolbarPlacement() {
        let landscape = view.bounds.width > view.bounds.height
        // 横屏地址栏窄一些，少挡页面
        toolbarMaxWidth.constant = landscape ? 400 : 560
        let wanted: NSLayoutConstraint = !landscape ? toolbarCenter : (Settings.handleSide == .right ? toolbarTrailing : toolbarLeading)
        guard !wanted.isActive else { return }
        for c in [toolbarCenter, toolbarLeading, toolbarTrailing] where c !== wanted { c?.isActive = false }
        wanted.isActive = true
    }

    private func setToolbar(expanded: Bool, animated: Bool = true) {
        toolbarExpanded = expanded
        toolbar.isUserInteractionEnabled = expanded
        if expanded { updateChrome() }
        let changes = {
            self.toolbar.alpha = expanded ? 1 : 0
            self.toolbar.transform = expanded ? .identity : CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.96, y: 0.96)
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
        toolbar.side = Settings.handleSide
        let x = Settings.handleSide == .left ? size.width / 2 : view.bounds.width - size.width / 2
        let apply = {
            self.handle.bounds = CGRect(origin: .zero, size: size)
            self.handle.center = CGPoint(x: x, y: y)
            // 首页的两颗按钮跟着竖线的高度
            // 用 center/bounds 算，frame 会被收起时的位移缩放变换影响
            self.toolbar.homeAnchorY = y - (self.toolbar.center.y - self.toolbar.bounds.height / 2)
            self.toolbar.layoutIfNeeded()
        }
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
        updateToolbarPlacement()
        layoutHandle(animated: true)
    }

    private func updateChrome() {
        updateOrientationSupport()
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

    /// ⋯ 菜单。菜单从按钮往上展开，数组里越靠前越靠下（离手指越近）。
    /// 一级只放常用项，两排横向小按钮 + 少量整行；网站相关的开关收进“网站设置”二级菜单，保证一屏放得下。
    private func toolbarMenu() -> [UIMenuElement] {
        guard let tab = current else { return [] }
        let webView = tab.webView
        let isPage = !tab.isBlank && tab.url != nil
        var groups: [UIMenu] = []

        // 最下面一排：分享、查找、所有标签页（最右）
        let count = tabManager.tabs(incognito: tab.isIncognito).filter { !$0.isBlank }.count
        var quickItems: [UIMenuElement] = []
        if let url = tab.url, isPage {
            quickItems.append(UIAction(title: L("分享"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(url)
            })
            quickItems.append(UIAction(title: L("查找"), image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                self?.setToolbar(expanded: false)
                webView.findInteraction?.presentFindNavigator(showingReplace: false)
            })
        }
        quickItems.append(UIAction(title: L("标签页（%d）", count), image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            self?.showTabs()
        })
        let quick = UIMenu(options: .displayInline, children: quickItems)
        quick.preferredElementSize = .medium
        groups.append(quick)

        // 第二排：新建标签页、新建无痕标签页、历史记录
        let creation = UIMenu(options: .displayInline, children: [
            UIAction(title: L("新建标签页"), image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.openNewTab(incognito: false, focusAddress: true)
            },
            UIAction(title: L("无痕标签页"), image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                self?.openNewTab(incognito: true, focusAddress: true)
            },
            UIAction(title: L("历史记录"), image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
                self?.showHistory()
            },
        ])
        creation.preferredElementSize = .medium
        groups.append(creation)

        // 当前页面的操作
        var pageItems: [UIMenuElement] = []
        if webView.canGoForward {
            pageItems.append(UIAction(title: L("前进"), image: UIImage(systemName: "chevron.forward")) { _ in webView.goForward() })
        }
        // 直接打开的文件（mp4、mp3、pdf…）：WebKit 只能预览，这里提供下载
        if tab.isFileDocument, let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            pageItems.append(UIAction(title: L("下载此文件"), image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.setToolbar(expanded: false)
                DownloadManager.shared.start(url, in: webView)
            })
        }
        if let url = tab.url, isPage {
            let saved = AppLibrary.shared.contains(url: url)
            pageItems.append(UIAction(title: saved ? L("已添加到收藏") : L("添加到收藏"), image: UIImage(systemName: saved ? "star.fill" : "star")) { [weak self] _ in
                if saved {
                    AppLibrary.shared.remove(url: url)
                    self?.showToast(L("已从收藏中移除"))
                } else {
                    let app = AppLibrary.shared.add(title: tab.title, url: url)
                    AppIconStore.shared.fetch(for: app, webView: webView, tint: tab.chromeColor)
                    self?.showToast(L("已添加到收藏，在首页往左滑查看"))
                }
            })
        }
        if isPage, let host = tab.url?.host() {
            pageItems.append(siteMenu(tab: tab, host: host))
        }
        if !pageItems.isEmpty { groups.append(UIMenu(options: .displayInline, children: pageItems)) }

        // 最上面：下载、设置
        let active = DownloadManager.shared.activeCount
        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(title: L("下载"), subtitle: active > 0 ? L("%d 个正在下载", active) : nil,
                     image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.showDownloads()
            },
            UIAction(title: L("设置"), image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showSettings()
            },
        ]))
        return groups
    }

    /// 二级菜单：只对当前网站生效的开关
    private func siteMenu(tab: Tab, host: String) -> UIMenu {
        let webView = tab.webView
        let blocker = ContentBlocker.shared
        let adOn = blocker.isEnabled && !blocker.isWhitelisted(host)
        let appLinksBlocked = AppLinkPolicy.isBlocked(host)
        var items: [UIMenuElement] = [
            UIAction(
                title: tab.prefersDesktop ? L("请求移动版网站") : L("请求桌面版网站"),
                image: UIImage(systemName: tab.prefersDesktop ? "iphone" : "desktopcomputer")
            ) { _ in
                tab.prefersDesktop.toggle()
                webView.reloadFromOrigin()
            },
            UIAction(title: L("广告过滤"), subtitle: adOn ? L("此网站已开启") : L("此网站已关闭"),
                     image: UIImage(systemName: adOn ? "shield.lefthalf.filled" : "shield.slash"), state: adOn ? .on : .off) { _ in
                if adOn {
                    blocker.setWhitelisted(host, true)
                } else {
                    if !blocker.isEnabled { blocker.setEnabled(true) }
                    blocker.setWhitelisted(host, false)
                }
                webView.reload()
            },
        ]
        if adOn {
            items.append(UIAction(title: L("屏蔽页面元素"), image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                self?.startPicker()
            })
        }
        items.append(UIAction(title: L("在此网站禁止跳转 App"), image: UIImage(systemName: "arrow.up.forward.app"), state: appLinksBlocked ? .on : .off) { _ in
            AppLinkPolicy.setBlocked(host, !appLinksBlocked)
        })
        // 副标题直接显示当前状态，不点进去也知道
        var summary = [adOn ? L("广告过滤开") : L("广告过滤关")]
        if tab.prefersDesktop { summary.append(L("桌面版")) }
        if appLinksBlocked { summary.append(L("禁止跳转 App")) }
        let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return UIMenu(title: L("网站设置"), subtitle: summary.joined(separator: " · "), image: UIImage(systemName: "globe"), children: [
            UIMenu(title: displayHost, options: .displayInline, children: items),
        ])
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

    /// 回到主页（首页 + 应用列表）：复用同模式的空白标签页，没有才新建；当前网页留在原标签页
    private func goHome() {
        setToolbar(expanded: false)
        let incognito = current?.isIncognito ?? false
        guard current?.isBlank != true else { return }
        if let blank = tabManager.tabs(incognito: incognito).first(where: \.isBlank) {
            tabManager.select(blank)
        } else {
            openNewTab(incognito: incognito, focusAddress: false)
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

        let dark = current?.isIncognito ?? false || current?.isBlank ?? true
        let model = AddressSuggestModel()
        let backdrop = UIHostingController(rootView: AddressSuggestionsView(
            model: model,
            onOpen: { [weak self] url in
                self?.hideAddressInput()
                self?.load(url)
            },
            onSearch: { [weak self] text in
                guard let url = URLResolver.resolve(text) else { return }
                self?.hideAddressInput()
                self?.load(url)
            }
        ))
        backdrop.view.backgroundColor = .clear
        backdrop.view.frame = view.bounds
        backdrop.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.overrideUserInterfaceStyle = dark ? .dark : .unspecified
        backdrop.view.alpha = 0
        addChild(backdrop)
        view.addSubview(backdrop.view)
        backdrop.didMove(toParent: self)

        let input = AddressInputView()
        input.setIncognito(dark)
        input.onTextChange = { text in model.query = text }
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
        addressBackdrop = backdrop
        startView.isSearchButtonHidden = true
        input.field.becomeFirstResponder()
        UIView.animate(withDuration: 0.25) {
            backdrop.view.alpha = 1
            self.handle.alpha = 0
        }
    }

    private func hideAddressInput() {
        guard let input = addressInput else { return }
        let backdrop = addressBackdrop
        addressInput = nil
        addressBackdrop = nil
        startView.isSearchButtonHidden = false
        input.field.resignFirstResponder()
        UIView.animate(withDuration: 0.2, animations: {
            input.alpha = 0
            backdrop?.view.alpha = 0
            self.handle.alpha = 1
        }, completion: { _ in
            input.removeFromSuperview()
            backdrop?.willMove(toParent: nil)
            backdrop?.view.removeFromSuperview()
            backdrop?.removeFromParent()
        })
    }

    private func showTabs() {
        // 播放器窗口盖在上面：先退出（不离开视频页），回来时再进入
        if player != nil { exitPlayer(notifyPage: true, leaveMediaPage: false) }
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
                    dismiss(animated: true) { [weak self] in self?.reenterMediaPlayerIfNeeded() }
                    if current == nil { openNewTab(incognito: false, focusAddress: false) }
                }
            )
            let host = UIHostingController(rootView: tabsView)
            host.modalPresentationStyle = .fullScreen
            self.present(host, animated: true)
        }
        if let tab = current { _ = SnapshotStore.capture(tab) }
        present()
    }

    /// 底部短暂提示
    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .label
        let capsule = GlassCapsuleView(interactive: false)
        capsule.contentView.addSubview(label)
        label.sizeToFit()
        capsule.bounds = CGRect(x: 0, y: 0, width: label.bounds.width + 36, height: 42)
        label.center = CGPoint(x: capsule.bounds.midX, y: capsule.bounds.midY)
        // 在地址胶囊上方，不和工具栏重叠
        // 全屏播放时提示放在播放器窗口里，否则被盖住
        let container: UIView = player?.window?.host.view ?? view
        capsule.center = CGPoint(x: container.bounds.midX, y: container.safeAreaLayoutGuide.layoutFrame.maxY - BottomToolbarView.height - 44)
        capsule.alpha = 0
        capsule.transform = CGAffineTransform(translationX: 0, y: 12)
        container.addSubview(capsule)
        UIView.animate(withDuration: 0.25) {
            capsule.alpha = 1
            capsule.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 1.8, options: [], animations: { capsule.alpha = 0 }, completion: { _ in capsule.removeFromSuperview() })
    }

    private func showHistory() {
        setToolbar(expanded: false)
        let history = HistoryView(onOpen: { [weak self] url in self?.load(url) })
        present(UIHostingController(rootView: history), animated: true)
    }

    private func showDownloads() {
        setToolbar(expanded: false)
        present(UIHostingController(rootView: DownloadsView()), animated: true)
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
        case "home-toolbar":
            openNewTab(incognito: false, focusAddress: false)
            setToolbar(expanded: true)
        case "newtab-incognito": openNewTab(incognito: true, focusAddress: false)
        case "picker": startPicker()
        case "history": showHistory()
        case "downloads": showDownloads()
        case "menu":
            setToolbar(expanded: true)
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.toolbar.debugPresentMenu() }
            #endif
        case "yt-enter":
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let js = "const v=document.querySelector('video'); if(!v) return 'no video'; window.name='aether-debug'; v.muted=true; try{await v.play()}catch(e){}; v.webkitEnterFullscreen(); return 'ok'"
                self.current?.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { DebugLog.log("yt-enter \($0)") }
            }
        case "seed-favs":
            let urls = ["https://m.youtube.com", "https://www.google.com", "https://en.wikipedia.org", "https://github.com", "https://www.bilibili.com",
                        "https://www.zhihu.com", "https://www.reddit.com", "https://www.apple.com", "https://x.com", "https://news.ycombinator.com",
                        "https://www.instagram.com", "https://www.netflix.com", "https://twitter.com", "https://www.amazon.com", "https://www.notion.so", "https://chatgpt.com"]
            for u in urls where !AppLibrary.shared.contains(url: URL(string: u)!) {
                AppIconStore.shared.refresh(AppLibrary.shared.add(title: "", url: URL(string: u)!))
            }
        case "refresh-icons":
            AppLibrary.shared.allApps.forEach(AppIconStore.shared.refresh)
        case "yt-probe":
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let js = "const f=document.createElement('iframe'); f.style.display='none'; document.body.appendChild(f); const w=f.contentWindow; const r={top:typeof Element.prototype.requestFullscreen, iframe:typeof w.Element.prototype.requestFullscreen, iframeWk:typeof w.Element.prototype.webkitRequestFullscreen, setPM:typeof HTMLVideoElement.prototype.webkitSetPresentationMode, docFs: typeof document.exitFullscreen}; f.remove(); return JSON.stringify(r)"
                self.current?.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { DebugLog.log("yt-probe \($0)") }
            }
        case "yt-fs":
            // 模拟点 YouTube 的全屏按钮：静音播放后对播放器容器请求全屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let js = "const v=document.querySelector('video'); if(!v) return 'no video'; v.muted=true; try{await v.play()}catch(e){}; const box=document.querySelector('#movie_player')||document.querySelector('.html5-video-player')||v.parentElement; box.requestFullscreen(); return box.id+'|'+box.className.slice(0,60)"
                self.current?.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { DebugLog.log("yt-fs \($0)") }
            }
        case "hash":
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.current?.webView.evaluateJavaScript("location.hash='searching'; location.href") { r, _ in DebugLog.log("hash set \(r ?? "")") }
            }
        case "drag-dismiss":
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { self.player?.overlay.debugDrag(180) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { self.player?.overlay.debugDragEnd() }
        case "landscape":
            setOrientation(.allButUpsideDown, request: .landscapeRight)
        case "landscape-toolbar":
            setOrientation(.allButUpsideDown, request: .landscapeRight)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setToolbar(expanded: true) }
        case "diag":
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let js = "if (location.hash.includes('ms')) return JSON.stringify({ms: typeof navigator.mediaSession, own: navigator.mediaSession && Object.getOwnPropertyNames(navigator.mediaSession), src: navigator.mediaSession && String(navigator.mediaSession.setActionHandler).slice(0,80), desc: navigator.mediaSession && JSON.stringify(Object.getOwnPropertyDescriptor(MediaSession.prototype,'setActionHandler') ? 'proto' : 'none')}); const v=document.querySelector('video'); const r=v?v.getBoundingClientRect():{}; JSON.stringify({iw:innerWidth,ih:innerHeight,vv:visualViewport&&visualViewport.scale,r:[r.x,r.y,r.width,r.height],nat:v&&[v.videoWidth,v.videoHeight],fit:v&&getComputedStyle(v).objectFit,meta:(document.querySelector('meta[name=viewport]')||{}).content})"
                self.current?.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in DebugLog.log("diag \(r)") }
                if let sv = self.current?.webView.scrollView { DebugLog.log("diag zoom=\(sv.zoomScale) min=\(sv.minimumZoomScale) max=\(sv.maximumZoomScale) size=\(sv.contentSize)") }
            }
        case "media-exit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.load(URL(string: "https://media.tankxu.com/tank/video/2026-10-09-f1884b7aa6.mp4")!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { self.exitPlayer(notifyPage: true) }
        case "media-menu":
            func waitPlayer(_ n: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let p = self.player { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { p.overlay.debugTogglePageMenu(); DebugLog.log("page menu toggled") } }
                    else if n > 0 { waitPlayer(n - 1) }
                }
            }
            waitPlayer(30)
        case "player-exit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.exitPlayer(notifyPage: true) }
        case "player-cycle":
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { self.rotatePlayer() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.exitPlayer(notifyPage: true) }
        case "pip": DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.sendPlayerCommand(.pip) }
        case "download":
            // 下载当前打开的文件，几秒后打开下载列表
            if let tab = current, let url = tab.url {
                DownloadManager.shared.start(url, in: tab.webView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.showDownloads() }
        case "tabs-open": showTabs()
        case "settings": showSettings()
        case "applinks": present(UIHostingController(rootView: NavigationStack { AppLinkSettingsView() }), animated: true)
        case "tabs-dust":
            showTabs()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: Notification.Name("aether.debugDissolveFirst"), object: nil)
            }
        case "tabs-demo":
            let urls = ["https://en.wikipedia.org/wiki/Saturn", "https://github.com", "https://news.ycombinator.com"]
            for (i, u) in urls.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 5) { [self] in
                    tabManager.open(url: URL(string: u), incognito: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [self] in showTabs() }
        case "favorite":
            if let tab = current, let url = tab.url, !AppLibrary.shared.contains(url: url) {
                let app = AppLibrary.shared.add(title: tab.title, url: url)
                AppIconStore.shared.fetch(for: app, webView: tab.webView, tint: tab.chromeColor)
                showToast(L("已添加到收藏，在首页往左滑查看"))
            }
        case "apps", "apps-edit", "folder", "make-folder":
            openNewTab(incognito: false, focusAddress: false)
            if what == "make-folder" { startView.debugHome.debugMakeFolder() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                if what == "folder" { startView.debugHome.debugOpenFirstFolder() } else { startView.debugHome.debugShowApps(editing: what == "apps-edit") }
            }
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
        if let tab = current, player == nil { _ = SnapshotStore.capture(tab) }
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
        var fullscreenObservation: NSKeyValueObservation?
        var window: PlayerWindow?

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
        if let tab = current, isMediaVideoPage(tab) {
            overlay.mediaPageMode = true
            overlay.onTabs = { [weak self] in self?.showTabs() }
            overlay.onLeave = { [weak self] in self?.exitPlayer(notifyPage: true) }
            overlay.pageMenuProvider = { [weak self] in self?.toolbarMenu() ?? [] }
        }
        overlay.onRotate = { [weak self] in self?.rotatePlayer() }
        overlay.onAutoPiPChange = { [weak self] on in
            // 打开时立刻进入 WebKit 元素全屏（自动画中画的前提）；关闭时留到这次播放结束
            guard on, let player = self?.player else { return }
            player.webView.callAsyncJavaScript("window.__aether && window.__aether.enterNativeFullscreen()", arguments: [:],
                                               in: player.frame, in: .page, completionHandler: nil)
        }
        // 下拉退出：元素全屏时视频画在 WebKit 自己的窗口里，移动视图不可靠，
        // 所以开始拖时给画面拍张快照放进播放器窗口，拖动的是快照（画面定格在那一帧）
        var drag: (backdrop: UIView, snapshot: UIView)?
        overlay.onDismissDrag = { [weak self, weak webView] dy in
            guard let self, let host = self.player?.window?.host.view else { return }
            if drag == nil {
                guard let source = webView?.window, let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
                let backdrop = UIView(frame: host.bounds)
                backdrop.backgroundColor = .black
                backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                snapshot.frame = host.bounds
                host.insertSubview(backdrop, at: 0)
                host.insertSubview(snapshot, aboveSubview: backdrop)
                drag = (backdrop, snapshot)
            }
            guard let drag else { return }
            // 画面跟手往下走并略微缩小；背后保持全黑（后面还是同一个视频，透出来像重影）
            let scale = 1 - min(dy / 1600, 0.15)
            drag.snapshot.transform = CGAffineTransform(translationX: 0, y: dy).scaledBy(x: scale, y: scale)
        }
        overlay.onDismissEnd = { [weak self] commit in
            guard let current = drag else { return }
            drag = nil
            if commit {
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn], animations: {
                    current.snapshot.transform = current.snapshot.transform.translatedBy(x: 0, y: 260)
                    current.snapshot.alpha = 0
                    current.backdrop.alpha = 0
                }, completion: { _ in
                    current.snapshot.removeFromSuperview()
                    current.backdrop.removeFromSuperview()
                    self?.exitPlayer(notifyPage: true)
                })
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: {
                    current.snapshot.transform = .identity
                }, completion: { _ in
                    current.snapshot.removeFromSuperview()
                    current.backdrop.removeFromSuperview()
                })
            }
        }

        player = PlayerSession(webView: webView, frame: frame, overlay: overlay, wasLandscape: interfaceIsLandscape)
        if let scene = view.window?.windowScene {
            let window = PlayerWindow(scene: scene, overlay: overlay)
            window.host.orientations = { [weak self] in self?.orientationMask ?? .allButUpsideDown }
            player?.window = window
        } else {
            view.addSubview(overlay)
        }
        view.backgroundColor = .black
        for v in [statusBackdrop, loadingBar, startView, toolbar, handle] as [UIView] { v.isHidden = true }
        webTopToSafeArea.isActive = false
        webTopToView.isActive = true
        updateSystemChrome()
        overlay.update(state)
        decidePlayerOrientation(state)

        // WebKit 元素全屏会把网页挪进它自己的窗口，控制层要跟过去
        player?.fullscreenObservation = webView.observe(\.fullscreenState) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.playerFullscreenChanged(webView) }
        }
        if Settings.autoPiP {
            webView.callAsyncJavaScript("window.__aether && window.__aether.enterNativeFullscreen()", arguments: [:],
                                        in: frame, in: .page, completionHandler: nil)
        }
    }

    /// 元素全屏里暂停的视频会被系统“实况文本”识别（右下角按钮、文字下划线），WebKit 没有开关，直接藏掉
    private static func hideLiveText(in webView: WKWebView) {
        func visit(_ v: UIView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)).hasPrefix("VKC") { sub.isHidden = true } else { visit(sub) }
            }
        }
        visit(webView.scrollView)
    }

    /// WebKit 元素全屏自带的 ✕ / 画中画按钮和“下滑退出”提示：Aether 有自己的控制层，全部拿掉
    private func hideWebKitFullscreenChrome(in window: UIWindow) {
        func visit(_ v: UIView) {
            for sub in v.subviews {
                if sub is PlayerOverlayView || sub is WKWebView { continue }
                if String(describing: type(of: sub)).hasPrefix("WKFullscreen") {
                    sub.removeFromSuperview()
                } else {
                    visit(sub)
                }
            }
        }
        visit(window)
    }

    private func playerFullscreenChanged(_ webView: WKWebView) {
        guard let player, player.webView === webView else { return }
        let overlay = player.overlay
        DebugLog.log("fullscreenState=\(webView.fullscreenState.rawValue) window=\(webView.window.map { String(describing: type(of: $0)) } ?? "nil")")
        guard webView.fullscreenState == .inFullscreen, let window = webView.window else { return }
        hideWebKitFullscreenChrome(in: window)
        // 提示条稍后才出现，过一会再清一次
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, self.player?.overlay === overlay else { return }
                self.hideWebKitFullscreenChrome(in: window)
            }
        }
    }

    private func updatePlayer(webView: WKWebView, state: PlayerState) {
        guard let player, player.webView === webView else { return }
        player.overlay.update(state)
        if state.paused, webView.fullscreenState == .inFullscreen {
            // 识别要过一会才出结果，分几次检查
            for delay in [0.2, 0.8, 2.0, 3.5, 5.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                    webView.map { Self.hideLiveText(in: $0) }
                }
            }
        }
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
        let isPiP = if case .pip = command { true } else { false }
        if isPiP { DebugLog.log("send pip, appState=\(UIApplication.shared.applicationState.rawValue)") }
        player.webView.callAsyncJavaScript("window.__aether && window.__aether.cmd(c)", arguments: ["c": command.payload],
                                           in: player.frame, in: .page) { result in
            if isPiP { DebugLog.log("pip cmd done \(result)") }
        }
    }

    // MARK: - 自动画中画
    //
    // 进入播放器时网页同时进入 WebKit 元素全屏（见 aether-player.js），视频处于画中画待命状态，
    // 离开 App 时由系统自动接成画中画、回来时自动还原。手动在离开瞬间启动画中画会被系统拒绝。

    func sceneWillResignActive() {
        guard let player else { return }
        DebugLog.log("willResignActive autoPiP=\(Settings.autoPiP) playing=\(player.overlay.isPlaying) fsState=\(player.webView.fullscreenState.rawValue)")
    }

    func sceneDidEnterBackground() {
        DebugLog.log("didEnterBackground")
    }

    func sceneDidBecomeActive() {
        guard let player else { return }
        DebugLog.log("didBecomeActive fsState=\(player.webView.fullscreenState.rawValue)")
    }

    private func exitPlayer(notifyPage: Bool, leaveMediaPage leave: Bool = true) {
        guard let player else { return }
        DebugLog.log("exitPlayer notify=\(notifyPage) fsState=\(player.webView.fullscreenState.rawValue)")
        if notifyPage {
            sendPlayerCommand(.exit)
            // 嵌套 iframe 时父页面也铺满了承载它的 iframe，一并还原
            player.webView.callAsyncJavaScript("window.__aether && window.__aether.clear()", arguments: [:],
                                               in: nil, in: .page, completionHandler: nil)
        }
        self.player = nil
        player.overlay.removeFromSuperview()
        player.window?.isHidden = true
        player.fullscreenObservation = nil

        view.backgroundColor = .systemBackground
        for v in [statusBackdrop, loadingBar, toolbar, handle] as [UIView] { v.isHidden = false }
        webTopToView.isActive = false
        webTopToSafeArea.isActive = true
        updateChrome()
        updateSystemChrome()
        setOrientation(.allButUpsideDown, request: !player.wasLandscape && interfaceIsLandscape ? .portrait : nil)

        // 直接打开的视频文件：页面里只有这个视频，用户退出播放器就离开这页（不露出系统播放器）。
        // 进画中画引起的退出（notifyPage == false）不算
        if notifyPage, leave, let tab = current, tab.webView === player.webView, isMediaVideoPage(tab) {
            leaveMediaPage(tab)
        }
    }

    /// 直接打开的视频文件（Aether 播放页）
    private func isMediaVideoPage(_ tab: Tab) -> Bool {
        guard let mediaURL = tab.mediaPageURL else { return false }
        return tab.webView.url == mediaURL && MediaPage.kind(forMIME: tab.mainMIME?.type) == .video
    }

    /// 回到视频文件页时重新进入播放器（页面里没有系统控件，不进播放器就只剩黑屏）
    private func reenterMediaPlayerIfNeeded() {
        guard player == nil, let tab = current, isMediaVideoPage(tab) else { return }
        tab.webView.callAsyncJavaScript("window.__aether && window.__aether.enterMedia()", arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    /// 回到打开视频前的页面；直接打开（没有上一页）就关掉这个标签页
    private func leaveMediaPage(_ tab: Tab) {
        if tab.webView.canGoBack {
            tab.webView.goBack()
        } else if let previous = tab.pageBeforeMedia, previous != tab.mediaPageURL {
            tab.webView.load(URLRequest(url: previous))
        } else {
            tabManager.close(tab)
            if current == nil { openNewTab(incognito: false, focusAddress: false) }
        }
    }

    // MARK: - 外部链接

    private func confirmOpenExternal(_ url: URL) {
        guard topPresenter === self else { return }
        let alert = UIAlertController(title: L("在其他 App 中打开？"), message: url.scheme.map { "\($0)://" }, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("打开"), style: .default) { _ in
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
        if player != nil { exitPlayer(notifyPage: true, leaveMediaPage: false) }
        picker?.cancel()
        // 切走之前给上一个标签页截一张缩略图（移出窗口后就截不到了）
        if let previous { _ = SnapshotStore.capture(previous) }
        previous?.webView.removeFromSuperview()
        if let webView = tab?.webView {
            // 用 autoresizing 而不是约束：WebKit 元素全屏会把网页挪到自己的窗口再挪回来，约束会丢、尺寸会变成 0
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = webContainer.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webContainer.addSubview(webView)
        }
        updateChrome()
        DispatchQueue.main.async { [weak self] in self?.reenterMediaPlayerIfNeeded() }
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
        case "log":
            DebugLog.log("js: \(body["msg"] as? String ?? "")")
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
            // Google / YouTube 补上地区和语言参数：只在从别的网站进入时补一次。
            // 站内跳转（含 #锚点、YouTube 去掉参数后的页内操作）不再改写，否则每次都会整页重载
            // 来源用已提交的当前页（webView.url 在加载开始时就已变成目标网址）
            let fromHost = webView.backForwardList.currentItem?.url.host()?.lowercased()
            let sameSite = fromHost != nil && fromHost == navigationAction.request.url?.host()?.lowercased()
            if !sameSite, navigationAction.navigationType != .backForward, navigationAction.navigationType != .reload,
               navigationAction.request.httpMethod ?? "GET" == "GET", let url = navigationAction.request.url,
               let rewritten = RegionSettings.rewrite(url) {
                let key = ObjectIdentifier(webView)
                let recent = lastRegionRewrite[key].map { $0.url == url.absoluteString && Date().timeIntervalSince($0.date) < 5 } ?? false
                if !recent {
                    DebugLog.log("region rewrite type=\(navigationAction.navigationType.rawValue) from=\(webView.url?.absoluteString ?? "nil") to=\(rewritten.absoluteString)")
                    lastRegionRewrite[key] = (url.absoluteString, Date())
                    webView.load(URLRequest(url: rewritten))
                    return (.cancel, preferences)
                }
            }
        }
        // <a download> 等网页要求下载的链接
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        // 服务器要求下载（attachment），或网页显示不了（zip、apk 等）：转成下载
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
            return .download
        }
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, let type = navigationResponse.response.mimeType,
           let tab = tab(for: webView) {
            if tab.mediaPageURL == url, MediaPage.kind(forMIME: type) == nil { return .allow }
            tab.mainMIME = (url, type)
            // 直接打开的视频 / 音频：换成 Aether 自己的页面（视频能被播放器接管，音频有播放卡片）
            if let kind = MediaPage.kind(forMIME: type) {
                if tab.mediaPageURL != url {
                    tab.pageBeforeMedia = webView.backForwardList.currentItem?.url
                }
                tab.mediaPageURL = url
                DispatchQueue.main.async { webView.loadHTMLString(MediaPage.html(for: url, kind: kind), baseURL: url) }
                return .cancel
            }
            tab.mediaPageURL = nil
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
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
        // 页面加载完稍等一下（图片渲染）再刷新缩略图
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak webView] in
            guard let self, let webView, let tab = self.current, tab.webView === webView, self.player == nil else { return }
            _ = SnapshotStore.capture(tab)
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
            alert.addAction(UIAlertAction(title: L("好"), style: .default) { _ in done.resume() })
            topPresenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: L("好"), style: .default) { _ in done.resume(returning: true) })
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
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: L("好"), style: .default) { [weak alert] _ in
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
            let open = UIAction(title: L("在新标签页打开"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                self?.tabManager.open(url: url, incognito: incognito, after: opener)
            }
            let background = UIAction(title: L("在后台打开"), image: UIImage(systemName: "square.stack")) { _ in
                self?.tabManager.open(url: url, incognito: incognito, after: opener, select: false)
                self?.updateChrome()
            }
            let private_ = UIAction(title: L("在无痕标签页打开"), image: UIImage(systemName: "eyeglasses")) { _ in
                self?.tabManager.open(url: url, incognito: true)
            }
            let copy = UIAction(title: L("拷贝链接"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            }
            let share = UIAction(title: L("分享…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.share(url)
            }
            let download = UIAction(title: L("下载链接文件"), image: UIImage(systemName: "arrow.down.circle")) { _ in
                DownloadManager.shared.start(url, in: webView)
            }
            return UIMenu(title: url.absoluteString, children: [
                UIMenu(options: .displayInline, children: incognito ? [open, background] : [open, background, private_]),
                UIMenu(options: .displayInline, children: [download, copy, share]),
            ])
        }
    }
}
