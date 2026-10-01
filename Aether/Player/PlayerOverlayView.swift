import UIKit

/// 全屏视频的原生控制层，盖在 WKWebView 上并吃掉所有触摸（网页自带控件不会被误触）。
/// 本身完全透明：只有侧边控制列和贴底进度条，没有任何蒙版。
final class PlayerOverlayView: UIView, UIGestureRecognizerDelegate {
    var onCommand: ((PlayerCommand) -> Void)?
    var onExit: (() -> Void)?
    var onRotate: (() -> Void)?

    private let rail = ControlRailView()
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

        progress.onScrub = { [weak self] phase, f in self?.scrub(phase, f) }
        progress.onTap = { [weak self] f in self?.progressTapped(f) }
        addSubview(progress)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        let railPan = UIPanGestureRecognizer(target: self, action: #selector(handleRailPan(_:)))
        rail.addGestureRecognizer(railPan)

        setControls(visible: true, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 状态

    func update(_ newState: PlayerState) {
        let wasPlaying = state?.isPlaying
        state = newState
        stateStamp = CACurrentMediaTime()
        rail.setPlaying(newState.isPlaying)
        rail.setHasSubtitles(!newState.textTracks.isEmpty)
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
        let trackCenterY: CGFloat = 50
        let height = ProgressBarView.height(trackCenterY: trackCenterY)
        progress.trackCenterY = trackCenterY
        progress.frame = CGRect(x: 0, y: bounds.height - line - trackCenterY, width: bounds.width, height: height)
        progress.horizontalInset = max(safe.left, safe.right) > 0 ? max(safe.left, safe.right) * 0.5 : 0

        let width = ControlRailView.width
        let top = max(safe.top, 10) + 4
        let bottom = line + 56
        let x: CGFloat = side == .left
            ? max(safe.left, 8)
            : bounds.width - max(safe.right, 8) - width
        rail.frame = CGRect(x: x + railDrag, y: top, width: width, height: bounds.height - top - bottom)
    }

    /// 进度条线条离屏幕底边的距离
    private var lineOffset: CGFloat { max(safeAreaInsets.bottom, 12) + 6 }

    // MARK: - 显隐

    private func setControls(visible: Bool, animated: Bool) {
        controlsVisible = visible
        rail.isUserInteractionEnabled = visible
        let changes = {
            self.rail.alpha = visible ? 1 : 0
            self.progress.setMode(visible ? .full : (Settings.alwaysShowProgress ? .minimal : .hidden))
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
        if visible { scheduleHide() } else { hideTask?.cancel() }
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
        setControls(visible: !controlsVisible, animated: true)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
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
            var actions = [UIAction(title: "关闭", state: anyOn ? .off : .on) { [weak self] _ in self?.send(.text(-1)) }]
            actions += state.textTracks.map { track in
                UIAction(title: track.label, state: track.isOn ? .on : .off) { [weak self] _ in self?.send(.text(track.index)) }
            }
            items.append(UIMenu(title: "字幕", image: UIImage(systemName: "captions.bubble"), children: actions))
        }

        if state.audioTracks.count > 1 {
            let actions = state.audioTracks.map { track in
                UIAction(title: track.label, state: track.isOn ? .on : .off) { [weak self] _ in self?.send(.audio(track.index)) }
            }
            items.append(UIMenu(title: "音轨", image: UIImage(systemName: "waveform"), children: actions))
        }

        let rates = Self.rates.map { rate in
            UIAction(title: rate == 1 ? "正常" : "\(rate.formatted())×", state: abs(state.rate - rate) < 0.01 ? .on : .off) { [weak self] _ in
                self?.send(.rate(rate))
            }
        }
        items.append(UIMenu(title: "播放速度", subtitle: "\(state.rate.formatted())×", image: UIImage(systemName: "speedometer"), children: rates))

        items.append(UIAction(title: "旋转屏幕", image: UIImage(systemName: "rotate.right")) { [weak self] _ in self?.onRotate?() })
        items.append(UIAction(title: "常显进度条", image: UIImage(systemName: "minus"), state: Settings.alwaysShowProgress ? .on : .off) { _ in
            Settings.alwaysShowProgress.toggle()
        })
        return items
    }
}
