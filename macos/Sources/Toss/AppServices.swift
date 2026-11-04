import Foundation

/// 应用级的一份服务：这台机器的属性，不属于某一扇窗。
///
/// 启动顺序不能反：先收上次的尸，再装轨迹本（装的时候会清空它），
/// 最后装信号处理器，并写下这次启动的第一行轨迹。
@MainActor
final class AppServices {
    let updates: UpdateChecker
    let installer: UpdateInstaller
    let crashes: CrashStore
    let profile: ProfileStore

    init() {
        updates = UpdateChecker()
        installer = UpdateInstaller(steps: UpdateInstaller.productionSteps())
        crashes = CrashStore()
        profile = ProfileStore()

        crashes.harvest()
        CrashBreadcrumbs.install(directory: crashes.directory)
        CrashCatcher.install(directory: crashes.directory)
        CrashBreadcrumbs.note("launch \(CrashEnvironment.appVersion)")
    }
}
