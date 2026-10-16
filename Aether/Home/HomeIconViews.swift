import UIKit

/// 桌面网格几何：在一张固定大小的"画布"上排版，再按可用空间等比缩放（横屏、小屏也不错位）
enum HomeGrid {
    // 每屏 5 行，基本不用缩放：图标约 58pt（比 iOS 桌面的 64pt 小一点）
    static let cell = CGSize(width: 76, height: 90)
    static let icon: CGFloat = 58
    static let columnGap: CGFloat = 15
    static let rowGap: CGFloat = 14

    static func canvasSize(columns: Int, rows: Int) -> CGSize {
        CGSize(width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * columnGap,
               height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * rowGap)
    }

    static func slotFrame(_ index: Int, columns: Int) -> CGRect {
        let col = index % columns, row = index / columns
        return CGRect(x: CGFloat(col) * (cell.width + columnGap), y: CGFloat(row) * (cell.height + rowGap),
                      width: cell.width, height: cell.height)
    }

    /// 手指位置对应的插入位置
    static func slot(at p: CGPoint, columns: Int, rows: Int, count: Int) -> Int {
        let col = min(max(Int(((p.x + columnGap / 2) / (cell.width + columnGap)).rounded(.down)), 0), columns - 1)
        let row = min(max(Int(((p.y + rowGap / 2) / (cell.height + rowGap)).rounded(.down)), 0), rows - 1)
        return min(row * columns + col, count)
    }
}

/// 桌面上的一个图标（应用或文件夹）：图标 + 名称，编辑模式下抖动并显示删除按钮
class HomeIconView: UIView {
    var item: HomeItem { didSet { refresh() } }
    var onDelete: (() -> Void)?

    let iconView = UIView()
    private let label = UILabel()
    private let deleteButton: UIButton

    init(item: HomeItem) {
        self.item = item
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
        config.image = UIImage(systemName: "minus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        deleteButton = UIButton(configuration: config)
        super.init(frame: CGRect(origin: .zero, size: HomeGrid.cell))

        let inset = (HomeGrid.cell.width - HomeGrid.icon) / 2
        iconView.frame = CGRect(x: inset, y: 0, width: HomeGrid.icon, height: HomeGrid.icon)
        iconView.layer.cornerRadius = HomeGrid.icon * 0.225
        iconView.layer.cornerCurve = .continuous
        iconView.layer.shadowColor = UIColor.black.cgColor
        iconView.layer.shadowOpacity = 0.25
        iconView.layer.shadowRadius = 6
        iconView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(iconView)

        label.frame = CGRect(x: -6, y: HomeGrid.icon + 5, width: HomeGrid.cell.width + 12, height: 16)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.6
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)

        deleteButton.frame = CGRect(x: inset - 8, y: -8, width: 24, height: 24)
        deleteButton.alpha = 0
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered)
        addSubview(deleteButton)

        buildIcon()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func buildIcon() {}

    func refresh() {
        label.text = item.title
    }

    func setEditing(_ editing: Bool, animated: Bool) {
        UIView.animate(withDuration: animated ? 0.2 : 0) {
            self.deleteButton.alpha = editing ? 1 : 0
            self.deleteButton.transform = editing ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
        }
        deleteButton.isUserInteractionEnabled = editing
        if editing { startJiggle() } else { layer.removeAnimation(forKey: "jiggle") }
    }

    /// iOS 桌面那种轻微抖动，每个图标相位不同
    private func startJiggle() {
        guard layer.animation(forKey: "jiggle") == nil else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = 0.035
        a.values = [-angle, angle, -angle]
        a.duration = 0.26 + Double.random(in: 0...0.04)
        a.repeatCount = .infinity
        a.timeOffset = Double.random(in: 0...0.26)
        layer.add(a, forKey: "jiggle")
    }

    /// 拖动中悬停在上面、准备合成文件夹
    func setMergeHighlight(_ on: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.iconView.transform = on ? CGAffineTransform(scaleX: 1.18, y: 1.18) : .identity
            self.iconView.alpha = on ? 0.75 : 1
        }
    }

    /// 图标中心在自身坐标里的位置
    var iconCenter: CGPoint { iconView.center }
}

final class AppIconView: HomeIconView {
    private let imageView = UIImageView()

    override func buildIcon() {
        imageView.frame = iconView.bounds
        imageView.layer.cornerRadius = iconView.layer.cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        iconView.addSubview(imageView)
    }

    override func refresh() {
        super.refresh()
        if case .app(let app) = item { imageView.image = AppIconStore.shared.image(for: app) }
    }
}

final class FolderIconView: HomeIconView {
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    private var minis: [UIImageView] = []

    override func buildIcon() {
        backdrop.frame = iconView.bounds
        backdrop.layer.cornerRadius = iconView.layer.cornerRadius
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        iconView.addSubview(backdrop)
        // 3×3 小图标
        let pad: CGFloat = 8, gap: CGFloat = 4
        let s = (HomeGrid.icon - pad * 2 - gap * 2) / 3
        for i in 0..<9 {
            let v = UIImageView(frame: CGRect(x: pad + CGFloat(i % 3) * (s + gap), y: pad + CGFloat(i / 3) * (s + gap), width: s, height: s))
            v.layer.cornerRadius = s * 0.225
            v.layer.cornerCurve = .continuous
            v.clipsToBounds = true
            iconView.addSubview(v)
            minis.append(v)
        }
    }

    override func refresh() {
        super.refresh()
        guard case .folder(let folder) = item else { return }
        for (i, v) in minis.enumerated() {
            v.image = i < folder.apps.count ? AppIconStore.shared.image(for: folder.apps[i]) : nil
        }
    }
}

func makeIconView(for item: HomeItem) -> HomeIconView {
    switch item {
    case .app: AppIconView(item: item)
    case .folder: FolderIconView(item: item)
    }
}
