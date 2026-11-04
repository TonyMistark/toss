import SwiftUI
import UniformTypeIdentifiers

enum Brand {
    /// 投递口命中时的品牌绿。
    static let green = Color(red: 0.09, green: 0.62, blue: 0.40)
}

/// 其余服务器 + 本机：一排大号堆叠投递口。
struct ThrowDockView: View {
    @ObservedObject var state: AppState
    let source: ServerConfig

    private var targets: [ThrowTarget] {
        state.servers
            .filter { $0.name != source.name }
            .map { ThrowTarget.server($0) }
            + [.local]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t("Drop into another server or this Mac"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(targets) { target in
                        ThrowTargetCard(state: state, target: target)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(height: 186)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ThrowTargetCard: View {
    @ObservedObject var state: AppState
    let target: ThrowTarget

    @State private var isTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            backingCard(scale: 0.92, offset: -18, opacity: 0.45)
            backingCard(scale: 0.96, offset: -9, opacity: 0.72)
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
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Throw to {}", target.displayName))
    }

    private var frontCard: some View {
        VStack(spacing: 6) {
            Image(systemName: target.isLocal ? "laptopcomputer" : "server.rack")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isTargeted ? Brand.green : Color.secondary)

            Text(target.displayName)
                .font(.headline)
                .lineLimit(1)

            Text(target.addressLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(t("Drop here"))
                .font(.caption2)
                .foregroundStyle(isTargeted ? Brand.green : Color.secondary.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(width: 210, height: 108)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Brand.green.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Brand.green : Color.secondary.opacity(0.28),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        .shadow(
            color: .black.opacity(isTargeted ? 0.16 : 0.06),
            radius: isTargeted ? 10 : 4,
            y: isTargeted ? 6 : 2
        )
        .offset(y: isTargeted ? -4 : 0)
    }

    private func backingCard(scale: CGFloat, offset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: 210, height: 108)
            .scaleEffect(x: scale, y: scale)
            .offset(y: offset)
            .opacity(opacity)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Brand.green.opacity(0.5) : Color.secondary.opacity(0.16),
                        lineWidth: 1
                    )
                    .scaleEffect(x: scale, y: scale)
                    .offset(y: offset)
            )
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
