# LinkDesk 双端 UI 一致性

2026-10-18。审计先于实现，见 [AUDIT.md](AUDIT.md)；HarmonyOS API 来源与适用边界见 [API-NOTES.md](API-NOTES.md)。本轮保留 Mac 原生液态玻璃，用鸿蒙系统模糊材质表达控制层；不追求逐像素复制。

## 单一数据源

在仓库根目录修改 `design-tokens.json` 或 `strings.json` 后运行：

```sh
python3 scripts/generate-design.py
python3 scripts/check-ui-parity.py
```

生成 Swift 常量（pt）、ArkTS 常量（数值尺寸默认 vp，字号显式 fp）、深浅两套 SVG 和网页控制层 CSS。生成文件首行标注“自动生成，勿手改”。两端构建和 CI 都检查生成结果；过期文件会阻止构建。

`python3 scripts/demo-design-token.py` 会实际修改 accent、同时生成并检查两端输出、记录 [TOKEN-DEMO.md](TOKEN-DEMO.md)，最后恢复正式配色。此命令同步的是源码，已安装应用需正常重新构建安装，不声称支持二进制热更新。

`strings.json` 提供中英页面、按钮、状态、空状态及错误提示。系统语言为英文时选择英文，其余语言回退中文；文件后缀和传输错误等兼容字符串通过 source() 保持既有原值。原引擎诊断、浏览器备用界面以及画布像素／笔迹数据不在原生视图字面量检查范围，未为去除字面量而修改协议或绘制算法。

## 一致性对照表

| 项目 | Mac | HarmonyOS MatePad | 统一约定 |
| --- | --- | --- | --- |
| 导航 | 原生五项侧栏 | 宽横屏侧栏；竖屏或窄窗口底部五项导航 | 工作台 → 扩展屏幕 → PDF 批注 → 实时白板 → 平板投屏 |
| 品牌色 | 浅 #3979DE，深 #78ACFF | 相同；图标描边同次生成 | accent／accentSoft，不混用系统默认蓝按钮 |
| 页面背景 | 浅 #F4F6FA，深 #0E1523 | 相同 | canvas／surface／control 三层；原生材质保留平台差异 |
| 正文／次级文字 | 浅 #152441／#596B85，深 #E8EEF8／#A5B4CA | 相同 | 状态颜色不代替文字 |
| 五档字号 | 12 / 14 / 17 / 22 / 30pt | 12 / 16 / 20 / 24 / 32fp | caption / body / label / section / title；平板加强阅读与触控可读性 |
| 间距 | 4pt 网格 | 4vp 网格 | 同名间距令牌；相对布局、描边及图标内部几何单独定义 |
| 三档圆角 | 12 / 20 / 28pt | 12 / 20 / 28vp | small / medium / large；Mac胶囊为平台原生形状 |
| PageHeader | 标题 + 功能副标题 + 右侧状态胶囊 | 同结构，窄处状态换行 | 文档名与配对码作为上下文，不替代功能名 |
| 空状态 | 淡色图标方块 + 标题 + 说明 + 主操作 | 同结构；等待 Mac 打开文件时给配对操作 | Mac可直接开文件，平板承担等待／配对职责 |
| SettingRow | 左标题说明、右控件，最低64pt | 同结构，最低80vp；窄处控件换行 | 触控控件最低48×48vp，避免扩大重叠热区 |
| 配对 | 配对码 | 配对码 | 内部 room、偏好键及协议字段不改名 |
| 材质 | macOS26 原生 glassEffect；旧系统 regularMaterial | COMPONENT_REGULAR 系统背景模糊 + 单色可读性遮罩 | 不使用渐变模拟折射；内容卡片和纸张实体色 |
| 动效 | SwiftUI timingCurve | ArkUI cubicBezierCurve | 反馈120ms、菜单进入240ms／退出180ms、收起520ms；同一曲线控制点 |
| 减少动态效果 | SwiftUI accessibilityReduceMotion | API23 查询并监听变化，前台刷新 | 禁用非必要位移、缩放及收起动效；读取失败保守关闭 |
| 指针／键盘 | 原生侧栏、菜单、搜索和既有快捷键 | 原生按钮按下态；保留手写笔悬停逻辑 | 不给平板控制按钮新增悬停反馈 |
| 接收沉浸 | 独立 Mac 窗口习惯 | 接收页隐藏系统栏；工作中隐藏导航，点按显示退出控制 | 退出恢复系统栏，保持视频宽高比，不改引擎 |

## ConnectionState

同一生成源输出枚举、文案与点色，两端只适配已有事件。Mac 不把连接本机中继当作平板连接；平板从已有 Web 状态和接收 stats 更新，导航与接收页共用同一 UI 状态。没有新增网络消息、服务端字段或持久化格式。

| 状态 | 中文 / English | 颜色语义 | 依据 |
| --- | --- | --- | --- |
| disconnected | 未连接 / Disconnected | tertiary | 当前工作空间没有可观察连接 |
| usbConnected | USB 已连接 / USB connected | accent | 已观察到 USB 通道，尚未进行该工作空间操作 |
| waitingForMode | 等待平板选择模式 / Choose a mode on your tablet | warning | 会话就绪或副屏准备中，等待模式／授权 |
| working | 工作中 / Working | success | 书写会话已连接，或视频接收／投屏实际运行 |
| error | 异常 / Connection issue | error | 原引擎或接收器报告异常；说明与重试操作另列 |

状态基于工作空间上下文实时推导，不是假定一个全局网络广播值。Wi-Fi 使用说明区保留传输方式，不标为 USB；尚未连上 Mac 时平板无法知道电脑的本地设备枚举结果。截图拍摄于不同时间，断开场景与已连接场景的胶囊可能不同，文案和颜色契约相同。

## 截图

Mac 为实际构建应用的内容视图快照，便于稳定比较层级与尺寸；不能据此断言系统合成的玻璃折射、阴影与真实桌面截图完全一致。平板图来自 USB 真机抓屏。使用独立 UI 审阅配对码，未清空原有笔迹；白板截图出现的既有笔迹不代表本轮实测了手写笔。扩展屏截图记录等待／重连界面，不公开桌面视频内容。

| 页面 | 浅色并排 | 深色并排 |
| --- | --- | --- |
| 工作台 | [浅色](pairs/home-light.png) | [深色](pairs/home-dark.png) |
| 扩展屏幕 | [浅色](pairs/display-light.png) | [深色](pairs/display-dark.png) |
| PDF 批注 | [浅色](pairs/pdf-light.png) | [深色](pairs/pdf-dark.png) |
| 实时白板 | [浅色](pairs/whiteboard-light.png) | [深色](pairs/whiteboard-dark.png) |
| 平板投屏 | [浅色](pairs/mirror-light.png) | [深色](pairs/mirror-dark.png) |

整组：[浅色总览](parity-light.png) / [深色总览](parity-dark.png)。原始快照见 mac/、tablet/；另有 [竖屏真机截图](tablet/portrait-home-dark.png)。

## 已验证与未验证

详见 [VERIFICATION.md](VERIFICATION.md)。本轮只进行生成／视图检查、必要编译与对应的界面操作，没有重复扩展完整视频、音频和手写笔测试。先前协议回归不能当作本轮新 UI 已通过全部真机验收的证据。

## 设计决定与待确认项

以下已作为默认方案实现，可据实际使用反馈调整，不额外阻塞交付：

1. 竖屏采用底部导航，给 PDF／画布保留横向空间；宽横屏采用侧栏。分屏以可用窗口形状和宽度判断。
2. 浅深主题分别采用较深／较亮蓝色，提高文字和图标可读性，而不是把同一个十六进制颜色强用于两种背景。
3. 进入平板投屏页只展示控制，点击“开始平板投屏”才申请录屏；与 Mac 的明确启动动作对齐。
4. PDF 纸张和白板纸面保持原色，不随深色主题反相；深色只调整周围控制层。

## 提交顺序

审计报告 → 数据源与生成器 → Mac迁移 → 鸿蒙迁移 → 导航与页面结构 → 平台适配 → 实机截图发现的问题修正 → 文档及验收证据。修正提交只处理截图或状态检查发现的差异，未扩充通信／显示引擎功能。
