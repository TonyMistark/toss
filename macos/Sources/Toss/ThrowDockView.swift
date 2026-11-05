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
struct ThrowDockView: View {
    @ObservedObject var state: AppState
    let source: ThrowTarget

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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(targets) { target in
                            ThrowTargetCard(
                                state: state,
                                target: target,
                                width: cardWidth(available: geometry.size.width)
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(height: 176)
        .background(.regularMaterial)
    }

    private var title: String {
        source.isLocal ? t("Drop into a server") : t("Drop into another server or this Mac")
    }

    private func cardWidth(available: CGFloat) -> CGFloat {
        let count = CGFloat(max(targets.count, 1))
        let spacing: CGFloat = 12
        let padding: CGFloat = 40
        let proposed = (available - padding - spacing * (count - 1)) / count
        return max(146, min(204, proposed))
    }
}

private struct ThrowTargetCard: View {
    @ObservedObject var state: AppState
    let target: ThrowTarget
    let width: CGFloat

    @State private var isTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            backingCard(scale: 0.93, offset: -16, opacity: 0.35)
            backingCard(scale: 0.965, offset: -8, opacity: 0.60)
            frontCard
        }
        .padding(.top, 22)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        // 整块（含后面两张卡与内边距）都是热区；24pt 缓冲避免拖不进去。
        .contentShape(Rectangle())
        .onDrop(of: [UTType.json], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Throw to {}", target.displayName))
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
        }) else {
            return false
        }

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
                state.beginThrow(payload: payload, target: target)
            }
        }
        return true
    }
}
