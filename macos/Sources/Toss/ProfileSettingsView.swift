import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 个人信息页

/// 设置里的「个人信息」：头像 + 昵称。
///
/// 只存本地——这页上那句话是承诺，不是装饰。页面自己铺满内容区，
/// 不依赖工程里私有的 `settingsPage()` 修饰符：拷过去就能用。
///
/// 用法：设置侧栏加一行 `case .profile: ProfileSettingsView()`，
/// 并给设置场景注入 `ProfileStore`（见 SKILL.md）。
struct ProfileSettingsView: View {
    @EnvironmentObject var profile: ProfileStore
    /// 选中的文件读不出来时给一句人话，而不是静悄悄什么都不发生。
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    ProfileAvatar(image: profile.avatar, initial: profile.initial, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button(t("Choose Picture…")) { choosePicture() }
                            if profile.avatar != nil {
                                Button(t("Remove")) { profile.clearAvatar() }
                            }
                        }
                        Text(t("PNG, JPEG or HEIC. Kept on this Mac, never uploaded."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let failure {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 4)

                TextField(
                    t("Nickname"),
                    text: $profile.nickname,
                    prompt: Text(t("What should we call you?"))
                )
                .textFieldStyle(.roundedBorder)
            }

            Section {
                Text(t("Your name and picture stay in this app's own folder. They never leave the machine and are not written into any document."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = t("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if profile.setAvatar(from: url) {
            failure = nil
        } else {
            failure = t("That file could not be read as a picture.")
        }
    }
}
