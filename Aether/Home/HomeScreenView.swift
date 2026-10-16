import Combine
import UIKit

/// 首页 + 应用列表：第 0 屏是首页（搜索），往左滑是收藏的网页，像 iOS 桌面一样排列。
/// 长按进入编辑（抖动）模式：拖动排序、拖到边缘翻页 / 新建一屏、拖到别的图标上合成文件夹。
final class HomeScreenView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onOpen: ((URL) -> Void)?
    var onSearch: (() -> Void)?
    /// 横向滚动位置（以屏为单位，0 = 首页）
    var onScroll: ((CGFloat) -> Void)?
    var onEditingChange: ((Bool) -> Void)?
    /// 文件夹打开 / 关闭（首页底部的切换器要让开）
    var onFolderVisible: ((Bool) -> Void)?
    weak var presenter: UIViewController?

    let scrollView = UIScrollView()
    /// 第 0 屏，StartView 把首页内容放在这里
    let startPage = UIView()

    private final class GridPage: UIView {
        let canvas = UIView()
        /// 每屏底部自己的搜索框，跟着页面一起滑动
        let search: UIButton
        var scale: CGFloat = 1
        override init(frame: CGRect) {
            var config: UIButton.Configuration
            if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
            config.cornerStyle = .capsule
            config.title = L("搜索或输入网址")
            config.image = UIImage(systemName: "magnifyingglass")
            config.imagePadding = 8
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            config.baseForegroundColor = UIColor(white: 1, alpha: 0.75)
            search = UIButton(configuration: config)
            super.init(frame: frame)
            addSubview(canvas)
            addSubview(search)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private final class Drag {
        var item: HomeItem
        /// 原图标留在原处隐藏（拖动手势挂在它上面）；从文件夹拖出来时为 nil
        let sourceView: HomeIconView?
        let ghost: HomeIconView
        let touchOffset: CGPoint
        var gap: (page: Int, index: Int)
        var hoverID: UUID?
        var mergeID: UUID?
        var hoverTask: Task<Void, Never>?
        var edgeTask: Task<Void, Never>?
        var lastLocation: CGPoint = .zero

        init(item: HomeItem, sourceView: HomeIconView?, ghost: HomeIconView, touchOffset: CGPoint, gap: (Int, Int)) {
            self.item = item
            self.sourceView = sourceView
            self.ghost = ghost
            self.touchOffset = touchOffset
            self.gap = gap
        }
    }

    private var gridPages: [GridPage] = []
    private let pageControl = UIPageControl()
    private let doneButton: UIButton
    private let emptyHint = UILabel()

    private var pages: [[HomeItem]] = AppLibrary.shared.pages
    private var iconViews: [UUID: HomeIconView] = [:]
    private(set) var isEditing = false
    private var drag: Drag?
    private var folderOverlay: FolderOverlayView?
    private var iconSubscription: AnyCancellable?

    private let columns = AppLibrary.columns
    private let rows = AppLibrary.rows

    override init(frame: CGRect) {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
        config.title = L("完成")
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        doneButton = UIButton(configuration: config)
        super.init(frame: frame)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(startPage)

        pageControl.hidesForSinglePage = true
        pageControl.addAction(UIAction { [weak self] _ in self?.pageControlChanged() }, for: .valueChanged)
        addSubview(pageControl)

        doneButton.alpha = 0
        doneButton.addAction(UIAction { [weak self] _ in self?.setEditing(false) }, for: .primaryActionTriggered)
        addSubview(doneButton)

        emptyHint.text = L("在网页的 ⋯ 菜单里选「添加到收藏」\n收藏的网页会像应用一样出现在这里")
        emptyHint.numberOfLines = 0
        emptyHint.textAlignment = .center
        emptyHint.font = .systemFont(ofSize: 14)
        emptyHint.textColor = UIColor(white: 1, alpha: 0.55)

        AppLibrary.shared.onChange = { [weak self] in self?.libraryChanged() }
        iconSubscription = AppIconStore.shared.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.iconViews.values.forEach { $0.refresh() } }
        }
        render(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    private var pageWidth: CGFloat { max(bounds.width, 1) }

    private var currentAppPage: Int {
        max(0, min(pages.count - 1, Int((scrollView.contentOffset.x / pageWidth).rounded()) - 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let wasPage = scrollView.bounds.width > 0 ? (scrollView.contentOffset.x / scrollView.bounds.width).rounded() : 0
        scrollView.frame = bounds
        scrollView.contentSize = CGSize(width: w * CGFloat(1 + gridPages.count), height: h)
        if !scrollView.isDragging && !scrollView.isDecelerating { scrollView.contentOffset.x = wasPage * w }
        startPage.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let safe = safeAreaInsets
        // 从下往上：模式切换器（固定）→ 页码圆点（固定）→ 搜索框（每屏一个，跟着滑）→ 图标网格
        let switchTop = h - safe.bottom - 24 - ModeSwitch.size.height
        pageControl.sizeToFit()
        pageControl.center = CGPoint(x: w / 2, y: switchTop - 30)
        let searchHeight: CGFloat = 48
        let searchY = pageControl.frame.minY - 10 - searchHeight
        let top = safe.top + 60
        let canvasSize = HomeGrid.canvasSize(columns: columns, rows: rows)
        let available = CGSize(width: w - 32, height: max(searchY - 18 - top, 100))
        let scale = min(1, available.width / canvasSize.width, available.height / canvasSize.height)
        for (i, page) in gridPages.enumerated() {
            page.frame = CGRect(x: w * CGFloat(i + 1), y: 0, width: w, height: h)
            page.scale = scale
            page.canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            page.canvas.center = CGPoint(x: w / 2, y: top + canvasSize.height * scale / 2)
            page.canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
            let searchWidth = min(w - 48, 380)
            page.search.frame = CGRect(x: (w - searchWidth) / 2, y: searchY, width: searchWidth, height: searchHeight)
        }
        if let first = gridPages.first {
            emptyHint.frame = CGRect(x: 32, y: 0, width: w - 64, height: 60)
            emptyHint.center = CGPoint(x: w / 2, y: h * 0.4)
            if emptyHint.superview !== first { first.addSubview(emptyHint) }
        }

        doneButton.frame = CGRect(x: w - safe.right - 16 - 76, y: safe.top + 8, width: 76, height: 40)
        folderOverlay?.frame = bounds
    }

    private func ensurePageViews(_ count: Int) {
        while gridPages.count < count {
            let page = GridPage()
            page.search.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .primaryActionTriggered)
            page.search.alpha = isEditing ? 0 : 1
            let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
            tap.delegate = self
            page.addGestureRecognizer(tap)
            scrollView.addSubview(page)
            gridPages.append(page)
        }
        while gridPages.count > count {
            gridPages.removeLast().removeFromSuperview()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - 渲染

    private func libraryChanged() {
        guard drag == nil else { return }
        pages = AppLibrary.shared.pages
        render(animated: true)
    }

    private func render(animated: Bool) {
        ensurePageViews(pages.count)
        var seen = Set<UUID>()
        for (p, items) in pages.enumerated() {
            let canvas = gridPages[p].canvas
            for (i, item) in items.enumerated() {
                var slot = i
                if let gap = drag?.gap, gap.page == p, i >= gap.index { slot += 1 }
                let view = iconViews[item.id] ?? createIconView(item)
                if view.item != item { view.item = item }
                let frame = HomeGrid.slotFrame(slot, columns: columns)
                if view.superview !== canvas {
                    canvas.addSubview(view)
                    view.frame = frame
                    view.setEditing(isEditing, animated: false)
                } else if animated {
                    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                                   options: [.allowUserInteraction, .beginFromCurrentState]) { view.frame = frame }
                } else {
                    view.frame = frame
                }
                // 拖动中当前屏放不下时，最后一个暂时藏起来（放下后会挤到下一屏）
                view.alpha = slot < AppLibrary.capacity ? 1 : 0
                seen.insert(item.id)
            }
        }
        for (id, view) in iconViews where !seen.contains(id) && view !== drag?.sourceView {
            view.removeFromSuperview()
            iconViews[id] = nil
        }
        pageControl.numberOfPages = 1 + pages.count
        emptyHint.isHidden = pages.contains { !$0.isEmpty } || drag != nil
        updatePageControl()
    }

    private func createIconView(_ item: HomeItem) -> HomeIconView {
        let view = makeIconView(for: item)
        let tap = UITapGestureRecognizer(target: self, action: #selector(iconTapped(_:)))
        view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(iconPressed(_:)))
        press.minimumPressDuration = isEditing ? 0.15 : 0.45
        view.addGestureRecognizer(press)
        view.onDelete = { [weak self, weak view] in
            guard let self, let view else { return }
            self.delete(view.item)
        }
        iconViews[item.id] = view
        return view
    }

    private func position(of id: UUID) -> (Int, Int)? {
        for (p, items) in pages.enumerated() {
            if let i = items.firstIndex(where: { $0.id == id }) { return (p, i) }
        }
        return nil
    }

    // MARK: - 编辑模式

    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        for view in iconViews.values {
            view.setEditing(editing, animated: true)
            for case let press as UILongPressGestureRecognizer in view.gestureRecognizers ?? [] {
                press.minimumPressDuration = editing ? 0.15 : 0.45
            }
        }
        folderOverlay?.setEditing(editing)
        updatePageControl()
        onEditingChange?(editing)
        if editing { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    /// 离开首页时调用
    func reset() {
        setEditing(false)
        folderOverlay?.dismiss(animated: false)
    }

    private func updatePageControl() {
        pageControl.currentPage = Int((scrollView.contentOffset.x / pageWidth).rounded())
        let onApps = scrollView.contentOffset.x > pageWidth * 0.5
        UIView.animate(withDuration: 0.2) { self.doneButton.alpha = self.isEditing && onApps ? 1 : 0 }
        doneButton.isUserInteractionEnabled = isEditing && onApps
        // 编辑时隐藏搜索框，免得拖图标时误触
        for page in gridPages {
            page.search.alpha = isEditing ? 0 : 1
            page.search.isUserInteractionEnabled = !isEditing
        }
    }

    /// 点页码圆点跳到对应的屏
    private func pageControlChanged() {
        scrollView.setContentOffset(CGPoint(x: CGFloat(pageControl.currentPage) * pageWidth, y: 0), animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?(scrollView.contentOffset.x / pageWidth)
        updatePageControl()
    }

    // MARK: - 点击

    @objc private func iconTapped(_ g: UITapGestureRecognizer) {
        guard let view = g.view as? HomeIconView, drag == nil else { return }
        switch view.item {
        case .app(let app):
            guard !isEditing, let url = URL(string: app.url) else { return }
            UIView.animate(withDuration: 0.1, animations: { view.iconView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) },
                           completion: { _ in UIView.animate(withDuration: 0.15) { view.iconView.transform = .identity } })
            onOpen?(url)
        case .folder(let folder):
            openFolder(folder, from: view)
        }
    }

    @objc private func backgroundTapped(_ g: UITapGestureRecognizer) {
        if isEditing { setEditing(false) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 背景点击只响应空白处
        !(touch.view is HomeIconView) && !(touch.view?.superview is HomeIconView) && touch.view?.isDescendant(ofType: HomeIconView.self) != true
    }

    private func delete(_ item: HomeItem) {
        switch item {
        case .app:
            AppLibrary.shared.remove(id: item.id)
        case .folder(let folder):
            let alert = UIAlertController(title: L("删除文件夹“%@”？", folder.name), message: L("其中的 %d 个网页会一起删除。", folder.apps.count), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { _ in AppLibrary.shared.remove(id: folder.id) })
            presenter?.present(alert, animated: true)
        }
    }

    // MARK: - 拖动

    @objc private func iconPressed(_ g: UILongPressGestureRecognizer) {
        guard let view = g.view as? HomeIconView else { return }
        let location = g.location(in: self)
        switch g.state {
        case .began:
            if !isEditing { setEditing(true) }
            beginDrag(view, at: location)
        case .changed:
            moveDrag(to: location)
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    private func beginDrag(_ view: HomeIconView, at location: CGPoint) {
        guard drag == nil, let (p, i) = position(of: view.item.id) else { return }
        let item = pages[p].remove(at: i)
        let center = view.superview!.convert(view.center, to: self)
        let ghost = makeGhost(for: item, at: center, scale: gridPages[p].scale)
        view.alpha = 0
        drag = Drag(item: item, sourceView: view, ghost: ghost,
                    touchOffset: CGPoint(x: location.x - center.x, y: location.y - center.y), gap: (p, i))
        drag?.lastLocation = location
        scrollView.isScrollEnabled = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 从文件夹里拖出来：接着在桌面上拖
    func beginExternalDrag(_ app: WebApp, from folderID: UUID, at location: CGPoint) {
        guard drag == nil else { return }
        pages = pages.map { page in
            page.map { item in
                guard case .folder(var f) = item, f.id == folderID else { return item }
                f.apps.removeAll { $0.id == app.id }
                return .folder(f)
            }
        }
        let p = currentAppPage
        let ghost = makeGhost(for: .app(app), at: location, scale: gridPages[safe: p]?.scale ?? 1)
        drag = Drag(item: .app(app), sourceView: nil, ghost: ghost, touchOffset: .zero, gap: (p, pages[p].count))
        drag?.lastLocation = location
        scrollView.isScrollEnabled = false
        render(animated: true)
    }

    private func makeGhost(for item: HomeItem, at center: CGPoint, scale: CGFloat) -> HomeIconView {
        let ghost = makeIconView(for: item)
        ghost.isUserInteractionEnabled = false
        ghost.center = center
        ghost.transform = CGAffineTransform(scaleX: scale, y: scale)
        addSubview(ghost)
        UIView.animate(withDuration: 0.2) {
            ghost.transform = CGAffineTransform(scaleX: scale * 1.15, y: scale * 1.15)
            ghost.alpha = 0.92
        }
        return ghost
    }

    func moveDrag(to location: CGPoint) {
        guard let drag else { return }
        drag.lastLocation = location
        drag.ghost.center = CGPoint(x: location.x - drag.touchOffset.x, y: location.y - drag.touchOffset.y)
        handleEdge(location)

        let p = currentAppPage
        guard let page = gridPages[safe: p] else { return }
        let point = page.canvas.convert(drag.ghost.center, from: self)

        // 悬停在别的图标上 → 准备合成文件夹（文件夹不能再放进文件夹）
        let isFolder: Bool = { if case .folder = drag.item { return true }; return false }()
        var hovered: UUID?
        if !isFolder {
            for (i, item) in pages[p].enumerated() {
                var slot = i
                if drag.gap.page == p, i >= drag.gap.index { slot += 1 }
                let f = HomeGrid.slotFrame(slot, columns: columns)
                let c = CGPoint(x: f.midX, y: f.minY + HomeGrid.icon / 2)
                if hypot(point.x - c.x, point.y - c.y) < HomeGrid.icon * 0.42 { hovered = item.id; break }
            }
        }
        if hovered != drag.hoverID {
            drag.hoverTask?.cancel()
            if let old = drag.mergeID { iconViews[old]?.setMergeHighlight(false) }
            drag.mergeID = nil
            drag.hoverID = hovered
            if let hovered {
                drag.hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self, let drag = self.drag, drag.hoverID == hovered else { return }
                    drag.mergeID = hovered
                    self.iconViews[hovered]?.setMergeHighlight(true)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        if hovered != nil { return }

        let slot = HomeGrid.slot(at: CGPoint(x: point.x, y: point.y - HomeGrid.icon / 2 + HomeGrid.cell.height / 2),
                                 columns: columns, rows: rows, count: pages[p].count)
        if drag.gap.page != p || drag.gap.index != slot {
            drag.gap = (p, slot)
            render(animated: true)
        }
    }

    /// 拖到左右边缘停一下：翻页；最后一屏再往右就新建一屏
    private func handleEdge(_ location: CGPoint) {
        guard let drag else { return }
        let margin: CGFloat = 26
        let direction = location.x < margin ? -1 : (location.x > bounds.width - margin ? 1 : 0)
        guard direction != 0 else {
            drag.edgeTask?.cancel()
            drag.edgeTask = nil
            return
        }
        guard drag.edgeTask == nil else { return }
        drag.edgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let drag = self.drag else { return }
            drag.edgeTask = nil
            let p = self.currentAppPage
            let target = p + direction
            guard target >= 0 else { return }
            if target >= self.pages.count {
                // 最后一屏只有拖动的这个图标时不再新建
                guard !self.pages[p].isEmpty || drag.gap.page != p else { return }
                self.pages.append([])
            }
            drag.gap = (target, self.pages[target].count)
            self.render(animated: true)
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
                self.scrollView.contentOffset.x = CGFloat(target + 1) * self.pageWidth
            }, completion: { _ in
                self.moveDrag(to: drag.lastLocation)
            })
        }
    }

    func endDrag() {
        guard let drag else { return }
        drag.hoverTask?.cancel()
        drag.edgeTask?.cancel()
        self.drag = nil
        scrollView.isScrollEnabled = true

        var targetID = drag.item.id
        if let mergeID = drag.mergeID, let (tp, ti) = position(of: mergeID), case .app(let dragged) = drag.item {
            iconViews[mergeID]?.setMergeHighlight(false)
            switch pages[tp][ti] {
            case .app(let target):
                let folder = AppFolder(name: L("文件夹"), apps: [target, dragged])
                pages[tp][ti] = .folder(folder)
                targetID = folder.id
            case .folder(var folder):
                folder.apps.append(dragged)
                pages[tp][ti] = .folder(folder)
                targetID = folder.id
            }
        } else {
            let page = min(drag.gap.page, pages.count - 1)
            pages[page].insert(drag.item, at: min(drag.gap.index, pages[page].count))
        }

        AppLibrary.shared.setPages(pages)
        pages = AppLibrary.shared.pages
        render(animated: true)
        let lastPage = CGFloat(pages.count) * pageWidth
        if scrollView.contentOffset.x > lastPage { scrollView.setContentOffset(CGPoint(x: lastPage, y: 0), animated: true) }

        // 幽灵图标飞到落点
        let ghost = drag.ghost
        guard let landing = iconViews[targetID], let canvas = landing.superview else {
            ghost.removeFromSuperview()
            return
        }
        landing.alpha = 0
        drag.sourceView?.alpha = landing === drag.sourceView ? 0 : 1
        let center = canvas.convert(landing.center, to: self)
        let scale = (gridPages.first { $0.canvas === canvas })?.scale ?? 1
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: {
            ghost.center = center
            ghost.transform = CGAffineTransform(scaleX: scale, y: scale)
            ghost.alpha = targetID == drag.item.id ? 1 : 0
        }, completion: { _ in
            ghost.removeFromSuperview()
            landing.alpha = 1
            landing.setEditing(self.isEditing, animated: false)
        })
    }

    // MARK: - 文件夹

    private func openFolder(_ folder: AppFolder, from view: HomeIconView) {
        let overlay = FolderOverlayView(folder: folder, editing: isEditing)
        overlay.frame = bounds
        overlay.onOpen = { [weak self] url in
            self?.folderOverlay?.dismiss(animated: true)
            self?.onOpen?(url)
        }
        overlay.onChange = { folder in AppLibrary.shared.updateFolder(folder) }
        overlay.onDelete = { id in AppLibrary.shared.remove(id: id) }
        overlay.onEnterEditing = { [weak self] in self?.setEditing(true) }
        overlay.onDismiss = { [weak self] in
            self?.folderOverlay = nil
            self?.onFolderVisible?(false)
        }
        overlay.onDragOut = { [weak self] app, point in
            guard let self, let folderID = self.folderOverlay?.folder.id else { return }
            self.folderOverlay?.dismiss(animated: true, keepForDrag: true)
            self.beginExternalDrag(app, from: folderID, at: self.convert(point, from: overlay))
        }
        overlay.onForwardDrag = { [weak self] state, point in
            guard let self else { return }
            let p = self.convert(point, from: overlay)
            if state == .changed { self.moveDrag(to: p) } else { self.endDrag(); overlay.removeFromSuperview() }
        }
        addSubview(overlay)
        folderOverlay = overlay
        onFolderVisible?(true)
        overlay.present(from: view.superview!.convert(view.frame, to: overlay))
    }
}

#if DEBUG
extension HomeScreenView {
    func debugShowApps(editing: Bool) {
        layoutIfNeeded()
        scrollView.contentOffset.x = pageWidth
        if editing { setEditing(true) }
    }

    func debugOpenFirstFolder() {
        debugShowApps(editing: false)
        for view in iconViews.values where { if case .folder = view.item { return true }; return false }() {
            if case .folder(let f) = view.item { openFolder(f, from: view) }
            return
        }
    }

    /// 把前两个应用合成一个文件夹（模拟拖到一起）
    func debugMakeFolder() {
        guard pages[0].count >= 3, case .app(let a) = pages[0][1], case .app(let b) = pages[0][2] else { return }
        pages[0].remove(at: 2)
        pages[0][1] = .folder(AppFolder(name: L("常用"), apps: [a, b]))
        AppLibrary.shared.setPages(pages)
    }
}
#endif

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension UIView {
    func isDescendant<T: UIView>(ofType: T.Type) -> Bool {
        var v: UIView? = self
        while let cur = v {
            if cur is T { return true }
            v = cur.superview
        }
        return false
    }
}
