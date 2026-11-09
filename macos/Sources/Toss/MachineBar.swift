import SwiftUI
import UniformTypeIdentifiers

enum Brand {
    /// 投递口命中时的品牌绿。
    static let green = Color(red: 0.09, green: 0.62, blue: 0.40)

    /// 统一的卡片圆角。
    static let radius: CGFloat = 12

    /// 分隔线与描边的「发丝」色。
    static let hairline = Color.primary.opacity(0.08)

    /// 没投中时用的红色。
    static let miss = Color(red: 0.86, green: 0.33, blue: 0.28)

    /// 当前正在查看、只负责往外发的来源机器：用蓝色和可投篮的绿色区分开。
    static let source = Color(red: 0.36, green: 0.50, blue: 0.76)
}

/// 顶部机器栏：本机 + 所有服务器排成一排。
/// 点一张卡片就切到那台机器的文件列表；拖动文件时，其余机器自动展开文件夹篮筐。
/// 放不下时横向滚动，两侧的 < / > 一次翻「一屏可见数量」。
struct MachineBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var drag: DragSession
    let source: ThrowTarget

    @State private var scrollIndex = 0
    @State private var tallestCard: CGFloat = 132

    private var machines: [ThrowTarget] {
        ThrowTargets.machines(servers: state.servers)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = DockLayout(available: geometry.size.width, count: machines.count)

            ScrollViewReader { proxy in
                HStack(spacing: 4) {
                    if layout.overflowing {
                        arrow(.backward, layout: layout, proxy: proxy)
                    }

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: layout.spacing) {
                            ForEach(machines) { target in
                                MachineCard(
                                    state: state,
                                    drag: drag,
                                    target: target,
                                    isSource: target == source,
                                    width: layout.cardWidth,
                                    folders: state.folders(for: target),
                                    onSelect: { state.selectedTarget = target }
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
                        proxy.scrollTo(source.id, anchor: .center)
                    }
                    .onChange(of: machines.count) { _ in
                        scrollIndex = min(scrollIndex, layout.maxIndex)
                    }

                    if layout.overflowing {
                        arrow(.forward, layout: layout, proxy: proxy)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: max(150, tallestCard + 32))
        .background(.regularMaterial)
        .onPreferenceChange(CardHeightKey.self) { height in
            tallestCard = height
        }
        .animation(.easeInOut(duration: 0.22), value: tallestCard)
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
            total: machines.count,
            forward: direction == .forward
        )
        guard next != scrollIndex, machines.indices.contains(next) else { return }
        scrollIndex = next

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(machines[next].id, anchor: .leading)
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

private struct MachineCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var drag: DragSession
    let target: ThrowTarget
    let isSource: Bool
    let width: CGFloat
    let folders: [String]
    let onSelect: () -> Void

    @State private var isTargeted = false
    @State private var hoveredBasket: Int?
    @State private var frameInRoot: CGRect = .zero

    private let faceHeight: CGFloat = 46
    private let basketRowHeight: CGFloat = 26
    private let basketGap: CGFloat = 4
    /// 收起时后面两张「叠卡」往上露一点；展开时这一点留白也保留，卡片顶边才对得齐。
    private let topPadding: CGFloat = 22

    /// 拖任何文件时，除来源以外的机器全部展开成篮筐；来源自己保持收起。
    private var showsBaskets: Bool {
        drag.isDragging && !isSource && !folders.isEmpty
    }

    private var basketTop: CGFloat { topPadding + faceHeight + 6 }

    /// 展开时把每个篮筐的落点在窗口里的位置报给拖拽会话，用来判断拉弓射线打得中哪一个。
    private var aimInfo: MachineAim? {
        guard showsBaskets, !frameInRoot.isEmpty else { return nil }
        let rowStride = basketRowHeight + basketGap
        let baskets = folders.indices.map { index in
            let top = frameInRoot.minY + basketTop + CGFloat(index) * rowStride
            return BasketAim(
                anchor: CGPoint(x: frameInRoot.midX, y: top + basketRowHeight / 2),
                rect: CGRect(
                    x: frameInRoot.minX + 8,
                    y: top,
                    width: max(0, frameInRoot.width - 16),
                    height: basketRowHeight
                )
            )
        }
        return MachineAim(targetID: target.id, cardFrame: frameInRoot, baskets: baskets)
    }

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
        .onTapGesture(perform: onSelect)
        .onDrop(
            of: [UTType.json],
            delegate: BasketDropDelegate(
                enabled: !isSource,
                isTargeted: $isTargeted,
                hovered: $hoveredBasket,
                drag: drag,
                targetID: target.id,
                cardFrame: frameInRoot,
                folderCount: folders.count,
                basketTop: basketTop,
                rowStride: basketRowHeight + basketGap,
                rowHeight: basketRowHeight,
                targetName: target.displayName,
                onDrop: handleDrop
            )
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isTargeted)
        .animation(.easeInOut(duration: 0.22), value: showsBaskets)
        .background(geometryReader)
        .onAppear { drag.setAim(targetID: target.id, aimInfo) }
        .onChange(of: aimInfo) { next in
            drag.setAim(targetID: target.id, next)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Throw to {}", target.displayName))
    }

    private var geometryReader: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(TossSpace.root))
            Color.clear
                .onAppear { frameInRoot = frame }
                .onChange(of: frame) { next in
                    frameInRoot = next
                }
                .preference(key: CardHeightKey.self, value: proxy.size.height)
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
    /// 指针真的落在这一行时高亮；指针还在下面「反向投篮」时，自动瞄准的篮筐也亮起来。
    private var basketList: some View {
        VStack(spacing: basketGap) {
            ForEach(Array(folders.enumerated()), id: \.offset) { index, directory in
                BasketRow(
                    directory: directory,
                    width: width,
                    height: basketRowHeight,
                    isHovered: hoveredBasket == index
                        || (drag.hover?.targetID == target.id && drag.hover?.basket == index),
                    isAimed: drag.aim?.hit == true
                        && drag.aim?.targetID == target.id
                        && drag.aim?.basket == index
                )
            }
        }
    }

    private var frontCard: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Brand.green.opacity(0.14) : Color.mainCardTint(isSource))
                    .frame(width: 34, height: 34)
                Image(systemName: target.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isTargeted ? Brand.green : (isSource ? Brand.source : Color.secondary))
            }

            Text(target.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(target.addressLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(isSource ? t("Viewing") : t("Drop here"))
                .font(.caption2)
                .foregroundStyle(isTargeted
                                 ? Brand.green
                                 : (isSource ? Brand.source : Color(nsColor: .tertiaryLabelColor)))
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 104)
        .background(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .fill(isTargeted
                      ? Brand.green.opacity(0.08)
                      : (isSource
                         ? Brand.source.opacity(0.08)
                         : Color(nsColor: .controlBackgroundColor).opacity(0.62)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.radius, style: .continuous)
                .strokeBorder(
                    isTargeted
                        ? Brand.green
                        : (isSource ? Brand.source : Brand.hairline),
                    lineWidth: isTargeted || isSource ? 1.5 : 0.5
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
        guard let directory = BasketChoice.directory(for: basket, among: folders) else {
            OperationLog.warning(t("No basket matched on {}", target.displayName))
            return false
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
        }) else {
            OperationLog.error(t("Drop on {} carried no matching payload", target.displayName))
            return false
        }

        let typeID = UTType.json.identifier
        let finish: (Data?, String) -> Void = { data, detail in
            guard let data,
                  !data.isEmpty,
                  let payload = try? JSONDecoder().decode(ThrowPayload.self, from: data)
            else {
                OperationLog.error(t("Could not read the drop payload for {}: {}",
                                     target.displayName,
                                     detail))
                return
            }
            DispatchQueue.main.async {
                state.beginThrow(payload: payload, target: target, targetDir: directory)
            }
        }

        // 数据型 provider 走 loadDataRepresentation；万一拿不到再退回 loadItem。
        provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, error in
            if let data, !data.isEmpty {
                finish(data, "data \(data.count) bytes")
                return
            }
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, itemError in
                let data: Data?
                if let value = item as? Data {
                    data = value
                } else if let value = item as? NSData {
                    data = value as Data
                } else if let value = item as? String {
                    data = value.data(using: .utf8)
                } else if let value = item as? NSString {
                    data = (value as String).data(using: .utf8)
                } else {
                    data = nil
                }
                let itemType = item.map { String(describing: Swift.type(of: $0)) } ?? "nil"
                let detail = "item=\(itemType), bytes=\(data?.count ?? 0), error=\(itemError?.localizedDescription ?? error?.localizedDescription ?? "-")"
                finish(data, detail)
            }
        }
        return true
    }
}

/// 整张展开卡片是一个投放目标；落点纵向落在第几个篮筐，就投到第几个文件夹。
private struct BasketDropDelegate: DropDelegate {
    let enabled: Bool
    @Binding var isTargeted: Bool
    @Binding var hovered: Int?
    let drag: DragSession
    let targetID: String
    let cardFrame: CGRect
    let folderCount: Int
    let basketTop: CGFloat
    let rowStride: CGFloat
    let rowHeight: CGFloat
    let targetName: String
    let onDrop: ([NSItemProvider], Int?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        let ok = info.hasItemsConforming(to: [UTType.json])
        if !ok {
            OperationLog.warning(t("Drop rejected on {}: no JSON payload", targetName))
        }
        return ok
    }

    func dropEntered(info: DropInfo) {
        guard enabled else { return }
        OperationLog.info(t("Drag entered {}", targetName))
        isTargeted = true
        updateHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard enabled else { return nil }
        updateHover(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        hovered = nil
        drag.clearHover(targetID: targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        updateHover(info)
        OperationLog.info(t("Dropped on {} at y={} with {} item(s)",
                            targetName,
                            Int(info.location.y),
                            info.itemProviders(for: [UTType.json]).count))
        let result = onDrop(info.itemProviders(for: [UTType.json]), hovered)
        let scoredBasket = hovered ?? (folderCount == 1 ? 0 : nil)
        if result, let scoredBasket {
            drag.finishScored(at: anchor(for: scoredBasket))
        } else {
            drag.finishMissed(at: nil)
        }
        isTargeted = false
        hovered = nil
        drag.clearHover(targetID: targetID)
        return result
    }

    private func anchor(for basket: Int) -> CGPoint {
        CGPoint(
            x: cardFrame.midX,
            y: cardFrame.minY + basketTop + CGFloat(basket) * rowStride + rowHeight / 2
        )
    }

    private func updateHover(_ info: DropInfo) {
        let index = DockBaskets.index(
            forY: info.location.y,
            basketTop: basketTop,
            rowStride: rowStride,
            count: folderCount
        )
        hovered = index

        guard let resolved = index ?? (folderCount == 1 ? 0 : nil) else {
            drag.clearHover(targetID: targetID)
            return
        }

        let anchor = CGPoint(
            x: cardFrame.midX,
            y: cardFrame.minY + basketTop + CGFloat(resolved) * rowStride + rowHeight / 2
        )
        drag.updateHover(targetID: targetID, basket: resolved, anchor: anchor)
    }
}

/// 一行文件夹篮筐。
/// 被拉弓射线指中时整行变成真正的蓝色描边框，并轻轻呼吸；指针直接落在这一行时保持绿色。
private struct BasketRow: View {
    let directory: String
    let width: CGFloat
    let height: CGFloat
    let isHovered: Bool
    let isAimed: Bool

    @State private var breathing = false

    private var isActive: Bool { isAimed || isHovered }
    private var accent: Color { isAimed ? Brand.source : Brand.green }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "tray.full.fill" : "tray")
                .font(.caption2)
            Text(directory)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isActive ? accent : Color.secondary)
        .padding(.horizontal, 9)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent.opacity(isActive ? 1 : 0),
                              lineWidth: isActive ? 2 : 0)
        )
        .shadow(color: accent.opacity(isActive ? (breathing ? 0.34 : 0.16) : 0),
                radius: isActive ? (breathing ? 7 : 4) : 0)
        .scaleEffect(isActive ? 1.015 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: isActive)
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: isAimed)
        .onChange(of: isActive) { active in
            breathing = false
            guard active else { return }
            breathe()
        }
        .onAppear {
            // 卡片展开时可能已经被瞄准，这里的呼吸动画要自己接上。
            guard isActive else { return }
            breathe()
        }
    }

    private var fill: Color {
        if isAimed {
            return Brand.source.opacity(breathing ? 0.20 : 0.12)
        }
        if isHovered {
            return Brand.green.opacity(0.14)
        }
        return Color.primary.opacity(0.05)
    }

    private func breathe() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 132

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Color {
    /// 来源卡片用淡蓝底，和可投篮的绿色区分开。
    static func mainCardTint(_ isSource: Bool) -> Color {
        isSource ? Brand.source.opacity(0.12) : Color.primary.opacity(0.05)
    }
}
