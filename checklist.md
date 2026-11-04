# Checklist：Toss 设置页地基 + Gitee 双源

## 自动化验证

- [x] `macos/Package.swift` 含 `TossTests` target。
- [x] `swift build` 成功。
- [x] `swift test` 14/14 通过。
- [x] L10n 翻译表覆盖全部 `t()` 键。
- [x] `TOSS_VERSION=0.1.0 ./scripts/build_app.sh` 产物版本为 0.1.0。
- [x] `VERSION=0.1.0 ./scripts/package_dmg.sh` 产出 `dist/toss-0.1.0.dmg`。
- [x] 工具栏设置入口使用 `SettingsEntryButton`。
- [x] CI workflow 使用 macOS 15 + 26，`fail-fast: false`，含 release build 兜底。
- [x] `VERSION=0.1.0 ./scripts/smoke_test.sh` 隔离冒烟通过。

## 启动与崩溃

- [x] `build/Toss.app` 可启动并保持运行。
- [x] `kill -SEGV` 后生成 `.inflight-*.raw`；下次启动 harvest 成 `.tosscrash`。
- [x] 崩溃报告落在 `~/Library/Application Support/toss/crashes/`。
- [x] 启动顺序为 harvest → breadcrumbs → catcher → launch note。

## Git 与 Gitee

- [x] 提交 `62467a2`，GitHub `origin/main` 推送成功。
- [x] 新建 `gitee` remote 并 `git push -u gitee main` 成功。
- [x] Gitee 仓库 API 可访问（HTTP 200）。
- [x] Release workflow 已就绪（`v*` tag 触发）。
- [x] 已推送 `v0.1.0` tag，GitHub Release 发布成功。
- [x] GitHub Secrets 已配置 `GITEE_TOKEN`。
- [x] 重跑 Release workflow 成功，Gitee Release 已包含 `toss-0.1.0.dmg`。

## 发布链

- [x] `dist/` 只保留当前版本 dmg。
- [x] Release 创建时标记 `--latest`。
- [x] 发布前隔离冒烟：DMG 可启动、轨迹首行正常、无崩溃报告。
- [x] Gitee 双源附件（`toss-0.1.0.dmg` 已上传）。

## 需用户本机确认的视觉项

由于当前终端没有屏幕录制与辅助功能权限，以下无法由 agent 截图确认：

- [ ] 设置窗口三页（个人信息 / 通用 / 应用）布局正常。
- [ ] 切换 English 并重启后，主界面与设置页均为英文。
- [ ] 选择头像后变圆、重启仍在。
- [ ] 「检查更新」失败时不弹窗，原因留在设置页。
- [ ] 崩溃面板在下次启动时正常展示（报告文件已确认生成）。
