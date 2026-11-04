# Tasks：Toss 设置页地基 + Gitee 双源

## 1. 工程守卫

- [x] `macos/Package.swift` 增加 `TossTests` testTarget。
- [x] 运行 `cd macos && swift test`，确认 scaffold 的 14 条守卫可编译通过。

## 2. 应用启动与设置场景

- [x] 新增 `AppServices.swift`，按序执行 harvest / breadcrumbs / catcher / launch note。
- [x] 新增 `RootView.swift`，挂 `crashPrompt`、启动检查更新。
- [x] 改造 `TossApp.swift`：WindowGroup 用 RootView，新增 Settings scene，
      App 菜单替换为 `AboutPanel.show()`。
- [x] 新增 `SettingsShell.swift`：三页侧栏 + 四个 environmentObject 注入 +
      `SettingsWindow.open()`。
- [x] 新增 `GeneralSettingsView.swift`，删除 `GlobalSettingsView.swift`；
      保留 `~/.toss` 默认目录。
- [x] `ContentView.swift` 删除设置 sheet，齿轮改开 Settings 窗口。

## 3. L10n 全量接入

- [x] `AppState.swift` 文案改 `t()`。
- [x] `ContentView.swift` 文案改 `t()`。
- [x] `ServerDetailView.swift` 文案改 `t()`（插值改 `{}`）。
- [x] `ServerEditorView.swift` 文案改 `t()`。
- [x] `TransferService.swift` 错误与成功文案改 `t()`。
- [x] `TossApp.swift` / `SettingsShell.swift` 新增文案改 `t()`。
- [x] `Translations+zh.swift` 补齐所有新键。
- [x] `swift test --filter L10n` 全绿。

## 4. 品牌与关于

- [x] `AppSettingsPage.swift` tagline 改为 Toss 的真实描述，补中文。
- [x] `Info.plist` 版权改为 `© 2026 TonyMistark`，版本保持 `0.1.0`。

## 5. 发布链路

- [x] `scripts/build_app.sh` 支持 `TOSS_VERSION` 并写入产物版本。
- [x] 新增 `scripts/package_dmg.sh`，产出 `dist/toss-<version>.dmg`。
- [x] 新增 `.github/workflows/ci.yml`（build + test）。
- [x] 新增 `.github/workflows/release.yml`（tag → test → build → dmg → GitHub Release
      → Gitee 同步）。
- [x] 新增 `scripts/sync_gitee_release.sh`（创建/复用 Release + 上传 dmg）。
- [x] `README.md` 增加发布与 `GITEE_TOKEN` 说明。

## 6. 验证

- [x] `cd macos && swift build` 成功。
- [x] `cd macos && swift test` 全部通过（14/14）。
- [x] `./scripts/build_app.sh` 生成 `build/Toss.app`。
- [x] `./scripts/package_dmg.sh` 生成 dmg。
- [x] 重启 App 检查设置三页、语言切换、头像持久化、崩溃面板、检查更新失败静默
      （代码/单元测试与启动验证通过；视觉细节需用户在本机确认，见 checklist.md）。

## 7. Git 同步

- [x] `git remote add gitee ...`（若不存在）。
- [x] 提交全部改动（含既有 Python 改动）。
- [x] `git push origin main`。
- [x] `git push -u gitee main`。
- [x] 若 SSH 失败，记录错误并给出用户可执行的命令（本次 SSH 成功，无需处理）。
