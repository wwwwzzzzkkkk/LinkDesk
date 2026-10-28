# 平板沉浸光感统一（V1.1.2）

应用目标为 HarmonyOS API 26，最低兼容为 API 24。entry 模块通过 `ohos.arkui.UIMaterial.state=enable` 请求系统沉浸光感；在 HarmonyOS 7 测试平板上，页面加载完成后系统接口返回 `state=1`、`supported=true`。低版本设备仍使用原有 ArkUI 控件与玻璃风格，未在 API 24 真机上验收。

工作台卡片、连接状态、侧边栏控件、PDF／白板工具栏与弹层、投屏页面、扩展屏幕浮层以及虚拟键盘使用协调的透光色、边缘与高光。系统支持的菜单、滑块和开关由系统提供原生光感；自绘组件、Web 内容和视频画面使用协调的自定义视觉，不能标称为系统原生光感。模糊局限于面板区域，不为每颗键或视频帧添加模糊。

2026-10-29 实机检查深／浅色工作台与PDF、深色白板和投屏、扩展屏幕、键盘和页面切换，恢复原深色。53项自动测试、原生回归、ArkTS构建和UI资源检查通过。144 fps目标、2880×1920 HDR动态短测25个一秒样本（筛选采集至少60帧）解码提交82–116 fps，中位104 fps；测试负载并非严格同轨迹对照，不能据此确认材质开销或锁帧。平板显示系统报告120 Hz。不同API版本、竖屏、长期热稳定、真实内容批注及投屏授权仍需更多设备验证。

参阅华为[开启沉浸光感](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-enable)及[设计指南](https://developer.huawei.com/consumer/cn/design/)；原生材质的效果范围由系统支持的组件与区域决定。
