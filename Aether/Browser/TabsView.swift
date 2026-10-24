import SwiftUI

struct TabsView: View {
    @ObservedObject var manager: TabManager
    @State var incognito: Bool
    var onSelect: (Tab) -> Void
    var onNew: (Bool) -> Void
    var onClose: (Tab) -> Void
    var onDone: () -> Void

    init(
        manager: TabManager,
        incognito: Bool,
        onSelect: @escaping (Tab) -> Void,
        onNew: @escaping (Bool) -> Void,
        onClose: @escaping (Tab) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.manager = manager
        _incognito = State(initialValue: incognito)
        self.onSelect = onSelect
        self.onNew = onNew
        self.onClose = onClose
        self.onDone = onDone
    }

    /// 列数按宽度算：手机竖屏两列、横屏四列，iPad 四到七列；高度紧凑（手机横屏）时卡片矮一些
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var landscape: Bool { verticalSizeClass == .compact }
    private func columns(width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: max(2, Int(width / 190)))
    }

    /// 卡片在窗口里的位置（粒子效果要截这块区域）
    @State private var cardFrames: [UUID: CGRect] = [:]
    /// 正在风化消失的卡片：立刻隐藏真卡片，粒子接管画面
    @State private var dissolving: Set<UUID> = []
    /// 滑动关闭：每张卡片的横向偏移
    @State private var swipeOffsets: [UUID: CGFloat] = [:]
    @State private var swipeAxisLocked: [UUID: Bool] = [:]

    /// 点关闭按钮：卡片碎成粒子飘散，随后其他卡片补位
    private func dissolve(_ tab: Tab) {
        guard !dissolving.contains(tab.id) else { return }
        if let frame = cardFrames[tab.id], let window = DustEffect.keyWindow {
            DustEffect.run(on: window, frame: frame)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { _ = dissolving.insert(tab.id) }
        // 等大部分粒子飘散开再让其他卡片补位，免得补位的卡片和粒子叠在一起
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { onClose(tab) }
            dissolving.remove(tab.id)
        }
    }

    /// 横向滑动卡片：跟手、变淡；滑够距离松手就飞出去关闭
    private func swipeGesture(for tab: Tab) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                if swipeAxisLocked[tab.id] == nil {
                    // 先判断方向：横向为主才算滑动关闭，纵向交给列表滚动
                    swipeAxisLocked[tab.id] = abs(dx) > abs(dy)
                }
                guard swipeAxisLocked[tab.id] == true else { return }
                swipeOffsets[tab.id] = dx
            }
            .onEnded { value in
                let horizontal = swipeAxisLocked[tab.id] == true
                swipeAxisLocked[tab.id] = nil
                guard horizontal else { return }
                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                if abs(dx) > 110 || abs(projected) > 260 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) { swipeOffsets[tab.id] = dx > 0 ? 500 : -500 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { onClose(tab) }
                        swipeOffsets[tab.id] = nil
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { swipeOffsets[tab.id] = 0 }
                }
            }
    }

    var body: some View {
        // 主页在实现上是空白标签页，但不算进标签页列表
        let tabs = manager.tabs(incognito: incognito).filter { !$0.isBlank }
        NavigationStack {
            GeometryReader { container in
            ScrollView {
                VStack(spacing: 0) {
                if tabs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: incognito ? "eyeglasses" : "square.on.square")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(incognito ? L("没有无痕标签页") : L("没有标签页"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 160)
                } else {
                    LazyVGrid(columns: columns(width: container.size.width), spacing: 18) {
                        ForEach(tabs) { tab in
                            let offset = swipeOffsets[tab.id] ?? 0
                            TabCard(tab: tab, isSelected: tab === manager.selected, height: landscape ? 130 : 210, onClose: { dissolve(tab) })
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: CardFramesKey.self, value: [tab.id: geo.frame(in: .global)])
                                })
                                .opacity(dissolving.contains(tab.id) ? 0 : 1 - min(abs(offset) / 260, 0.85))
                                .offset(x: offset)
                                .rotationEffect(.degrees(Double(offset) / 40))
                                .onTapGesture { onSelect(tab) }
                                .simultaneousGesture(swipeGesture(for: tab))
                                .transition(.opacity)
                        }
                    }
                    .padding(16)
                    .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
                }
                }
                // 内容至少撑满一屏：点卡片以外的空白处 = 完成（卡片自己的点击优先）
                .frame(maxWidth: .infinity, minHeight: container.size.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDone)
            }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            // 自己画底部栏：系统 bottomBar 在 iOS 26 会把两个按钮合并成一组居中
            .safeAreaInset(edge: .bottom) {
                // 完成和 + 放在惯用手一侧（和边缘竖线同侧），全部关闭放另一边
                let onRight = Settings.handleSide == .right
                HStack(spacing: 12) {
                    if onRight {
                        closeAllButton(tabs)
                        Spacer()
                        doneButton
                        newButton
                    } else {
                        newButton
                        doneButton
                        Spacer()
                        closeAllButton(tabs)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $incognito) {
                        Text(L("标签页")).tag(false)
                        Text(L("无痕")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(incognito ? .dark : nil)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aether.debugDissolveFirst"))) { _ in
            if let first = manager.tabs(incognito: incognito).first(where: { !$0.isBlank }) { dissolve(first) }
        }
        #endif
    }
}

extension TabsView {
    @ViewBuilder fileprivate func closeAllButton(_ tabs: [Tab]) -> some View {
        if !tabs.isEmpty {
            Button(role: .destructive) { manager.closeAll(incognito: incognito) } label: {
                Text(L("全部关闭")).font(.body.weight(.medium)).padding(.horizontal, 6)
            }
            .modifier(GlassButtonStyle())
        }
    }

    fileprivate var doneButton: some View {
        Button(action: onDone) {
            Text(L("完成")).font(.body.weight(.semibold)).padding(.horizontal, 6)
        }
        .modifier(GlassButtonStyle())
    }

    fileprivate var newButton: some View {
        Button { onNew(incognito) } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).frame(width: 30, height: 30)
        }
        .modifier(GlassButtonStyle(circle: true))
    }
}

/// iOS 26 用液态玻璃按钮，旧系统用普通描边按钮
private struct GlassButtonStyle: ViewModifier {
    /// circle：正圆（只放图标的按钮）
    var circle = false
    func body(content: Content) -> some View {
        let shape: ButtonBorderShape = circle ? .circle : .capsule
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(shape).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(shape).controlSize(.large)
        }
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TabCard: View {
    let tab: Tab
    let isSelected: Bool
    var height: CGFloat = 210
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // 缩略图只做叠加层、不参与布局：横屏截的图很宽，按填满缩放会把卡片撑出格子、和旁边重叠
                Color.clear
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) { thumbnail }
                    .clipped()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2.5 : 1)
            )
            Text(tab.title)
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = tab.snapshot {
            // 优先按宽度铺满、只裁掉下面（看得到页面顶部的完整宽度）；图太扁时才按高度填满
            GeometryReader { geo in
                let fitHeight = geo.size.width * image.size.height / max(image.size.width, 1)
                if fitHeight >= geo.size.height {
                    Image(uiImage: image).resizable().frame(width: geo.size.width, height: fitHeight)
                } else {
                    // 靠左上：网页内容从左边开始，裁掉右侧
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
        } else if tab.isBlank {
            // 空白标签页 = 主页
            LinearGradient(colors: [Color(white: 0.12), Color(red: 0.08, green: 0.06, blue: 0.18)], startPoint: .top, endPoint: .bottom)
                .overlay(VStack(spacing: 6) {
                    Image(systemName: "house").font(.title2)
                    Text(L("主页")).font(.caption)
                }.foregroundStyle(.white.opacity(0.7)))
        } else {
            Color(uiColor: .secondarySystemGroupedBackground)
                .overlay(Image(systemName: "globe").font(.title).foregroundStyle(.tertiary))
        }
    }
}
