import UIKit

/// 竖排在屏幕一侧的控制列：顶部退出，中间 快退10s / 播放暂停 / 快进10s，底部菜单。
/// 没有任何底板或蒙版，只有带阴影的白色图标。
final class ControlRailView: UIView {
    static let width: CGFloat = 60

    var onExit: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onToggle: (() -> Void)?
    var menuProvider: (() -> [UIMenuElement])?

    private let exitButton = ControlRailView.makeButton("arrow.down.right.and.arrow.up.left", size: 17)
    private let backButton = ControlRailView.makeButton("gobackward.10", size: 25)
    private let playButton = ControlRailView.makeButton("pause.fill", size: 32)
    private let forwardButton = ControlRailView.makeButton("goforward.10", size: 25)
    private let menuButton = ControlRailView.makeButton("ellipsis", size: 18)
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var isPlaying = true
    private var hasSubtitles = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        exitButton.addAction(UIAction { [weak self] _ in self?.onExit?() }, for: .touchUpInside)
        backButton.addAction(UIAction { [weak self] _ in self?.seekTapped(-10, self?.backButton) }, for: .touchUpInside)
        forwardButton.addAction(UIAction { [weak self] _ in self?.seekTapped(10, self?.forwardButton) }, for: .touchUpInside)
        playButton.addAction(UIAction { [weak self] _ in
            self?.haptic.impactOccurred()
            self?.onToggle?()
        }, for: .touchUpInside)

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            },
        ])

        let center = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        center.axis = .vertical
        center.spacing = 14
        center.alignment = .center

        for v in [exitButton, center, menuButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            exitButton.topAnchor.constraint(equalTo: topAnchor),
            exitButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        playButton.configuration?.image = Self.symbol(playing ? "pause.fill" : "play.fill", size: 32)
    }

    func setHasSubtitles(_ has: Bool) {
        guard has != hasSubtitles else { return }
        hasSubtitles = has
        menuButton.configuration?.image = Self.symbol(has ? "captions.bubble" : "ellipsis", size: 18)
    }

    private func seekTapped(_ delta: Double, _ button: UIButton?) {
        haptic.impactOccurred()
        onSeek?(delta)
        guard let button else { return }
        // 轻微旋转一下作为反馈，不额外弹出任何提示
        let angle: CGFloat = delta < 0 ? -0.5 : 0.5
        UIView.animate(withDuration: 0.12, animations: {
            button.transform = CGAffineTransform(rotationAngle: angle)
        }, completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
                button.transform = .identity
            }
        })
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    private static func makeButton(_ name: String, size: CGFloat) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = symbol(name, size: size)
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.6
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = .zero
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 52),
            button.heightAnchor.constraint(equalToConstant: 52),
        ])
        return button
    }
}
