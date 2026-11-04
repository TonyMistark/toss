import SwiftUI

/// 窗口底部的传输队列：等待 → 打包 → 传输 → 解包 → 校验 → 完成。
struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue

    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 7)

            Divider()

            if expanded {
                if queue.jobs.isEmpty {
                    Text(t("No transfers yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(height: expanded ? (queue.jobs.isEmpty ? 96 : 196) : 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .foregroundStyle(.secondary)
            Text(t("Transfers"))
                .font(.headline)

            if queue.activeCount > 0 {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if !queue.jobs.isEmpty {
                Button(t("Clear finished")) {
                    queue.clearFinished()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.title)
                        .font(.callout)
                        .bold()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(job.stage.label)
                        .font(.caption)
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
                .foregroundStyle(.secondary)

                if job.stage.isActive {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 16)
        }
    }

    private var stageIcon: some View {
        Group {
            switch job.stage {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .packing, .transferring, .unpacking, .verifying:
                ProgressView()
                    .controlSize(.small)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
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
        VStack(spacing: 4) {
            if job.stage.isActive || job.stage == .queued {
                Button(t("Cancel")) {
                    queue.cancel(job.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if job.stage == .failed || job.stage == .cancelled {
                Button(t("Retry")) {
                    queue.retry(job.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if job.stage == .finished {
                Button(job.target.isLocal ? t("Open") : t("Copy path")) {
                    queue.openDestination(of: job.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
