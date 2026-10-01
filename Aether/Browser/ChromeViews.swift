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
        accessibilityLabel = "展开工具栏"
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
    static func circleButton(_ symbol: String, size: CGFloat = 48) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .gray()
            config.background.visualEffect = UIBlurEffect(style: .systemChromeMaterial)
        }
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
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

final class BottomToolbarView: UIView {
    static let height: CGFloat = 48

    var onBack: (() -> Void)?
    var onAddress: (() -> Void)?
    var onReload: (() -> Void)?
    var onTabs: (() -> Void)?
    var onSwitchTab: ((Int) -> Void)?
    var onCollapse: (() -> Void)?
    var menuProvider: (() -> [UIMenuElement])?
    var backMenuProvider: (() -> [UIMenuElement])?

    private let backButton = Glass.circleButton("chevron.backward")
    private let moreButton = Glass.circleButton("ellipsis")
    private let pill = GlassCapsuleView()
    private let pillButton = UIControl()
    private let statusIcon = UIImageView()
    private let hostLabel = UILabel()
    private let reloadButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)

        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .primaryActionTriggered)

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

        let hostRow = UIStackView(arrangedSubviews: [statusIcon, hostLabel])
        hostRow.spacing = 6
        hostRow.alignment = .center
        hostRow.isUserInteractionEnabled = false

        for v in [pillButton, hostRow, reloadButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pill.contentView.addSubview(v)
        }
        let row = UIStackView(arrangedSubviews: [backButton, pill, moreButton])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.height),

            pillButton.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            pillButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            pillButton.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor),
            pillButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -4),
            reloadButton.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 40),
            reloadButton.heightAnchor.constraint(equalToConstant: 40),

            // 域名在胶囊里居中，空间不够时让开刷新按钮
            hostRow.centerXAnchor.constraint(equalTo: pill.contentView.centerXAnchor).withPriority(.defaultHigh),
            hostRow.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
            hostRow.leadingAnchor.constraint(greaterThanOrEqualTo: pill.contentView.leadingAnchor, constant: 16),
            hostRow.trailingAnchor.constraint(lessThanOrEqualTo: reloadButton.leadingAnchor, constant: -2),
        ])

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

    func update(tab: Tab?, tabCount: Int) {
        // 按钮始终可点、保持和其他按钮同色；能否后退在点击时判断（禁用状态会被系统画成灰色）

        let incognito = tab?.isIncognito ?? false
        let host = tab.flatMap { $0.isBlank ? nil : $0.url?.host() }
        hostLabel.text = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "搜索或输入网址"
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

        field.placeholder = "搜索或输入网址"
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

    private let space = SpaceBackgroundView()
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
        didSet { space.isPaused = isHidden || window == nil }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        space.frame = bounds
        space.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(space)
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
        config.title = "搜索或输入网址"
        config.image = UIImage(systemName: "magnifyingglass")
        config.imagePadding = 8
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        config.baseForegroundColor = UIColor(white: 1, alpha: 0.75)
        search = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onSearch?() })

        historyButton.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .primaryActionTriggered)
        historyButton.accessibilityLabel = "历史记录"

        modeSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onModeChange?(modeSwitch.isIncognito)
        }, for: .valueChanged)

        for v in [hero, titleLabel, noteLabel, search, historyButton, modeSwitch] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            hero.centerXAnchor.constraint(equalTo: centerXAnchor),
            NSLayoutConstraint(item: hero, attribute: .centerY, relatedBy: .equal, toItem: self, attribute: .bottom, multiplier: 0.3, constant: 0),
            hero.widthAnchor.constraint(equalToConstant: 1),
            hero.heightAnchor.constraint(equalToConstant: 1),

            // 黑洞 + 吸积盘大约占屏宽 0.6，标题放在吸积盘下方
            titleLabel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 0),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noteLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            noteLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noteLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            search.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 30),
            search.centerXAnchor.constraint(equalTo: centerXAnchor),
            search.widthAnchor.constraint(equalToConstant: 280),
            search.heightAnchor.constraint(equalToConstant: 50),

            historyButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            historyButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),

            modeSwitch.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeSwitch.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            modeSwitch.widthAnchor.constraint(equalToConstant: ModeSwitch.size.width),
            modeSwitch.heightAnchor.constraint(equalToConstant: ModeSwitch.size.height),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        setIncognito(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        space.holeCenter = hero.center
        // 标题落在星球下方（星球半径 0.12 × 屏宽；行星环纵向更扁，不超过球底）
        let diskBottom = bounds.width * 0.19
        if let c = constraints.first(where: { $0.firstItem === titleLabel && $0.firstAttribute == .top }), abs(c.constant - diskBottom) > 0.5 {
            c.constant = diskBottom
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        space.isPaused = isHidden || window == nil
    }

    func setIncognito(_ incognito: Bool) {
        modeSwitch.setIncognito(incognito, animated: false)
        space.isMonochrome = incognito
        historyButton.isHidden = incognito
        titleLabel.text = incognito ? "无痕浏览" : "Aether"
        noteLabel.text = incognito
            ? "无痕标签页不会保留浏览记录、Cookie 和网站数据。\n关闭所有无痕标签页后，这些数据会被清除。"
            : "沉浸浏览 · 纯净无扰"
    }

    @objc private func tapped() {
        onSearch?()
    }
}

/// 标准 / 无痕切换：可交互的液态玻璃胶囊，里面一个玻璃高亮块
final class ModeSwitch: UIControl {
    static let size = CGSize(width: 228, height: 46)

    private(set) var isIncognito = false
    private let capsule = GlassCapsuleView(interactive: true)
    private let indicator: UIView
    private let standardButton = ModeSwitch.segment("globe", "标准")
    private let incognitoButton = ModeSwitch.segment("eyeglasses", "无痕")

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
        config.imagePadding = 6
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
