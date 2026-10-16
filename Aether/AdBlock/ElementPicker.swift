import UIKit
import WebKit

/// 手动屏蔽网页元素：脚本跑在独立 content world，底部玻璃面板负责调整范围和确认
final class ElementPicker {
    static let world = WKContentWorld.world(name: "aether-picker")
    static let messageName = "aetherPicker"

    private static let source: String = {
        guard let url = Bundle.main.url(forResource: "aether-picker", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    let webView: WKWebView
    let host: String
    let bar = PickerBarView()
    var onFinish: (() -> Void)?

    init(webView: WKWebView, host: String) {
        self.webView = webView
        self.host = host
        bar.onExpand = { [weak self] in self?.run("window.__aetherPicker.expand()") }
        bar.onShrink = { [weak self] in self?.run("window.__aetherPicker.shrink()") }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onConfirm = { [weak self] in self?.confirm() }
    }

    func start() {
        webView.evaluateJavaScript(Self.source, in: nil, in: Self.world, completionHandler: nil)
    }

    func handle(_ body: [String: Any]) {
        guard body["type"] as? String == "pick", let selector = body["selector"] as? String else { return }
        bar.update(selector: selector, count: (body["count"] as? NSNumber)?.intValue ?? 0)
    }

    func cancel() {
        run("window.__aetherPicker.cancel()")
        onFinish?()
    }

    private func confirm() {
        webView.evaluateJavaScript("window.__aetherPicker.confirm()", in: nil, in: Self.world) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, let selector = value as? String, !selector.isEmpty {
                ContentBlocker.shared.addUserRule(host: host, selector: selector)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            onFinish?()
        }
    }

    private func run(_ js: String) {
        webView.evaluateJavaScript(js, in: nil, in: Self.world, completionHandler: nil)
    }
}

final class PickerBarView: UIView {
    var onExpand: (() -> Void)?
    var onShrink: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let panel = GlassCapsuleView(cornerRadius: 26)
    private let titleLabel = UILabel()
    private let selectorLabel = UILabel()
    private let confirmButton: UIButton

    override init(frame: CGRect) {
        var confirm: UIButton.Configuration
        if #available(iOS 26.0, *) { confirm = .prominentGlass() } else { confirm = .filled() }
        confirm.title = L("屏蔽")
        confirm.cornerStyle = .capsule
        confirm.baseBackgroundColor = .systemRed
        confirmButton = UIButton(configuration: confirm)
        super.init(frame: frame)

        titleLabel.text = L("轻点要屏蔽的内容")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        selectorLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        selectorLabel.textColor = .secondaryLabel
        selectorLabel.lineBreakMode = .byTruncatingMiddle
        selectorLabel.text = L("选中后可以扩大或缩小范围")

        let expand = Self.toolButton("arrow.up.left.and.arrow.down.right", L("扩大"))
        let shrink = Self.toolButton("arrow.down.right.and.arrow.up.left", L("缩小"))
        let cancel = Glass.circleButton("xmark", size: 44)
        expand.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .primaryActionTriggered)
        shrink.addAction(UIAction { [weak self] _ in self?.onShrink?() }, for: .primaryActionTriggered)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm?() }, for: .primaryActionTriggered)
        confirmButton.isEnabled = false

        let text = UIStackView(arrangedSubviews: [titleLabel, selectorLabel])
        text.axis = .vertical
        text.spacing = 2
        let buttons = UIStackView(arrangedSubviews: [shrink, expand, UIView(), confirmButton])
        buttons.spacing = 8
        buttons.alignment = .center
        let content = UIStackView(arrangedSubviews: [text, buttons])
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(content)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        addSubview(cancel)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            cancel.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: 10),
            cancel.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancel.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12),
            confirmButton.heightAnchor.constraint(equalToConstant: 40),
            confirmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(selector: String, count: Int) {
        titleLabel.text = L("已选中 %d 处", max(count, 1))
        selectorLabel.text = selector
        confirmButton.isEnabled = true
    }

    private static func toolButton(_ symbol: String, _ title: String) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
        config.image = UIImage(systemName: symbol)
        config.title = title
        config.imagePadding = 4
        config.cornerStyle = .capsule
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }
}
