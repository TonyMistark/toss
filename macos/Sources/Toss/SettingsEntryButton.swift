import SwiftUI

// MARK: - 设置入口

/// 工具栏上的「我」——点它进设置。
///
/// 入口本身就是一张身份卡：
///
/// - 头像三级回落：设了图就画图；没设图但设了昵称，画昵称的第一个字；
///   两个都没设，画一枚系统人像。**默认头像不是空白**——一个没有名字的
///   app 也得有个地方可以「是我」。
/// - 昵称只在设了的时候显示：没设就只画一枚圆，不放占位文字。
///   入口是给用户自己看的，「未命名」只会提醒人「你还没填表」。
///
/// 头像怎么画的见 `ProfileAvatar`（工具栏、设置侧栏、个人信息页共用同一个
/// 视图——三处显示同一个人，才不会出现「侧栏里是我，工具栏里是系统人像」
/// 这种分裂）。
///
/// 用法：工具栏上放 `SettingsEntryButton { openSettings() }`。打开设置的
/// 具体路径各 app 不同（SwiftUI 的 `.openSettings`、私有的窗口管理器……），
/// 所以留成闭包由宿主注入，模板不猜。
struct SettingsEntryButton: View {
    @EnvironmentObject var profile: ProfileStore
    /// How to open the settings window — injected by the host app.
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProfileAvatar(image: profile.avatar, initial: profile.initial, size: 20)
                if profile.hasNickname {
                    Text(profile.nickname)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(t("Settings"))
        .accessibilityLabel(t("Settings"))
        .accessibilityValue(profile.displayName)
    }
}
