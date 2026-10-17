# HarmonyOS API 核对

查阅日期：2026-10-18。工程兼容及目标 SDK 均为 HarmonyOS 6.1.1 / API 24。先查官方资料，再核对本机 DevEco SDK 类型声明，没有使用系统内部窗口接口。

| 用途 | 本次使用 | 核对与边界 |
| --- | --- | --- |
| 点击热区 | Button 本体与 constraintSize 至少48×48vp | [华为官方热区规范](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/ide_touch-target-size-V5)推荐48vp，最低40vp。本项目采用48vp，比需求44vp更大，不用互相重叠的 responseRegion 补足 |
| 控制层材质 | backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, colorMode) | [华为动态模糊入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-blur-effect)、[官方 OpenHarmony 背景参考](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-background.md)；本机 SDK 的 COMPONENT_REGULAR 标注 API11。用系统材质与单色可读性遮罩，删除控制层彩色渐变；纸张及卡片保持实体色 |
| 动效曲线 | curves.cubicBezierCurve | [官方曲线参考](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/js-apis-curve.md)，API9。JSON 时长毫秒在 Swift 转秒；同一四控制点在 ArkUI 创建 ICurve |
| 减少动态效果 | isAnimationReduceEnabledSync、onAnimationReduceStateChange、offAnimationReduceStateChange | [官方 Accessibility 参考](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-accessibility-kit/js-apis-accessibility.md)，三项均 API23，SDK24支持；使用相同具名回调注册／注销，重新进入前台刷新。查询失败保守禁用非必要动画 |
| 沉浸接收 | setWindowLayoutFullScreen、setWindowSystemBarEnable、setSpecificSystemBarEnabled('navigationIndicator') | [华为沉浸式窗口示例](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-199)、[官方 Window 参考](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/arkts-apis-window-Window.md)。进入接收场景隐藏；离开／退后台恢复；串行队列避免快速进入退出时旧异步操作覆盖新状态。系统可能在分屏／自由窗口中保留自己的栏，不把 Promise成功当作视觉验收 |
| 自适应 | onAreaChange、GridRow、Scroll、Flex、constraintSize | 沿用工程已使用的 ArkUI 控件与 SDK24公开声明；按实际窗口宽度选择导航和列数，不判断设备型号 |
| 主题系统栏 | 原有 setColorMode、setWindowSystemBarProperties | 只把颜色改为令牌，未重写 preference/pending、revision、请求或持久化机制 |

华为部分 API 详情网址本次联网抓取返回空正文／超时。上表明确给出成功读取的官方 OpenHarmony 一手参考，并与当前 Huawei SDK 声明交叉核对；不把第三方博客当作 API 依据。Huawei 专属自由窗口材质表现、系统字体放大、减少动态效果开关切换与系统栏最终显示以实机结果为准，未实测的列入验收清单。

此前源码只调用布局全屏，没有显式隐藏系统栏；这解释了“布局扩展到栏后面”和“系统栏消失”不是同一件事。本次按可见性 API处理，不通过染色或修改显示引擎掩盖所谓蓝条。没有此前蓝条排查报告可供核对，不声称复现或彻底修复了该历史现象。

页面返回使用 @Entry 的 onBackPress：已核对[官方页面生命周期](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/ui/arkts-routing.md#lifecycle)，在工作空间返回工作台，工作台保留系统退出行为。竖屏截图使用公开的 setPreferredOrientation 与内存中的审阅参数，不调用私有旋转接口、不保存方向偏好；正常重启仍为 AUTO_ROTATION。Scroll 子内容按 Top 对齐，依据本机 SDK common.d.ts 的 align 注释（支持 Scroll）；不是改动触控滚动手势。

SettingRow 的可插拔控件按照[官方 @BuilderParam 文档](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/ui/state-management/arkts-builderparam.md)用箭头函数包装父组件 Builder，保留父接收器的主题、状态与事件上下文；不直接传递未绑定的方法引用。
