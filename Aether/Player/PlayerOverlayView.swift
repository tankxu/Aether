import UIKit

/// 全屏视频的原生控制层，盖在 WKWebView 上并吃掉所有触摸（网页自带控件不会被误触）。
/// 本身完全透明：只有侧边控制列和贴底进度条，没有任何蒙版。
final class PlayerOverlayView: UIView, UIGestureRecognizerDelegate {
    var onCommand: ((PlayerCommand) -> Void)?
    var onExit: (() -> Void)?
    var onRotate: (() -> Void)?
    /// 播放中切换“离开 App 时自动画中画”：立即生效
    var onAutoPiPChange: ((Bool) -> Void)?
    /// 下滑退出：拖动中的位移（0 表示复位），以及松手时是否退出
    var onDismissDrag: ((CGFloat) -> Void)?
    var onDismissEnd: ((Bool) -> Void)?
    /// 直接打开的视频文件：显示边缘竖线，点开有 ⋯（网页操作，如下载）和返回
    var onTabs: (() -> Void)? { didSet { rail.onTabs = onTabs } }
    var onLeave: (() -> Void)?
    var pageMenuProvider: (() -> [UIMenuElement])?
    var mediaPageMode = false { didSet { configureMediaPageMode() } }
    private let pageHandle = EdgeHandleView()
    private let pageMoreButton = Glass.circleButton("ellipsis")
    private let pageBackButton = Glass.circleButton("chevron.backward")
    private var pageMenuVisible = false

    private let rail = ControlRailView()
    /// 右上角：画中画、AirPlay，液态玻璃圆形按钮
    private let pipButton = Glass.circleButton("pip.enter", size: 44, iconSize: 14)
    private let airplayButton = Glass.circleButton("airplay.video", size: 44, iconSize: 14)
    private let cornerStack = UIStackView()
    private let progress = ProgressBarView()

    private var state: PlayerState?
    private var stateStamp: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    private var controlsVisible = false
    private var hideTask: Task<Void, Never>?

    private var side = Settings.railSide
    private var railDrag: CGFloat = 0
    private var railDragging = false

    private var scrubbing = false
    private var scrubTime: Double = 0
    private var lastScrubSeek: CFTimeInterval = 0

    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    /// 长按画面临时 2 倍速
    private var rateBeforeBoost: Double?
    private let boostHint = GlassCapsuleView(interactive: false)
    private weak var dismissPan: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        rail.onExit = { [weak self] in self?.onExit?() }
        rail.onToggle = { [weak self] in
            self?.send(.toggle)
            self?.poke()
        }
        rail.onSeek = { [weak self] delta in self?.seek(by: delta) }
        rail.menuProvider = { [weak self] in self?.menuElements() ?? [] }
        addSubview(rail)

        pipButton.addAction(UIAction { [weak self] _ in self?.send(.pip) }, for: .touchUpInside)
        airplayButton.addAction(UIAction { [weak self] _ in
            self?.send(.airplay)
            self?.poke()
        }, for: .touchUpInside)
        pipButton.accessibilityLabel = L("画中画")
        airplayButton.accessibilityLabel = "AirPlay"
        cornerStack.addArrangedSubview(airplayButton)
        cornerStack.addArrangedSubview(pipButton)
        cornerStack.axis = .horizontal
        cornerStack.spacing = 12
        // 视频上统一用深色玻璃、白色图标
        cornerStack.overrideUserInterfaceStyle = .dark
        addSubview(cornerStack)

        progress.onScrub = { [weak self] phase, f in self?.scrub(phase, f) }
        progress.onTap = { [weak self] f in self?.progressTapped(f) }
        addSubview(progress)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        let boost = UILongPressGestureRecognizer(target: self, action: #selector(handleBoost(_:)))
        boost.minimumPressDuration = 0.4
        boost.delegate = self
        addGestureRecognizer(boost)

        // 往下拉：视频跟着手指往下走，拉够距离或甩一下就退出全屏
        let dismiss = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismiss.delegate = self
        dismiss.maximumNumberOfTouches = 1
        addGestureRecognizer(dismiss)
        dismissPan = dismiss

        // 图标和文字分开排、各自垂直居中（图标做成文字附件会把基线拉低，文字显得偏下）
        let hintIcon = UIImageView(image: UIImage(systemName: "forward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
        hintIcon.tintColor = .white
        let hintLabel = UILabel()
        hintLabel.text = L("2× 倍速播放中")
        hintLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hintLabel.textColor = .white
        hintIcon.sizeToFit()
        hintLabel.sizeToFit()
        let hintGap: CGFloat = 7
        let contentWidth = hintIcon.bounds.width + hintGap + hintLabel.bounds.width
        boostHint.bounds = CGRect(x: 0, y: 0, width: contentWidth + 34, height: 38)
        let startX = (boostHint.bounds.width - contentWidth) / 2
        hintIcon.center = CGPoint(x: startX + hintIcon.bounds.width / 2, y: boostHint.bounds.midY)
        hintLabel.center = CGPoint(x: startX + hintIcon.bounds.width + hintGap + hintLabel.bounds.width / 2, y: boostHint.bounds.midY)
        boostHint.contentView.addSubview(hintIcon)
        boostHint.contentView.addSubview(hintLabel)
        boostHint.overrideUserInterfaceStyle = .dark
        boostHint.alpha = 0
        boostHint.isUserInteractionEnabled = false
        addSubview(boostHint)

        let railPan = UIPanGestureRecognizer(target: self, action: #selector(handleRailPan(_:)))
        rail.addGestureRecognizer(railPan)

        setControls(visible: true, animated: false)

        // 视频画面深浅不定：浅色填充 + 深色描边，两种背景上都看得见
        pageHandle.overrideUserInterfaceStyle = .dark
        pageHandle.onTap = { [weak self] in self?.setPageMenu(visible: !(self?.pageMenuVisible ?? true)) }
        pageHandle.onDrop = { [weak self] side, y in
            guard let self else { return }
            Settings.handleSide = side
            let h = max(self.bounds.height, 1)
            Settings.handleY = Double(y / h).clamped01
            self.setNeedsLayout()
            UIView.animate(withDuration: 0.3) { self.layoutIfNeeded() }
        }
        pageMoreButton.showsMenuAsPrimaryAction = true
        pageMoreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.pageMenuProvider?() ?? []) },
        ])
        pageBackButton.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)
        for b in [pageMoreButton, pageBackButton] {
            b.removeConstraints(b.constraints)
            b.translatesAutoresizingMaskIntoConstraints = true
            b.overrideUserInterfaceStyle = .dark
        }
        for v in [pageHandle, pageMoreButton, pageBackButton] as [UIView] {
            v.isHidden = true
            addSubview(v)
        }
    }

    private func configureMediaPageMode() {
        rail.useTabsButton(mediaPageMode)
        pageHandle.isHidden = !mediaPageMode
        setPageMenu(visible: false)
        setNeedsLayout()
    }

    private func setPageMenu(visible: Bool) {
        pageMenuVisible = visible && mediaPageMode
        for b in [pageMoreButton, pageBackButton] {
            b.isHidden = false
            UIView.animate(withDuration: 0.2, animations: { b.alpha = self.pageMenuVisible ? 1 : 0 },
                           completion: { _ in b.isHidden = !self.pageMenuVisible })
        }
        if pageMenuVisible { hideTask?.cancel() } else { scheduleHide() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 状态

    var isPlaying: Bool { state?.isPlaying ?? false }

    func update(_ newState: PlayerState) {
        let wasPlaying = state?.isPlaying
        state = newState
        stateStamp = CACurrentMediaTime()
        rail.setPlaying(newState.isPlaying)
        rail.setHasSubtitles(!newState.textTracks.isEmpty)
        if pipButton.isHidden == newState.supportsPiP {
            pipButton.isHidden = !newState.supportsPiP
            setNeedsLayout()   // 按钮组宽度变了，重新排（否则 AirPlay 被挤扁）
        }
        // 投放中图标高亮成系统蓝
        airplayButton.configuration?.baseForegroundColor = newState.isWireless ? .systemBlue : .label
        progress.isHidden = newState.range == nil

        if !newState.isPlaying {
            hideTask?.cancel()
            if !controlsVisible { setControls(visible: true, animated: true) }
        } else if wasPlaying != true {
            scheduleHide()
        }
        tick()
    }

    /// 两次上报之间按播放速率插值，进度条才能连续走
    private var currentTime: Double {
        guard let state else { return 0 }
        var t = state.time
        if state.isPlaying {
            t += min(CACurrentMediaTime() - stateStamp, 1.0) * state.rate
        }
        if let range = state.range { t = min(max(t, range.lowerBound), range.upperBound) }
        return t
    }

    @objc private func tick() {
        guard let state else { return }
        let t = scrubbing ? scrubTime : currentTime
        if let range = state.range {
            let span = max(range.upperBound - range.lowerBound, 0.001)
            progress.set(played: (t - range.lowerBound) / span, buffered: (state.buffered - range.lowerBound) / span)
            progress.setTime(current: t, total: state.isLive ? nil : range.upperBound, live: state.isLive)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaInsets
        // 轨道放在 Home 手势区上方；触摸区从轨道下方 10pt 一直到竖线顶端再往上，手指可以在高处拖
        let line = lineOffset
        // 轨道上方留出更高的触摸区，手指可以在高处拖
        let trackCenterY: CGFloat = 70
        let height = ProgressBarView.height(trackCenterY: trackCenterY)
        progress.trackCenterY = trackCenterY
        progress.frame = CGRect(x: 0, y: bounds.height - line - trackCenterY, width: bounds.width, height: height)
        // 两端留足余量，不伸到屏幕圆角外面：横屏让出整个安全区（刘海那一侧的宽度），竖屏 32pt
        let notch = max(safe.left, safe.right)
        progress.horizontalInset = notch > 0 ? notch + 6 : 32

        let width = ControlRailView.width
        let top = max(safe.top, 10) + 4
        let bottom = line + 78
        let x: CGFloat = side == .left
            ? max(safe.left, 8)
            : bounds.width - max(safe.right, 8) - width
        rail.frame = CGRect(x: x + railDrag, y: top, width: width, height: bounds.height - top - bottom)
        // 画中画 / AirPlay 放在控制列对面的上角（和退出按钮同一行），控制列换边时一起换；
        // 画中画靠屏幕边缘
        let order: [UIView] = side == .right ? [pipButton, airplayButton] : [airplayButton, pipButton]
        if cornerStack.arrangedSubviews != order { order.forEach { cornerStack.addArrangedSubview($0) } }
        let cornerSize = cornerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // 和对面控制列里的退出按钮左右对称
        let inset = (width - 44) / 2
        let cornerX = side == .right
            ? max(safe.left, 8) + inset
            : bounds.width - max(safe.right, 8) - inset - cornerSize.width
        cornerStack.frame = CGRect(x: cornerX, y: top + (44 - cornerSize.height) / 2,
                                   width: cornerSize.width, height: cornerSize.height)
        boostHint.center = CGPoint(x: bounds.midX, y: max(safe.top, 12) + 28)

        if mediaPageMode {
            // 和浏览器里的竖线一样：贴边、按保存的高度；⋯ / 返回 竖排在它旁边
            let size = EdgeHandleView.size
            let onRight = Settings.handleSide == .right
            let minY = safe.top + size.height / 2, maxY = bounds.height - max(safe.bottom, 12) - size.height / 2
            let y = min(max(bounds.height * Settings.handleY, minY), maxY)
            pageHandle.side = Settings.handleSide
            pageHandle.frame = CGRect(x: onRight ? bounds.width - size.width : 0, y: y - size.height / 2, width: size.width, height: size.height)
            let d: CGFloat = 44, g: CGFloat = 10
            var x = onRight ? bounds.width - max(safe.right, 0) - size.width - d : max(safe.left, 0) + size.width
            // 和控制列在同一侧时，让到控制列里侧
            if (side == .right) == onRight {
                x = onRight ? rail.frame.minX - 8 - d : rail.frame.maxX + 8
            }
            pageMoreButton.frame = CGRect(x: x, y: y - d - g / 2, width: d, height: d)
            pageBackButton.frame = CGRect(x: x, y: y + g / 2, width: d, height: d)
        }
    }

    /// 进度条线条离屏幕底边的距离
    private var lineOffset: CGFloat { max(safeAreaInsets.bottom, 12) + 6 }

    // MARK: - 显隐

    private func setControls(visible: Bool, animated: Bool) {
        controlsVisible = visible
        rail.isUserInteractionEnabled = visible
        cornerStack.isUserInteractionEnabled = visible
        let changes = {
            self.rail.alpha = visible ? 1 : 0
            self.cornerStack.alpha = visible ? 1 : 0
            self.progress.setMode(visible ? .full : (Settings.alwaysShowProgress ? .minimal : .hidden))
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
        if visible { scheduleHide() } else { hideTask?.cancel(); if pageMenuVisible { setPageMenu(visible: false) } }
    }

    /// 有操作时重置自动隐藏计时
    private func poke() {
        if !controlsVisible { setControls(visible: true, animated: true) } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controlsVisible, state?.isPlaying ?? true, !scrubbing, !railDragging else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.setControls(visible: false, animated: true)
        }
    }

    @objc private func handleTap() {
        if pageMenuVisible { setPageMenu(visible: false); return }
        setControls(visible: !controlsVisible, animated: true)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 按钮、进度条、控制列上的触摸不触发点击显隐 / 长按加速 / 下拉退出
        guard !(touch.view is UIControl), touch.view?.isDescendant(of: progress) != true,
              touch.view?.isDescendant(of: pageHandle) != true else { return false }
        if g is UILongPressGestureRecognizer || g === dismissPan, touch.view?.isDescendant(of: rail) == true { return false }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === dismissPan, let pan = g as? UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(g) }
        // 只接往下、且以竖直方向为主的拖动；长按加速中不触发
        let v = pan.velocity(in: self)
        return rateBeforeBoost == nil && v.y > 0 && v.y > abs(v.x) * 1.2
    }

    #if DEBUG
    func debugTogglePageMenu() { setPageMenu(visible: !pageMenuVisible) }
    func debugDrag(_ dy: CGFloat) { onDismissDrag?(dy); alpha = max(0, 1 - dy / 160) }
    func debugDragEnd() { onDismissEnd?(true) }
    #endif

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        let dy = max(0, g.translation(in: self).y)
        switch g.state {
        case .began:
            hideTask?.cancel()
        case .changed:
            onDismissDrag?(dy)
            alpha = max(0, 1 - dy / 160)
        case .ended, .cancelled, .failed:
            let commit = g.state == .ended && (dy > 120 || g.velocity(in: self).y > 900)
            if !commit {
                UIView.animate(withDuration: 0.25) { self.alpha = 1 }
                scheduleHide()
            }
            onDismissEnd?(commit)
        default:
            break
        }
    }

    @objc private func handleBoost(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard let s = state, s.isPlaying, s.rate < 1.99 else { return }
            rateBeforeBoost = s.rate
            setRate(2)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            boostHint.transform = CGAffineTransform(translationX: 0, y: -8)
            UIView.animate(withDuration: 0.25) {
                self.boostHint.alpha = 1
                self.boostHint.transform = .identity
            }
        case .ended, .cancelled, .failed:
            guard let previous = rateBeforeBoost else { return }
            rateBeforeBoost = nil
            setRate(previous)
            UIView.animate(withDuration: 0.25) { self.boostHint.alpha = 0 }
        default:
            break
        }
    }

    private func setRate(_ rate: Double) {
        send(.rate(rate))
        // 乐观更新，进度插值立刻按新速度走
        if var s = state {
            s.time = currentTime
            s.rate = rate
            state = s
            stateStamp = CACurrentMediaTime()
        }
    }

    // MARK: - 控制列拖动换边

    @objc private func handleRailPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            railDragging = true
            hideTask?.cancel()
        case .changed:
            railDrag = g.translation(in: self).x
            setNeedsLayout()
            layoutIfNeeded()
        case .ended, .cancelled, .failed:
            railDragging = false
            let projected = rail.frame.midX + g.velocity(in: self).x * 0.15
            side = projected < bounds.midX ? .left : .right
            Settings.railSide = side
            railDrag = 0
            setNeedsLayout()
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3) {
                self.layoutIfNeeded()
            }
            scheduleHide()
        default:
            break
        }
    }

    // MARK: - 跳转

    private func seek(by delta: Double) {
        send(.seekBy(delta))
        // 乐观更新，避免等网页回报时进度条回跳
        if var s = state {
            s.time = currentTime + delta
            if let r = s.range { s.time = min(max(s.time, r.lowerBound), r.upperBound) }
            state = s
            stateStamp = CACurrentMediaTime()
        }
        poke()
    }

    private func time(at fraction: Double) -> Double? {
        guard let range = state?.range else { return nil }
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    private func scrub(_ phase: ProgressBarView.Phase, _ fraction: Double) {
        guard let t = time(at: fraction) else { return }
        scrubTime = t
        switch phase {
        case .began:
            scrubbing = true
            if !controlsVisible { setControls(visible: true, animated: true) }
            hideTask?.cancel()
            fallthrough
        case .changed:
            let now = CACurrentMediaTime()
            if now - lastScrubSeek > 0.12 {
                lastScrubSeek = now
                send(.seekTo(t, fast: true))
            }
        case .ended:
            scrubbing = false
            send(.seekTo(t, fast: false))
            if var s = state {
                s.time = t
                state = s
                stateStamp = CACurrentMediaTime()
            }
            scheduleHide()
        }
        tick()
    }

    private func progressTapped(_ fraction: Double) {
        // 控件隐藏时点底边只唤出控件，不误跳转
        guard controlsVisible else {
            setControls(visible: true, animated: true)
            return
        }
        guard let t = time(at: fraction) else { return }
        send(.seekTo(t, fast: false))
        if var s = state {
            s.time = t
            state = s
            stateStamp = CACurrentMediaTime()
        }
        poke()
    }

    private func send(_ command: PlayerCommand) {
        onCommand?(command)
    }

    // MARK: - 菜单（字幕 / 音轨 / 倍速 / 旋转）

    private func menuElements() -> [UIMenuElement] {
        hideTask?.cancel()
        defer { scheduleHide() }
        guard let state else { return [] }
        var items: [UIMenuElement] = []

        if !state.textTracks.isEmpty {
            let anyOn = state.textTracks.contains(where: \.isOn)
            var actions = [UIAction(title: L("关闭"), state: anyOn ? .off : .on) { [weak self] _ in self?.send(.text(-1)) }]
            actions += state.textTracks.map { track in
                UIAction(title: track.label, state: track.isOn ? .on : .off) { [weak self] _ in self?.send(.text(track.index)) }
            }
            items.append(UIMenu(title: L("字幕"), image: UIImage(systemName: "captions.bubble"), children: actions))
        }

        if state.audioTracks.count > 1 {
            let actions = state.audioTracks.map { track in
                UIAction(title: track.label, state: track.isOn ? .on : .off) { [weak self] _ in self?.send(.audio(track.index)) }
            }
            items.append(UIMenu(title: L("音轨"), image: UIImage(systemName: "waveform"), children: actions))
        }

        let rates = Self.rates.map { rate in
            UIAction(title: rate == 1 ? L("正常") : "\(rate.formatted())×", state: abs(state.rate - rate) < 0.01 ? .on : .off) { [weak self] _ in
                self?.send(.rate(rate))
            }
        }
        items.append(UIMenu(title: L("播放速度"), subtitle: "\(state.rate.formatted())×", image: UIImage(systemName: "speedometer"), children: rates))

        items.append(UIAction(title: L("旋转屏幕"), image: UIImage(systemName: "rotate.right")) { [weak self] _ in self?.onRotate?() })
        items.append(UIAction(title: L("常显进度条"), image: UIImage(systemName: "minus"), state: Settings.alwaysShowProgress ? .on : .off) { _ in
            Settings.alwaysShowProgress.toggle()
        })
        items.append(UIAction(title: L("离开 App 时自动画中画"), image: UIImage(systemName: "pip"), state: Settings.autoPiP ? .on : .off) { [weak self] _ in
            Settings.autoPiP.toggle()
            self?.onAutoPiPChange?(Settings.autoPiP)
        })
        return items
    }
}
