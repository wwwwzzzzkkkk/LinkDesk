# 版本与发布

- `main`：Mac mini 版及后续开发。语义版本 `MAJOR.MINOR.PATCH`。
- `legacy/macbook`：MacBook 0.5.2 源码归档；原标签 `macbook-v0.5.2` 不移动。
- `v0.6.3` 等：正式版本标签，发布后不覆写；回退检出旧标签并保留相应签名。
- `VERSION`：Mac 营销版本；`BUILD_NUMBER`：Mac 构建号，递增。
- HarmonyOS 的 `AppScope/app.json5` 同步 `versionName`，`versionCode` 必须递增。

## 发布步骤

1. 更新版本文件、HarmonyOS 版本和 CHANGELOG。
2. 运行 CI 检查并在两端验证屏幕、扬声器、麦克风。
3. 使用原固定证书构建；公开发行设置 `LINKDESK_BUNDLE_HDC=0`，不包含 SDK 工具。
4. `scripts/package-release.sh` 生成包含 Mac 应用、驱动、安装脚本、许可证和对应源码的压缩包与 SHA-256 文件。证书指纹为公开验证数据，私钥不打包。
5. 提交后打 `vVERSION` 标签，`gh release create` 上传 zip 与校验文件。HarmonyOS 个人调试签名与设备绑定，不公开上传个人 HAP；有公开分发资质后另行发布。
6. 更新 `wwwwzzzzkkkk/homebrew-linkdesk` 中 Cask 的版本和 SHA-256，验证下载、语法与签名保护。

签名私钥不进入 GitHub Actions。CI 仅临时签名编译检查，不替代本机正式发行。将来迁移 Developer ID 必须记录证书变化，并提示首次重新授权录屏。

保留 MacBook 原版：`git switch legacy/macbook`，或 `git switch --detach macbook-v0.5.2`。原版分支仅源码归档，不发布未经验证的新二进制。
