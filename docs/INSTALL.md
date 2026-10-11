# 安装与卸载

MacBook 原版保留在 `legacy/macbook` 分支与 `macbook-v0.5.2` 标签。原目录与应用不作修改。新版主分支的预编译包适用于 Apple Silicon；不宣称已验证所有 MacBook 型号。

Homebrew Cask 下载固定版本及 SHA-256 校验的发行包，再调用签名保护安装脚本，不直接覆盖已安装应用。旧应用备份位于 `~/Library/Application Support/LinkDesk/Backups`。音频插件另行请求管理员授权安装。

卸载 Homebrew 应用：`brew uninstall --cask linkdesk`。手动安装可退出应用后从“应用程序”移到废纸篓。插件保留，避免卸载应用时意外中断音频。

要删除插件，请先将声音输入输出切回 Mac 或其他设备，结束通话，再删除以下三个目录（Finder 会请求管理员授权），然后重启 Mac：

- `/Library/Audio/Plug-Ins/HAL/LinkDeskTablet.driver`
- `/Library/Audio/Plug-Ins/HAL/LinkDeskMacVolume.driver`
- `/Library/Audio/Plug-Ins/HAL/LinkDeskMicrophone.driver`

不要删除其他 Core Audio 插件。旧插件备份位于 `/Library/Audio/Plug-Ins/LinkDesk-Backups`。

发行证书是固定本地开发证书，尚未公证。没有移除 Gatekeeper 或批量重置录屏权限的安装步骤。
