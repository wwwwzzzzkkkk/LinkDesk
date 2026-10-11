# LinkDesk · MacBook 原版 0.5.2

2026-09-09 本地源码快照，保留扩展桌面和平板扬声器功能。未加入 Mac mini 版平板麦克风回传。

此分支仅归档，不自动升级到 main。原有应用和本机签名均未改动。签名密钥、调试 provisioning、历史日志和二进制工具不公开。

Mac 构建：安装 Xcode Command Line Tools 后，设置自己的固定签名：

```sh
LINKDESK_SIGN_IDENTITY="你的代码签名证书" bash scripts/build-mac.sh
bash scripts/install-mac.sh ../LinkDesk.app
```

USB 工具需要安装 DevEco Studio。HarmonyOS 请在 DevEco Studio 中配置自己的签名后构建。

录屏授权依赖签名身份；请保留原 MacBook 证书，使用安装脚本，不手动覆盖已授权应用。Mac mini 新版见 main 分支。
