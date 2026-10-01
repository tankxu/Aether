import Combine
import WebKit

protocol TabManagerDelegate: AnyObject {
    func tabManager(_ manager: TabManager, didCreate tab: Tab)
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?)
    func tabManager(_ manager: TabManager, didUpdate tab: Tab)
}

final class TabManager: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selected: Tab?

    weak var delegate: TabManagerDelegate?
    private let environment: WebEnvironment

    private static let sessionKey = "session.tabs"
    private static let selectedKey = "session.selected"

    init(environment: WebEnvironment) {
        self.environment = environment
    }

    func tabs(incognito: Bool) -> [Tab] {
        tabs.filter { $0.isIncognito == incognito }
    }

    @discardableResult
    func open(
        url: URL?,
        incognito: Bool,
        configuration: WKWebViewConfiguration? = nil,
        after opener: Tab? = nil,
        select: Bool = true,
        lazyTitle: String? = nil,
        lazy: Bool = false
    ) -> Tab {
        let config = configuration ?? environment.makeConfiguration(incognito: incognito)
        let webView = environment.makeWebView(configuration: config)
        let tab = Tab(webView: webView, incognito: incognito, pendingURL: lazy ? url : nil, pendingTitle: lazyTitle)
        tab.onUpdate = { [weak self] tab in
            guard let self else { return }
            self.objectWillChange.send()
            self.delegate?.tabManager(self, didUpdate: tab)
        }

        if let opener, let index = tabs.firstIndex(of: opener) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        delegate?.tabManager(self, didCreate: tab)
        if let url, !lazy { tab.load(url) }
        if select { self.select(tab) }
        return tab
    }

    func select(_ tab: Tab) {
        guard tab !== selected else { return }
        let previous = selected
        selected = tab
        tab.activate()
        delegate?.tabManager(self, didSelect: tab, previous: previous)
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tabs.remove(at: index)

        if tab.isIncognito, tabs(incognito: true).isEmpty {
            environment.dropIncognitoStore()
        }

        if tab === selected {
            // 优先切到同模式的相邻标签页
            let sameMode = tabs.enumerated().filter { $0.element.isIncognito == tab.isIncognito }
            let next = sameMode.last(where: { $0.offset < index })?.element
                ?? sameMode.first?.element
                ?? tabs.last
            let previous = selected
            selected = nil
            if let next {
                select(next)
            } else {
                delegate?.tabManager(self, didSelect: nil, previous: previous)
            }
        }
    }

    func closeAll(incognito: Bool) {
        tabs(incognito: incognito).forEach(close)
    }

    // MARK: - 会话（只保存普通标签页）

    func saveSession() {
        let normal = tabs(incognito: false)
        let items: [[String: String]] = normal.compactMap { tab in
            guard let url = tab.url, !tab.isBlank else { return nil }
            return ["url": url.absoluteString, "title": tab.title]
        }
        UserDefaults.standard.set(items, forKey: Self.sessionKey)
        let selectedIndex = selected.flatMap { s in normal.filter { !$0.isBlank }.firstIndex(of: s) } ?? -1
        UserDefaults.standard.set(selectedIndex, forKey: Self.selectedKey)
    }

    func restoreSession() {
        let items = UserDefaults.standard.array(forKey: Self.sessionKey) as? [[String: String]] ?? []
        let selectedIndex = UserDefaults.standard.integer(forKey: Self.selectedKey)
        var restored: [Tab] = []
        for item in items {
            guard let s = item["url"], let url = URL(string: s) else { continue }
            restored.append(open(url: url, incognito: false, select: false, lazyTitle: item["title"], lazy: true))
        }
        if restored.indices.contains(selectedIndex) {
            select(restored[selectedIndex])
        } else if let last = restored.last {
            select(last)
        }
    }
}
