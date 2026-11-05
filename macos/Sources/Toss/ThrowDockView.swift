import SwiftUI
import UniformTypeIdentifiers

enum Brand {
    /// 投递口命中时的品牌绿。
    static let green = Color(red: 0.09, green: 0.62, blue: 0.40)

    /// 统一的卡片圆角。
    static let radius: CGFloat = 12

    /// 分隔线与描边的「发丝」色。
    static let hairline = Color.primary.opacity(0.08)
}

/// 其余服务器 + 本机：一排大号堆叠投递口。
/// 放不下时横向滚动，两侧的 < / > 一次翻「一屏可见数量」，不会跳过没见过的机器。
struct ThrowDockView: View {
    @ObservedObject var state: AppState
    let source: ThrowTarget

    @State private var scrollIndex = 0
    @State private var tallestCard: CGFloat = 132

    private var targets: [ThrowTarget] {
        ThrowTargets.destinations(servers: state.servers, source: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            GeometryReader { geometry in
                let layout = DockLayout(available: geometry.size.width, count: targets.count)

                ScrollViewReader { proxy in
                    HStack(spacing: 4) {
                        if layout.overflowing {
                            arrow(.backward, layout: layout, proxy: proxy)
                        }

                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: layout.spacing) {
                                ForEach(targets) { target in
                                    ThrowTargetCard(
                                        state: state,
                                        target: target,
                                        width: layout.cardWidth,
                                        folders: state.folders(for: target)
                                    )
                                    .id(target.id)
                                }
                            }
                            .padding(.horizontal, layout.inset)
                            .padding(.vertical, 8)
                            .background(offsetReader)
                        }
                        .coordinateSpace(name: DockSpace.name)
                        .onPreferenceChange(DockOffsetKey.self) { offset in
                            scrollIndex = layout.index(forOffset: offset)
                        }
                        .onChange(of: source.id) { _ in
                            scrollIndex = 0
                            proxy.scrollTo(targets.first?.id, anchor: .leading)
                        }
                        .onChange(of: targets.count) { _ in
                            scrollIndex = min(scrollIndex, layout.maxIndex)
                        }

                        if layout.overflowing {
                            arrow(.forward, layout: layout, proxy: proxy)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        // 拖到有多目录的机器时会展开文件夹篮筐，投递口整体跟着长高。
        .frame(height: max(184, tallestCard + 44))
        .background(.regularMaterial)
        .onPreferenceChange(CardHeightKey.self) { height in
            tallestCard = height
        }
        .animation(.easeInOut(duration: 0.22), value: tallestCard)
    }

    private var title: String {
        source.isLocal ? t("Drop into a server") : t("Drop into another server or this Mac")
    }

    private func arrow(
        _ direction: DockDirection,
        layout: DockLayout,
        proxy: ScrollViewProxy
    ) -> some View {
        let enabled = canGo(direction, layout: layout)

        return Button {
            move(direction, layout: layout, proxy: proxy)
        } label: {
            Image(systemName: direction == .forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.25))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Color.primary.opacity(0.05))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(direction == .forward ? t("Show more") : t("Show previous"))
        .accessibilityLabel(direction == .forward ? t("Show more") : t("Show previous"))
    }

    /// 翻页按钮只改索引并滚动；跨页距离由 `DockPaging` 限制在一屏之内。
    private func move(_ direction: DockDirection, layout: DockLayout, proxy: ScrollViewProxy) {
        let next = DockPaging.step(
            index: scrollIndex,
            visible: layout.visibleCount,
            total: targets.count,
            forward: direction == .forward
        )
        guard next != scrollIndex, targets.indices.contains(next) else { return }
        scrollIndex = next

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(targets[next].id, anchor: .leading)
        }
    }

    private func canGo(_ direction: DockDirection, layout: DockLayout) -> Bool {
        direction == .forward ? scrollIndex < layout.maxIndex : scrollIndex > 0
    }

    private var offsetReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DockOffsetKey.self,
                value: proxy.frame(in: .named(DockSpace.name)).minX
            )
        }
    }
}

private enum DockSpace {
    static let name = "toss.dock.scroll"
}

private enum DockDirection {
    case backward
    case forward
}

private struct DockOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 卡片宽度与「一屏能放几张」。
private struct DockLayout {
    /// 两侧箭头（24*2）加它们的间距（4*2）。
    static let arrowSpace: CGFloat = 56
    /// 外层左右留白（12*2）。
    static let outer: CGFloat = 24

    let spacing: CGFloat = 12
    let inset: CGFloat = 14
    let cardWidth: CGFloat
    let visibleCount: Int
    let overflowing: Bool
    let count: Int

    var step: CGFloat { cardWidth + spacing }
    var maxIndex: Int { max(0, count - visibleCount) }

    init(available: CGFloat, count: Int) {
        self.count = count
        let spacing: CGFloat = 12
        let inset: CGFloat = 14

        guard count > 0, available > 0 else {
            cardWidth = 146
            visibleCount = 1
            overflowing = false
            return
        }

        let fitting = Self.cardWidth(
            available: available - Self.outer,
            inset: inset,
            spacing: spacing,
            count: count
        )
        let content = inset * 2 + fitting * CGFloat(count) + spacing * CGFloat(count - 1)
        let overflows = content > available - Self.outer
        let width = overflows
            ? Self.cardWidth(
                available: available - Self.outer - Self.arrowSpace,
                inset: inset,
                spacing: spacing,
                count: count
            )
            : fitting
        // 真正的可视宽度：去掉外层留白，放不下时再扣掉箭头。
        let viewport = available - Self.outer - (overflows ? Self.arrowSpace : 0)
        let visible = max(1, Int(floor((viewport - inset * 2 + spacing) / (width + spacing))))

        self.cardWidth = width
        self.visibleCount = visible
        self.overflowing = overflows
    }

    /// 滚动偏移 → 当前最左边那张卡的索引。
    func index(forOffset offset: CGFloat) -> Int {
        guard step > 0 else { return 0 }
        let scrolled = -offset - inset
        let raw = Int((scrolled / step).rounded())
        return min(max(raw, 0), maxIndex)
    }

    private static func cardWidth(
        available: CGFloat,
        inset: CGFloat,
        spacing: CGFloat,
        count: Int
    ) -> CGFloat {
        let proposed = (available - inset * 2 - spacing * CGFloat(max(count - 1, 0))) / CGFloat(count)
        return max(146, min(204, proposed))
    }
}

private struct ThrowTargetCard: View {
    @ObservedObject var state: AppState
    let target: ThrowTarget
    let width: CGFloat
    let folders: [String]

    @State private var isTargeted = false
    @State private var hoveredBasket: Int?

    private let faceHeight: CGFloat = 52
    private let basketRowHeight: CGFloat = 30
    private let basketGap: CGFloat = 4
    private let topPadding: CGFloat = 22

    private var showsBaskets: Bool { isTargeted && folders.count > 1 }

    var body: some View {
        ZStack(alignment: .top) {
            if !showsBaskets {
                backingCard(scale: 0.93, offset: -16, opacity: 0.35)
                backingCard(scale: 0.965, offset: -8, opacity: 0.60)
            }

            VStack(spacing: 6) {
                if showsBaskets {
                    compactFace
                    basketList
                } else {
                    frontCard
                }
            }
        }
        .padding(.top, topPadding)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(width: width + 16)
        // 整块（含后面两张卡、展开的篮筐与内边距）都是热区。
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.json],
            delegate: BasketDropDelegate(
                isTargeted: $isTargeted,
                hovered: $hoveredBasket,
                folderCount: folders.count,
                basketTop: topPadding + faceHeight + 6,
                rowStride: basketRowHeight + basketGap,
                onDrop: handleDrop
            )
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isTargeted)
        .background(heightReader)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Throw to {}", target.displayName))
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
        }
    }

    /// 悬停时机器卡片收成一条标题，下面腾出位置放文件夹篮筐。
    private var compactFace: some View {
        HStack(spacing: 8) {
            Image(systemName: target.isLocal ? "laptopcomputer" : "server.rack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.green)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(t("Pick a folder below"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: faceHeight)
        .background(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .fill(Brand.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .strokeBorder(Brand.green, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
    }

    /// 一台机器配置了几个文件夹，就摆几个篮筐。
    private var basketList: some View {
        VStack(spacing: basketGap) {
            ForEach(Array(folders.enumerated()), id: \.offset) { index, directory in
                HStack(spacing: 6) {
                    Image(systemName: hoveredBasket == index ? "tray.full.fill" : "tray")
                        .font(.caption2)
                    Text(directory)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hoveredBasket == index ? Brand.green : Color.secondary)
                .padding(.horizontal, 9)
                .frame(width: width, height: basketRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hoveredBasket == index
                              ? Brand.green.opacity(0.14)
                              : Color.primary.opacity(0.05))
                )
            }
        }
    }

    private var frontCard: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Brand.green.opacity(0.14) : Color.primary.opacity(0.05))
                    .frame(width: 34, height: 34)
                Image(systemName: target.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isTargeted ? Brand.green : Color.secondary)
            }

            Text(target.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(target.addressLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(t("Drop here"))
                .font(.caption2)
                .foregroundStyle(isTargeted ? Brand.green : Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 104)
        .background(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .fill(isTargeted
                      ? Brand.green.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .strokeBorder(
                    isTargeted ? Brand.green : Brand.hairline,
                    lineWidth: isTargeted ? 1.5 : 0.5
                )
        )
        .shadow(
            color: .black.opacity(isTargeted ? 0.10 : 0.02),
            radius: isTargeted ? 8 : 2,
            y: isTargeted ? 4 : 1
        )
        .scaleEffect(isTargeted ? 1.02 : 1)
        .offset(y: isTargeted ? -3 : 0)
    }

    private func backingCard(scale: CGFloat, offset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.42))
            .frame(width: width, height: 104)
            .scaleEffect(x: scale, y: scale)
            .offset(y: offset)
            .opacity(opacity)
    }

    /// 单目录直接落进去；多目录必须落在某个篮筐上。
    private func handleDrop(_ providers: [NSItemProvider], basket: Int?) -> Bool {
        guard let directory = BasketChoice.directory(for: basket, among: folders),
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
              })
        else { return false }

        provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { item, _ in
            let data: Data?
            if let value = item as? Data {
                data = value
            } else if let value = item as? NSData {
                data = value as Data
            } else {
                data = nil
            }

            guard let data,
                  let payload = try? JSONDecoder().decode(ThrowPayload.self, from: data)
            else { return }

            DispatchQueue.main.async {
                state.beginThrow(payload: payload, target: target, targetDir: directory)
            }
        }
        return true
    }
}

/// 整张展开卡片是一个投放目标；落点纵向落在第几个篮筐，就投到第几个文件夹。
private struct BasketDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var hovered: Int?
    let folderCount: Int
    let basketTop: CGFloat
    let rowStride: CGFloat
    let onDrop: ([NSItemProvider], Int?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.json])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        updateHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHover(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        hovered = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        updateHover(info)
        let result = onDrop(info.itemProviders(for: [UTType.json]), hovered)
        isTargeted = false
        hovered = nil
        return result
    }

    private func updateHover(_ info: DropInfo) {
        hovered = DockBaskets.index(
            forY: info.location.y,
            basketTop: basketTop,
            rowStride: rowStride,
            count: folderCount
        )
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 132

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
