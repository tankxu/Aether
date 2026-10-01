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

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        let tabs = manager.tabs(incognito: incognito)
        NavigationStack {
            ScrollView {
                if tabs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: incognito ? "eyeglasses" : "square.on.square")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(incognito ? "没有无痕标签页" : "没有标签页")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 160)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(tabs) { tab in
                            TabCard(tab: tab, isSelected: tab === manager.selected, onClose: { onClose(tab) })
                                .onTapGesture { onSelect(tab) }
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $incognito) {
                        Text("标签页").tag(false)
                        Text("无痕").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onDone).bold()
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if !tabs.isEmpty {
                        Button("全部关闭", role: .destructive) { manager.closeAll(incognito: incognito) }
                    }
                    Spacer()
                    Button { onNew(incognito) } label: { Image(systemName: "plus") }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(incognito ? .dark : nil)
    }
}

private struct TabCard: View {
    let tab: Tab
    let isSelected: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = tab.snapshot {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .overlay(Image(systemName: "globe").font(.title).foregroundStyle(.tertiary))
                    }
                }
                .frame(height: 210)
                .frame(maxWidth: .infinity)
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
}
