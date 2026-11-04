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

0 → 15 项单元测试（版本比较、先问后装、崩溃入账、L10n 覆盖、个人信息）。

## 崩溃分类修正（issue #1）

### 现象

v0.1.0 的账本里出现一份 `[退出] toss 没有正常退出`，正文却写着「信号：SIGSEGV」。

### 结论

系统日志 `Toss-2026-11-04-113310.ips` 显示那次是真 `EXC_CRASH / SIGSEGV`，但主线程停在
`mach_msg` 空闲等待——是手工 `kill -SEGV` 打进来的信号，不是业务代码越界。信号处理器
写了 `kind signal` / `signal SIGSEGV`，只是 `backtrace` 没抓到帧。

旧逻辑把「帧为空」当成「被外部结束」，于是真崩溃被报成强退：标题说没正常退出，正文
又写着 SIGSEGV，自相矛盾。纯头部的现场（`kill -9`、断电）确实没有帧，两者不能混为一谈。

### 修正

- `CrashRaw.kind` 改为可选：`nil` 才是「只有头部」。
- `CrashStore.report(from:)` 用 `raw.kind ?? .terminated`，帧是否为空不再参与分类。
- 真崩溃但没抓到栈时，正文改写「记下了故障类型，但没抓到调用栈」。
- 新增守卫测试「写了信号但抓栈失败：仍算崩溃」。

