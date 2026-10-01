import SwiftUI

struct SettingsView: View {
    var onAdBlockChange: () -> Void
    var onClearData: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.searchEngine) private var searchEngine = SearchEngine.google.rawValue
    @ObservedObject private var blocker = ContentBlocker.shared
    @AppStorage(SettingsKey.autoRotate) private var autoRotate = true
    @AppStorage(SettingsKey.alwaysShowProgress) private var alwaysShowProgress = false
    @AppStorage(SettingsKey.railSide) private var railSide = Side.right.rawValue
    @AppStorage(RegionSettings.regionKey) private var regionCode = ""
    @AppStorage(RegionSettings.languageKey) private var languageCode = ""
    @State private var launchRegion = UserDefaults.standard.string(forKey: RegionSettings.regionKey) ?? ""
    @State private var launchLanguage = UserDefaults.standard.string(forKey: RegionSettings.languageKey) ?? ""
    @State private var confirmClear = false

    private var regionFooter: String {
        var text = "网页按这里的地区和语言显示：所有网站都会收到对应的语言偏好；Google、YouTube、Bing、DuckDuckGo 还会带上地区参数（比如人在泰国也按新加坡出搜索结果）。少数只按 IP 判断地区的网站需要 VPN。"
        if regionCode != launchRegion || languageCode != launchLanguage {
            text += "\n\n语言偏好需要彻底关闭 Aether 再打开后生效（搜索地区已立即生效）。"
        }
        return text
    }
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("搜索") {
                    Picker("搜索引擎", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }

                Section {
                    Picker("地区", selection: $regionCode) {
                        Text("跟随系统").tag("")
                        ForEach(RegionSettings.regions) { Text($0.name).tag($0.code) }
                    }
                    Picker("网页语言", selection: $languageCode) {
                        Text("跟随系统").tag("")
                        ForEach(RegionSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("地区与语言")
                } footer: {
                    Text(regionFooter)
                }

                Section {
                    NavigationLink {
                        AdBlockSettingsView(onChange: onAdBlockChange)
                    } label: {
                        LabeledContent("广告过滤", value: blocker.isEnabled ? "已开启" : "已关闭")
                    }
                }

                Section {
                    Toggle("全屏时自动横屏", isOn: $autoRotate)
                    Toggle("控件隐藏时保留细进度条", isOn: $alwaysShowProgress)
                    Picker("控制按钮位置", selection: $railSide) {
                        Text("左侧").tag(Side.left.rawValue)
                        Text("右侧").tag(Side.right.rawValue)
                    }
                } header: {
                    Text("视频播放")
                } footer: {
                    Text("全屏播放时也可以直接拖动按钮列换到另一侧。")
                }

                Section {
                    NavigationLink {
                        AppLinkSettingsView()
                    } label: {
                        LabeledContent("禁止跳转 App", value: AppLinkPolicy.blockedHosts.isEmpty ? "无" : "\(AppLinkPolicy.blockedHosts.count) 个网站")
                    }
                } footer: {
                    Text("在工具栏菜单里选“在此网站禁止跳转 App”，该网站的链接就只在浏览器里打开，不会跳到 YouTube 等 App。")
                }

                Section("隐私") {
                    Button(cleared ? "已清除" : "清除浏览数据", role: .destructive) { confirmClear = true }
                        .disabled(cleared)
                        .confirmationDialog("清除所有网站的 Cookie、缓存、本地存储和历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("清除", role: .destructive) {
                                onClearData()
                                cleared = true
                            }
                        }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct AppLinkSettingsView: View {
    @State private var hosts = AppLinkPolicy.blockedHosts

    var body: some View {
        List {
            if hosts.isEmpty {
                Text("没有网站").foregroundStyle(.secondary)
            }
            ForEach(hosts, id: \.self) { Text($0) }
                .onDelete { offsets in
                    hosts.remove(atOffsets: offsets)
                    AppLinkPolicy.blockedHosts = hosts
                }
        }
        .navigationTitle("禁止跳转 App")
        .navigationBarTitleDisplayMode(.inline)
    }
}
