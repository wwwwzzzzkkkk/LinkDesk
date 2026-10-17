# LinkDesk 统一工作空间

2026-10-18 将 InkBridge 纳入 LinkDesk，产品版本 0.7.0。

## 整合范围

| 工作空间 | Mac | HarmonyOS |
| --- | --- | --- |
| 扩展屏幕 | 原 LinkDesk 虚拟显示、硬件编码、音频及麦克风 | 原 LinkDesk 原生解码与音频模块 |
| PDF 批注 | 原生 PDFKit、文字选择、搜索、标准 Ink 导出 | 原生笔输入、压感、防误触与 ArkWeb PDF 渲染 |
| 实时白板 | 无限画布、独立历史与视口 | 手写笔书写、手指平移、双指缩放 |
| 平板投屏 | H.264 原生接收窗口 | 系统录屏授权、硬件编码与后台任务 |
| 华为笔记往返 | 发送 PDF 与接收批注副本 | 优先打开华为笔记，分享回 LinkDesk |

Mac 只有一个可执行文件和一个应用进程。原 Objective-C 显示引擎作为 `LinkDeskCore` 直接链接进 SwiftUI 应用；没有启动另一个 InkBridge.app 或独立显示助手。Node 中继作为内部子进程随应用启停，运行时及许可证随包提供，无需用户安装 Node。

鸿蒙只有一个 `EntryAbility` 和一个 `com.zhekuan.linkdesk` 包，同时编译 `liblinkdesk.so`（副屏接收）与 `libscreenmirror.so`（平板投屏）。首页、手写工作区和副屏接收器统一组织。离开手写工作区进入副屏时停止录屏、后台任务、网页轮询和笔输入；离开副屏时关闭麦克风、解码器与计时器。在首页保留手写桥，以处理从华为笔记分享回来的 PDF；外部分享及实况窗操作会导航到手写工作区。

## 设计约定

- Mac 使用原生侧栏，平板使用适合触控的工作台；四个功能采用相同名称、顺序、图标语义。
- 主色 `#4F8FF7`，连接及创作辅色 `#58D3B7`；主页采用低饱和蓝绿渐变，正文卡片留足空间。
- Mac 和平板共用浅色／深色设计语言。两端可选择“跟随系统／浅色／深色”；自动模式由 Mac 的系统外观决定，并同步到平板。主页、配对页、设置、书写工具栏、二级菜单和系统栏同步变化，PDF 纸张与已有笔迹颜色保持原样。
- 外观通过独立的 `/api/appearance` 同步，按版本拒绝过期写入、限制请求大小并原子保存到 `Application Support/InkBridge/appearance.json`；切换文档或房间不改变外观。首次 USB 连接无需先进入 PDF 房间就可以同步主题；Wi-Fi 使用已配对的 Mac 地址。断线保留最后的外观，恢复连接后继续同步。
- 统一保留 LinkDesk 的既有图标；PDF、白板工具仍遵守原来的笔／手指分工与收起动画。
- Mac 文档视图在切换设备和设置页时保持挂载，保留撤销、视口和远端输入。
- PDF 空白状态提供明确的打开入口。窄窗口标题省略，卡片和设置页可滚动；平板窄屏改为单列。
- 音频和麦克风状态必须用文字表达；不只依靠颜色。麦克风每次会话默认关闭，应用退后台立即停止拾音。

## 兼容与数据

- Mac bundle ID 保留 `com.zhekuan.linkdesk.mac`，使用原安装器校验固定签名；鸿蒙保留 `com.zhekuan.linkdesk`。更新不能绕过签名检查或卸载旧平板包。
- 内部沿用 InkBridge 协议 v2、协议构建号 1.6.10、3210/3211 端口与 `_inkbridge._tcp` 服务类型，便于旧客户端过渡。产品界面和安装包版本为 LinkDesk 0.7.0。
- 同一台 Mac 上，第一次启动复制旧 `local.zhekuan.bijiqiao` 偏好中缺失的 InkBridge 字段；已有 LinkDesk 偏好优先。中继保留原 `Application Support/InkBridge` 存储路径，不改写 PDF 原件。
- MacBook 到 Mac mini 的历史文档不会跨机器自动搬迁。旧 InkBridge 的鸿蒙沙箱也不会自动移入 LinkDesk；鸿蒙包身份隔离，需用户主动导出需要保留的文件。
- 不同时运行同一台 Mac 上的旧 InkBridge 与新 LinkDesk，避免争用 3210/3211。PDF 和白板可以 Wi-Fi／USB 切换；扩展屏幕与视频投屏使用 USB。
- PDF.js 已从 6.1.200 升至 6.4.299，并同步更新网页主包、worker 和许可证，处理 [上游安全公告](https://github.com/advisories/GHSA-hq66-cqwq-w95j) 中的已知问题。

## 来源与许可证

- LinkDesk 基线：`8f4e9a71c602cb6bba3d24b0b1f6ac98c3f014e0`。
- InkBridge 来源：[wwwwzzzzkkkk/InkBridge](https://github.com/wwwwzzzzkkkk/InkBridge)，快照 `f3851a446127febda27a6b4033bf9a5699356dd6`，内部版本 1.6.10。
- 导入实现位于 `InkBridge/`，鸿蒙实现合入现有 `HarmonyOS/`。`UPSTREAM.md` 和 `UPSTREAM-HANDOFF.md` 为历史参考，当前构建以本仓库 README 为准。
- 保留第三方版权与许可证，见 `InkBridge/THIRD_PARTY_NOTICES.md`。正式源码不包含 Huawei SDK 工具、证书、设备 Profile、签名密码、用户文档或依赖缓存。

## 验证边界

已在 Mac mini 通过统一应用编译、固定签名校验、原身份安装和普通 LaunchServices 启动；在独立测试房间加载 PDF 并检查工作台、明暗外观、窄窗口、扩展屏设置、PDF、白板与投屏界面。协议回归 37/37、PDF 坐标旋转往返、白板实时笔迹／历史像素回归、麦克风缓冲测试通过。鸿蒙 ArkTS 和两个原生 C++ 模块编译、未签名 HAP 打包通过。

2026-10-18 已在 DevEco 更新原应用的过期签名，并成功构建、覆盖安装和启动鸿蒙统一版。当前调试叶证书到期时间为 2026-11-01 04:00:30（新加坡时间），签名材料仅保留在 MacBook 本机。统一首页已检查，USB 实机确认平板选浅色同步到 Mac、Mac 选深色同步到平板，并恢复“跟随系统”。按用户要求，不再扩展视频和外设联调；扩展屏幕与投屏的实际视频链路未在本轮复测。LiveView 仍需要华为平台权益；此合并不会自动取得权益。实体手写笔和双指手势需要用户验收，不以自动化点击代替。
