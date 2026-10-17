<p align="center"><img src="assets/linkdesk-icon.png" width="128" alt="LinkDesk icon"></p>

# LinkDesk

Mac 与 MatePad 的跨屏工作空间。统一版 **0.7.0** 把扩展屏幕、PDF 批注、无限白板、平板投屏和华为笔记往返放进同一个 LinkDesk。

| 工作空间 | 用途 | 连接 |
| --- | --- | --- |
| 扩展屏幕 | 把平板用作独立桌面，并连接扬声器与麦克风 | USB |
| PDF 批注 | 两端同步阅读、压感书写、撤销与导出 | USB / Wi-Fi |
| 实时白板 | 无限画布、双向缩放和平移、独立历史 | USB / Wi-Fi |
| 平板投屏 | 把平板全屏画面投射到 Mac | USB |

Mac 使用原生侧栏；平板使用统一工作台和悬浮书写工具栏。两端提供同步的“跟随系统／浅色／深色”外观选择，自动模式跟随 Mac。应用名称、图标与功能顺序一致，视觉采用蓝色、薄荷绿与原生材质。完整架构、兼容规则与验收记录见 [整合说明](docs/UNIFICATION.md)。

## 当前状态

Mac 统一版已构建并使用原固定签名安装到 Mac mini，协议与原生绘制回归通过。鸿蒙已更新原调试签名，合并包成功覆盖安装并启动；统一首页和深浅色双向同步已实机检查。LiveView 需要单独开通华为平台权益。

统一版尚未作为正式 Release 发布。现有 Releases 和 Homebrew 仍提供 0.6.4；不要把它们当作此合并版本。

## 构建与安装

Mac：Apple Silicon、macOS 14+；构建使用 Swift 6 和支持 macOS 26 SDK 的 Xcode。构建脚本下载并校验官方 Node 24.14.1 便携运行时，随应用打包；使用者无需单独安装 Node。华为 HDC SDK 工具不进入公开安装包。

```sh
LINKDESK_SIGN_IDENTITY="固定代码签名证书名称或指纹" LINKDESK_BUNDLE_HDC=0 bash scripts/build-mac.sh
bash scripts/install-mac.sh ../LinkDesk.app
```

使用同一证书更新，保留 `com.zhekuan.linkdesk.mac` 和录屏权限身份。安装器会备份旧应用并拒绝不兼容签名。不要手动覆盖或重新签名已安装应用。无证书时可用 `LINKDESK_SIGN_IDENTITY=-` 生成开发测试包，不能覆盖已授权版本。

USB 工具会依次尝试应用内工具、本机 `~/Library/Application Support/LinkDesk/tools/hdc` 和 DevEco Studio SDK。HDC 与其 libusb 库需要配套。可用 `LINKDESK_HDC` 指定平板安装工具路径。

鸿蒙：DevEco Studio 打开 `HarmonyOS/`，保持 `com.zhekuan.linkdesk`，在本机配置自动调试签名后构建。源码不包含签名材料。也可在独立本机构建目录保留私有签名，通过 `LINKDESK_HARMONY_BUILD_ROOT` 指定该目录。

```sh
bash scripts/build-harmony.sh
bash scripts/install-harmony.sh
```

安装器使用覆盖安装，不删除应用数据。首次配置平板时，开启开发者选项和 USB 调试并允许 Mac。签名证书过期时先在 DevEco 更新，不能通过卸载应用绕过更新失败。

## 使用

- 两端打开 LinkDesk，在工作台选择工作空间。PDF／白板通过“连接与配对”扫码或使用同一个六位房间号；自动连接优先 USB，断线回退 Wi-Fi。
- 扩展屏幕：平板选择“扩展屏幕”，Mac 允许录屏；在 Mac“排列显示器”调整位置。
- PDF：Mac 打开 PDF，平板手写；手指平移、双指缩放。Mac 支持文字选择、⌘F 搜索、撤销／重做和另存为标准 PDF Ink 批注。
- 白板：两端切换“实时白板”，画布没有边界，缩放范围 25%–800%。
- 华为笔记：文件菜单“发送 PDF 到平板批注…”，平板优先打开华为笔记；完成后通过分享菜单回传 LinkDesk，Mac 保存批注副本。
- 平板投屏：保持 USB 连接，在任一端启动并在平板允许系统录屏。进入平板扩展屏幕前会停止平板投屏。
- 麦克风每次默认关闭；平板和 Mac 两端均需手动启用。离开平板前台立即停止拾音。

首次使用扬声器或麦克风，需要已有 LinkDesk Core Audio 驱动；驱动无需因本次 UI／工作区合并而重新安装。驱动安装会请求管理员授权并短暂重启音频服务，见 [安装说明](docs/INSTALL.md)。

## 验证

```sh
cd InkBridge && npm ci --ignore-scripts && npm test
```

协议覆盖 PDF 生命周期、断线快照、压感、视口控制、白板历史、撤销与重做、持久化和双向投屏控制。`scripts/check-unified.sh` 还会编译并运行 PDF 坐标、白板像素及麦克风回归。界面开发可通过 `--ui-snapshots /absolute/output/directory` 仅渲染应用自己的内容视图；测试房间请用 `-InkBridgeRoomCode QA2026`，避免写入日常文档房间。

## 许可证

[GPL-3.0](LICENSE)。音频驱动衍生自 BlackHole；PDF.js、QR、WebSocket 测试库和 Node 保留各自许可证，见 [第三方说明](InkBridge/THIRD_PARTY_NOTICES.md)。Huawei SDK、HDC、个人证书及设备 Profile 不随公开源码分发。
