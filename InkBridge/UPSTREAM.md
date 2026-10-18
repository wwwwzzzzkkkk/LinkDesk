# 笔迹桥

当前稳定开发版为 **1.6.10（协议 v2）**。

本仓库为“笔迹桥”当前完整源码快照，包含 macOS 原生应用、HarmonyOS 平板应用（ArkTS/ArkUI 与 C++ 投屏模块）、本机中继、Web 渲染层和回归测试。此快照收录了最后一个本地提交之后的全部产品改动；GitHub 上传日期为 2026-10-18，未变更产品版本号。

核心能力包括 PDF 双端同步、无限白板、USB/Wi-Fi 自动切换、平板全局投屏、PDF 直达华为笔记与批注文件回传。实况窗胶囊代码已接入，仍需华为 LiveView 调测或正式权益。

仓库不包含证书、私钥、签名密码、设备 Profile、本机 SDK 路径、依赖缓存、用户 PDF 和运行数据。鸿蒙工程使用空的签名配置，安装真机前需要在 DevEco Studio 中配置自己的调试签名。

目录说明：

- `MacPDFAnnotator/`：macOS SwiftUI/AppKit/PDFKit 应用与 H.264 投屏接收。
- `HarmonyPad/`：鸿蒙平板 ArkUI/ArkTS 应用、华为笔记互通、LiveView 控制及 C++ 录屏编码。
- `local-server.mjs`、`public/`：本地中继、协议和 PDF/白板渲染。
- `scripts/`、`tests/`：构建安装脚本与协议回归。
- `HANDOFF.md`、`交付文档/`：开发交接及设计决策；其中绝对路径和旧测试记录属于原开发环境。

直接打开 Mac 桌面的“笔迹桥”，即可在“PDF 批注”和“实时白板”之间切换。MatePad 端安装原生“笔迹桥”后，可选择 Wi‑Fi 或 USB 有线连接；两端使用相同的六位房间号。

## 第五阶段能力

- Mac、MatePad、网页和本机中继统一使用协议 v2。
- 每个客户端具有稳定 ID、递增序号和消息确认，可过滤重复、过期及回环消息。
- 断线重连后通过完整快照恢复模式、PDF、视口和笔迹。
- PDF 使用文档 ID、版本号及 SHA‑256 校验；Mac 更换 PDF 后，平板自动下载、校验、热切换并返回加载完成状态。
- PDF 笔迹只应用于对应文档版本，避免旧文档的滚动或笔迹混入新文档。
- 保留 PDF 批注、实时白板、压感、悬停光标、防误触、手指平移、双指缩放及 Wi‑Fi/USB 切换。
- 平板单指滑动具有惯性阻尼；拖动和惯性过程以最新视口实时同步到 Mac，Mac 端滑动也持续同步到平板。
- PDF 使用事务 ID、稳定内容哈希和原子提交；校验、下载或渲染失败时，两端继续保留上一份有效文档。
- Mac 显示 PDF 传输、校验和打开进度，支持取消未提交传输及失败后重新加载。
- 快速连续选择 PDF 时只有最后一次事务生效；同一 PDF 重开恢复上次视口，新 PDF 默认回到第一页并适合窗口。
- 视口统一为页面索引、页面归一化中心锚点、缩放、可视区域尺寸、来源与递增序号；跨页时两端选择同一个视觉中心页。
- 滚动和缩放使用短时视口控制权，另一端只应用渲染而不反向争抢；中继拒绝旧文档和非当前控制者的视口更新。
- 平板捏合围绕双指中心预览，手势结束后离屏重绘并原子替换；高频远端视口只保留最新状态，旧 Canvas 会主动释放。
- Mac 与平板统一使用 CropBox、页面旋转、相对页面尺寸和 18 pt 页面间距，旋转页笔迹仍使用正确的页面坐标。
- ArkTS 原生层按 `SourceTool.Pen` 接收压感、倾角、时间戳、历史采样和采样序号；触控笔只书写，手指继续负责平移和双指缩放。
- 原生采样按显示帧合并，每个网络包最多 40 点；重复点会过滤，Mac 端以轻量曲线平滑显示并保留原始页面坐标。
- 每条笔划具有独立 `strokeSequence`，未确认的完整笔划在重连快照后自动重放；中继按客户端、`strokeId` 和序号过滤重复。
- 悬停由一个显示层负责，平板、PDF 和白板统一显示无中心小点的蓝色笔尖环；Mac 工具栏同步显示当前颜色、粗细或橡皮擦状态。
- 重压橡皮擦继续使用 0.90 高阈值并在整条笔划内锁定，擦除范围仍可从平板工具栏调整。
- 每次书写、整次橡皮擦和清空均作为一个原子历史操作；Mac 与平板共享统一操作序号和历史游标。
- 两端均可撤销、重做书写、擦除和清空；连续 100 次撤销/重做、重复消息和断线重连由协议回归测试覆盖。
- 完整笔划结束后，PDF、操作日志、历史游标和视口立即原子保存到 Mac 的 Application Support；中断中的半条笔划不会进入恢复记录。
- 本机中继或应用重启后自动恢复最后一份 PDF 和最后完整笔划；按 PDF 内容哈希隔离项目，重开同一文件恢复对应批注。
- Mac 提供最近文档入口和恢复状态；“另存为 PDF”默认创建副本，不修改原文件。
- 导出保留原 PDF 页面、既有注释、MediaBox/CropBox、旋转和混合页面尺寸，并将压感笔迹写为标准 PDF Ink 注释，供 Preview 与 Acrobat 读取。
- Mac PDF 笔迹预览严格裁剪在文档视口内，不再越过状态栏或工具栏；触控板支持带惯性的双指横向/纵向滚动，以及围绕手势焦点的双指捏合缩放，并持续同步给平板。
- Mac 与平板的 PDF 视口同步由 30 Hz 提升到 60 Hz；Mac 纯滚动跳过重复 PDFKit 布局，平板按显示帧合并远端视口，降低拖动延迟并保持最终位置权威同步。
- Mac 与平板的视口链路最高提升到 120 Hz；平板双指捏合会在手指按住期间持续发送预览视口，两端对远端中间缩放帧采用轻量显示路径，并只在手势结束帧执行一次高清 PDF 布局稳定。
- Mac 端提供“自动 / Wi‑Fi / USB”连接选择并持续发现 HDC 设备；自动模式优先使用已就绪的 USB 反向通道，拔线后平板自动回退 Wi‑Fi，重新插线后再无缝切回 USB。切换会等待当前笔划结束，并通过完整快照恢复 PDF、视口和笔迹。

## 开发与构建

常用检查：

```bash
npm ci
npm run test:protocol
swift build
```

需要 Node.js 22.13+，macOS 应用需要 macOS 14+ 及 Swift 6+；Liquid Glass 效果依赖支持的系统版本。鸿蒙使用 DevEco Studio 与 HMS/OpenHarmony SDK，兼容目标为 HarmonyOS 6.1.0（API 23），原开发验证使用 API 24 SDK。

单独启动本机中继：

```bash
npm run local
```

默认端口为 3210；USB 视频使用 3211。Mac 打包后会携带中继源码与网页资源；运行时需要本机 Node.js。

鸿蒙正式源码位于 `HarmonyPad`，脚本会同步到纯英文路径后构建：

```bash
npm run harmony:sync
npm run harmony:wireless
npm run harmony:build
npm run harmony:install
```

首次使用 `harmony:wireless` 时保持一台 USB 平板连接，脚本会读取其 Wi-Fi 地址并开启 HDC TCP 调试。之后 `harmony:install` 会优先选择唯一的无线 TCP 平板，找不到无线目标时再回退 USB；不会复制或输出证书、私钥及密码。若同时连接多台无线设备，可通过 `INKBRIDGE_HDC_TARGET=IP:端口` 明确指定。

构建脚本会根据仓库位置定位 `HarmonyPad`，默认 ASCII 构建镜像为 `$HOME/DevEcoStudioProjects/InkBridgeHarmony`，可用 `INKBRIDGE_DEVECO_PROJECT` 覆盖。镜像中已有的本地签名配置会保留。不要将英文镜像中的签名配置覆盖到仓库。

### USB 高画质平板投屏

1. 使用 USB 连接并打开两端笔迹桥。
2. 在平板顶部点击“投屏”，或在 Mac 顶部工具栏点击“开始平板投屏”；只需任意一端操作，另一端会自动启动。
3. 首次使用或由 Mac 远程发起时，在平板的鸿蒙录屏授权框中点击“允许”。

当前原型使用 2400×1600（3:2）、60 fps、30 Mbps H.264 硬件编码，通过独立的 USB TCP 3211 端口发送到 Mac。笔迹、PDF、白板和控制仍使用 3210，视频不会进入原有 JSON 通道。

投屏启动后会申请鸿蒙 `audioRecording` 长时任务并显示系统常驻通知。按 Home、切换到桌面或其他应用后仍会持续全局投屏；返回笔迹桥点击“停止投屏”会同时释放录屏、USB 视频和长时任务。系统强制停止、彻底杀死进程或删除长时任务通知仍会按鸿蒙安全规则终止投屏。

### PDF 往返、华为笔记与实况窗

Mac 菜单 `文件 → 发送 PDF 到平板批注…` 会把 PDF 下载到平板，并优先显式打开系统“华为笔记” (`com.huawei.hmos.hinote / HiNotePcMainAbility`)。该能力使用华为笔记真机声明的 `viewData + file URI + com.adobe.pdf`，若目标 Ability 不可用才回退到系统 PDF 打开方式。

PDF 打开前，平板会通过官方 Live View Kit 创建“笔迹桥”实况窗。胶囊显示未投屏/投屏中；展开区包含动态“开始投屏/停止投屏”和“返回笔迹桥”服务按钮。投屏状态变化会更新胶囊，批注 PDF 成功回传 Mac 后结束实况窗。

Live View Kit 受华为平台权益控制。当前调试签名在未配置调测设备或未开通正式权益时，真机会返回 `1003500005`，此时 PDF 仍会正常进入华为笔记，但系统不会显示胶囊。调试设备需按[华为官方联调测试文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-joint-commission-test)使用 Push Token 加入 AppGallery Connect 调测名单；正式发布需按[实况窗权益开通文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-rights)提交场景方案并重新生成 Profile。

生成 Mac 桌面应用：

```bash
zsh MacPDFAnnotator/make-app.sh /Users/zhekuan/Desktop/笔迹桥.app
```

## 默认回归测试

PDF 显示、跨页滚动、缩放和批注同步默认使用：

`/Users/zhekuan/Desktop/博士计划/论文阅读/Economic impact of biofouling on a naval surface ship.pdf`

## 版本回退

- 第一阶段之前的基线：`inkbridge-v1.0.0-baseline`
- 第一阶段完成版：`inkbridge-v1.1.0-phase1`
- 实时惯性滑动版：`inkbridge-v1.1.1-inertial-scroll`
- Mac 触控板双向同步修复版：`inkbridge-v1.1.2-mac-scroll-sync`
- 跨页滚动防跳顶修复版：`inkbridge-v1.1.3-page-boundary-sync`
- 第二阶段 PDF 文档生命周期：`inkbridge-v1.2.0-phase2-document-lifecycle`
- 第三阶段统一视口与坐标：`inkbridge-v1.3.0-phase3-viewport-coordinate-sync`
- 第四阶段原生笔与防误触：`inkbridge-v1.4.0-phase4-native-pen`
- 第五阶段持久化、历史与可靠导出：`inkbridge-v1.5.0-phase5-persistence-export`
- 平板工具与 Mac 界面优化：`inkbridge-v1.6.0-ui-pressure-eraser`
- PDF 加载显存与闪退修复：`inkbridge-v1.6.1-pdf-memory-fix`
- 固定小尺寸悬停光标：`inkbridge-v1.6.2-fixed-hover-cursor`
- 平板方案 A 工具栏与整笔工具锁定：`inkbridge-v1.6.3-tablet-tool-menu-stroke-lock`
- Mac 笔迹裁剪与触控板手势：`inkbridge-v1.6.4-mac-clip-trackpad-gestures`
- Mac/平板 60 Hz 视口同步：`inkbridge-v1.6.5-viewport-60hz`
- Mac/平板 120 Hz 连续同步与自动连接切换：`inkbridge-v1.6.6-live-sync-auto-transport`
- 平板液态高光玻璃 UI 与全产品版本统一：`inkbridge-v1.6.7-liquid-glass-ui`

查看旧版本源码时可基于标签新建分支，避免覆盖当前修改：

```bash
git switch -c codex/rollback-v1.0.0 inkbridge-v1.0.0-baseline
```
