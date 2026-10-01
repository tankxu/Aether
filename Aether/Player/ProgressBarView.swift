import UIKit

/// 全屏播放的进度条：液态玻璃圆头轨道 + 当前进度竖线 + 竖线旁的时间。
/// 轨道在系统 Home 手势区上方；触摸区一直延伸到竖线顶端再往上一些，手指可以在高处拖。
final class ProgressBarView: UIView {
    enum Mode { case hidden, minimal, full }
    enum Phase { case began, changed, ended }

    var onScrub: ((Phase, Double) -> Void)?
    var onTap: ((Double) -> Void)?
    /// 横屏时左右避开刘海/圆角
    var horizontalInset: CGFloat = 0 { didSet { setNeedsLayout() } }
    /// 轨道中心距离 view 顶部的距离（上方是竖线和触摸余量，下方留一点余量）
    var trackCenterY: CGFloat = 50 { didSet { setNeedsLayout() } }

    /// view 需要的总高度：轨道中心上方 trackCenterY，下方 10pt
    static func height(trackCenterY: CGFloat) -> CGFloat { trackCenterY + 10 }

    private let track = GlassCapsuleView(interactive: false, clear: true)
    private let bufferedBar = UIView()
    private let playedBar = UIView()
    private let thinLine = UIView()      // 控件隐藏时“常显进度条”用的细线
    private let playhead: UIView = {
        // 竖线也是通透的玻璃，带一点白色调
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .clear)
            glass.tintColor = UIColor(white: 1, alpha: 0.35)
            let v = UIVisualEffectView(effect: glass)
            v.cornerConfiguration = .capsule()
            return v
        }
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        v.layer.borderWidth = 0.5
        return v
    }()
    private let timeLabel = UILabel()

    private var played: Double = 0
    private var buffered: Double = 0
    private var mode: Mode = .full
    private var scrubbing = false
    private var lastTimeText = ""

    private static let grabRadius: CGFloat = 26
    private var dragAbsolute = false
    private var dragStartFraction: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        track.isUserInteractionEnabled = false
        // 半透明，透出底下的画面，不要像实心条
        bufferedBar.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        playedBar.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        thinLine.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        playedBar.layer.shadowColor = UIColor.black.cgColor
        playedBar.layer.shadowOpacity = 0.12
        playedBar.layer.shadowRadius = 2
        playedBar.layer.shadowOffset = .zero
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.layer.shadowColor = UIColor.black.cgColor
        timeLabel.layer.shadowOpacity = 0.75
        timeLabel.layer.shadowRadius = 3
        timeLabel.layer.shadowOffset = .zero
        for v in [track, bufferedBar, playedBar, thinLine, playhead, timeLabel] as [UIView] {
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(played: Double, buffered: Double) {
        self.played = played.clamped01
        self.buffered = buffered.clamped01
        layoutBars()
    }

    func setTime(current: Double, total: Double?, live: Bool) {
        let text = live && total == nil ? "直播" : TimeFormat.string(current) + (total.map { " / " + TimeFormat.string($0) } ?? "")
        guard text != lastTimeText else { return }
        lastTimeText = text
        let s = NSMutableAttributedString(string: text)
        if let slash = text.range(of: " / ") {
            let r = NSRange(slash.lowerBound..., in: text)
            s.addAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.65),
                             .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)], range: r)
        }
        timeLabel.attributedText = s
        timeLabel.sizeToFit()
        layoutBars()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        layoutBars()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private var trackWidth: CGFloat { max(bounds.width - horizontalInset * 2, 1) }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = mode == .full || scrubbing
        let h: CGFloat = scrubbing ? 10 : 6
        let x0 = horizontalInset
        let w = trackWidth
        let y = trackCenterY - h / 2

        track.frame = CGRect(x: x0, y: y, width: w, height: h)
        // 两段都是圆头胶囊；进度很短时至少保留一个圆点
        let inner: CGFloat = 1
        let innerH = h - inner * 2
        let bw = max(innerH, (w - inner * 2) * buffered)
        let pw = max(innerH, (w - inner * 2) * played)
        bufferedBar.frame = CGRect(x: x0 + inner, y: y + inner, width: bw, height: innerH)
        playedBar.frame = CGRect(x: x0 + inner, y: y + inner, width: pw, height: innerH)
        for v in [bufferedBar, playedBar] { v.layer.cornerRadius = innerH / 2 }

        let px = x0 + w * played
        let lineH: CGFloat = scrubbing ? 32 : 26
        playhead.frame = CGRect(x: px - 2, y: trackCenterY + h / 2 + 2 - lineH, width: 4, height: lineH)
        if #unavailable(iOS 26.0) { playhead.layer.cornerRadius = 2 }

        // 时间放在竖线顶部旁边，默认右侧，靠近右边缘换到左侧
        let size = timeLabel.bounds.size
        let gap: CGFloat = 7
        let labelY = playhead.frame.minY + size.height / 2 + 1
        var lx = px + gap + size.width / 2
        if lx + size.width / 2 > bounds.width - horizontalInset - 6 { lx = px - gap - size.width / 2 }
        lx = max(lx, size.width / 2 + 6)
        timeLabel.center = CGPoint(x: lx, y: labelY)

        thinLine.frame = CGRect(x: x0, y: trackCenterY - 1, width: w * played, height: 2)
        thinLine.layer.cornerRadius = 1

        for v in [track, bufferedBar, playedBar, playhead, timeLabel] as [UIView] { v.alpha = full ? 1 : 0 }
        thinLine.alpha = !full && mode == .minimal ? 1 : 0
    }

    private func fraction(at point: CGPoint) -> Double {
        Double((point.x - horizontalInset) / trackWidth).clamped01
    }

    /// 拖动：默认相对位移（从当前进度按手指移动距离前后调）；
    /// 只有按下时正好在进度竖线附近，才跟随手指走绝对位置
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: self).x
        switch g.state {
        case .began:
            // 识别出拖动时手指已移动了一小段，倒推出按下的位置
            let downX = g.location(in: self).x - translation
            let playheadX = horizontalInset + trackWidth * played
            dragAbsolute = abs(downX - playheadX) <= Self.grabRadius
            dragStartFraction = played
            scrubbing = true
            fallthrough
        case .changed:
            let f = dragAbsolute
                ? fraction(at: g.location(in: self))
                : (dragStartFraction + Double(translation / trackWidth)).clamped01
            played = f
            layoutBars()
            onScrub?(g.state == .began ? .began : .changed, f)
        case .ended, .cancelled, .failed:
            scrubbing = false
            layoutBars()
            onScrub?(.ended, played)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        onTap?(fraction(at: g.location(in: self)))
    }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
