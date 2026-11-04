import SwiftUI

/// 窗口底部的传输队列：等待 → 打包 → 传输 → 解包 → 校验 → 完成。
struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue

    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            Divider()
                .opacity(0.6)

            if expanded {
                if queue.jobs.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tertiary)
                        Text(t("No transfers yet"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(queue.jobs) { job in
                                TransferJobRow(queue: queue, job: job)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: expanded ? (queue.jobs.isEmpty ? 86 : 196) : 36)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(t("Transfers"))
                .font(.subheadline.weight(.semibold))

            if queue.activeCount > 0 {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if !queue.jobs.isEmpty {
                Button(t("Clear finished")) {
                    queue.clearFinished()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(t("Collapse or expand the transfer queue"))
        }
    }
}

private struct TransferJobRow: View {
    @ObservedObject var queue: TransferQueue
    let job: TransferJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stageIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(job.stage.label)
                        .font(.caption2)
                        .foregroundStyle(stageColor)
                }

                Text(job.entrySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(job.targetDir)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(ByteCount.format(job.bytesTransferred))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                if job.stage.isActive {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Brand.green)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Brand.green)
                    }
                }

                if let message = job.message,
                   job.stage == .failed || job.stage == .cancelled || job.stage == .finished {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(job.stage == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
            }

            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.5)
                .padding(.leading, 48)
        }
    }

    private var stageIcon: some View {
        Group {
            switch job.stage {
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            case .packing, .transferring, .unpacking, .verifying:
                ProgressView()
                    .controlSize(.small)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Brand.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "slash.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18)
        .padding(.top, 2)
    }

    private var stageColor: Color {
        switch job.stage {
        case .finished: return Brand.green
        case .failed: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            if job.stage.isActive || job.stage == .queued {
                iconButton("xmark", label: t("Cancel")) {
                    queue.cancel(job.id)
                }
            } else if job.stage == .failed || job.stage == .cancelled {
                iconButton("arrow.clockwise", label: t("Retry")) {
                    queue.retry(job.id)
                }
            } else if job.stage == .finished {
                if job.target.isLocal {
                    iconButton("folder", label: t("Open")) {
                        queue.openDestination(of: job.id)
                    }
                } else {
                    iconButton("doc.on.doc", label: t("Copy path")) {
                        queue.openDestination(of: job.id)
                    }
                }
            }
        }
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
