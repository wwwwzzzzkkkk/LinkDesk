# HDR 显示能力与真机验证

2026-10-25完成主要真机验证，相关改动纳入2026-10-26的1.0.0。保留2880×1920及既有独立光标和防积压优化。

## 本次支持范围

Mac「扩展屏幕」增加 **HDR10 · 10-bit** 开关，保存选择，切换时重新连接。平板面板在色彩信号及实际10-bit显示缓冲均验证成功后显示HDR10。默认不开启；HDR会增加性能开销。

| 内容/能力 | 当前结果 |
| --- | --- |
| 10-bit HDR10 桌面投送 | 已实现并完成基础真机检查 |
| 广色域 | HDR虚拟屏P3色域，传输BT.2020/PQ，最终由显示器映射 |
| 杜比视界原始码流、RPU动态元数据直通 | 未实现；不能标为原生杜比视界播放 |
| 杜比内容先由Mac播放器解码，再投送HDR画面 | 使用同一HDR桌面路径，前提是播放器能正确输出HDR；本轮没有实际杜比片源验收 |
| 所有杜比Profile、受保护视频 | 不保证；屏幕采集不等于原始片源码流传输 |

当前平板系统探测：HDR formats为2、1、3（HDR10、HLG、HDR Vivid），HEVC profile为0、1（Main、Main10）；`video/dolby-vision`硬件解码能力查询为空。因此没有添加杜比模式开关或杜比标识。

## 完整链路

1. 平板在请求启动前，通过既有控制连接发送HDR10显示与Main10解码能力。未就绪/不支持时沿用SDR。两端建议一起更新。
2. Mac虚拟屏使用经运行时ABI验证的扩展亮度模式，HDR时切换P3原色。仅修改本应用虚拟屏，没有改物理显示器配置或系统全局HDR。
3. ScreenCaptureKit canonical HDR采集，x420 10-bit、BT.2020/PQ。第一帧实际格式和色彩附件不匹配时停止并提示，避免仅重标SDR。
4. VideoToolbox硬件HEVC Main10；明确写入BT.2020原色、ST2084 PQ和BT.2020矩阵，检查设置返回值。保留可用HDR元数据的系统处理，不伪造杜比元数据。
5. 新LDQ1流头明确表示固定的HDR10配置，与原SDR/诊断流头区分。平板检查分辨率、帧率、HDR显示和Main10能力。
6. 平板Surface设为BT.2020/PQ limited，硬件解码器获得对应色彩信息。进一步查询最后显示缓冲的真实格式与色彩空间，确认P010或10-bit RGBA及PQ后才显示HDR10状态。

Mac至少需要macOS15、Apple Silicon，以及可验证的虚拟屏扩展亮度ABI；实际测试为当前Mac系统。旧系统ABI不匹配时禁用功能，不猜测调用类型。运行时API与已测系统相关，后续系统升级需重新验证。

## 真机证据

- 开启HDR时，虚拟屏potential EDR headroom从1.00变为5.00；关闭后恢复1.00。
- 采集：pixel=`0x78343230`（x420），原色ITU_R_2020、传递函数SMPTE_ST_2084_PQ、矩阵ITU_R_2020，格式校验通过。
- 编码：hvcC profile=2（Main10）、bits=10。
- 解码：primaries=9、transfer=16、matrix=9。
- 最终显示缓冲：format=35（P010），color=10（BT.2020 PQ limited），查询成功；`ten_bit=1 active=1`。
- 测试使用自行生成的线性亮度0.05、0.25、1、2、4、8梯度，未把SDR图片重标HDR。源头仍为SDR的早期试验只到10-bit码值554；启用扩展亮度后出现701–718的高光码值。该数字描述编码前像素，不是亮度计测得的屏幕nits。
- 用户观看真机后确认“亮部有层次，桌面颜色正常”。截图会映射到SDR，因此不把普通PNG截图当作HDR物理亮度证明。
- HDR关闭/重开、接收端恢复、状态清除均已检查。60目标短窗口约57–61 fps；HDR120测试约86–90 fps，尚未锁120，更不能宣称HDR锁144。
- HDR144短窗口稳定段约75–79 fps，仍有更低波动；当前HDR高刷瓶颈需要继续优化。已恢复原144目标及SDR设置，HDR可以在Mac设置中按需开启。
- 设置切换导致的重连会保留麦克风开启意图；真机验证HDR开启时仍为“麦克风传输中”，关闭HDR后Mac复选状态保持开启。

## 改动位置与检查

- Mac：`macOS/LDDesktopController.m`、公开控制接口、`LinkDeskWorkspaceView.swift`。
- 平板：`hdr_capabilities.h`、`stream_format.h`、`receiver.cpp`及面板状态。
- 文案由`strings.json`生成，检查通过。
- Mac/ArkTS/C++及签名HAP构建通过；沿用原签名身份和正常应用启动流程，未修改TCC。
- 统一37项回归及原生内存检查通过；新增流格式测试覆盖HDR10必须使用高清HEVC配置、SDR兼容、诊断格式和非法版本/尺寸/帧率。仅有既有fabsf类型警告。

原始日志位于本地`../hdr-*.log`，签名资料保留在仓库外。签名资料不进入源码与公开发行包。

## 尚存限制

原生杜比视界解码与动态元数据直通尚不支持；未完成真实杜比片源、长时间热稳定、HDR高帧率、色度计校准和端到端物理亮度/延迟测量。HDR关闭后仍可使用已优化的SDR低延迟模式。

参考：[Apple HDR采集说明](https://developer.apple.com/videos/play/wwdc2024/10088/)、[HDR与杜比元数据要求](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata)。
