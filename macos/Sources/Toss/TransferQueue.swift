import AppKit
import Foundation
import SwiftUI

/// 一个可取消的传输。终止信号通过它传给两条 SSH 进程。
final class ThrowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ process: Process) {
        lock.lock()
        if cancelled {
            lock.unlock()
            process.terminate()
            return
        }
        processes.append(process)
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}

struct ThrowCancelled: LocalizedError {
    var errorDescription: String? { t("Transfer cancelled") }
}

/// 串行执行的传输队列。服务层可以注入，测试不用碰 SSH。
@MainActor
final class TransferQueue: ObservableObject {
    typealias Performer = (
        TransferJob,
        @escaping (TransferStage, Double?, Int64?) -> Void,
        ThrowCancellation
    ) async throws -> Void

    @Published private(set) var jobs: [TransferJob] = []

    private let perform: Performer
    private var runningID: UUID?
    private var cancellations: [UUID: ThrowCancellation] = [:]

    init(perform: @escaping Performer = { job, report, cancellation in
        try await ThrowService().run(job, cancellation: cancellation, report: report)
    }) {
        self.perform = perform
    }

    var activeCount: Int {
        jobs.filter { $0.stage.isActive || $0.stage == .queued }.count
    }

    var isIdle: Bool { runningID == nil }

    func enqueue(_ job: TransferJob) {
        jobs.append(job)
        startNextIfNeeded()
    }

    func cancel(_ id: UUID) {
        guard let job = job(with: id), !job.stage.isFinished else { return }

        // 还没轮到它：直接标记取消，不需要终止进程。
        if runningID != id && job.stage == .queued {
            update(id) { $0.stage = .cancelled }
            return
        }

        cancellations[id]?.cancel()
    }

    func retry(_ id: UUID) {
        guard let job = job(with: id), job.stage == .failed || job.stage == .cancelled else {
            return
        }
        update(id) { item in
            item.stage = .queued
            item.progress = nil
            item.bytesTransferred = 0
            item.message = nil
        }
        startNextIfNeeded()
    }

    func clearFinished() {
        jobs.removeAll { $0.stage.isFinished }
    }

    /// 本机目标在访达里打开；远程目标复制 `user@host:/path` 方便粘贴。
    func openDestination(of id: UUID) {
        guard let job = job(with: id), job.stage == .finished else { return }
        if let server = job.target.server {
            let path = "\(server.address):\(job.targetDir)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            update(id) { $0.message = t("Copied the remote path") }
            return
        }

        let expanded = (job.targetDir as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            update(id) { $0.message = t("Could not open the destination: {}", url.path) }
        }
    }

    // MARK: - 调度

    private func startNextIfNeeded() {
        guard runningID == nil else { return }
        guard let pending = jobs.first(where: { $0.stage == .queued }) else { return }

        let id = pending.id
        let cancellation = ThrowCancellation()
        runningID = id
        cancellations[id] = cancellation

        Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try await self.perform(pending, { stage, progress, bytes in
                    DispatchQueue.main.async {
                        self.apply(id: id, stage: stage, progress: progress, bytes: bytes)
                    }
                }, cancellation)
            } catch {
                failure = error
            }
            self.finish(id: id, error: failure, cancellation: cancellation)
        }
    }

    private func finish(id: UUID, error: Error?, cancellation: ThrowCancellation) {
        update(id) { job in
            if cancellation.isCancelled {
                job.stage = .cancelled
                job.message = t("Transfer cancelled")
            } else if let error {
                job.stage = .failed
                job.message = error.localizedDescription
            } else {
                job.stage = .finished
                job.progress = 1
                job.message = nil
            }
        }
        cancellations[id] = nil
        runningID = nil
        startNextIfNeeded()
    }

    private func apply(id: UUID, stage: TransferStage, progress: Double?, bytes: Int64?) {
        update(id) { job in
            // finish() 可能已经先把任务收尾；迟到的进度不能再把状态改回去。
            guard !job.stage.isFinished else { return }
            job.stage = stage
            if let progress {
                job.progress = progress
            }
            if let bytes {
                job.bytesTransferred = bytes
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func job(with id: UUID) -> TransferJob? {
        jobs.first { $0.id == id }
    }
}
