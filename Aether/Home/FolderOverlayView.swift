import UIKit

/// 打开的文件夹：模糊背景 + 可改名的标题 + 玻璃面板里的图标网格。
/// 面板里长按可以拖动排序；拖出面板就回到桌面继续拖。
final class FolderOverlayView: UIView, UITextFieldDelegate {
    private(set) var folder: AppFolder
    var onOpen: ((URL) -> Void)?
    var onChange: ((AppFolder) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onEnterEditing: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// 拖出面板：交给桌面接着拖（坐标是本视图坐标）
    var onDragOut: ((WebApp, CGPoint) -> Void)?
    var onForwardDrag: ((UIGestureRecognizer.State, CGPoint) -> Void)?

    private let backdrop = UIVisualEffectView(effect: nil)
    private let titleField = UITextField()
    private let panel = GlassCapsuleView(cornerRadius: 38, interactive: false)
    private let canvas = UIView()
    private var iconViews: [UUID: HomeIconView] = [:]
    private var editing: Bool

    private let columns = 3
    private var dragApp: WebApp?
    private var dragView: HomeIconView?
    private var ghost: HomeIconView?
    private var gapIndex = 0
    private var touchOffset: CGPoint = .zero
    private var outsideTask: Task<Void, Never>?
    private var forwarding = false

    init(folder: AppFolder, editing: Bool) {
        self.folder = folder
        self.editing = editing
        super.init(frame: .zero)

        backdrop.frame = bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))
        addSubview(backdrop)

        titleField.text = folder.name
        titleField.font = UIFont.systemFont(ofSize: 30, weight: .bold)
        titleField.textColor = .white
        titleField.textAlignment = .center
        titleField.returnKeyType = .done
        titleField.clearButtonMode = .whileEditing
        titleField.delegate = self
        titleField.layer.shadowColor = UIColor.black.cgColor
        titleField.layer.shadowOpacity = 0.3
        titleField.layer.shadowRadius = 6
        titleField.layer.shadowOffset = .zero
        addSubview(titleField)

        panel.contentView.addSubview(canvas)
        addSubview(panel)
        renderIcons(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: Int { max(1, Int(ceil(Double(folder.apps.count + (dragApp != nil ? 1 : 0)) / Double(columns)))) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let canvasSize = HomeGrid.canvasSize(columns: columns, rows: max(rows, 3))
        let pad: CGFloat = 26
        let maxWidth = bounds.width - 48
        let scale = min(1, (maxWidth - pad * 2) / canvasSize.width)
        let panelSize = CGSize(width: canvasSize.width * scale + pad * 2, height: min(canvasSize.height * scale + pad * 2, bounds.height * 0.6))
        panel.bounds = CGRect(origin: .zero, size: panelSize)
        panel.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvas.center = CGPoint(x: panelSize.width / 2, y: pad + canvasSize.height * scale / 2)
        titleField.frame = CGRect(x: 32, y: panel.frame.minY - 64, width: bounds.width - 64, height: 44)
    }

    // MARK: - 打开 / 关闭

    func present(from sourceFrame: CGRect) {
        layoutIfNeeded()
        let finalCenter = panel.center
        panel.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.minY + HomeGrid.icon / 2)
        panel.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        panel.alpha = 0
        titleField.alpha = 0
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3) {
            self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            self.panel.center = finalCenter
            self.panel.transform = .identity
            self.panel.alpha = 1
            self.titleField.alpha = 1
        }
    }

    /// keepForDrag：拖出文件夹时界面先隐藏，等拖动手势结束再移除
    func dismiss(animated: Bool, keepForDrag: Bool = false) {
        commitName()
        onDismiss?()
        let finish = {
            if !keepForDrag { self.removeFromSuperview() }
        }
        guard animated else {
            alpha = 0
            finish()
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.backdrop.effect = nil
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            self.titleField.alpha = 0
            if keepForDrag { self.ghost?.alpha = 0 }
        }, completion: { _ in finish() })
    }

    @objc private func backgroundTapped() {
        if titleField.isFirstResponder { titleField.resignFirstResponder(); return }
        dismiss(animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitName()
    }

    private func commitName() {
        let name = titleField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty, name != folder.name else { return }
        folder.name = name
        onChange?(folder)
    }

    func setEditing(_ editing: Bool) {
        self.editing = editing
        iconViews.values.forEach { $0.setEditing(editing, animated: true) }
    }

    // MARK: - 图标

    private func renderIcons(animated: Bool) {
        var seen = Set<UUID>()
        for (i, app) in folder.apps.enumerated() {
            let slot = dragApp != nil && i >= gapIndex ? i + 1 : i
            let item = HomeItem.app(app)
            let view = iconViews[app.id] ?? makeView(item)
            let frame = HomeGrid.slotFrame(slot, columns: columns)
            if view.superview !== canvas {
                canvas.addSubview(view)
                view.frame = frame
                view.setEditing(editing, animated: false)
            } else if animated {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) { view.frame = frame }
            } else {
                view.frame = frame
            }
            seen.insert(app.id)
        }
        for (id, view) in iconViews where !seen.contains(id) && view !== dragView {
            view.removeFromSuperview()
            iconViews[id] = nil
        }
        setNeedsLayout()
    }

    private func makeView(_ item: HomeItem) -> HomeIconView {
        let view = makeIconView(for: item)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(iconTapped(_:))))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(iconPressed(_:)))
        press.minimumPressDuration = 0.35
        view.addGestureRecognizer(press)
        view.onDelete = { [weak self, weak view] in
            guard let self, let view else { return }
            self.folder.apps.removeAll { $0.id == view.item.id }
            self.onDelete?(view.item.id)
            self.renderIcons(animated: true)
            if self.folder.apps.isEmpty { self.dismiss(animated: true) }
        }
        iconViews[item.id] = view
        return view
    }

    @objc private func iconTapped(_ g: UITapGestureRecognizer) {
        guard !editing, let view = g.view as? HomeIconView, case .app(let app) = view.item, let url = URL(string: app.url) else { return }
        onOpen?(url)
    }

    // MARK: - 拖动

    @objc private func iconPressed(_ g: UILongPressGestureRecognizer) {
        let location = g.location(in: self)
        if forwarding {
            if g.state == .changed { onForwardDrag?(.changed, location) }
            if [.ended, .cancelled, .failed].contains(g.state) { onForwardDrag?(.ended, location) }
            return
        }
        guard let view = g.view as? HomeIconView, case .app(let app) = view.item else { return }
        switch g.state {
        case .began:
            if !editing { onEnterEditing?() }
            guard let index = folder.apps.firstIndex(of: app) else { return }
            folder.apps.remove(at: index)
            dragApp = app
            dragView = view
            gapIndex = index
            let center = canvas.convert(view.center, to: self)
            touchOffset = CGPoint(x: location.x - center.x, y: location.y - center.y)
            let ghost = makeIconView(for: .app(app))
            ghost.isUserInteractionEnabled = false
            ghost.center = center
            let s = canvas.transform.a
            ghost.transform = CGAffineTransform(scaleX: s * 1.15, y: s * 1.15)
            addSubview(ghost)
            self.ghost = ghost
            view.alpha = 0
        case .changed:
            guard let ghost else { return }
            ghost.center = CGPoint(x: location.x - touchOffset.x, y: location.y - touchOffset.y)
            if panel.frame.insetBy(dx: -16, dy: -16).contains(location) {
                outsideTask?.cancel()
                outsideTask = nil
                let p = canvas.convert(ghost.center, from: self)
                let slot = HomeGrid.slot(at: CGPoint(x: p.x, y: p.y - HomeGrid.icon / 2 + HomeGrid.cell.height / 2),
                                         columns: columns, rows: rows, count: folder.apps.count)
                if slot != gapIndex {
                    gapIndex = slot
                    renderIcons(animated: true)
                }
            } else if outsideTask == nil {
                // 在面板外停一下：拖出文件夹
                outsideTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let self, let app = self.dragApp else { return }
                    self.forwarding = true
                    self.onChange?(self.folder)
                    self.ghost?.removeFromSuperview()
                    self.ghost = nil
                    self.dragApp = nil
                    self.onDragOut?(app, location)
                }
            }
        case .ended, .cancelled, .failed:
            outsideTask?.cancel()
            outsideTask = nil
            guard let app = dragApp, let ghost else { return }
            folder.apps.insert(app, at: min(gapIndex, folder.apps.count))
            dragApp = nil
            renderIcons(animated: true)
            onChange?(folder)
            let landing = dragView
            dragView = nil
            let target = landing.map { canvas.convert($0.center, to: self) } ?? ghost.center
            let s = canvas.transform.a
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: {
                ghost.center = target
                ghost.transform = CGAffineTransform(scaleX: s, y: s)
            }, completion: { _ in
                ghost.removeFromSuperview()
                landing?.alpha = 1
            })
            self.ghost = nil
        default:
            break
        }
    }
}
