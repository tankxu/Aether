import Combine
import WebKit

/// 广告过滤总调度：
/// - 订阅规则 + 内置规则 → 解析（后台）→ 多张 WKContentRuleList（网络拦截 / 元素隐藏）+ 网页脚本数据
/// - 用户手动屏蔽的元素单独一张小表，改动后秒级重编
/// - 每个标签页一个 WKUserContentController：导航到白名单网站时把规则摘掉
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    enum Status: Equatable {
        case idle
        case downloading
        case compiling
        case failed(String)
    }

    struct UserRule: Codable, Hashable, Identifiable {
        var host: String
        var selector: String
        var id: String { host + "##" + selector }
    }

    @Published private(set) var subscriptions: [FilterSubscription]
    @Published private(set) var status: Status = .idle
    @Published private(set) var ruleCount = 0
    @Published private(set) var lastBuilt: Date?
    @Published private(set) var whitelist: [String]
    @Published private(set) var userRules: [UserRule]

    var isEnabled: Bool { Settings.adBlockEnabled }

    private let store = WKContentRuleListStore.default()!
    private var ruleLists: [WKContentRuleList] = []
    private var userList: WKContentRuleList?
    private var pageScript: WKUserScript?
    private var blockedHosts: Set<String> = []
    private var building = false
    private var rebuildQueued = false

    private final class ControllerState {
        weak var controller: WKUserContentController?
        let baseScripts: [WKUserScript]
        var host: String?
        var appliedActive: Bool?
        var appliedGeneration = -1
        init(controller: WKUserContentController, baseScripts: [WKUserScript]) {
            self.controller = controller
            self.baseScripts = baseScripts
        }
    }
    private var controllers: [ObjectIdentifier: ControllerState] = [:]
    /// 规则或脚本每更新一次加一，用来判断控制器是否需要重新挂载
    private var generation = 0

    private static let subscriptionsKey = "adblock.subscriptions"
    private static let whitelistKey = "adblock.whitelist"
    private static let userRulesKey = "adblock.userRules"
    nonisolated private static let listPrefix = "aether-ab-"
    private static let userPrefix = "aether-user-"
    /// 解析/生成逻辑改动时加一，强制重建缓存
    nonisolated private static let builderVersion = 3

    private init() {
        let defaults = UserDefaults.standard
        let saved = (defaults.data(forKey: Self.subscriptionsKey))
            .flatMap { try? JSONDecoder().decode([FilterSubscription].self, from: $0) } ?? []
        subscriptions = FilterSubscription.catalog.map { item in
            guard let s = saved.first(where: { $0.id == item.id }) else { return item }
            var merged = item
            merged.enabled = s.enabled
            merged.lastFetched = s.lastFetched
            merged.etag = s.etag
            merged.lastModified = s.lastModified
            return merged
        }
        whitelist = defaults.stringArray(forKey: Self.whitelistKey) ?? []
        userRules = (defaults.data(forKey: Self.userRulesKey))
            .flatMap { try? JSONDecoder().decode([UserRule].self, from: $0) } ?? []
    }

    // MARK: - 启动

    func prepare() {
        Task {
            await rebuild()
            await rebuildUserList()
            await updateSubscriptions(force: false)
        }
    }

    // MARK: - 控制器

    func register(_ controller: WKUserContentController, baseScripts: [WKUserScript]) {
        controllers[ObjectIdentifier(controller)] = ControllerState(controller: controller, baseScripts: baseScripts)
        apply(ObjectIdentifier(controller))
    }

    /// 主框架导航前调用：按目标网站决定是否启用过滤
    func prepare(_ controller: WKUserContentController, for url: URL?) {
        guard let host = url?.host()?.lowercased(), let state = controllers[ObjectIdentifier(controller)] else { return }
        state.host = host
        apply(ObjectIdentifier(controller))
    }

    func isActive(for controller: WKUserContentController) -> Bool {
        guard let state = controllers[ObjectIdentifier(controller)] else { return isEnabled }
        return isEnabled && !(state.host.map(isWhitelisted) ?? false)
    }

    private func apply(_ id: ObjectIdentifier) {
        guard let state = controllers[id] else { return }
        guard let controller = state.controller else {
            controllers[id] = nil
            return
        }
        let active = isEnabled && !(state.host.map(isWhitelisted) ?? false)
        guard state.appliedActive != active || state.appliedGeneration != generation else { return }
        state.appliedActive = active
        state.appliedGeneration = generation

        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()
        state.baseScripts.forEach(controller.addUserScript)
        guard active else { return }
        ruleLists.forEach(controller.add)
        if let userList { controller.add(userList) }
        if let pageScript { controller.addUserScript(pageScript) }
    }

    private func applyAll() {
        controllers.keys.forEach(apply)
    }

    // MARK: - 开关 / 白名单

    func setEnabled(_ enabled: Bool) {
        Settings.adBlockEnabled = enabled
        objectWillChange.send()
        applyAll()
    }

    func isWhitelisted(_ host: String) -> Bool {
        var h = host.lowercased()
        while true {
            if whitelist.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
        }
    }

    func setWhitelisted(_ host: String, _ on: Bool) {
        let h = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        if on {
            if !whitelist.contains(h) { whitelist.append(h) }
        } else {
            whitelist.removeAll { $0 == h || host.lowercased().hasSuffix("." + $0) || host.lowercased() == $0 }
        }
        whitelist.sort()
        UserDefaults.standard.set(whitelist, forKey: Self.whitelistKey)
        applyAll()
    }

    func removeWhitelist(at offsets: IndexSet) {
        whitelist.remove(atOffsets: offsets)
        UserDefaults.standard.set(whitelist, forKey: Self.whitelistKey)
        applyAll()
    }

    /// 弹窗目标是否属于广告域名
    func shouldBlockPopup(to url: URL?, from controller: WKUserContentController) -> Bool {
        guard isActive(for: controller), var host = url?.host()?.lowercased() else { return false }
        while true {
            if blockedHosts.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
        }
    }

    // MARK: - 订阅

    func setSubscription(_ id: String, enabled: Bool) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[i].enabled = enabled
        saveSubscriptions()
        Task {
            if enabled { await updateSubscriptions(force: false) }
            await rebuild()
        }
    }

    func updateNow() {
        Task { await updateSubscriptions(force: true) }
    }

    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(data, forKey: Self.subscriptionsKey)
        }
    }

    private func updateSubscriptions(force: Bool) async {
        let due = subscriptions.filter { sub in
            guard sub.enabled else { return false }
            if force { return true }
            guard FileManager.default.fileExists(atPath: FilterStorage.listURL(sub.id).path), let last = sub.lastFetched else { return true }
            return Date().timeIntervalSince(last) > FilterDownloader.updateInterval
        }
        guard !due.isEmpty else { return }
        status = .downloading
        var changed = false
        var failures: [String] = []
        await withTaskGroup(of: FilterDownloader.Result.self) { group in
            for sub in due { group.addTask { await FilterDownloader.fetch(sub) } }
            for await result in group {
                switch result {
                case .updated(let s):
                    changed = true
                    replace(s)
                case .unchanged(let s):
                    replace(s)
                case .failed(let message):
                    failures.append(message)
                }
            }
        }
        saveSubscriptions()
        status = failures.isEmpty ? .idle : .failed("部分规则下载失败：\(failures[0])")
        if changed { await rebuild() }
    }

    private func replace(_ sub: FilterSubscription) {
        if let i = subscriptions.firstIndex(where: { $0.id == sub.id }) { subscriptions[i] = sub }
    }

    // MARK: - 编译订阅规则

    private struct Manifest: Codable {
        var inputHash: String
        var identifiers: [String]
        var ruleCount: Int
        var builtAt: Date
    }

    private func rebuild() async {
        if building { rebuildQueued = true; return }
        building = true
        defer {
            building = false
            if rebuildQueued {
                rebuildQueued = false
                Task { await rebuild() }
            }
        }

        let inputs: [(id: String, url: URL, trusted: Bool)] =
            [("builtin", Bundle.main.url(forResource: "aether-builtin", withExtension: "txt")!, true)]
            + subscriptions.filter(\.enabled).map { ($0.id, FilterStorage.listURL($0.id), $0.trusted) }
                .filter { FileManager.default.fileExists(atPath: $0.url.path) }

        // 输入没变：直接复用上次编译结果
        let inputHash = await Task.detached(priority: .utility) {
            var data = Data("v\(Self.builderVersion)".utf8)
            for input in inputs {
                data.append(Data(input.id.utf8))
                data.append(Data(StableHash.hex((try? Data(contentsOf: input.url)) ?? Data()).utf8))
            }
            return StableHash.hex(data)
        }.value
        if let manifest = loadManifest(), manifest.inputHash == inputHash,
           let lists = await lookUp(manifest.identifiers),
           let pageData = try? String(contentsOf: FilterStorage.pageDataURL, encoding: .utf8) {
            let hosts = (try? String(contentsOf: FilterStorage.hostsURL, encoding: .utf8)) ?? ""
            install(lists: lists, pageData: pageData, hosts: Set(hosts.split(separator: "\n").map(String.init)), count: manifest.ruleCount, date: manifest.builtAt)
            return
        }

        status = .compiling
        let started = Date()
        let output = await Task.detached(priority: .utility) { () -> (BuildOutput, [(String, String)]) in
            var set = FilterSet()
            let texts = inputs.map { ((try? String(contentsOf: $0.url, encoding: .utf8)) ?? "", $0.trusted) }
            for (text, _) in texts { FilterParser.collectBadfilters(text, into: &set) }
            for (text, trusted) in texts { FilterParser.parse(text, trusted: trusted, into: &set) }
            FilterParser.finalize(&set)
            let output = RuleListBuilder.build(set, prefix: "")
            let encoder = JSONEncoder()
            let encoded = output.lists.map { spec -> (String, String) in
                let json = String(decoding: (try? encoder.encode(spec.rules + spec.tail)) ?? Data("[]".utf8), as: UTF8.self)
                return (Self.listPrefix + spec.name + "-" + StableHash.hex(Data(json.utf8)), json)
            }
            return (output, encoded)
        }.value

        var lists: [WKContentRuleList] = []
        var identifiers: [String] = []
        for (index, (identifier, json)) in output.1.enumerated() {
            if let existing = await lookUp([identifier])?.first {
                lists.append(existing)
                identifiers.append(identifier)
                continue
            }
            let spec = output.0.lists[index]
            if let list = await compileResilient(identifier, json: json, spec: spec) {
                lists.append(list.0)
                identifiers.append(list.1)
            }
        }

        let pageData = output.0.pageData
        try? pageData.write(to: FilterStorage.pageDataURL, atomically: true, encoding: .utf8)
        try? output.0.blockedHosts.sorted().joined(separator: "\n").write(to: FilterStorage.hostsURL, atomically: true, encoding: .utf8)
        let manifest = Manifest(inputHash: inputHash, identifiers: identifiers, ruleCount: output.0.ruleCount, builtAt: Date())
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: FilterStorage.manifestURL, options: .atomic) }

        install(lists: lists, pageData: pageData, hosts: output.0.blockedHosts, count: output.0.ruleCount, date: manifest.builtAt)
        if status == .compiling { status = .idle }
        print("[Aether] 广告规则编译完成：\(output.0.ruleCount) 条，\(lists.count) 张表，用时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        await removeStale(keeping: Set(identifiers))
    }

    private func install(lists: [WKContentRuleList], pageData: String, hosts: Set<String>, count: Int, date: Date) {
        ruleLists = lists
        blockedHosts = hosts
        ruleCount = count
        lastBuilt = date
        pageScript = Self.makePageScript(pageData)
        generation += 1
        applyAll()
    }

    private static func makePageScript(_ data: String) -> WKUserScript? {
        guard let url = Bundle.main.url(forResource: "aether-adblock", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source.replacingOccurrences(of: "/*AETHER_DATA*/null", with: data),
                            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    private func loadManifest() -> Manifest? {
        (try? Data(contentsOf: FilterStorage.manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    private func lookUp(_ identifiers: [String]) async -> [WKContentRuleList]? {
        var lists: [WKContentRuleList] = []
        for id in identifiers {
            guard let list = try? await store.contentRuleList(forIdentifier: id) else { return nil }
            lists.append(list)
        }
        return lists
    }

    private func compile(_ identifier: String, _ json: String) async -> WKContentRuleList? {
        do {
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        } catch {
            return nil
        }
    }

    /// 整张表编译失败时，二分找出被 WebKit 拒绝的规则并剔除
    private func compileResilient(_ identifier: String, json: String, spec: RuleListSpec) async -> (WKContentRuleList, String)? {
        if let list = await compile(identifier, json) { return (list, identifier) }
        let encoder = JSONEncoder()
        func encode(_ rules: [WKRule]) -> String { String(decoding: (try? encoder.encode(rules)) ?? Data(), as: UTF8.self) }

        var bad: Set<WKRule> = []
        func probe(_ rules: [WKRule]) async {
            if rules.isEmpty { return }
            if await compile("aether-probe", encode(rules)) != nil { return }
            if rules.count == 1 {
                if let parts = rules[0].splitSelectors() {
                    // 合并的选择器里有坏的：拆开逐个试，留下好的
                    for part in parts { await probe([part]) }
                    bad.insert(rules[0])
                } else {
                    bad.insert(rules[0])
                }
                return
            }
            await probe(Array(rules[..<(rules.count / 2)]))
            await probe(Array(rules[(rules.count / 2)...]))
        }
        await probe(spec.rules)
        try? await store.removeContentRuleList(forIdentifier: "aether-probe")

        // 坏规则里拆出来的好选择器补回去
        var kept = spec.rules.filter { !bad.contains($0) }
        for rule in bad {
            for part in rule.splitSelectors() ?? [] where !bad.contains(part) { kept.append(part) }
        }
        print("[Aether] \(spec.name) 剔除了 \(bad.count) 条无法编译的规则")
        let fixed = encode(kept + spec.tail)
        let id = identifier + "-fixed"
        return await compile(id, fixed).map { ($0, id) }
    }

    private func removeStale(keeping: Set<String>) async {
        let ids = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { done.resume(returning: $0 ?? []) }
        }
        let userID = userList?.identifier
        for id in ids where (id.hasPrefix(Self.listPrefix) && !keeping.contains(id)) || (id.hasPrefix(Self.userPrefix) && id != userID) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    // MARK: - 用户规则（手动屏蔽的元素）

    func addUserRule(host: String, selector: String) {
        let h = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        let rule = UserRule(host: h, selector: selector)
        guard !userRules.contains(rule) else { return }
        userRules.append(rule)
        saveUserRules()
    }

    func removeUserRules(at offsets: IndexSet) {
        userRules.remove(atOffsets: offsets)
        saveUserRules()
    }

    private func saveUserRules() {
        if let data = try? JSONEncoder().encode(userRules) { UserDefaults.standard.set(data, forKey: Self.userRulesKey) }
        Task { await rebuildUserList() }
    }

    private func rebuildUserList() async {
        guard !userRules.isEmpty else {
            userList = nil
            generation += 1
            applyAll()
            return
        }
        let text = userRules.map { "\($0.host)##\($0.selector)" }.joined(separator: "\n")
        let (rules, json): ([WKRule], String) = await Task.detached(priority: .userInitiated) {
            var set = FilterSet()
            FilterParser.parse(text, trusted: true, into: &set)
            let rules = RuleListBuilder.build(set, prefix: "user").lists.flatMap { $0.rules + $0.tail }
            return (rules, String(decoding: (try? JSONEncoder().encode(rules)) ?? Data("[]".utf8), as: UTF8.self))
        }.value
        let id = Self.userPrefix + StableHash.hex(Data(json.utf8))
        if let existing = await lookUp([id])?.first {
            userList = existing
        } else if let list = await compileResilient(id, json: json, spec: RuleListSpec(name: "user", rules: rules, tail: [])) {
            userList = list.0
        }
        generation += 1
        applyAll()
    }
}
