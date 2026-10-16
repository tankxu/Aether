import SwiftUI

struct SettingsView: View {
    var onAdBlockChange: () -> Void
    var onClearData: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.searchEngine) private var searchEngine = SearchEngine.google.rawValue
    @ObservedObject private var blocker = ContentBlocker.shared
    @AppStorage(SettingsKey.autoRotate) private var autoRotate = true
    @AppStorage(SettingsKey.alwaysShowProgress) private var alwaysShowProgress = false
    @AppStorage(SettingsKey.autoPiP) private var autoPiP = true
    @AppStorage(SettingsKey.railSide) private var railSide = Side.right.rawValue
    @AppStorage(AppLanguage.key) private var appLanguage = ""
    @State private var launchAppLanguage = UserDefaults.standard.string(forKey: AppLanguage.key) ?? ""
    @AppStorage(RegionSettings.regionKey) private var regionCode = ""
    @AppStorage(RegionSettings.languageKey) private var languageCode = ""
    @State private var launchRegion = UserDefaults.standard.string(forKey: RegionSettings.regionKey) ?? ""
    @State private var launchLanguage = UserDefaults.standard.string(forKey: RegionSettings.languageKey) ?? ""
    @State private var confirmClear = false

    private var regionFooter: String {
        var text = L("网页按这里的地区和语言显示：所有网站都会收到对应的语言偏好；Google、YouTube、Bing、DuckDuckGo 还会带上地区参数（比如人在泰国也按新加坡出搜索结果）。少数只按 IP 判断地区的网站需要 VPN。")
        if regionCode != launchRegion || languageCode != launchLanguage {
            text += L("\n\n语言偏好需要彻底关闭 Aether 再打开后生效（搜索地区已立即生效）。")
        }
        return text
    }
    @State private var cleared = false
    @State private var appLinkCount = AppLinkPolicy.blockedHosts.count

    var body: some View {
        NavigationStack {
            Form {
                Section(L("搜索")) {
                    Picker(L("搜索引擎"), selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }

                Section {
                    Picker(L("App 语言"), selection: $appLanguage) {
                        Text(L("跟随系统")).tag("")
                        ForEach(AppLanguage.supported, id: \.code) { Text($0.name).tag($0.code) }
                    }
                } footer: {
                    if appLanguage != launchAppLanguage {
                        Text(L("彻底关闭 Aether 再打开后生效。"))
                    }
                }

                Section {
                    Picker(L("地区"), selection: $regionCode) {
                        Text(L("跟随系统")).tag("")
                        ForEach(RegionSettings.regions) { Text($0.name).tag($0.code) }
                    }
                    Picker(L("网页语言"), selection: $languageCode) {
                        Text(L("跟随系统")).tag("")
                        ForEach(RegionSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text(L("地区与语言"))
                } footer: {
                    Text(regionFooter)
                }

                Section {
                    NavigationLink {
                        AdBlockSettingsView(onChange: onAdBlockChange)
                    } label: {
                        LabeledContent(L("广告过滤"), value: blocker.isEnabled ? L("已开启") : L("已关闭"))
                    }
                }

                Section {
                    Toggle(L("全屏时自动横屏"), isOn: $autoRotate)
                    Toggle(L("离开 App 时自动画中画"), isOn: $autoPiP)
                    Toggle(L("控件隐藏时保留细进度条"), isOn: $alwaysShowProgress)
                    Picker(L("控制按钮位置"), selection: $railSide) {
                        Text(L("左侧")).tag(Side.left.rawValue)
                        Text(L("右侧")).tag(Side.right.rawValue)
                    }
                } header: {
                    Text(L("视频播放"))
                } footer: {
                    Text(L("全屏播放时也可以直接拖动按钮列换到另一侧。右上角可以手动进入画中画或用 AirPlay 投放。"))
                }

                Section {
                    NavigationLink {
                        AppLinkSettingsView { appLinkCount = $0 }
                    } label: {
                        LabeledContent(L("禁止跳转 App"), value: appLinkCount == 0 ? L("无") : L("%d 个网站", appLinkCount))
                    }
                } footer: {
                    Text(L("在工具栏菜单里选“在此网站禁止跳转 App”，该网站的链接就只在浏览器里打开，不会跳到 YouTube 等 App。"))
                }

                Section(L("隐私")) {
                    Button(cleared ? L("已清除") : L("清除浏览数据"), role: .destructive) { confirmClear = true }
                        .disabled(cleared)
                        .confirmationDialog(L("清除所有网站的 Cookie、缓存、本地存储和历史记录？"), isPresented: $confirmClear, titleVisibility: .visible) {
                            Button(L("清除"), role: .destructive) {
                                onClearData()
                                cleared = true
                            }
                        }
                }

                Section {
                    LabeledContent(L("版本"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
    }
}

struct AppLinkSettingsView: View {
    var onChange: (Int) -> Void = { _ in }

    @State private var hosts = AppLinkPolicy.blockedHosts
    @State private var input = ""
    @State private var invalid = false
    @State private var editMode: EditMode = .inactive
    @FocusState private var inputFocused: Bool
    @ObservedObject private var favicons = FaviconStore.shared

    /// 常被唤起 App 的网站，一键加入
    private static let common = [
        "youtube.com", "bilibili.com", "zhihu.com", "xiaohongshu.com", "douyin.com", "weibo.com",
        "taobao.com", "jd.com", "reddit.com", "x.com", "instagram.com", "tiktok.com",
    ]

    private var suggestions: [String] { Self.common.filter { !hosts.contains($0) } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField(L("网址或域名，如 youtube.com"), text: $input)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($inputFocused)
                        .onSubmit(addInput)
                        .onChange(of: input) { invalid = false }
                    Button(L("添加"), action: addInput)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(L("添加网站"))
            } footer: {
                if invalid { Text(L("不是有效的网址或域名")).foregroundStyle(.red) }
                else { Text(L("子域名一起生效：添加 youtube.com 后 m.youtube.com 也不会跳转。")) }
            }

            if !suggestions.isEmpty {
                Section(L("常用网站")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { host in
                                Button {
                                    withAnimation { add(host) }
                                } label: {
                                    Label(host, systemImage: "plus")
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section {
                if hosts.isEmpty {
                    Text(L("没有网站")).foregroundStyle(.secondary)
                }
                ForEach(hosts, id: \.self) { host in
                    HStack(spacing: 12) {
                        icon(for: host)
                        Text(host)
                    }
                }
                .onDelete { offsets in
                    hosts.remove(atOffsets: offsets)
                    save()
                }
            } header: {
                Text(L("已禁止的网站（%d）", hosts.count))
            } footer: {
                Text(L("这些网站的链接只在浏览器里打开，不会跳到对应的 App。左滑可以删除。"))
            }
        }
        .navigationTitle(L("禁止跳转 App"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            // 系统的 EditButton 跟随系统语言，这里用 App 语言
            if !hosts.isEmpty || editMode.isEditing {
                Button(editMode.isEditing ? L("完成") : L("编辑")) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
    }

    @ViewBuilder private func icon(for host: String) -> some View {
        let _ = favicons.revision
        Group {
            if let image = favicons.image(for: host) {
                Image(uiImage: image).resizable()
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: Double(host.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360, saturation: 0.45, brightness: 0.75))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func addInput() {
        guard let host = Self.host(from: input) else {
            invalid = true
            return
        }
        withAnimation { add(host) }
        input = ""
        inputFocused = false
    }

    private func add(_ host: String) {
        let h = AppLinkPolicy.normalize(host)
        guard !hosts.contains(h) else { return }
        hosts.append(h)
        hosts.sort()
        save()
    }

    private func save() {
        AppLinkPolicy.blockedHosts = hosts
        onChange(hosts.count)
    }

    /// 接受完整网址或裸域名
    static func host(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let url = URL(string: t.contains("://") ? t : "https://" + t)
        guard let host = url?.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return host
    }
}
