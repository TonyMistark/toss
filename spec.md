# Spec：Toss 接入 macapp-vitals 设置页地基 + GitHub/Gitee 双源发布

## 目标

把全局 skill `~/.agents/skills/macapp-vitals` 的「应用地基」完整接入 `macos/` 的
SwiftUI App，并把仓库同步到 Gitee。GitHub 为主仓库；每次 Release 同时发布到
Gitee，更新器在 GitHub 检查或下载失败时自动回退 Gitee。

## 已完成（scaffold 产物，不重复生成）

`python3 ~/.agents/skills/macapp-vitals/scripts/scaffold.py --dest macos/Sources/Toss
--tests macos/Tests/TossTests --module Toss --product Toss --slug toss
--github TonyMistark/toss --gitee Micestark/toss` 已执行，新增：

- `L10n.swift`、`Translations+zh.swift`、`PathKey.swift`
- `UpdateChecker.swift`（GitHub + Gitee 并发检查、24h/1h 节流）
- `UpdateInstaller.swift`（下载 → 确认 → 挂载 → 装配 → 重启，支持换源）
- `CrashCatcher.swift` / `CrashReport.swift` / `CrashStore.swift` /
  `CrashPanel.swift` / `CrashPrompt.swift` / `GitHubIssue.swift`
- `AppSettingsPage.swift`（语言 / 版本 / 关于）
- `Profile.swift` / `ProfileSettingsView.swift`（昵称 + 512px 本地头像）
- `Tests/TossTests/{AppVitalsTests,L10nCoverageTests,ProfileStoreTests}.swift`

## 设计决策

1. **应用级对象只建一份**：`AppServices` 持有 `UpdateChecker`、`UpdateInstaller`、
   `CrashStore`、`ProfileStore`。启动顺序严格为
   `crashes.harvest()` → `CrashBreadcrumbs.install(directory:)` →
   `CrashCatcher.install(directory:)` → `CrashBreadcrumbs.note("launch <version>")`。
2. **设置用系统 Settings scene**：侧栏三页——个人信息 / 通用 / 应用。
   工具栏齿轮改为打开 Settings 窗口；移除 `GlobalSettingsView` sheet。
3. **现有界面文案也接入 L10n**：英文原文作为键，中文放 `Translations+zh.swift`；
   字符串插值统一改成 `t("... {} ...", arg)`，禁止 `\(...)` 作为键。
   这样切换英文时整个 App 一致，而不是只有设置页变英文。
4. **更新先问后装**：沿用模板；安装前必须出现「安装并重启 / 以后」弹窗。
   检查失败静默，原因只留在设置页。
5. **崩溃只本地入账**：不上传；按钮只预填 GitHub issue，提交由用户决定。
6. **版本号单一来源**：`CFBundleShortVersionString` = Release tag 去掉 `v`；
   dmg 命名 `toss-<version>.dmg`；安装时核对 bundle 版本，不一致拒装。
7. **发布双写**：GitHub Actions 在 `v*` tag 上构建 dmg、创建 GitHub Release，
   再调用 Gitee API 创建同名 Release 并上传同一个 dmg。Gitee 失败不阻断 GitHub
   发布，但 workflow 会标红提醒。

## 变更清单

### 1. 工程与启动

- `macos/Package.swift`：新增
  `.testTarget(name: "TossTests", dependencies: ["Toss"], path: "Tests/TossTests")`。
- 新增 `macos/Sources/Toss/AppServices.swift`：
  ```swift
  @MainActor final class AppServices {
      let updates = UpdateChecker()
      let installer = UpdateInstaller(steps: UpdateInstaller.productionSteps())
      let crashes = CrashStore()
      let profile = ProfileStore()
      init() { /* harvest → breadcrumbs install → catcher install → launch note */ }
  }
  ```
- 新增 `macos/Sources/Toss/RootView.swift`：
  `@StateObject private var crashPrompt: CrashPrompt`；
  `ContentView(state: state).crashPrompt(crashPrompt)`
  `.task { crashPrompt.offerIfNeeded() }`
  `.task { await services.updates.checkIfDue() }`。
- `macos/Sources/Toss/TossApp.swift`：
  - 持有 `@StateObject state` 与 `let services = AppServices()`；
  - `WindowGroup` 使用 `RootView`；
  - 新增 `Settings { SettingsShell(state: state, services: services) }`；
  - App 菜单 `CommandGroup(replacing: .appInfo)` 调 `AboutPanel.show()`。

### 2. 设置页

- 新增 `macos/Sources/Toss/SettingsShell.swift`：
  - `enum SettingsTab: String, CaseIterable, Identifiable { case profile, general, app }`
  - 左侧 `List(selection:)`，右侧 `ProfileSettingsView()` / `GeneralSettingsView(state:)` /
    `AppSettingsView()`；注入 `profile`、`updates`、`installer`、`crashes` 四个
    `environmentObject`。
- 新增 `macos/Sources/Toss/GeneralSettingsView.swift`（由现有 `GlobalSettingsView`
  改造成无标题、无 sheet 的设置内容页）：
  - 配置文件路径 + 「在 Finder 中显示」；
  - 默认收发目录 `TextField` + 保存；
  - 保留 `~/.toss` 默认值（不要回退成其它目录）；
  - 保存失败在页面上显示错误，不弹窗。
- 删除 `macos/Sources/Toss/GlobalSettingsView.swift`（内容已迁入
  `GeneralSettingsView`）。
- `macos/Sources/Toss/ContentView.swift`：删除 `showingSettings` 与 `.sheet`；
  齿轮按钮改为 `SettingsWindow.open()`。
- 新增 `SettingsWindow.open()`（放在 `SettingsShell.swift`）：
  macOS 14+ 用 `NSApp.sendAction(Selector(("showSettingsWindow:"))...)`，
  失败时兼容 `showPreferencesWindow:`；保证 macOS 13 也能打开。

### 3. L10n 全量接入

把以下文件中的用户可见中文字面量改为 `t("English key")`，中文写入
`Translations+zh.swift`；插值改成 `{}` 模板参数：

- `AppState.swift`（创建配置、服务器名校验等错误）
- `ContentView.swift`（侧栏空态、按钮、FileChooser 面板）
- `ServerDetailView.swift`（分段控件、发送/拉取/列表、输出区、所有路径提示）
- `ServerEditorView.swift`（表单标签、校验、删除确认）
- `TransferService.swift`（`TossError` 文案、成功/失败提示）
- `TossApp.swift` / `SettingsShell.swift`（菜单与设置页标签）

规则：

- 键必须是单个字符串字面量；动态内容一律 `{}`。
- 每个新键都在 `TranslationsZh.table` 补中文；`L10nCoverageTests` 必须全绿。
- 不改业务逻辑、不改错误触发条件，只替换展示文案。

### 4. 品牌与关于

- `AppSettingsPage.swift` 的 tagline 改为
  `t("A simple SCP and SFTP file transfer tool for macOS.\n")`，
  中文补「一个简单的 macOS SCP / SFTP 文件传输工具。」
- `GitHubIssue.swift` 仓库保持 `TonyMistark/toss`。
- `Info.plist`：版权改为 `© 2026 TonyMistark`；版本仍为 `0.1.0` / build `1`
  （首次 Release 前不改版本；Release tag 必须是 `v0.1.0`）。

### 5. 发布与 Gitee 同步

- 修改 `scripts/build_app.sh`：支持 `TOSS_VERSION` 环境变量；若提供则写入
  构建产物的 `CFBundleShortVersionString`，并校验 `Info.plist` 同名键。
- 新增 `scripts/package_dmg.sh`：从 `build/Toss.app` 生成
  `dist/toss-<version>.dmg`（`hdiutil create -format UDZO`）。
- 新增 `.github/workflows/release.yml`：
  - 触发 `push: tags: ['v*']`；`permissions: contents: write`；`runs-on: macos-15`；
  - 步骤：checkout → `swift test`（`macos/`）→ `TOSS_VERSION=<tag去掉v>
    ./scripts/build_app.sh` → `./scripts/package_dmg.sh` → 校验 dmg 存在 →
    `gh release create v$VERSION dist/toss-$VERSION.dmg --title ...` →
    `./scripts/sync_gitee_release.sh`（`GITEE_TOKEN` secret）。
- 新增 `.github/workflows/ci.yml`：push / PR 时在 `macos/` 跑
  `swift build` + `swift test`。
- 新增 `scripts/sync_gitee_release.sh`：
  - 读取 `GITEE_TOKEN`、`GITEE_OWNER`（默认 `Micestark`）、`GITEE_REPO`（默认 `toss`）、
    `VERSION`、`DMG_PATH`；
  - `GET /repos/{owner}/{repo}/releases/tags/v{version}`，存在则复用，否则
    `POST /releases` 创建；
  - 查询已有 assets，若已存在同名 dmg 则跳过；否则
    `POST /releases/{id}/attach_files` 上传；
  - 所有请求失败返回非 0，workflow 标红。
- `README.md` 增加「发布」一节：tag 规则、dmg 命名、GitHub + Gitee 双源说明、
  必需 secret `GITEE_TOKEN`。

### 6. Git 同步

- 若不存在则执行
  `git remote add gitee git@gitee.com:Micestark/toss.git`。
- 提交全部改动（保留现有未提交的 Python `~/.toss` 默认目录改动）。
- `git push origin main`；`git push -u gitee main`。
- 若 SSH 认证失败，不反复重试，输出错误并给出需用户执行的命令。

## 验证

1. `cd macos && swift build` 成功。
2. `cd macos && swift test` 通过；重点分组：
   `版本号比较|一键更新的流程|崩溃报告入账|L10n|个人信息`。
3. `cd macos && ./scripts/build_app.sh`（或根目录脚本）生成 `build/Toss.app`。
4. 重启 App 手动检查：
   - 设置窗口三页可切换；个人信息昵称/头像重启后仍在；头像显示为圆形。
   - 「立即检查」失败不弹窗，原因留在设置页；GitHub/Gitee 两个源都列在失败原因里。
   - 语言切到 English 并重启，主界面与设置页均为英文；切回中文恢复。
   - `kill -SEGV <pid>` 后重新打开 App，出现崩溃面板；报告文件在
     `~/Library/Application Support/toss/crashes/`。
5. `./scripts/package_dmg.sh` 产出 `dist/toss-0.1.0.dmg`。
6. Git：`git remote -v` 含 gitee；`git log` 有新提交；两个 remote 的 main 同步。
   Release workflow 只能在推 tag 后验证，不在此次本地执行中强制。

## 不做

- 不引入第三方更新框架或网络依赖。
- 不上传崩溃报告、昵称、头像。
- 不自动提交 issue。
- 不在本次改业务传输逻辑。
- 不创建实际 Release / 不推 tag（等用户确认版本后由 workflow 触发）。
