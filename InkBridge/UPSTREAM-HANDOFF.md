# 笔迹桥项目交接文档

> 更新时间：2026-08-20（Asia/Singapore）  
> 工作区：`/Users/zhekuan/Documents/触控板`  
> 当前分支：`codex/phase1-protocol-v2`  
> 当前 HEAD：`d632986 feat(harmony): apply liquid glass UI v1.6.7`  
> 当前产品版本：`1.6.10`，协议版本：`2`  
> 注意：HEAD 之后存在大量尚未提交的有效产品改动，不能根据 HEAD 判断当前功能状态。

## 1. 给完全没有上下文的新会话

这是“笔迹桥”项目：让 Huawei MatePad Pro 13.2（HarmonyOS 6）作为 Mac 的 PDF 阅读/批注终端与实时白板。系统由四部分组成：

1. macOS 原生 SwiftUI/AppKit/PDFKit 应用。
2. Mac 本机 Node.js 中继服务。
3. HarmonyOS 原生 ArkUI 外壳，内部使用 ArkWeb，并由原生层接管触控笔输入。
4. Web 白板/PDF 渲染层和共享协议。

当前最新工作是“无限白板”：白板已升级为世界坐标画布，纸张可以向任意方向无边界移动，缩放范围为 `25%–800%`。平板使用单指平移、双指围绕手势焦点缩放；触控笔继续只负责书写/擦除。Mac 支持鼠标拖动、触控板滚动和捏合，并同步同一个白板视口。

本轮继续补齐了白板历史与持久化：Mac 和平板白板均可撤销/重做，clear 是可撤销历史操作，快照带独立白板游标；纯白板即使没有 PDF，也会在中继进程退出/重启后从独立 room 文件恢复笔迹、clear、历史游标和视口，且不会写进 PDF 哈希 project。

本轮代码已经通过协议测试、Swift 编译、HarmonyOS 类型检查/签名构建，并覆盖安装到真机。Mac 桌面应用也已重新生成并启动。不过，真实双指手势不能用当前 HDC 自动化可靠模拟，所以仍需要用户本人在平板上完成最终手势验收。

新会话首先应阅读本文件，然后检查工作树和设备状态。不要重新设计已有功能，不要把无限白板改成超大固定位图，也不要继续此前“把平板模拟成 Mac 触控板”的探索；该方向已经停止，当前产品仍是 PDF 批注和实时白板。

## 2. 任务目标和不可破坏的交互约定

### 2.1 产品目标

- Mac 打开 PDF 后，平板自动显示同一份 PDF。
- 任意一端滚动或缩放 PDF，另一端实时同步。
- 平板笔迹实时显示在 Mac，并固定在 PDF 页面/文档坐标中。
- PDF 文字在 Mac 上保持可选择、复制和搜索。
- 支持实时白板，Mac 和平板可双向切换 PDF/白板模式。
- 白板为无限世界坐标：纸张位置不设边界，缩放范围 `0.25–8.0`。
- 支持 Wi-Fi 和 USB，自动模式优先 USB，断开后回退 Wi-Fi。
- 连接或传输切换不能破坏当前笔划、视口、模式和历史。
- UI 在 Mac 和 HarmonyOS 上保持同一套蓝绿液态玻璃视觉语言，同时遵守各平台原生交互。

### 2.2 输入规则

- 必须使用 HarmonyOS `SourceTool.Pen` 区分触控笔，不能用压力猜测输入源。
- 触控笔：书写、荧光笔或擦除。
- 单指：平移 PDF 或白板。
- 双指：围绕双指中心缩放并允许同步平移。
- 捏合结束只剩一指时，要从当前点重新建立平移基准，不能跳动。
- 手掌和手指不能在手写笔模式下落笔。
- 重按临时橡皮只允许在一笔开始时判断；落笔后工具整笔锁定，不能中途反复切换。
- 重按橡皮结束后恢复此前画笔；高压力阈值约 `0.90`。
- 悬停光标是固定小尺寸蓝色空心环，无中心蓝点；退出、抬笔、断连或切换模式后隐藏。
- 荧光笔支持粗细和透明度，停顿 `2 秒` 后拉直；拉直不能改变用户设置的透明度。

### 2.3 无限白板坐标约定

- 新笔迹使用 `coordinateSpace: "whiteboard-world-v1"`。
- `RelayPoint.x/y` 在该坐标空间下是可正可负的世界坐标，不再限制为 `0...1`。
- 白板视口为独立状态：`centerX`、`centerY`、`zoom`、`viewportWidth`、`viewportHeight`、`interactionId`、`interactionPhase`。
- `centerX/centerY` 不设产品边界；协议只保留极宽的数值安全限制。
- `zoom` 当前必须统一限制在 `0.25...8.0`，即 `25%–800%`。
- 世界坐标和屏幕坐标转换以 `screenToWorld` / `worldToScreen` 为唯一入口。
- 旧白板历史没有 `coordinateSpace`，仍按旧 `canvasAspect + 0...1` 归一化坐标映射到默认世界画布，不能让旧笔迹消失。
- PDF 的 `viewport` 和白板的 `whiteboardViewport` 必须完全独立，控制权也分别使用 `viewportControl` 和 `whiteboardViewportControl`。

## 3. 项目结构和当前运行环境

### 3.1 HarmonyOS

- 正式源码：`/Users/zhekuan/Documents/触控板/HarmonyPad`
- ASCII 英文构建镜像：`/Users/zhekuan/DevEcoStudioProjects/InkBridgeHarmony`
- 主页面：`HarmonyPad/entry/src/main/ets/pages/Index.ets`
- Ability：`HarmonyPad/entry/src/main/ets/entryability/EntryAbility.ets`
- 应用配置：`HarmonyPad/AppScope/app.json5`
- 构建配置：`HarmonyPad/build-profile.json5`
- Bundle：`com.zhekuan.inkbridge`
- Ability：`EntryAbility`
- 当前版本：`1.6.10 / 1061000`
- compatible/target SDK：HarmonyOS `6.1.0(23)`
- 当前编译环境：DevEco Studio 6.1.1，API 24 SDK
- 当前真机：`3ZL0224C26000762`
- 交接时设备状态：USB Connected

正式源码的 `Index.ets` 与英文构建镜像在最后检查时一致，`cmp` 返回 `0`。长期修改必须在正式源码进行，再用现有脚本同步，不能直接把英文镜像当唯一源码。

### 3.2 macOS

- Swift Package：`Package.swift`
- 主界面：`MacPDFAnnotator/Sources/ContentView.swift`
- App 菜单和生命周期：`MacPDFAnnotator/Sources/MacPDFAnnotatorApp.swift`
- 工作区状态：`MacPDFAnnotator/Sources/PDFWorkspace.swift`
- PDFKit 视图：`MacPDFAnnotator/Sources/PDFCanvasView.swift`
- 白板视图：`MacPDFAnnotator/Sources/WhiteboardCanvasView.swift`
- 协议模型：`MacPDFAnnotator/Sources/RelayMessage.swift`
- WebSocket 客户端：`MacPDFAnnotator/Sources/RelayClient.swift`
- USB 自动切换：`MacPDFAnnotator/Sources/USBRelayManager.swift`
- 本机中继启动：`MacPDFAnnotator/Sources/LocalRelayLauncher.swift`
- 打包脚本：`MacPDFAnnotator/make-app.sh`
- 当前桌面应用：`/Users/zhekuan/Desktop/笔迹桥.app`

交接时 Mac 应用及其本机中继均已按最新工作区重新打包、严格签名验证并运行；界面停留在实时白板。`http://127.0.0.1:3210/config` 最后返回：

```json
{
  "relayVersion": 10,
  "appVersion": "1.6.10",
  "protocolVersion": 2,
  "urls": ["http://192.168.68.67:3210"]
}
```

IP 会随网络环境变化，不能写死。

### 3.3 中继与网页层

- 本机中继：`local-server.mjs`
- 共享协议：`public/inkbridge-protocol.js`
- 白板：`public/whiteboard.js`
- 白板样式：`public/whiteboard.css`
- PDF 平板端：`public/pdfpad.js`
- HTML 外壳：`public/whiteboard.html`
- 默认端口：`3210`

两端使用同一个六位房间号。协议 v2 包含客户端稳定 ID、sequence/messageId、ACK、revision、全量快照、文档身份、历史操作和视口控制租约。

## 4. 已完成内容

### 4.1 跨端产品与 UI

- Mac 和平板已经整合 PDF 批注与实时白板两种模式。
- 顶部工具栏采用蓝绿液态玻璃风格，Mac 使用原生 Material/AppKit，HarmonyOS 使用原生模糊材质和高光边框。
- PDF/白板模式标题已在状态栏上下居中。
- 顶部工具栏可收起成圆形按钮，并有卷帘式收拢/展开动画。
- 平板一级工具栏的画笔、荧光笔、橡皮只显示图标，不显示冗余中文。
- 平板二级菜单已加入动画。
- 顶部状态栏和底部白条安全区已经按沉浸式布局处理。
- 工具栏悬浮在内容上，PDF/白板内容保持主视觉。
- Mac 的打开 PDF、最近文件、导出、搜索等操作已放入系统菜单体系。
- 文件标题采用居中和截断策略，Mac/平板均避免遮挡固定操作。

### 4.2 PDF 阅读、文字选择和搜索

- Mac 使用 PDFKit 原生文档视图，保留文字选择、复制、上下文菜单和辅助功能。
- 支持 `⌘F` 搜索 PDF 文字、显示匹配数量并跳转上一个/下一个结果。
- 扫描图片 PDF 没有文字层时仍需要 OCR，这不是当前搜索实现的 bug。
- Mac 打开/更换 PDF 后，平板可以自动下载、校验并热切换。
- PDF 使用文档 ID、递增版本、SHA-256、事务 ID 和文件大小保护，最大 250 MB。
- 同一 PDF 可恢复视口和批注；快速连续选择时只接受最后一个事务。
- PDF 视口同步支持边界滚动、手势焦点缩放、Mac 触控板滚动/捏合和 120 Hz 上限的帧合并。
- 批注存储在 PDF 页面/文档坐标，不随缩放、滚动或窗口变化漂移。
- 导出使用标准 PDF Ink 注释，保留页面框、旋转、混合尺寸和原有注释。

### 4.3 触控笔、橡皮和荧光笔

- ArkTS 原生层使用 `SourceTool.Pen`，保留压力、倾角、时间戳、历史采样和 sampleIndex。
- 原生样本按帧合并，每个网络消息最多 40 点，并做重复样本过滤。
- 已修复画笔模式下“重按橡皮开关开启但无法激活”的逻辑；开关在橡皮二级菜单，画笔模式下也生效。
- 重按橡皮在落笔初期收集约 42 ms 压力窗口，再整笔锁定工具。
- 手动橡皮和临时重压橡皮状态分离。
- 橡皮范围光标会随当前缩放显示正确大小。
- 荧光笔支持粗细、透明度和 2 秒停顿拉直。
- 荧光笔移动时使用独立临时 Canvas，避免每个采样点重放全部历史，已经针对卡顿做过优化。
- 2026-08-20 继续修复长荧光笔高延迟：此前临时 Canvas 虽不重放历史，却仍在每个 `stroke:move` 批次清空整层并从起点重画全部当前笔划，长笔划会形成平方级重复工作。PDF 与白板现在对单条活动荧光笔使用不透明临时遮罩和 Canvas 层级透明度，普通移动只增量补画最新线段；仅在 `stroke:replace` 拉直、视口/尺寸变化或多条并发荧光笔时完整重绘。抬笔后仍以原透明度一次性合成到正式笔迹层，接缝不会叠加变深。
- 2026-08-20 修复“界面写停顿 2 秒、实际超过 4 秒才拉直”：根因是原生层对每个移动事件都发起独立异步 `runJavaScript`，拉直命令可能排在大量旧移动任务之后。ArkTS 源码现使用串行、合并、带上限的笔输入桥，移动批次合并、直线端点只保留最新值；PDF/白板 Web 层同时使用本地 2000ms 计时器直接执行 `stroke:replace`，不再等待旧原生桥命令。拉直后后续移动只更新直线终点，抬笔保持最终点。
- `stroke:replace` 用于荧光笔拉直，透明度保持原值。

### 4.4 Wi-Fi、USB、扫码和自动切换

- 支持 Wi-Fi 与 USB 两种应用传输模式，协议与传输层解耦。
- Mac 提供自动 / Wi-Fi / USB 三种偏好。
- 自动模式发现 HDC 设备，USB 可用时优先 USB，拔线后回退 Wi-Fi，重插后再切回。
- 传输切换会等待当前笔划结束，再进行快照恢复，不能在半条笔迹中切换。
- 平板已加入原生扫码连接入口，扫描后识别房间/主机并进入自动传输选择。
- 更换 Wi-Fi 或国家/网络环境后不依赖旧 IP；局域网发现、当前地址和 USB 转发会重新建立。
- 当前交接时 USB 设备可见，Mac 中继通过当前新加坡局域网地址运行。

### 4.5 无限白板（本轮重点）

- Web 白板已从固定 `0...1` 画布升级为稳定世界坐标。
- 新笔迹带 `coordinateSpace: "whiteboard-world-v1"`。
- 旧归一化笔迹按 `canvasAspect` 映射到默认世界画布，保持可见。
- 平板单指平移视口，`centerX/centerY` 可以持续变为任意正负坐标。
- 平板双指围绕手势中心原子更新缩放和中心位置。
- 双指结束剩一指时重新建立平移基准，避免突跳。
- 当前缩放范围已按用户最后要求扩大到 `25%–800%`。
- 原生工具栏的放大/缩小按钮对白板生效。
- Mac 支持鼠标拖动、触控板滚动和捏合；菜单 `⌘+`、`⌘-`、`⌘0` 对白板分别执行放大、缩小、回到原点。
- Mac 和平板通过 `whiteboard:viewport` 同步同一白板视口。
- 中继为白板设置独立的最新状态与控制租约，避免与 PDF 视口相互覆盖。
- `session:snapshot` 包含最新 `whiteboardViewport`，网络断开或 USB/Wi-Fi 切换后可恢复。
- 白板点阵网格改为世界网格，随平移移动，并根据缩放自动选择分级间距。
- 网格使用独立 `whiteboard-grid-canvas`，不会被橡皮擦一起擦掉。
- 高亮临时层继续独立存在，缩放/平移时按当前世界变换重绘。
- Mac 白板使用透明图层内的 clear blend 擦除笔迹，擦除后仍能显示下面的世界网格。
- Mac 菜单撤销/重做会按当前 PDF/白板模式发送，白板模式不再误发 `mode: pdf`。
- Mac 和 Web 白板都按独立 `whiteboardHistoryCursor` 重放历史，clear 之前的内容不会在重连后错误重现；撤销 clear 会恢复清空前内容。
- 已修复 Mac 白板实时笔迹回归：`stroke:start/move` 阶段会额外绘制历史游标后的未结束操作，不再等 `stroke:end`；已经完成的 redo 操作和 redo 区 clear 仍保持隐藏。
- 平板白板工具栏现在复用原生撤销/重做按钮，清空提示明确说明可以撤销。
- 中继以 schema v2 room 文件独立保存纯白板 operations、historyCursor、whiteboardViewport 和序列元数据；PDF project 仍只保存 PDF 状态。
- 旧 schema v1 PDF 房间仍可读取，白板恢复事件会重新验证并移除任何 PDF 文档字段。

### 4.6 本轮自动化和构建证据

- `node --check public/whiteboard.js`：成功。
- `npm run test:protocol`：26 项全部通过。
- 测试覆盖白板大范围正负中心、`0.25...8.0` 边界、非法 NaN/Infinity、世界坐标笔迹、白板 clear/undo/redo、角色独立游标、快照恢复，以及无 PDF 的纯白板跨中继进程重启恢复。
- Swift `swift build`：成功；只有本机 CommandLineTools 搜索路径 linker warning，没有编译错误。
- HarmonyOS ArkTS 类型检查：成功。
- HarmonyOS HAP 构建：成功。
- DevEco 调试签名：成功。
- 签名 HAP 路径：`/Users/zhekuan/DevEcoStudioProjects/InkBridgeHarmony/entry/build/default/outputs/default/entry-default-signed.hap`
- 真机 `3ZL0224C26000762` 通过 USB 覆盖安装：成功。
- Ability 启动：成功。
- Mac `/Users/zhekuan/Desktop/笔迹桥.app` 重新生成、严格签名验证并重启成功；bundle 内 `local-server.mjs` / `public/whiteboard.js` 与工作区一致。
- Mac 实际界面已切换到白板并截图检查，液态玻璃工具栏、模式标题、连接状态和世界网格均正常显示。
- 平板实际截图已检查，状态栏、安全区、底部工具栏、白板网格和连接状态均正常。
- Mac 实时笔迹回归修复后，新增 `WhiteboardHistoryVisibilityTests`：像素级确认未抬笔线段已经显示，并确认 completed redo stroke / redo clear 不会提前显示；测试成功。
- 修复后再次完成 `node --check`、协议测试 26/26、Swift 全量构建、App 严格签名、重新启动和真实窗口截图检查；运行中的中继仍为 `1.6.10 / protocol v2 / relay 10`。
- 2026-08-20 荧光笔增量渲染修复后，`node --check`、协议回归 28/28、`WhiteboardHistoryVisibilityTests`、Mac App 重打包、bundle 资源一致性和启动前严格签名均通过。真机 `3ZL0224C26000762` 通过 USB 重新启动 Ability，成功加载 PDF、恢复笔迹并显示已连接；当时仅修改 Mac 中继提供的 `public/pdfpad.js` / `public/whiteboard.js`，未重复安装 HAP。实体 M-Pencil 在 Wi-Fi 下的快速长荧光笔跟手感仍需用户本人最终验收。
- 2026-08-20 两秒拉直修复后，协议回归仍为 28/28、白板像素测试通过，Mac App 已重新打包并严格签名，真机重启后确认从运行中继加载的 PDF/白板脚本均包含本地 2000ms 计时器。原 DevEco 调试证书曾于 2026-08-15 过期；用户登录后已在 DevEco Project Structure → Signing Configs 启用自动签名并成功刷新。随后 ArkTS 类型检查、`PackageHap`、`SignHap`、覆盖安装和 Ability 启动全部成功，签名 HAP 为 `/Users/zhekuan/DevEcoStudioProjects/InkBridgeHarmony/entry/build/default/outputs/default/entry-default-signed.hap`，真机版本为 `1.6.10 / 1061000`。
- 安装后打开当前 18.4 MB 长荧光笔项目时，Mac 的 16 MiB WebSocket 帧上限触发重连。`RelayClient.maximumMessageSize` 已以有界方式提升到 32 MiB；Swift 构建和新增专项测试通过，Mac App 再次打包/严格签名后成功显示“已连接 · 协议 v2”和“已恢复上次完整笔划”，平板 PDF、工具栏和 USB 已连接状态正常。

### 4.7 macOS 方向 A 原生工具栏（2026-08-13）

- 用户已确认采用方向 A：标准 macOS 标题栏/工具栏，不再保留旧的深蓝自定义悬浮栏。
- 设计合同：`交付文档/inkbridge-macos-native-liquid-glass-design-contract.md`。
- `ContentView.swift` 现使用标准 `.toolbar`：左侧 PDF/白板分段选择，中部文档/白板标题与小号房间号，右侧连接菜单、PDF 搜索、收起操作。PDF 传输进度、取消和重试收纳在连接菜单，导出/恢复结果用底部紧凑状态胶囊反馈，避免丢失旧栏功能。
- `MacPDFAnnotatorApp.swift` 使用 `.windowToolbarStyle(.unified(showsTitle: false))`；隐藏的是重复的 App 窗口标题，标题栏、交通灯和原生窗口行为均保留。
- macOS 26+ 采用系统 Liquid Glass；14/15 回退到统一系统工具栏材质。搜索浮层在 26+ 使用 `.glassEffect`，旧系统使用 `.regularMaterial`。
- 工具栏收起/展开已在真实 App 验证：收起后保留标准标题栏与交通灯，左上角显示“桥”按钮并可恢复工具栏。
- 720×520 最小窗口和约 1066×768 常用窗口已检查，模式、标题/房间、Wi-Fi、搜索和收起操作无重叠或裁切。
- PDF 搜索已验证：`research` 共 9 项，上下条在 1/9 与 2/9 间正确切换，Escape 可关闭；白板模式搜索按钮禁用，PDF 模式启用。
- 协议测试更新为 28/28 通过；`WhiteboardHistoryVisibilityTests` 通过；Swift 构建、桌面 App 重打包、资源一致性与 ad-hoc 严格签名验证通过。
- 待人工补验：宽屏/全屏、非活动窗口、系统浅色外观、USB 实际切换、PDF 深色图像区域，以及 PDF 文字鼠标选择/复制和触控板捏合的真人输入。自动化期间 Mac 锁屏，未把这些状态误报为已完成。
- 用户随后指出原生标题栏呈实心或会透出窗口后方应用，不符合搜索栏的窗口内采样语义。最终实现隐藏系统 `NSToolbar` 背景，在全尺寸内容窗口内使用 SwiftUI `.glassEffect(.regular)` 绘制紧凑状态栏；PDF/白板真实铺到它背后，玻璃只采样当前文档，窗口本身保持不透明。
- 真实 App 已验证：PDF 正文滚动经过顶部时，状态栏内出现当前 PDF 文字的模糊/折射；切换白板后采样为白板内容，不再出现桌面或其他应用。720×520、收起/展开、协议 28/28、实时笔迹像素测试和严格签名均通过。
- 用户随后要求增强状态文字可读性，并让搜索栏从中间向下带轻弹簧展开。实现前已核对 Apple 官方 SwiftUI `spring(duration:bounce:)`、锚点缩放过渡和 `accessibilityReduceMotion` 文档。顶栏现加入深色 10% 黑/浅色 8% 白的极轻自适应色调，标题/房间号/连接状态使用更明确的语义主色与轻描边阴影；房间号为 10pt medium monospaced。搜索使用顶部中央锚点、0.68 起始缩放、-14pt 位移、0.34 秒/0.18 bounce 弹簧，减少动态效果时仅做 0.12 秒淡入淡出。
- 本轮真实 App 已检查 PDF 白纸正文和实时白板背景；PDF/白板仍被窗口内玻璃正确采样，状态文字可读。`⌘F`、`research` 1/9 和 Escape 关闭正常；Swift 构建、协议 28/28、`WhiteboardHistoryVisibilityTests`、重打包和严格签名通过，桌面 App 已重新启动。
- 用户继续要求状态栏更窄、玻璃更厚、搜索点击空白处自动收起。状态栏已从 52pt 收至 46pt；深色/浅色自适应色调增至 16%/14%，并加入 0.5pt 顶部高光、16% 底部分界和更明显的低位阴影，仍保持窗口内 PDF/白板采样。搜索使用 `NSEvent` 窗口本地观察判断搜索胶囊外点击，不使用透明全屏遮罩，事件仍传递给 PDFKit/白板。
- 真实 App 已验证搜索内部输入 `research` 保持展开并显示 1/9、点击 PDF 空白处自动收起、Escape 关闭正常。Swift 构建、协议 28/28、`WhiteboardHistoryVisibilityTests`、重打包和启动前严格签名通过，桌面 App 已重新启动。
- 2026-08-20 用户以 macOS Preview 截图为最新参考，明确要求状态栏不是“向上移动”，而是真正与交通灯合并。Mac 现改用原生 SwiftUI `.toolbar` / `NSToolbar`：交通灯、PDF/白板模式、中央标题/房间、连接、搜索和收起入口同处约 50pt unified titlebar。标题为 80% 语义主色、房间 60%、连接 78%，全部移除描边/发光阴影；窗口背景保持不透明的深灰系统材质，macOS 26 工具按钮使用原生 Liquid Glass，不会映出窗口后方应用。
- 搜索浮层继续从标题栏中央下方弹簧展开，但外部点击关闭改为搜索焦点丢失触发，避免原窗口级鼠标监听误判 native toolbar 点击。真实 App 已检查 720×520 PDF 与白板、工具栏收起/展开、`research` 1/9、点击 PDF 空白自动收起；独立临时 Swift 构建、桌面 App 重打包和启动前严格签名通过。
- 2026-08-23 用户报告 Mac 顶部状态栏按钮无法用鼠标点击。辅助功能动作能触发、真实坐标点击不能触发，定位为 unified window 仍带 `fullSizeContentView`，PDF 内容命中层覆盖原生 `NSToolbar`。`WindowLiquidGlassConfigurationView` 现显式 `window.styleMask.remove(.fullSizeContentView)`，并将 `window.isMovableByWindowBackground` 设为 `false`；窗口仍可通过原生标题栏拖动，但模式、连接、搜索、收起/展开按钮不再被背景拖动层截获。新增源码回归断言，真实 App 已验证 PDF/白板切换、搜索、Escape、收起与展开。
- 2026-08-23 用户要求保留动效，并让底部“已恢复上次完整笔划”像球一样展开、缩回消失。`MacStatusToastMorphModifier` 现在以横向 20%/纵向 72% 的近圆形为转场端点，0.38 秒轻弹簧展开/收回；普通状态 2.8 秒自动消失，失败状态 4.2 秒。实际恢复到包含 `stroke:*`/`clear` 的历史时会显示恢复提示，不再只依赖可能失真的 `restoreAvailable`。搜索继续使用 0.34 秒弹簧，点击文档滚动区失焦后自动反向收起；减少动态效果时两者均退化为短淡入淡出。
- 2026-08-23 用户反馈搜索点击空白仍经常不关闭。根因是 AppKit/PDFKit 点击不保证 SwiftUI `TextField` 失去 first responder；已改为搜索胶囊内的 `SearchOutsideClickMonitorView` 观察窗口本地左右键 `mouseDown`。监听延迟 0.25 秒启用，按搜索胶囊实际 bounds 外扩 6pt 判断，始终返回原事件给 PDFKit，并由 `dismantleNSView` 明确清理。初版读取 `NSApp.currentEvent.eventNumber` 会在 macOS 27 布局阶段抛异常并导致 App 崩溃，已依据 `.ips` 堆栈移除。最终真实 App 连续 6/6 次“打开搜索→点击文档区”均关闭；搜索内部 `FEM` 导航保持展开并从 1/22 到 2/22，Escape 正常。

## 5. 当前问题和待验证内容

### P0：真实双指和单指手势仍需用户本人验收

HDC 的 `uitest uiInput swipe` 在当前设备上会被应用识别为手写笔输入，曾生成一条测试线，不能把它当作单指平移证据。该测试线随后通过白板清空操作移除，当前白板已恢复为空白。

下一会话必须请用户在真机上实际验证：

1. 单指连续向四个方向拖动多个屏幕，确认没有边界停止。
2. 双指在偏离中心的位置缩放，确认焦点不跳回屏幕中心。
3. 分别到达约 25% 和 800%，确认不会继续越界或突然消失。
4. 捏合结束只剩一指时继续拖动，确认不突跳。
5. 触控笔落下只画线，不移动画布；手掌不会落笔。
6. 移动和缩放后旧笔迹位置稳定。
7. 在不同缩放下验证橡皮命中和范围光标。
8. 验证荧光笔透明度和 2 秒拉直仍正常。
9. 验证 Mac 与平板双向移动/缩放没有回弹和回环。

### P0：工作树尚未提交

- 当前 Git HEAD 仍是 1.6.7 的 `d632986`。
- 当前实际产品是 1.6.10，且无限白板也在尚未提交的工作树中。
- `HANDOFF.md` 自身当前是未跟踪文件。
- 不要 reset、checkout 或清理工作树，否则会丢失 1.6.8–1.6.10 和无限白板等大量有效工作。
- 不要直接 `git add .`，工作区还有许多用户无关目录。
- 是否拆分提交、升级为 1.6.11 并打标签，应在用户确认功能后再做。

### 已完成：纯白板独立磁盘持久化与 Mac 白板历史

- 纯白板在无 PDF 时也会保存 room 状态，并在中继进程重启后恢复 operations、historyCursor、whiteboardViewport 和历史序列。
- 白板状态与 PDF 哈希 project 分离；PDF project 不包含白板 operations。
- Mac、Web 白板和平板原生工具栏均支持白板 undo/redo；clear 是可撤销操作。
- Mac snapshot 重放只显示最后一个有效 clear 之后的笔迹，撤销 clear 时恢复更早笔迹。
- 已用端到端协议测试覆盖 clear → undo → snapshot，以及纯白板中继重启恢复。

### 已完成：Mac 白板笔迹实时显示回归

- 根因是 `WhiteboardCanvasView.draw()` 原先只绘制 `historyCursor` 之前的操作，而游标要等 `stroke:end` 才推进，所以 Mac 只能在抬笔后看到完整笔迹。
- 现在绘制集合为“游标前已提交操作 + 游标后尚未包含 `stroke:end` 的活动笔划”，与 Web 白板语义一致。
- 不能把所有游标后操作直接显示；这样会泄露已撤销、可 redo 的完整笔划和 clear。
- 相关文件：`MacPDFAnnotator/Sources/WhiteboardCanvasView.swift`、`MacPDFAnnotator/Sources/WhiteboardHistoryVisibility.swift`、`MacPDFAnnotator/Tests/WhiteboardHistoryVisibilityTests.swift`。
- 自动化已覆盖 `stroke:start/move` 后、`stroke:end` 前的像素渲染。仍需用户用真实触控笔确认跨设备连续书写的主观流畅性与网络时延。

### P1：高倍率性能与视觉需要实机回归

- 800% 下笔迹、荧光笔、橡皮和网格都会放大重绘，尚未在真机进行连续快速缩放压力测试。
- 需要快速往返缩放 20 次并观察掉帧、卡顿、内存和闪退。
- 如果需要优化，只能做视口裁剪、历史缓存或帧合并；不能改成超大固定 bitmap。

### P1：PDF 和连接功能需要一次短回归

无限白板改动触及共享协议、中继和 Mac RelayClient。虽然自动化测试全部通过，仍建议短测：

- PDF 更换和热加载。
- 两端 PDF 滚动/缩放及笔迹锚定。
- Mac 文字选择、复制和 `⌘F` 搜索。
- 悬停、重按橡皮、荧光笔。
- 自动/Wi-Fi/USB 拔插切换。
- 断线重连 snapshot。

### P2：版本管理还没有完成

- 所有当前产品位置统一显示 1.6.10：`VERSION`、npm、Web 协议、Swift、Info.plist、HarmonyOS。
- 无限白板属于 1.6.10 之后的新功能，但本轮没有升版本，避免在用户验收前扩大版本改动。
- 用户确认后建议统一升级为 `1.6.11`，再重建两端并创建清晰回退点。

## 6. 下一步计划

### 第一步：真机验收无限白板

按 P0 清单用真实手指和触控笔测试。重点不是只看画面会动，而是确认焦点稳定、剩余一指不跳、笔与手指路由正确、不同倍率下笔迹和橡皮锚定正确。

### 第二步：白板持久化与历史（已完成）

1. 中继已通过 schema v2 room 文件保存纯白板历史和视口。
2. 白板与 PDF project 已保持隔离，并兼容 schema v1 PDF 房间。
3. Mac / Web / HarmonyOS 白板 undo/redo 与 clear 重放已统一。
4. 已添加 clear/undo/redo、角色游标和中继进程重启测试。

### 第三步：高倍率性能回归

1. 25%、100%、400%、800% 各写一段笔迹。
2. 快速来回缩放 20 次。
3. 检查荧光笔临时层是否仍流畅。
4. 检查橡皮命中、范围光标和 Mac 清除混合模式。
5. 只在有测量证据时优化，继续按帧合并视口更新。

### 第四步：共享功能回归

测试 PDF 文档切换、文字选择/搜索、视口同步、压感橡皮、悬停、荧光笔、模式切换和 Wi-Fi/USB 自动切换。

### 第五步：版本与提交

用户验收后：

1. 将产品统一升级到 1.6.11。
2. 只暂存本项目相关文件，不要包含无关目录。
3. 最好将“此前 1.6.8–1.6.10 功能”和“无限白板”按可回退边界拆分提交，前提是能够安全辨认改动来源。
4. 重建、安装、启动并再次验证版本。
5. 创建明确的回退标签，并更新 README/HANDOFF。

## 7. 常用命令

### 7.1 查看状态

```bash
cd /Users/zhekuan/Documents/触控板
git -c core.fsmonitor=false status --short
git branch --show-current
git rev-parse --short HEAD
```

### 7.2 Web、协议和 Swift

```bash
node --check public/whiteboard.js
npm run test:protocol
swift build --scratch-path /private/tmp/InkBridgeBuild
```

### 7.3 HarmonyOS 设备、同步、构建和安装

```bash
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets -v
npm run harmony:sync
npm run harmony:build
INKBRIDGE_HDC_TARGET=3ZL0224C26000762 npm run harmony:install
```

设备 ID 每次都要重新查询；上面的 ID 只是交接时真机。

### 7.4 重建 Mac 应用

```bash
zsh MacPDFAnnotator/make-app.sh '/Users/zhekuan/Desktop/笔迹桥.app'
```

重建后必须正常退出旧 App，再重新打开，否则运行的仍可能是旧 bundle 和旧中继资源：

```bash
open '/Users/zhekuan/Desktop/笔迹桥.app'
curl http://127.0.0.1:3210/config
```

### 7.5 截取平板画面

当前系统的 `snapshot_display` 只接受 `.jpeg` 后缀：

```bash
hdc -t DEVICE shell snapshot_display -f /data/local/tmp/inkbridge.jpeg
hdc -t DEVICE file recv /data/local/tmp/inkbridge.jpeg /private/tmp/inkbridge.jpeg
```

## 8. 本轮无限白板相关文件

- `public/inkbridge-protocol.js`
  - 白板坐标空间常量。
  - `WHITEBOARD_MIN_ZOOM = 0.25`。
  - `WHITEBOARD_MAX_ZOOM = 8`。
  - `normalizeWhiteboardViewport()`。
  - `whiteboard:viewport` ACK 类型。

- `public/whiteboard.js`
  - 世界坐标变换。
  - 旧历史兼容。
  - 单指平移、双指焦点缩放和手势结束重基准。
  - 世界网格和独立网格 Canvas。
  - 新笔迹、悬停、荧光笔和橡皮的世界坐标。
  - 快照应用和白板视口发送。

- `public/whiteboard.css`
  - 关闭旧固定 DOM 点阵。
  - 独立世界网格层级。

- `local-server.mjs`
  - `whiteboardViewport` 与独立控制租约。
  - 世界坐标笔迹验证。
  - snapshot 和广播。

- `MacPDFAnnotator/Sources/RelayMessage.swift`
  - `WhiteboardViewport`、`centerX/centerY`、`coordinateSpace`。

- `MacPDFAnnotator/Sources/RelayClient.swift`
  - 白板视口收发、snapshot 回调和能力声明。

- `MacPDFAnnotator/Sources/PDFWorkspace.swift`
  - 白板历史/视口挂接和待应用状态。
  - 白板缩放命令路由。

- `MacPDFAnnotator/Sources/WhiteboardCanvasView.swift`
  - 世界坐标绘制、网格、鼠标/触控板手势、缩放范围和远端视口应用。

- `MacPDFAnnotator/Sources/MacPDFAnnotatorApp.swift`
  - 菜单缩放命令对白板可用。

- `tests/inkbridge-protocol-v2.test.mjs`
  - 无限中心、25%–800%、非法数值、世界坐标笔迹和 snapshot 测试。

## 9. 踩过的坑和硬性边界

### 9.1 不能用超大位图模拟无限画布

无限白板必须保存世界坐标和视口变换，只按当前屏幕重绘。创建超大 Canvas 会导致内存爆炸、缩放模糊和坐标精度问题。

### 9.2 旧白板历史仍是 0...1

协议验证不能简单放开所有点，也不能把所有旧点当世界坐标。必须以 `coordinateSpace` 分支解释：新白板世界坐标可正负，旧白板和 PDF 仍使用原坐标规则。

### 9.3 白板和 PDF 视口不能共用一个字段或控制锁

共用会导致切换模式后互相覆盖、快照恢复错误和两端回弹。必须保留独立的 `whiteboardViewportControl`。

### 9.4 捏合必须原子保持焦点

先改 zoom 再改 center 会出现“跳一下再回来”。正确做法是先求旧视口下的 `worldFocus`，再一次性计算新 zoom 与 center。

### 9.5 双指变单指必须重建基准

不能复用旧 pinch distance 或旧单指位置，否则松开一根手指时画布会突然跳动。

### 9.6 网格不能画在笔迹 Canvas 里

橡皮使用 `destination-out` / clear blend。若网格和笔迹在同一个 Canvas，橡皮会把网格也擦掉。Web 已使用独立 grid Canvas；Mac 在透明笔迹层下单独画网格。

### 9.7 HDC UI 自动化不能证明手指手势

本机 `uitest uiInput swipe` 被识别为手写笔，曾误画测试线。不要再用该命令声称单指平移或双指缩放已验证；必须真人触控，或找到能够明确注入 `SourceTool.Finger` 和多指 ID 的官方接口。

### 9.8 ArkWeb Pointer Events 不能替代原生笔输入

触控笔接触、悬停、压力和历史样本必须继续由 ArkTS 原生层处理。手指事件留给 WebView 的 pan/pinch。不要移除 `handlePenTouch()` 中的 `SourceTool.Pen` 判断。

### 9.9 高频消息和渲染必须合并

- 笔样本按帧和最多 40 点分批。
- 白板/PDF 视口中间帧按 requestAnimationFrame 合并。
- 手势结束帧必须立即发送。
- 荧光笔移动只画临时层，不要每点重放全部历史。

### 9.10 构建路径和签名安全

- 正式 HarmonyOS 源码路径含中文，hvigor 可能拒绝，构建应使用 ASCII 镜像。
- 英文构建镜像可能含 DevEco 自动签名配置。
- 严禁读取、打印、复制、提交或重建证书、私钥、密码、token 和 `.ohos/config`。
- 工作区 `build-profile.json5` 不能被英文镜像中的签名内容覆盖。
- 未签名 HAP 只能证明编译，不能声称可安装。
- 不卸载 App、不清数据；覆盖安装使用现有脚本的 `install -r`。

### 9.11 当前技能文档提到的 doctor 脚本不存在

`scripts/inkbridge_doctor.sh` 在当前工作区不存在。不要反复假设它可用；用 `hdc list targets`、源码比较、版本搜索和现有构建脚本完成等价检查。

### 9.12 打包后的中继不是工作区源码

Mac App 运行的是 bundle 内的 `local-server.mjs`。仅修改工作区并不会更新正在运行的 App；必须运行 `make-app.sh`，退出旧 App 并重新打开。

### 9.13 网络地址会变化

用户更换过 Wi-Fi，目前在新加坡。不要依赖旧 IP、旧 TCP HDC target 或旧进程 PID。每次都重新发现设备和当前 URL。VPN、防火墙和不同子网会影响无线连接。

### 9.14 工作树属于用户

当前有大量无关未跟踪目录，例如 `.openai/`、`app/`、`db/`、`examples/`、`worker/`、`ui-concepts/`、`交付文档/` 等。不能删除、移动、格式化、批量暂存或纳入提交。严禁 `git reset --hard`、`git checkout -- .` 和 `git add .`。

### 9.15 USB 平板投屏原型（2026-08-23）

- 方向已确认为“鸿蒙平板画面投到 Mac”，不是 Mac 投到平板。
- 平板端按华为官方 ScreenCapture Surface 示例改造：`OH_AVScreenCapture_StartScreenCaptureWithSurface` 直接连接 `OH_VideoEncoder_GetSurface`，避免 CPU 逐帧截图和颜色转换。
- 默认参数：2560×1600、60 fps、30 Mbps、H.264 High、CBR、1 秒关键帧、低时延模式。
- 媒体走 HDC Reverse TCP 3211；控制、笔迹、PDF 仍走 3210。Mac 使用 `AVSampleBufferDisplayLayer` 显示 H.264，并另开“平板有线投屏”窗口。
- 关键文件：`HarmonyPad/entry/src/main/cpp/screen_mirror.cpp`、`MacPDFAnnotator/Sources/TabletMirrorManager.swift`、`HarmonyPad/entry/src/main/ets/pages/Index.ets`、`MacPDFAnnotator/Sources/USBRelayManager.swift`。
- `scripts/inkbridge-harmony.sh` 现在只保留英文镜像根目录的签名 `build-profile.json5`，会正常同步 `entry/build-profile.json5` 中的 CMake 配置。
- HarmonyOS 原生库已编译为 `libs/arm64-v8a/libscreenmirror.so`，签名 HAP 已覆盖安装到真机 `3ZL0224C26000762`。Mac 串行 Swift 构建成功并已重新打包到桌面 App。
- 用户已完成鸿蒙系统录屏授权。真机画面已在 Mac 显示，PDF 文字、荧光笔和细笔迹可读，顶部栏收起等界面变化能连续刷新。
- 真机调试修复了两个 Mac 崩溃：NAL 长度字节需使用 `UInt8(truncatingIfNeeded:)`；显示附件必须用 Foundation 安全桥接，不能用底层 Core Foundation 指针改写。
- 发送端已加入 350 ms 重连循环、断线缓冲丢弃和重连关键帧请求。已实测关闭/重开 Mac 投屏窗口后无需重新操作平板，连接与画面会自动恢复。
- 2026-08-23 后续修复快速操作黑屏和双端闪退：已移除连接状态下“队列超过 6 帧就丢帧”的错误策略，避免丢失 H.264 参考帧；断线时才丢弃编码缓冲，重连后请求新关键帧。
- 平板“停止投屏”流程改为：禁止新缓冲入队 → 停止采集 → 等待发送线程 → 停止编码器 → 等待活动输出回调清零 → 销毁编码器。套接字只由发送线程关闭，不再重复 `close` 或与回调并发销毁。
- Mac 显示层不再逐帧修改 CoreMedia 附件，改用 `CMTimebase` 和每次连接归一化时间戳。投屏 `NSWindow` 和 `AVSampleBufferDisplayLayer` 在 App 生命周期中常驻，窗口关闭只隐藏不析构，避免 CoreMedia 硬解线程与 AppKit 窗口释放竞态。Mac 客户端套接字也修复了停止时重复关闭文件描述符的问题。
- 真机压力回归：平板状态栏投屏启停 5 轮、顶部栏快速展开/收起 10 次、Mac 投屏窗口关闭/重开 10 轮全部通过；平板 PID `43940`、Mac PID `65111` 在对应测试中保持不变，画面最终仍正常。
- 2026-08-23 “只显示首帧”的根因是 Surface 编码器输出 PTS 的时基不能直接当作微秒传给 Mac，后续帧被 `CMTimebase` 排到错误的未来时间。发送端现使用 `steady_clock` 从每次投屏启动时刻生成严格递增的微秒 PTS，同时兼容静止后再操作的时间间隔。真机已验证首帧后连续缩放、顶部栏动画和静止 6 秒后的后续多帧均能刷新，最终画面位置与内容已变化。
- 2026-08-23 全局投屏：移除 `Index.aboutToDisappear()` 中的自动 `screenMirror.stop()`，开始投屏后按官方长时任务文档申请 `audioRecording` 模式。`module.json5` 已声明 `ohos.permission.KEEP_BACKGROUND_RUNNING`、`backgroundModes: ["audioRecording"]` 和用户可见的持续通知原因。显式停止投屏时会同时调用 `stopBackgroundRunning()`。
- 全局投屏真机回归：启动后按 Home 回到鸿蒙桌面，Mac 成功显示整个桌面；随后打开系统“设置 → 电池健康”，Mac 仍连续显示设置应用。测试期间笔迹桥 PID `59242`、Mac PID `68280` 与 TCP 3211 `ESTABLISHED` 状态全程保持。强制停止/杀进程仍会由系统终止录屏，不可规避。
- 120 fps 能力实测：H.264 硬编在 2560×1600 下返回范围 1–120 fps，`AreVideoSizeAndFrameRateSupported(2560, 1600, 120)` 为 true；在 `OH_SCREEN_CAPTURE_STATE_STARTED` 回调中设置录屏上限 120 也返回 0。但连续顶部栏动画和系统设置滚动下，每 120 个编码输出稳定耗时 1.99–2.00 秒，真实仅约 60 fps。结论是该固件公开 `AVScreenCapture` 源实际限制约 60 fps，不是编码器或 USB 瓶颈。生产配置已恢复 2560×1600@60、30 Mbps；保留 120 只会增加功耗并误报帧率。真正的 120 fps 全局投屏需要非公开 RenderService/虚拟显示系统权限，普通三方 App 不能依赖。
- 2026-08-31 单端发起投屏：新增经 3210 控制通道转发的 `screen-mirror:request/status` 消息，并在 PDF/白板两个 Web 客户端都接入 ArkTS `__nativeHost` 代理。Mac 启动后会隐藏预启动 TCP 3211 接收器：平板单击“投屏”会先通知 Mac 显示窗口，160 ms 后启动原生采集；Mac 单击“开始平板投屏”则先开启等待窗口，再通知平板弹出系统录屏授权。任意一端的停止操作也会同步到另一端。协议回归新增用例已通过，总计 33/33。
- 单端发起要求中继升级为 relayVersion 11，否则 Mac 可能复用仍在运行的 relayVersion 10 进程并丢弃新控制类型。`LocalRelayLauncher.requiredRelayVersion`、`local-server.mjs` 和测试期望必须同步。
- 2026-08-31 投屏窗口比例：平板采集画布从 2560×1600 改为 2400×1600（3:2），与真机 2880×1920 面板一致；Mac 窗口初始内容区 960×640、最小 720×480，并根据视频流头动态设置 `contentAspectRatio` 和窗口大小。真机截图中视频已贴近四边，原有明显黑边消失。Mac 工具栏投屏按钮拆为独立 `@ObservedObject` 组件，停止后能立即恢复“开始平板投屏”，不再显示上一次的分辨率/连接状态。

## 10. 新会话开场清单

1. 完整阅读本文件。
2. 阅读 `/Users/zhekuan/.codex/skills/inkbridge-harmonyos-development/SKILL.md`；涉及 UI 时同时使用 `inkbridge-product-design`。
3. 执行 `git -c core.fsmonitor=false status --short`，确认未覆盖用户改动。
4. 确认 `VERSION`、Web、Swift、HarmonyOS 均为 1.6.10，白板缩放常量是 `0.25` 和 `8`。
5. 重新执行 `hdc list targets -v`，不要假定交接设备仍在线。
6. 询问用户是否已经实际测试单指无限平移和双指 25%–800% 缩放。
7. 若用户报告手势 bug，先复现并记录具体倍率、手指数、焦点位置和松指顺序，再修改。
8. 修改后分别报告：测试、编译、签名、安装、启动、真实行为验证；不能互相替代。
9. 未经用户要求，不恢复“平板模拟 Mac 触控板”方向。

## 11. PDF 直达华为笔记与实况窗（2026-08-31）

- 真机只读探测确认系统“华为笔记”为 `com.huawei.hmos.hinote / HiNotePcMainAbility`，并明确声明支持 `ohos.want.action.viewData + file URI + com.adobe.pdf`。`com.huawei.hmos.notepad` 是另一套备忘录应用，不是本功能目标。
- `Index.ets` 的 PDF 往返下载完成后现优先显式启动华为笔记，失败才回退到原来的通用 `application/pdf` 隐式打开。真实 3.4 MB PDF 已连续多次直接进入华为笔记 PDF 批注界面，未再落到 WPS。
- 新增 `RoundTripLiveViewController.ets`，使用官方 `@kit.LiveViewKit` 的 `isLiveViewEnabled/startLiveView/updateLiveView/stopLiveView`。实况窗在笔迹桥仍处于前台时创建；胶囊显示未投屏/投屏中，进度扩展区提供“开始投屏/停止投屏”和“返回笔迹桥”服务按钮。
- `EntryAbility.onCreate/onNewWant` 会解析 `liveViewAction`，通过扩展后的 `RoundTripBridge` 交给当前页面；投屏按钮复用既有单端发起与 USB 投屏函数，投屏状态改变时更新实况窗，PDF 回传成功后停止实况窗。
- 官方本地构建文档确认进度模板必须使用受支持场景名和 `/resources/rawfile` 图标。当前采用官方 `QUEUE` 模板、两个节点图标、`START_ABILITIES` WantAgent；图标位于 `entry/src/main/resources/rawfile/inkbridge_liveview_*.svg`。
- 真机先后排除了 `PickupLayout.descPic`、空 `ProgressLayout.nodeIcons` 和胶囊背景色等参数校验问题。最终请求已经通过完整参数校验并到达系统发布阶段，唯一失败为 `1003500005 The right of liveView is not enabled`。
- 华为官方规定：调试可在 AppGallery Connect `增长 → 推送服务 → 配置 → 实况窗-调测设备管理` 中使用 Push Token 添加设备，名单处理最多 24 小时；正式权益需在 `项目设置 → 开放能力管理 → 实况窗服务` 提交场景说明与设计附件，预计 5 个工作日，并在通过后重新生成签名 Profile。未经用户授权没有代为提交外部权益申请。
- 相关官方文档：`https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-create-locally`、`liveview-joint-commission-test`、`liveview-rights`。
- 最终构建证据：API 24 SDK、default/entry/debug 类型检查成功、HAP 打包成功、DevEco 调试签名成功、`entry-default-signed.hap` 覆盖安装成功、Ability 启动成功。协议测试 34/34、Swift 全量构建通过。
- 实际完成边界：华为笔记直达已完成并可用；实况窗代码已完成但胶囊 UI 和服务按钮还不能做视觉/点击验收，必须先给当前应用/设备开通 LiveView 调测或正式权益。
