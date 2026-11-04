# V0 计划与版本记录

## v0.1.0 — 首个可用版本

### 现象

需要把仓库里的 SCP 传输能力做成一个原生 macOS App，并具备可持续发版的基础设施：
中英切换、检查更新、关于面板、崩溃报告、个人信息，以及 GitHub / Gitee 双源安装包。

### 方案

- SwiftUI 单窗口 App，服务器列表、配置编辑、发送 / 拉取 / 文件列表共用 `~/.toss/config.json`。
- 接入 macapp-vitals：`L10n`、`UpdateChecker`、`UpdateInstaller`、`CrashStore`、`ProfileStore`。
- 设置改为系统 Settings 窗口，三页：个人信息、通用、应用。
- 头像支持选图、拖动缩放裁剪，裁成 512 px 本地 PNG；工具栏使用 `SettingsEntryButton`。
- 发布链：tag `v<version>` → CI 测试 → 构建 → dmg → 隔离冒烟 → GitHub Release → Gitee 同步。
- Gitee 同步拆成独立 workflow：无令牌不挡发布，tag / release / 附件全部幂等；本机留 `sync-gitee-all.sh` 兜底。

### 坑

- Gitee 同步依赖 `GITEE_TOKEN`；未配置时脚本打印指引并跳过，不挡 GitHub 发布。
- 隔离冒烟必须直接 exec 二进制并注入 `CFFIXED_USER_HOME`，不能用 `open -n --env`。
- `hdiutil` 在 `/tmp` 下会显示为 `/private/tmp`，卸载要直接用原 mountpoint，不能靠 `mount | grep`。
- 工具栏头像与设置页必须共用 `ProfileAvatar`，否则会出现「一处是我、一处是系统人像」。
- 用 `GITHUB_TOKEN` 创建的 Release 不会触发 `release: published`，因此 `gitee-sync.yml` 同时监听 `workflow_run`。

### 测试数变化

0 → 14 项单元测试（版本比较、先问后装、崩溃入账、L10n 覆盖、个人信息）。
