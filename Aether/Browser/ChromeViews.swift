import UIKit

// MARK: - 贴边竖线

/// 工具栏收起时唯一可见的东西：屏幕边缘一根细竖线。
/// 点一下展开工具栏；上下拖动换位置，拖到另一边就贴到另一边。
final class EdgeHandleView: UIView {
    static let size = CGSize(width: 26, height: 84)

    var side: Side = Settings.handleSide { didSet { setNeedsLayout() } }
    var onTap: (() -> Void)?
    /// 拖动结束：新的边、竖线中心在父视图中的 y
    var onDrop: ((Side, CGFloat) -> Void)?
    private(set) var isDragging = false

    private let pill = UIView()
    private var dragStart: CGPoint = .zero

    var isIncognito = false { didSet { updateColors() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.layer.cornerRadius = 2.5
        pill.layer.borderWidth = 0.5
        addSubview(pill)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        isAccessibilityElement = true
        accessibilityLabel = L("展开工具栏")
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w: CGFloat = 5, h: CGFloat = 46
        let x = side == .right ? bounds.width - w - 2 : 2
        pill.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func updateColors() {
        if isIncognito {
            // 无痕页面是深色的：用和深色模式一致的浅灰
            pill.backgroundColor = UIColor.white.withAlphaComponent(0.4)
            pill.layer.borderColor = UIColor.black.withAlphaComponent(0.3).cgColor
        } else {
            // 深浅背景上都能看到：半透明主色 + 反色细描边
            pill.backgroundColor = UIColor.label.withAlphaComponent(0.35)
            pill.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        }
    }

    @objc private func tapped() {
        onTap?()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch g.state {
        case .began:
            isDragging = true
            dragStart = center
            UIView.animate(withDuration: 0.15) { self.pill.transform = CGAffineTransform(scaleX: 1.4, y: 1.15) }
        case .changed:
            let t = g.translation(in: superview)
            center = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y)
        case .ended, .cancelled, .failed:
            isDragging = false
            let newSide: Side = center.x < superview.bounds.midX ? .left : .right
            UIView.animate(withDuration: 0.15) { self.pill.transform = .identity }
            onDrop?(newSide, center.y)
        default:
            break
        }
    }
}

// MARK: - 液态玻璃

/// iOS 26 起用系统液态玻璃，旧系统退回毛玻璃
final class GlassCapsuleView: UIVisualEffectView {
    /// nil 为胶囊形，否则为固定圆角
    private let fixedRadius: CGFloat?

    /// clear：更通透的玻璃（用在视频画面上）
    init(cornerRadius: CGFloat? = nil, interactive: Bool = true, clear: Bool = false) {
        fixedRadius = cornerRadius
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: clear ? .clear : .regular)
            glass.isInteractive = interactive
            super.init(effect: glass)
            cornerConfiguration = cornerRadius.map { .corners(radius: .fixed($0)) } ?? .capsule()
        } else {
            super.init(effect: UIBlurEffect(style: .systemChromeMaterial))
            layer.cornerCurve = .continuous
            clipsToBounds = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if #unavailable(iOS 26.0) { layer.cornerRadius = fixedRadius ?? bounds.height / 2 }
    }
}

enum Glass {
    static func circleButton(_ symbol: String, size: CGFloat = 48, iconSize: CGFloat = 17) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .gray()
            config.background.visualEffect = UIBlurEffect(style: .systemChromeMaterial)
        }
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        return button
    }
}

// MARK: - 底部工具栏（Safari 紧凑布局：‹  [ 地址 ]  ⋯）

/// 底部工具栏：拇指操作区。主页 / 新标签页 / 标签页 / ⋯ / ‹ 从上到下竖排成一列，和地址胶囊并排；
/// 这一列和胶囊里的刷新按钮都跟着边缘竖线在哪一侧。
final class BottomToolbarView: UIView {
    static let height: CGFloat = 48
    static let columnGap: CGFloat = 10
    /// 整体高度：五颗按钮竖排
    static let totalHeight: CGFloat = height * 5 + columnGap * 4

    var side: Side = Settings.handleSide {
        didSet { if side != oldValue { setNeedsLayout() } }
    }

    var onBack: (() -> Void)?
    var onHome: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onAddress: (() -> Void)?
    var onReload: (() -> Void)?
    var onTabs: (() -> Void)?
    var onSwitchTab: ((Int) -> Void)?
    var onCollapse: (() -> Void)?
    var menuProvider: (() -> [UIMenuElement])?

    #if DEBUG
    /// 调试截图用：用私有方法直接弹出 ⋯ 菜单
    func debugPresentMenu() {
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let interaction = moreButton.contextMenuInteraction, interaction.responds(to: selector) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(interaction.method(for: selector), to: Present.self)(interaction, selector, CGPoint(x: 24, y: 24))
    }
    #endif
    var backMenuProvider: (() -> [UIMenuElement])?

    private let backButton = Glass.circleButton("chevron.backward")
    private let moreButton = Glass.circleButton("ellipsis")
    private let homeButton = Glass.circleButton("house")
    private let tabsButton = Glass.circleButton("square.on.square")
    private let newTabButton = Glass.circleButton("plus")
    /// 在首页时只显示 ⋯ 和标签页两个按钮（不需要返回和地址栏）
    private var homeMode = false
    /// 首页时两个按钮跟着边缘竖线：竖线中心在本视图坐标里的 y（可能在本视图上方）
    var homeAnchorY: CGFloat? { didSet { if homeAnchorY != oldValue { setNeedsLayout() } } }
    private let pill = GlassCapsuleView()
    private let pillButton = UIControl()
    private let statusIcon = UIImageView()
    private let hostLabel = UILabel()
    private let reloadButton = UIButton(configuration: .plain())
    private let hostRow = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .primaryActionTriggered)
        homeButton.addAction(UIAction { [weak self] _ in self?.onHome?() }, for: .primaryActionTriggered)
        tabsButton.addAction(UIAction { [weak self] _ in self?.onTabs?() }, for: .primaryActionTriggered)
        tabsButton.accessibilityLabel = L("全部标签页")
        newTabButton.addAction(UIAction { [weak self] _ in self?.onNewTab?() }, for: .primaryActionTriggered)
        newTabButton.accessibilityLabel = L("新建标签页")
        homeButton.accessibilityLabel = L("主页")

        // 长按后退：历史列表
        backButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.backMenuProvider?() ?? [])
            },
        ])

        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            },
        ])

        statusIcon.contentMode = .center
        statusIcon.tintColor = .secondaryLabel
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        hostLabel.font = .systemFont(ofSize: 16, weight: .medium)
        hostLabel.textColor = .label
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var reloadConfig = UIButton.Configuration.plain()
        reloadConfig.image = UIImage(systemName: "arrow.clockwise")
        reloadConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        reloadConfig.baseForegroundColor = .label
        reloadButton.configuration = reloadConfig
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReload?() }, for: .primaryActionTriggered)

        pillButton.addAction(UIAction { [weak self] _ in self?.onAddress?() }, for: .touchUpInside)

        hostRow.addArrangedSubview(statusIcon)
        hostRow.addArrangedSubview(hostLabel)
        hostRow.spacing = 6
        hostRow.alignment = .center
        hostRow.isUserInteractionEnabled = false

        for v in [pillButton, hostRow, reloadButton] as [UIView] { pill.contentView.addSubview(v) }
        // 位置随 side 变化，统一在 layoutSubviews 里用 frame 摆放
        for button in [backButton, moreButton, homeButton, tabsButton, newTabButton] {
            button.removeConstraints(button.constraints)
            button.translatesAutoresizingMaskIntoConstraints = true
        }
        for v in [pill, homeButton, moreButton, backButton, tabsButton, newTabButton] as [UIView] { addSubview(v) }

        // 地址胶囊上：左右滑切换标签页，上滑打开标签页总览
        for (direction, action) in [
            (UISwipeGestureRecognizer.Direction.left, #selector(swipedLeft)),
            (.right, #selector(swipedRight)),
            (.up, #selector(swipedUp)),
        ] {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            pill.addGestureRecognizer(swipe)
        }
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        down.direction = .down
        addGestureRecognizer(down)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = Self.height, gap = Self.columnGap
        let onRight = side == .right
        let columnX = onRight ? bounds.width - b : 0
        let rowY = bounds.height - b
        // 从下往上数第 n 格
        func slot(_ n: Int) -> CGRect { CGRect(x: columnX, y: rowY - CGFloat(n) * (gap + b), width: b, height: b) }
        moreButton.frame = slot(1)
        homeButton.frame = slot(4)
        newTabButton.frame = slot(3)
        // 首页：只有 ⋯ 和标签页，放在边缘竖线旁边、和竖线垂直居中；网页：主页 / 标签页 / ⋯ / ‹
        tabsButton.frame = homeMode ? slot(0) : slot(2)
        if homeMode, let anchor = homeAnchorY, let superview {
            // 两颗按钮整体的中心对齐竖线，并限制在屏幕安全区内
            let safeTop = superview.safeAreaInsets.top + 8 - (center.y - bounds.height / 2)
            let safeBottom = bounds.height
            let top = min(max(anchor - b - gap / 2, safeTop), safeBottom - b * 2 - gap)
            moreButton.frame = CGRect(x: columnX, y: top, width: b, height: b)
            tabsButton.frame = CGRect(x: columnX, y: top + b + gap, width: b, height: b)
        }
        for v in [pill, backButton, homeButton, newTabButton] as [UIView] { v.isHidden = homeMode }
        backButton.frame = CGRect(x: columnX, y: rowY, width: b, height: b)
        pill.frame = CGRect(x: onRight ? 0 : b + gap, y: rowY, width: bounds.width - b - gap, height: b)

        let w = pill.bounds.width
        pillButton.frame = pill.bounds
        let reloadSize: CGFloat = 40
        reloadButton.frame = CGRect(x: onRight ? w - 4 - reloadSize : 4, y: (b - reloadSize) / 2, width: reloadSize, height: reloadSize)
        // 域名在胶囊里居中，空间不够时让开刷新按钮
        let maxWidth = w - 16 - reloadSize - 6
        let fitting = hostRow.systemLayoutSizeFitting(CGSize(width: maxWidth, height: b))
        let rowWidth = min(fitting.width, maxWidth)
        var x = (w - rowWidth) / 2
        if onRight { x = min(x, w - 4 - reloadSize - 2 - rowWidth) } else { x = max(x, 4 + reloadSize + 2) }
        hostRow.frame = CGRect(x: x, y: (b - 24) / 2, width: rowWidth, height: 24)
    }


    /// 竖排按钮上方的空白区域不挡页面
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        [pill, moreButton, backButton, homeButton, tabsButton, newTabButton].filter { $0.alpha > 0 && !$0.isHidden }.contains { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }
    }

    func update(tab: Tab?, tabCount: Int) {
        // 按钮始终可点、保持和其他按钮同色；能否后退在点击时判断（禁用状态会被系统画成灰色）

        let incognito = tab?.isIncognito ?? false
        let host = tab.flatMap { $0.isBlank ? nil : $0.url?.host() }
        hostLabel.text = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? L("搜索或输入网址")
        hostLabel.textColor = host == nil ? .secondaryLabel : .label

        let symbol: String? = if incognito {
            "eyeglasses"
        } else if host == nil {
            "magnifyingglass"
        } else if tab?.url?.scheme == "https", tab?.webView.hasOnlySecureContent ?? false {
            "lock.fill"
        } else {
            nil
        }
        statusIcon.image = symbol.flatMap { UIImage(systemName: $0) }
        statusIcon.isHidden = symbol == nil

        let loading = tab?.webView.isLoading ?? false
        reloadButton.configuration?.image = UIImage(systemName: loading ? "xmark" : "arrow.clockwise")
        reloadButton.isHidden = host == nil
        homeMode = tab?.isBlank ?? true
        setNeedsLayout()
        // 首页始终是深色背景，工具栏跟着用深色
        overrideUserInterfaceStyle = incognito || host == nil ? .dark : .unspecified
    }

    @objc private func swipedLeft() { onSwitchTab?(1) }
    @objc private func swipedRight() { onSwitchTab?(-1) }
    @objc private func swipedUp() { onTabs?() }
    @objc private func swipedDown() { onCollapse?() }
}

// MARK: - 地址输入（键盘上方的玻璃胶囊 + 关闭按钮）

final class AddressInputView: UIView, UITextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// 用户每次改动输入内容
    var onTextChange: ((String) -> Void)?

    let field = UITextField()
    private let capsule = GlassCapsuleView()
    private let closeButton = Glass.circleButton("xmark")

    override init(frame: CGRect) {
        super.init(frame: frame)

        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        field.placeholder = L("搜索或输入网址")
        field.borderStyle = .none
        field.font = .systemFont(ofSize: 17)
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.textContentType = .URL
        field.clearButtonMode = .whileEditing
        field.delegate = self

        closeButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)
        field.addAction(UIAction { [weak self] _ in self?.onTextChange?(self?.field.text ?? "") }, for: .editingChanged)

        for v in [capsule, icon, field, closeButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(capsule)
        capsule.contentView.addSubview(icon)
        capsule.contentView.addSubview(field)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.heightAnchor.constraint(equalToConstant: BottomToolbarView.height),
            closeButton.leadingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIncognito(_ incognito: Bool) {
        overrideUserInterfaceStyle = incognito ? .dark : .unspecified
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?(textField.text ?? "")
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        DispatchQueue.main.async { textField.selectAll(nil) }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

// MARK: - 空白标签页

/// 新标签页：实时渲染的星球 + 行星环 + 时空网格背景，始终深色
final class StartView: UIView {
    var onSearch: (() -> Void)?
    var onHistory: (() -> Void)?
    /// 底部切换器：true = 无痕
    var onModeChange: ((Bool) -> Void)?
    var onOpenApp: ((URL) -> Void)? {
        get { home.onOpen }
        set { home.onOpen = newValue }
    }
    weak var presenter: UIViewController? {
        get { home.presenter }
        set { home.presenter = newValue }
    }

    private let space = SpaceBackgroundView()
    /// 第 0 屏是首页，往左滑是收藏的网页（应用列表）
    private let home = HomeScreenView()
    private var historyTop: NSLayoutConstraint!
    private var pageOffset: CGFloat = 0
    /// 星球所在位置（不可见的占位）
    private let hero = UIView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private var search: UIButton!
    private let historyButton = Glass.circleButton("clock.arrow.circlepath", size: 44)
    private let modeSwitch = ModeSwitch()

    /// 地址输入框弹出时隐藏，免得透过玻璃叠在一起
    var isSearchButtonHidden = false {
        didSet {
            UIView.animate(withDuration: 0.2) {
                for v in [self.search, self.modeSwitch, self.historyButton] as [UIView] { v.alpha = self.isSearchButtonHidden ? 0 : 1 }
            }
        }
    }

    override var isHidden: Bool {
        didSet {
            space.isPaused = isHidden || window == nil
            if isHidden { home.reset() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        space.frame = bounds
        space.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(space)
        home.frame = bounds
        home.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        home.onSearch = { [weak self] in self?.onSearch?() }
        home.onFolderVisible = { [weak self] visible in
            UIView.animate(withDuration: 0.25) { self?.modeSwitch.alpha = visible ? 0 : 1 }
        }
        home.onScroll = { [weak self] offset in
            self?.pageOffset = offset
            self?.updateHoleCenter()
        }
        addSubview(home)
        hero.isUserInteractionEnabled = false

        titleLabel.font = UIFont.systemFont(ofSize: 32, weight: .bold).rounded
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.layer.shadowColor = UIColor(red: 0.6, green: 0.4, blue: 1, alpha: 1).cgColor
        titleLabel.layer.shadowOpacity = 0.8
        titleLabel.layer.shadowRadius = 12
        titleLabel.layer.shadowOffset = .zero
        noteLabel.font = .systemFont(ofSize: 14)
        noteLabel.textColor = UIColor(white: 1, alpha: 0.6)
        noteLabel.textAlignment = .center
        noteLabel.numberOfLines = 0

        var config: UIButton.Configuration
        if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
        config.cornerStyle = .capsule
        config.title = L("搜索或输入网址")
        config.image = UIImage(systemName: "magnifyingglass")
        config.imagePadding = 8
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        config.baseForegroundColor = UIColor(white: 1, alpha: 0.75)
        search = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onSearch?() })

        historyButton.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .primaryActionTriggered)
        historyButton.accessibilityLabel = L("历史记录")

        modeSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onModeChange?(modeSwitch.isIncognito)
        }, for: .valueChanged)

        // 首页内容放在第 0 屏里，跟着翻页滑走；模式切换器固定在底部
        let page = home.startPage
        for v in [hero, titleLabel, noteLabel, search, historyButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(v)
        }
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeSwitch)
        historyTop = historyButton.topAnchor.constraint(equalTo: page.topAnchor, constant: 60)
        NSLayoutConstraint.activate([
            hero.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            NSLayoutConstraint(item: hero, attribute: .centerY, relatedBy: .equal, toItem: page, attribute: .bottom, multiplier: 0.3, constant: 0),
            hero.widthAnchor.constraint(equalToConstant: 1),
            hero.heightAnchor.constraint(equalToConstant: 1),

            // 黑洞 + 吸积盘大约占屏宽 0.6，标题放在吸积盘下方
            titleLabel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 0),
            titleLabel.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            noteLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            noteLabel.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            noteLabel.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -64),
            search.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 30),
            search.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            search.widthAnchor.constraint(equalToConstant: 280),
            search.heightAnchor.constraint(equalToConstant: 50),

            historyTop,
            historyButton.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -16),

            modeSwitch.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeSwitch.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            modeSwitch.widthAnchor.constraint(equalToConstant: ModeSwitch.size.width),
            modeSwitch.heightAnchor.constraint(equalToConstant: ModeSwitch.size.height),
        ])
        page.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        setIncognito(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        historyTop.constant = safeAreaInsets.top + 8
        updateHoleCenter()
        // 标题落在星球下方（星球半径 0.12 × 屏宽；行星环纵向更扁，不超过球底）
        let diskBottom = bounds.width * 0.19
        if let c = home.startPage.constraints.first(where: { $0.firstItem === titleLabel && $0.firstAttribute == .top }), abs(c.constant - diskBottom) > 0.5 {
            c.constant = diskBottom
        }
    }

    /// 星球位置：和 hero 占位的约束一致（水平居中、高度 30%），跟着翻页以一半的速度移动（视差）。
    /// 直接按几何算，不读 hero.center——hero 在翻页容器里，可能还没完成布局
    private func updateHoleCenter() {
        space.holeCenter = CGPoint(x: bounds.width / 2 - pageOffset * bounds.width * 0.5, y: bounds.height * 0.3)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        space.isPaused = isHidden || window == nil
    }

    func setIncognito(_ incognito: Bool) {
        modeSwitch.setIncognito(incognito, animated: false)
        space.isMonochrome = incognito
        historyButton.isHidden = incognito
        home.reset()
        titleLabel.text = incognito ? L("无痕浏览") : "Aether"
        noteLabel.text = incognito
            ? L("无痕标签页不会保留浏览记录、Cookie 和网站数据。\n关闭所有无痕标签页后，这些数据会被清除。")
            : L("沉浸浏览 · 纯净无扰")
    }

    @objc private func tapped() {
        onSearch?()
    }

    #if DEBUG
    var debugHome: HomeScreenView { home }
    #endif
}

/// 标准 / 无痕切换：可交互的液态玻璃胶囊，里面一个玻璃高亮块
final class ModeSwitch: UIControl {
    static let size = CGSize(width: 272, height: 46)

    private(set) var isIncognito = false
    private let capsule = GlassCapsuleView(interactive: true)
    private let indicator: UIView
    private let standardButton = ModeSwitch.segment("globe", L("标准"))
    private let incognitoButton = ModeSwitch.segment("eyeglasses", L("无痕"))

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            glass.tintColor = UIColor(white: 1, alpha: 0.22)
            let v = UIVisualEffectView(effect: glass)
            v.cornerConfiguration = .capsule()
            indicator = v
        } else {
            indicator = UIView()
            indicator.backgroundColor = UIColor(white: 1, alpha: 0.18)
            indicator.layer.cornerCurve = .continuous
        }
        super.init(frame: frame)
        indicator.isUserInteractionEnabled = false
        addSubview(capsule)
        // 按钮放进玻璃内部，按压时玻璃本身才会有交互反馈
        capsule.contentView.addSubview(indicator)
        for (button, incognito) in [(standardButton, false), (incognitoButton, true)] {
            button.addAction(UIAction { [weak self] _ in self?.select(incognito) }, for: .primaryActionTriggered)
            button.addAction(UIAction { [weak self] _ in self?.press(true) }, for: [.touchDown, .touchDragEnter])
            button.addAction(UIAction { [weak self] _ in self?.press(false) }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            capsule.contentView.addSubview(button)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        let inset: CGFloat = 4
        let half = (bounds.width - inset * 2) / 2
        standardButton.frame = CGRect(x: inset, y: inset, width: half, height: bounds.height - inset * 2)
        incognitoButton.frame = standardButton.frame.offsetBy(dx: half, dy: 0)
        let target = isIncognito ? incognitoButton.frame : standardButton.frame
        indicator.bounds = CGRect(origin: .zero, size: target.size)
        indicator.center = CGPoint(x: target.midX, y: target.midY)
        if #unavailable(iOS 26.0) { indicator.layer.cornerRadius = target.height / 2 }
    }

    func setIncognito(_ incognito: Bool, animated: Bool) {
        isIncognito = incognito
        let change = {
            self.setNeedsLayout()
            self.layoutIfNeeded()
            self.updateColors()
        }
        if animated {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.5, animations: change)
        } else {
            change()
        }
    }

    /// 按下时高亮块微微放大，像系统分段控件的“透镜”
    private func press(_ down: Bool) {
        UIView.animate(withDuration: down ? 0.18 : 0.35, delay: 0, usingSpringWithDamping: down ? 1 : 0.6,
                       initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.indicator.transform = down ? CGAffineTransform(scaleX: 1.08, y: 1.14) : .identity
        }
    }

    private func select(_ incognito: Bool) {
        guard incognito != isIncognito else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        setIncognito(incognito, animated: true)
        sendActions(for: .valueChanged)
    }

    private func updateColors() {
        standardButton.configuration?.baseForegroundColor = isIncognito ? .secondaryLabel : .label
        incognitoButton.configuration?.baseForegroundColor = isIncognito ? .label : .secondaryLabel
    }

    private static func segment(_ symbol: String, _ title: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 5
        // 各语言长度差别大（Standard / Estándar / プライベート）：收窄内边距，只显示一行
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        config.titleLineBreakMode = .byTruncatingTail
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        var text = AttributedString(title)
        text.font = .systemFont(ofSize: 14, weight: .semibold)
        config.attributedTitle = text
        let button = UIButton(configuration: config)
        // 不要系统默认的按下变暗，反馈交给玻璃
        button.configurationUpdateHandler = { b in
            b.configuration?.background.backgroundColor = .clear
        }
        return button
    }
}

private extension UIFont {
    var rounded: UIFont {
        fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

// MARK: - 顶部加载进度

final class LoadingBarView: UIView {
    private let bar = UIView()
    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        bar.backgroundColor = .tintColor
        addSubview(bar)
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(progress: Double, loading: Bool) {
        let visible = loading && progress < 1
        if visible && alpha == 0 {
            self.progress = 0
            layoutBar()
        }
        self.progress = progress
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.layoutBar()
        }
        UIView.animate(withDuration: 0.25, delay: visible ? 0 : 0.2) {
            self.alpha = visible ? 1 : 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBar()
    }

    private func layoutBar() {
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }
}
