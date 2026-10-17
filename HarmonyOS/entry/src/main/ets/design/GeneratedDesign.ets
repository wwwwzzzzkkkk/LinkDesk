// 自动生成，勿手改。Source: design-tokens.json + strings.json; python3 scripts/generate-design.py

import { curves } from '@kit.ArkUI';

export class DT {
  static accent(dark: boolean): string { return dark ? "#78ACFF" : "#3979DE"; }
  static accentSoft(dark: boolean): string { return dark ? "#203451" : "#E7EFFD"; }
  static creative(dark: boolean): string { return dark ? "#58D3B7" : "#19856E"; }
  static canvas(dark: boolean): string { return dark ? "#0E1523" : "#F4F6FA"; }
  static surface(dark: boolean): string { return dark ? "#182337" : "#FFFFFF"; }
  static control(dark: boolean): string { return dark ? "#223149" : "#EDF1F8"; }
  static glass(dark: boolean): string { return dark ? "#CC16243A" : "#CCF8FAFF"; }
  static text(dark: boolean): string { return dark ? "#E8EEF8" : "#152441"; }
  static secondary(dark: boolean): string { return dark ? "#A5B4CA" : "#596B85"; }
  static tertiary(dark: boolean): string { return dark ? "#8B9DB7" : "#73839A"; }
  static border(dark: boolean): string { return dark ? "#30425F" : "#DFE6F1"; }
  static success(dark: boolean): string { return dark ? "#58D3B7" : "#19856E"; }
  static warning(dark: boolean): string { return dark ? "#F0C267" : "#986808"; }
  static error(dark: boolean): string { return dark ? "#FF9FA9" : "#BD3949"; }
  static onAccent(dark: boolean): string { return dark ? "#0E1523" : "#FFFFFF"; }
  static paper(dark: boolean): string { return dark ? "#FFFFFF" : "#FFFFFF"; }
  static ink(dark: boolean): string { return dark ? "#152441" : "#152441"; }
  static video(dark: boolean): string { return dark ? "#000000" : "#000000"; }
  static clear(dark: boolean): string { return dark ? "#00000000" : "#00000000"; }
  static scrim(dark: boolean): string { return dark ? "#000000" : "#19283C"; }
  static selection(dark: boolean): string { return dark ? "#2C4973" : "#D7E7FF"; }
  static readonly fontCaption = "12fp";
  static readonly fontBody = "16fp";
  static readonly fontLabel = "20fp";
  static readonly fontSection = "24fp";
  static readonly fontTitle = "32fp";
  static readonly spacingS0 = 0;
  static readonly spacingS4 = 4;
  static readonly spacingS8 = 8;
  static readonly spacingS12 = 12;
  static readonly spacingS16 = 16;
  static readonly spacingS20 = 20;
  static readonly spacingS24 = 24;
  static readonly spacingS28 = 28;
  static readonly spacingS32 = 32;
  static readonly spacingS36 = 36;
  static readonly spacingS40 = 40;
  static readonly spacingS44 = 44;
  static readonly spacingS48 = 48;
  static readonly spacingS52 = 52;
  static readonly spacingS56 = 56;
  static readonly spacingS60 = 60;
  static readonly spacingS64 = 64;
  static readonly spacingS68 = 68;
  static readonly spacingS72 = 72;
  static readonly spacingS76 = 76;
  static readonly spacingS80 = 80;
  static readonly spacingS84 = 84;
  static readonly spacingS88 = 88;
  static readonly spacingS92 = 92;
  static readonly spacingS96 = 96;
  static readonly radiusSmall = 12;
  static readonly radiusMedium = 20;
  static readonly radiusLarge = 28;
  static readonly layoutTouchTarget = 48;
  static readonly layoutMacControl = 28;
  static readonly layoutSidebar = 224;
  static readonly layoutSidebarMin = 208;
  static readonly layoutSidebarMax = 272;
  static readonly layoutWideBreakpoint = 840;
  static readonly layoutSingleColumnBreakpoint = 600;
  static readonly layoutPageMax = 960;
  static readonly layoutPagePadding = 32;
  static readonly layoutCompactPadding = 16;
  static readonly layoutSettingRowMac = 64;
  static readonly layoutSettingRowTablet = 80;
  static readonly layoutBottomNavigation = 80;
  static readonly layoutIconSmall = 16;
  static readonly layoutIcon = 24;
  static readonly layoutIconTile = 48;
  static readonly layoutStatusDot = 8;
  static readonly layoutCardMinHeight = 176;
  static readonly layoutHeaderMinHeight = 80;
  static readonly layoutMenuMaxWidth = 384;
  static readonly layoutToolbarHeight = 64;
  static readonly layoutFormMaxWidth = 480;
  static readonly layoutStroke = 1;
  static readonly dimensionsD120 = 120;
  static readonly dimensionsD112 = 112;
  static readonly dimensionsD144 = 144;
  static readonly dimensionsD208 = 208;
  static readonly dimensionsD220 = 220;
  static readonly dimensionsD420 = 420;
  static readonly dimensionsD320 = 320;
  static readonly dimensionsD1000 = 1000;
  static readonly dimensionsD680 = 680;
  static readonly dimensionsD184 = 184;
  static readonly dimensionsD360 = 360;
  static readonly dimensionsD380 = 380;
  static readonly dimensionsD392 = 392;
  static readonly durationFeedback: number = 120;
  static readonly durationMenuEnter: number = 240;
  static readonly durationMenuExit: number = 180;
  static readonly durationCollapse: number = 520;
  static readonly durationNone: number = 0;
  static readonly opacityMuted: number = 0.6;
  static readonly opacitySubtle: number = 0.08;
  static readonly opacityBorder: number = 0.16;
  static readonly opacityPressed: number = 0.84;
  static readonly transformMenuScale: number = 0.96;
  static readonly transformExitScale: number = 0.98;
  static readonly transformSearchScale: number = 0.96;
  static curveStandard(): ICurve { return curves.cubicBezierCurve(0.42, 0, 0.58, 1); }
  static curveEnter(): ICurve { return curves.cubicBezierCurve(0.16, 1, 0.3, 1); }
  static curveExit(): ICurve { return curves.cubicBezierCurve(0.4, 0, 1, 1); }
  static readonly iconHome: Resource = $r("app.media.workspace_home");
  static readonly iconDisplay: Resource = $r("app.media.workspace_display");
  static readonly iconPdf: Resource = $r("app.media.workspace_pdf");
  static readonly iconWhiteboard: Resource = $r("app.media.workspace_whiteboard");
  static readonly iconMirror: Resource = $r("app.media.workspace_mirror");
  static readonly inkInk: string = "#152441";
  static readonly inkRed: string = "#e74c3c";
  static readonly inkBlue: string = "#2980b9";
  static readonly inkGreen: string = "#27ae60";
  static readonly inkPurple: string = "#8e44ad";
  static readonly inkOrange: string = "#f39c12";
  static readonly inkWhite: string = "#ffffff";
  static readonly inkColor7: string = "#2269ef";
  static readonly inkColor8: string = "#e45a4f";
  static readonly inkColor9: string = "#1b9a7e";
}

export class Strings {
  static language: string = "zh-Hans";
  static get(key: string, args: string[] = []): string {
    let value = Strings.value(key);
    for (let i = 0; i < args.length; i++) value = value.split(`{${i}}`).join(args[i]);
    return value;
  }
  private static value(key: string): string {
    const english = Strings.language.startsWith("en");
    switch (key) {
      case "productName": return english ? "LinkDesk" : "LinkDesk";
      case "productSubtitle": return english ? "Your workspace across screens" : "你的跨屏工作空间";
      case "workspaces": return english ? "Workspaces" : "工作空间";
      case "homeTitle": return english ? "Workspace" : "工作台";
      case "displayTitle": return english ? "Extended Display" : "扩展屏幕";
      case "pdfTitle": return english ? "PDF Annotation" : "PDF 批注";
      case "whiteboardTitle": return english ? "Live Whiteboard" : "实时白板";
      case "mirrorTitle": return english ? "Tablet Mirroring" : "平板投屏";
      case "homeSubtitle": return english ? "Bring your Mac and MatePad together." : "让 Mac 与 MatePad 一起工作。";
      case "displaySubtitle": return english ? "Use your MatePad as an extended Mac display." : "把 MatePad 变成 Mac 的高清扩展屏幕。";
      case "pdfSubtitle": return english ? "Write on your tablet, read and organize on your Mac." : "在平板上书写，在 Mac 上同步阅读与整理。";
      case "whiteboardSubtitle": return english ? "One canvas. Room for every idea." : "一块画布，让想法自由延伸。";
      case "mirrorSubtitle": return english ? "Bring tablet notes and presentations to your Mac." : "将平板上的笔记、演示和灵感带到 Mac。";
      case "heroTitle": return english ? "Ideas flow across screens." : "让灵感，在屏幕间流动。";
      case "heroSubtitle": return english ? "Extend your desktop, annotate, or think together." : "扩展桌面，随手批注，或一起构思。";
      case "connectionHint": return english ? "Use USB for display and mirroring; PDF and whiteboard also support Wi-Fi." : "扩展屏幕与平板投屏使用 USB；PDF 和白板也支持 Wi-Fi。";
      case "pairingCode": return english ? "Pairing code" : "配对码";
      case "pairingCodeValue": return english ? "Pairing code {0}" : "配对码 {0}";
      case "pairingTitle": return english ? "Connect & Pair" : "连接与配对";
      case "pairingSubtitle": return english ? "Choose a connection and use the same pairing code." : "选择连接方式，使用相同的配对码。";
      case "connectTablet": return english ? "Connect Tablet" : "连接平板";
      case "connectMac": return english ? "Connect to Mac" : "连接 Mac";
      case "connect": return english ? "Connect" : "连接";
      case "reconnect": return english ? "Reconnect" : "重新连接";
      case "done": return english ? "Done" : "完成";
      case "cancel": return english ? "Cancel" : "取消";
      case "hide": return english ? "Hide" : "隐藏";
      case "close": return english ? "Close" : "关闭";
      case "backHome": return english ? "Back to Workspace" : "返回工作台";
      case "appearance": return english ? "Appearance" : "外观";
      case "themeAutomatic": return english ? "System" : "跟随系统";
      case "themeLight": return english ? "Light" : "浅色";
      case "themeDark": return english ? "Dark" : "深色";
      case "themeHelp": return english ? "Follow your Mac appearance, or sync a light or dark theme." : "跟随 Mac 系统外观，或选择两端同步的浅色／深色主题。";
      case "themeAccessibility": return english ? "Change appearance on both devices" : "切换外观，两端同步";
      case "stateDisconnected": return english ? "Disconnected" : "未连接";
      case "stateUSBConnected": return english ? "USB connected" : "USB 已连接";
      case "stateWaitingForMode": return english ? "Choose a mode on your tablet" : "等待平板选择模式";
      case "stateWorking": return english ? "Working" : "工作中";
      case "stateError": return english ? "Connection issue" : "异常";
      case "transportWifi": return english ? "Wi-Fi connected" : "Wi-Fi 已连接";
      case "transportUSB": return english ? "USB" : "USB";
      case "transportWireless": return english ? "Wi-Fi" : "Wi-Fi";
      case "pdfEmptyTitle": return english ? "Start with a PDF" : "从一份 PDF 开始";
      case "pdfEmptyDescription": return english ? "Open a PDF on your Mac and write naturally on your tablet." : "在 Mac 打开文档，在平板上自然书写。";
      case "openPDF": return english ? "Open PDF…" : "打开 PDF…";
      case "waitPDFTitle": return english ? "Waiting for a PDF" : "等待 Mac 打开 PDF";
      case "waitPDFDescription": return english ? "Open a PDF on your Mac to read and annotate here." : "在 Mac 打开文档后，即可在此阅读与批注。";
      case "mirrorEmptyTitle": return english ? "Bring your tablet to your Mac" : "把平板画面带到 Mac";
      case "mirrorEmptyDescription": return english ? "Connect with USB, then allow screen capture on your tablet." : "保持 USB 连接，启动后在平板允许录屏。";
      case "startMirror": return english ? "Start Mirroring" : "开始平板投屏";
      case "stopMirror": return english ? "Stop Mirroring" : "停止平板投屏";
      case "startDisplay": return english ? "Start Display" : "启动扩展";
      case "stopDisplay": return english ? "Stop Display" : "停止扩展";
      case "displayEmptyTitle": return english ? "Connect your MatePad" : "连接你的 MatePad";
      case "displayEmptyDescription": return english ? "Connect with USB, then select Extended Display." : "连接 USB 数据线，再选择扩展屏幕。";
      case "recentFiles": return english ? "Recent Files" : "最近使用";
      case "displaySettings": return english ? "Display" : "显示";
      case "displayScale": return english ? "Workspace Size" : "工作空间大小";
      case "displayScaleDescription": return english ? "Choose a scale for reading or multitasking." : "选择适合阅读或多任务的显示比例。";
      case "frameRate": return english ? "Target Frame Rate" : "目标帧率";
      case "frameRateDescription": return english ? "Higher rates depend on your Mac, tablet, and connection." : "更高帧率取决于 Mac、平板与连接性能。";
      case "frameRateValue": return english ? "{0} fps" : "{0} 帧/秒";
      case "arrangeDisplays": return english ? "Arrange Displays…" : "排列显示器…";
      case "testDisplay": return english ? "Show Test Pattern" : "显示测试画面";
      case "audioSettings": return english ? "Audio & Microphone" : "声音与麦克风";
      case "tabletSpeaker": return english ? "Tablet Speaker" : "平板扬声器";
      case "useTablet": return english ? "Use Tablet" : "使用平板";
      case "restoreMac": return english ? "Restore Mac" : "恢复 Mac";
      case "tabletMicrophone": return english ? "Tablet Microphone" : "平板麦克风";
      case "microphoneDescription": return english ? "Use the tablet microphone as Mac input." : "允许平板麦克风作为 Mac 输入。";
      case "audioDelay": return english ? "Mac Audio Delay" : "Mac 声音延后";
      case "audioDelayDescription": return english ? "Adjust audio and video alignment." : "调整音画同步。";
      case "milliseconds": return english ? "{0} ms" : "{0} ms";
      case "chooseMode": return english ? "Choose a Workspace" : "选择工作空间";
      case "usbHint": return english ? "Connect and unlock your tablet using USB." : "使用 USB 数据线连接并解锁平板。";
      case "scanPairing": return english ? "Scan to Pair" : "扫码连接";
      case "hostAddress": return english ? "Mac Address" : "Mac 地址";
      case "hostPlaceholder": return english ? "Enter your Mac address" : "输入 Mac 地址";
      case "pairingPlaceholder": return english ? "Enter the six-character pairing code" : "输入六位配对码";
      case "invalidPairing": return english ? "Enter a six-character pairing code using letters and numbers." : "请输入六位字母或数字配对码。";
      case "genericError": return english ? "Check your cable or network, then retry." : "连接遇到问题，请检查数据线或网络后重试。";
      case "connectionMethod": return english ? "Connection" : "连接方式";
      case "automatic": return english ? "Automatic" : "自动选择";
      case "usbOnly": return english ? "USB Only" : "仅 USB";
      case "wifiOnly": return english ? "Wi-Fi Only" : "仅 Wi-Fi";
      case "inkTools": return english ? "Writing Tools" : "书写工具";
      case "collapseTools": return english ? "Collapse Toolbar" : "收起工具栏";
      case "expandTools": return english ? "Expand Toolbar" : "展开工具栏";
      case "returnPDF": return english ? "Return Annotated PDF" : "回传批注";
      case "searchPDF": return english ? "Search PDF" : "搜索 PDF";
      case "searchPlaceholder": return english ? "Search PDF text" : "搜索 PDF 文字";
      case "noResults": return english ? "No results" : "无结果";
      case "previousMatch": return english ? "Previous Match" : "上一个匹配";
      case "nextMatch": return english ? "Next Match" : "下一个匹配";
      case "closeSearch": return english ? "Close Search" : "关闭搜索";
      case "pen": return english ? "Pen" : "画笔";
      case "eraser": return english ? "Eraser" : "橡皮";
      case "highlighter": return english ? "Highlighter" : "荧光笔";
      case "undo": return english ? "Undo" : "撤销";
      case "redo": return english ? "Redo" : "重做";
      case "clearAnnotations": return english ? "Clear Annotations" : "清空批注";
      case "clearWhiteboard": return english ? "Clear Whiteboard" : "清空白板";
      case "penWidth": return english ? "Pen Width" : "画笔粗细";
      case "penColor": return english ? "Pen Color" : "画笔颜色";
      case "eraserSettings": return english ? "Eraser Settings" : "橡皮设置";
      case "opacity": return english ? "Opacity" : "不透明度";
      case "width": return english ? "Width" : "粗细";
      case "pixelValue": return english ? "{0} px" : "{0} px";
      case "percentValue": return english ? "{0}%" : "{0}%";
      case "macAndTablet": return english ? "MAC + MATEPAD" : "MAC + MATEPAD";
      case "navigation": return english ? "Main Navigation" : "主导航";
      case "connectionStatus": return english ? "Connection Status" : "连接状态";
      case "stop": return english ? "Stop" : "停止";
      case "allowMicrophone": return english ? "Allow Tablet Microphone" : "允许 Mac 使用平板麦克风";
      case "disableMicrophone": return english ? "Disable Tablet Microphone" : "关闭平板麦克风";
      case "microphoneOff": return english ? "Tablet microphone: off" : "平板麦克风：关闭";
      case "microphoneSending": return english ? "Sending microphone audio to Mac over USB" : "麦克风正在通过 USB 发送到 Mac";
      case "microphoneMacHint": return english ? "Enable the tablet microphone on Mac" : "请在 Mac 中开启平板麦克风";
      case "microphoneDenied": return english ? "Allow microphone access in Settings" : "未允许麦克风，可在设置中重新授权";
      case "microphoneError": return english ? "Check microphone permission" : "无法开启麦克风，请检查权限";
      case "microphoneForeground": return english ? "Allow microphone access again after returning" : "返回应用后请重新允许麦克风";
      case "lowLatencyOn": return english ? "Low Latency: On" : "低延迟显示：开";
      case "lowLatencyOff": return english ? "Low Latency: Off" : "低延迟显示：关";
      case "receiverHint": return english ? "Keep USB connected and start the display on Mac." : "保持数据线连接，在 Mac 中启动扩展屏幕。";
      case "capturePermissionHint": return english ? "Allow screen capture on Mac" : "请先在 Mac 上允许录屏";
      case "macNotResponding": return english ? "Mac is not responding; check it is running" : "Mac 未响应，请确认电脑仍在运行";
      case "usbChannelHint": return english ? "Check your USB cable and device authorization" : "等待 Mac USB 通道，请检查数据线与授权";
      case "connectingDisplay": return english ? "Connecting to Mac" : "正在连接 Mac";
      case "diagnosticCode": return english ? "Reconnecting. Diagnostic code: {0}" : "连接已中断，正在重试。诊断码：{0}";
      case "receiverMetrics": return english ? "USB · {0} × {1} · {2} fps · target {3} fps" : "USB · {0} × {1} · 实时 {2} 帧/秒 · 目标 {3} 帧/秒";
      case "receiverProcessing": return english ? "Tablet processing: {0} ms" : "最近一帧平板处理 {0} ms";
      case "receiverStatistics": return english ? "Last-second statistics; static content reduces frame output" : "近 1 秒统计，静止画面会减少出帧";
      case "audioPlaying": return english ? "Playing Mac audio" : "正在播放 Mac 声音";
      case "audioSelectHint": return english ? "Select MatePad Speaker in Mac audio output" : "在 Mac 声音输出中选择 MatePad 扬声器";
      case "scaleLarger": return english ? "Larger Text" : "更大字体";
      case "scaleLarge": return english ? "Large" : "较大";
      case "scaleDefault": return english ? "Default" : "默认";
      case "scaleMore": return english ? "More Space" : "较多空间";
      case "scaleMost": return english ? "Most Space" : "更多空间";
      case "roundTripTitle": return english ? "Huawei Notes Round Trip" : "华为笔记往返";
      case "roundTripDescription": return english ? "Send a PDF to Huawei Notes, annotate, and share it back to LinkDesk." : "发送 PDF 到华为笔记，批注后通过分享菜单回传 LinkDesk。";
      case "sendToNotes": return english ? "Send PDF to Huawei Notes…" : "发送 PDF 到华为笔记…";
      case "searchHelp": return english ? "Search PDF text (⌘F)" : "搜索 PDF 文字（⌘F）";
      case "searchUnavailable": return english ? "Open a PDF to search text" : "打开 PDF 后可搜索文字";
      case "modePicker": return english ? "Workspace Mode" : "工作区模式";
      case "modePickerHelp": return english ? "Switch between PDF Annotation and Live Whiteboard" : "在 PDF 批注与实时白板之间切换";
      case "cancelTransfer": return english ? "Cancel PDF Transfer" : "取消 PDF 传送";
      case "retryTransfer": return english ? "Resend PDF" : "重新发送 PDF";
      case "switching": return english ? "Switching" : "切换中";
      case "connected": return english ? "Connected" : "已连接";
      case "chooseConnection": return english ? "Choose a connection; your Mac will keep searching and switch automatically." : "选择连接方式后，Mac 会持续搜索并自动切换。";
      case "scanHint": return english ? "Scan to pair for the first time; paired tablets reconnect automatically." : "首次连接可扫码；已安装的平板客户端会自动加入房间。";
      case "discoveredDevices": return english ? "Discovered Devices" : "已发现设备";
      case "recentEmpty": return english ? "No Recent Files" : "暂无历史记录";
      case "sendPDF": return english ? "Send PDF to Tablet…" : "发送 PDF 到平板批注…";
      case "savePDF": return english ? "Save PDF As…" : "另存为 PDF…";
      case "searchMenu": return english ? "Search PDF…" : "搜索 PDF…";
      case "zoomIn": return english ? "Zoom In" : "放大";
      case "zoomOut": return english ? "Zoom Out" : "缩小";
      case "whiteboardOrigin": return english ? "Return to Canvas Origin" : "回到白板原点";
      case "fitWindow": return english ? "Fit to Window" : "适合窗口";
      case "productInitial": return english ? "L" : "L";
      case "penWidthLevels": return english ? "4 levels" : "4 档";
      case "inkFeatureHint": return english ? "PDF annotation · Live whiteboard · Shared workspace" : "PDF 批注 · 无限白板 · 双端同步";
      case "stylusHint": return english ? "Stylus hover · Pressure sensitivity · Live sync" : "触控笔悬停定位 · 压感书写 · 实时同步";
      case "usbLowLatency": return english ? "Low-latency USB connection" : "USB 超低延时连接";
      case "usbAutoHint": return english ? "Keep USB connected; your Mac sets up the connection automatically" : "保持数据线连接，Mac 会自动建立有线通道";
      case "automaticHint": return english ? "Prefer USB; discover your Mac over Wi-Fi when unplugged" : "优先 USB，无数据线时自动发现同 Wi-Fi 下的 Mac";
      case "usbOnlyHint": return english ? "USB mode uses the cable connection" : "USB 模式不使用 Wi-Fi，保持数据线连接即可";
      case "wifiHint": return english ? "Connect your tablet and Mac to the same Wi-Fi network" : "确保平板与 Mac 处于同一 Wi-Fi 网络";
      case "macPDFHint": return english ? "Open LinkDesk and a PDF on your Mac" : "Mac 端需先启动LinkDesk服务并打开 PDF";
      case "automaticHostPlaceholder": return english ? "Discover Mac automatically or enter an address" : "自动发现 Mac（也可手动输入 IP）";
      case "scanMac": return english ? "Scan Mac QR Code" : "扫描 Mac 二维码";
      case "autoConnectMac": return english ? "Connect Automatically" : "自动连接 Mac";
      case "usbConnectMac": return english ? "Connect over USB" : "通过 USB 连接 Mac";
      case "wifiConnectMac": return english ? "Connect over Wi-Fi" : "通过 Wi-Fi 连接 Mac";
      case "returnAccessibility": return english ? "Select an annotated PDF and return it to Mac" : "选择已批注 PDF 并回传到 Mac";
      case "mirrorAccessibility": return english ? "Mirror to Mac over USB" : "通过 USB 投屏到 Mac";
      case "stopMirrorAccessibility": return english ? "Stop mirroring to Mac" : "停止投屏到 Mac";
      case "eraserRange": return english ? "Eraser Range" : "当前擦除范围";
      case "eraserRing": return english ? "Show a gray ring while erasing" : "擦除时显示灰色范围圆环";
      case "secondaryMenu": return english ? "Tool Options" : "工具选项";
      case "highlighterHold": return english ? "Hold for 2 seconds to straighten" : "停顿 2 秒自动拉直";
      case "pressureEraseOn": return english ? "Pressure Erasing: On" : "重按临时擦除 开";
      case "pressureEraseOff": return english ? "Pressure Erasing: Off" : "重按临时擦除 关";
      case "sensitivityLow": return english ? "Low" : "低";
      case "sensitivityMedium": return english ? "Medium" : "中";
      case "sensitivityHigh": return english ? "High" : "高";
      case "confirm": return english ? "Confirm" : "确定";
      case "clearPDFConfirm": return english ? "Clear all PDF annotations? You can undo this." : "确定要清空全部 PDF 批注吗？清空后仍可撤销。";
      case "clearWhiteboardConfirm": return english ? "Clear the whiteboard? You can undo this." : "确定要清空白板吗？清空后仍可撤销。";
      case "mirrorForegroundHint": return english ? "Keep LinkDesk in the foreground to continue mirroring" : "全局投屏保活失败，请保持LinkDesk在前台";
      case "notesFallback": return english ? "Huawei Notes is unavailable; opened with the system PDF app" : "华为笔记不可用，已交给系统 PDF 应用";
      case "mirrorStopped": return english ? "Mirroring stopped" : "已停止投屏";
      case "returnedMac": return english ? "Returned to Mac" : "已回传到 Mac";
      case "notesOpened": return english ? "Opened in Huawei Notes; export and share back to LinkDesk after annotating" : "已在华为笔记打开，批注后请导出并分享到LinkDesk";
      case "returnSaveHint": return english ? "Annotated PDF returned; choose a save location on Mac" : "批注版已回传，请在 Mac 选择保存位置";
      case "fileSizeUnsupported": return english ? "Unsupported file size" : "文件大小不受支持";
      case "fileReadIncomplete": return english ? "Could not read the entire file" : "文件读取不完整";
      case "scanUnavailable": return english ? "Could not start the scanner" : "无法启动系统扫码服务";
      case "scanInvalid": return english ? "No valid LinkDesk pairing QR code found" : "未识别到有效的LinkDesk连接二维码";
      case "pdfDownloading": return english ? "Downloading to tablet…" : "正在下载到平板…";
      case "pdfReturning": return english ? "Returning to Mac…" : "正在回传到 Mac…";
      case "mirrorRunning": return english ? "Mirroring to Mac" : "正在投屏到 Mac";
      case "notesOpening": return english ? "Opening Huawei Notes…" : "正在用华为笔记打开…";
      case "noReturnTask": return english ? "No PDF is waiting to be returned" : "没有等待回传的 PDF 任务";
      case "switchUSBFirst": return english ? "Switch to USB first" : "请先切换到 USB 连接";
      case "waitConnection": return english ? "Waiting for connection" : "等待连接";
      case "lowLatency": return english ? "Low Latency" : "低延迟显示";
      default: return key;
    }
  }
  static get productName(): string { return Strings.value("productName"); }
  static get productSubtitle(): string { return Strings.value("productSubtitle"); }
  static get workspaces(): string { return Strings.value("workspaces"); }
  static get homeTitle(): string { return Strings.value("homeTitle"); }
  static get displayTitle(): string { return Strings.value("displayTitle"); }
  static get pdfTitle(): string { return Strings.value("pdfTitle"); }
  static get whiteboardTitle(): string { return Strings.value("whiteboardTitle"); }
  static get mirrorTitle(): string { return Strings.value("mirrorTitle"); }
  static get homeSubtitle(): string { return Strings.value("homeSubtitle"); }
  static get displaySubtitle(): string { return Strings.value("displaySubtitle"); }
  static get pdfSubtitle(): string { return Strings.value("pdfSubtitle"); }
  static get whiteboardSubtitle(): string { return Strings.value("whiteboardSubtitle"); }
  static get mirrorSubtitle(): string { return Strings.value("mirrorSubtitle"); }
  static get heroTitle(): string { return Strings.value("heroTitle"); }
  static get heroSubtitle(): string { return Strings.value("heroSubtitle"); }
  static get connectionHint(): string { return Strings.value("connectionHint"); }
  static get pairingCode(): string { return Strings.value("pairingCode"); }
  static get pairingCodeValue(): string { return Strings.value("pairingCodeValue"); }
  static get pairingTitle(): string { return Strings.value("pairingTitle"); }
  static get pairingSubtitle(): string { return Strings.value("pairingSubtitle"); }
  static get connectTablet(): string { return Strings.value("connectTablet"); }
  static get connectMac(): string { return Strings.value("connectMac"); }
  static get connect(): string { return Strings.value("connect"); }
  static get reconnect(): string { return Strings.value("reconnect"); }
  static get done(): string { return Strings.value("done"); }
  static get cancel(): string { return Strings.value("cancel"); }
  static get hide(): string { return Strings.value("hide"); }
  static get close(): string { return Strings.value("close"); }
  static get backHome(): string { return Strings.value("backHome"); }
  static get appearance(): string { return Strings.value("appearance"); }
  static get themeAutomatic(): string { return Strings.value("themeAutomatic"); }
  static get themeLight(): string { return Strings.value("themeLight"); }
  static get themeDark(): string { return Strings.value("themeDark"); }
  static get themeHelp(): string { return Strings.value("themeHelp"); }
  static get themeAccessibility(): string { return Strings.value("themeAccessibility"); }
  static get stateDisconnected(): string { return Strings.value("stateDisconnected"); }
  static get stateUSBConnected(): string { return Strings.value("stateUSBConnected"); }
  static get stateWaitingForMode(): string { return Strings.value("stateWaitingForMode"); }
  static get stateWorking(): string { return Strings.value("stateWorking"); }
  static get stateError(): string { return Strings.value("stateError"); }
  static get transportWifi(): string { return Strings.value("transportWifi"); }
  static get transportUSB(): string { return Strings.value("transportUSB"); }
  static get transportWireless(): string { return Strings.value("transportWireless"); }
  static get pdfEmptyTitle(): string { return Strings.value("pdfEmptyTitle"); }
  static get pdfEmptyDescription(): string { return Strings.value("pdfEmptyDescription"); }
  static get openPDF(): string { return Strings.value("openPDF"); }
  static get waitPDFTitle(): string { return Strings.value("waitPDFTitle"); }
  static get waitPDFDescription(): string { return Strings.value("waitPDFDescription"); }
  static get mirrorEmptyTitle(): string { return Strings.value("mirrorEmptyTitle"); }
  static get mirrorEmptyDescription(): string { return Strings.value("mirrorEmptyDescription"); }
  static get startMirror(): string { return Strings.value("startMirror"); }
  static get stopMirror(): string { return Strings.value("stopMirror"); }
  static get startDisplay(): string { return Strings.value("startDisplay"); }
  static get stopDisplay(): string { return Strings.value("stopDisplay"); }
  static get displayEmptyTitle(): string { return Strings.value("displayEmptyTitle"); }
  static get displayEmptyDescription(): string { return Strings.value("displayEmptyDescription"); }
  static get recentFiles(): string { return Strings.value("recentFiles"); }
  static get displaySettings(): string { return Strings.value("displaySettings"); }
  static get displayScale(): string { return Strings.value("displayScale"); }
  static get displayScaleDescription(): string { return Strings.value("displayScaleDescription"); }
  static get frameRate(): string { return Strings.value("frameRate"); }
  static get frameRateDescription(): string { return Strings.value("frameRateDescription"); }
  static get frameRateValue(): string { return Strings.value("frameRateValue"); }
  static get arrangeDisplays(): string { return Strings.value("arrangeDisplays"); }
  static get testDisplay(): string { return Strings.value("testDisplay"); }
  static get audioSettings(): string { return Strings.value("audioSettings"); }
  static get tabletSpeaker(): string { return Strings.value("tabletSpeaker"); }
  static get useTablet(): string { return Strings.value("useTablet"); }
  static get restoreMac(): string { return Strings.value("restoreMac"); }
  static get tabletMicrophone(): string { return Strings.value("tabletMicrophone"); }
  static get microphoneDescription(): string { return Strings.value("microphoneDescription"); }
  static get audioDelay(): string { return Strings.value("audioDelay"); }
  static get audioDelayDescription(): string { return Strings.value("audioDelayDescription"); }
  static get milliseconds(): string { return Strings.value("milliseconds"); }
  static get chooseMode(): string { return Strings.value("chooseMode"); }
  static get usbHint(): string { return Strings.value("usbHint"); }
  static get scanPairing(): string { return Strings.value("scanPairing"); }
  static get hostAddress(): string { return Strings.value("hostAddress"); }
  static get hostPlaceholder(): string { return Strings.value("hostPlaceholder"); }
  static get pairingPlaceholder(): string { return Strings.value("pairingPlaceholder"); }
  static get invalidPairing(): string { return Strings.value("invalidPairing"); }
  static get genericError(): string { return Strings.value("genericError"); }
  static get connectionMethod(): string { return Strings.value("connectionMethod"); }
  static get automatic(): string { return Strings.value("automatic"); }
  static get usbOnly(): string { return Strings.value("usbOnly"); }
  static get wifiOnly(): string { return Strings.value("wifiOnly"); }
  static get inkTools(): string { return Strings.value("inkTools"); }
  static get collapseTools(): string { return Strings.value("collapseTools"); }
  static get expandTools(): string { return Strings.value("expandTools"); }
  static get returnPDF(): string { return Strings.value("returnPDF"); }
  static get searchPDF(): string { return Strings.value("searchPDF"); }
  static get searchPlaceholder(): string { return Strings.value("searchPlaceholder"); }
  static get noResults(): string { return Strings.value("noResults"); }
  static get previousMatch(): string { return Strings.value("previousMatch"); }
  static get nextMatch(): string { return Strings.value("nextMatch"); }
  static get closeSearch(): string { return Strings.value("closeSearch"); }
  static get pen(): string { return Strings.value("pen"); }
  static get eraser(): string { return Strings.value("eraser"); }
  static get highlighter(): string { return Strings.value("highlighter"); }
  static get undo(): string { return Strings.value("undo"); }
  static get redo(): string { return Strings.value("redo"); }
  static get clearAnnotations(): string { return Strings.value("clearAnnotations"); }
  static get clearWhiteboard(): string { return Strings.value("clearWhiteboard"); }
  static get penWidth(): string { return Strings.value("penWidth"); }
  static get penColor(): string { return Strings.value("penColor"); }
  static get eraserSettings(): string { return Strings.value("eraserSettings"); }
  static get opacity(): string { return Strings.value("opacity"); }
  static get width(): string { return Strings.value("width"); }
  static get pixelValue(): string { return Strings.value("pixelValue"); }
  static get percentValue(): string { return Strings.value("percentValue"); }
  static get macAndTablet(): string { return Strings.value("macAndTablet"); }
  static get navigation(): string { return Strings.value("navigation"); }
  static get connectionStatus(): string { return Strings.value("connectionStatus"); }
  static get stop(): string { return Strings.value("stop"); }
  static get allowMicrophone(): string { return Strings.value("allowMicrophone"); }
  static get disableMicrophone(): string { return Strings.value("disableMicrophone"); }
  static get microphoneOff(): string { return Strings.value("microphoneOff"); }
  static get microphoneSending(): string { return Strings.value("microphoneSending"); }
  static get microphoneMacHint(): string { return Strings.value("microphoneMacHint"); }
  static get microphoneDenied(): string { return Strings.value("microphoneDenied"); }
  static get microphoneError(): string { return Strings.value("microphoneError"); }
  static get microphoneForeground(): string { return Strings.value("microphoneForeground"); }
  static get lowLatencyOn(): string { return Strings.value("lowLatencyOn"); }
  static get lowLatencyOff(): string { return Strings.value("lowLatencyOff"); }
  static get receiverHint(): string { return Strings.value("receiverHint"); }
  static get capturePermissionHint(): string { return Strings.value("capturePermissionHint"); }
  static get macNotResponding(): string { return Strings.value("macNotResponding"); }
  static get usbChannelHint(): string { return Strings.value("usbChannelHint"); }
  static get connectingDisplay(): string { return Strings.value("connectingDisplay"); }
  static get diagnosticCode(): string { return Strings.value("diagnosticCode"); }
  static get receiverMetrics(): string { return Strings.value("receiverMetrics"); }
  static get receiverProcessing(): string { return Strings.value("receiverProcessing"); }
  static get receiverStatistics(): string { return Strings.value("receiverStatistics"); }
  static get audioPlaying(): string { return Strings.value("audioPlaying"); }
  static get audioSelectHint(): string { return Strings.value("audioSelectHint"); }
  static get scaleLarger(): string { return Strings.value("scaleLarger"); }
  static get scaleLarge(): string { return Strings.value("scaleLarge"); }
  static get scaleDefault(): string { return Strings.value("scaleDefault"); }
  static get scaleMore(): string { return Strings.value("scaleMore"); }
  static get scaleMost(): string { return Strings.value("scaleMost"); }
  static get roundTripTitle(): string { return Strings.value("roundTripTitle"); }
  static get roundTripDescription(): string { return Strings.value("roundTripDescription"); }
  static get sendToNotes(): string { return Strings.value("sendToNotes"); }
  static get searchHelp(): string { return Strings.value("searchHelp"); }
  static get searchUnavailable(): string { return Strings.value("searchUnavailable"); }
  static get modePicker(): string { return Strings.value("modePicker"); }
  static get modePickerHelp(): string { return Strings.value("modePickerHelp"); }
  static get cancelTransfer(): string { return Strings.value("cancelTransfer"); }
  static get retryTransfer(): string { return Strings.value("retryTransfer"); }
  static get switching(): string { return Strings.value("switching"); }
  static get connected(): string { return Strings.value("connected"); }
  static get chooseConnection(): string { return Strings.value("chooseConnection"); }
  static get scanHint(): string { return Strings.value("scanHint"); }
  static get discoveredDevices(): string { return Strings.value("discoveredDevices"); }
  static get recentEmpty(): string { return Strings.value("recentEmpty"); }
  static get sendPDF(): string { return Strings.value("sendPDF"); }
  static get savePDF(): string { return Strings.value("savePDF"); }
  static get searchMenu(): string { return Strings.value("searchMenu"); }
  static get zoomIn(): string { return Strings.value("zoomIn"); }
  static get zoomOut(): string { return Strings.value("zoomOut"); }
  static get whiteboardOrigin(): string { return Strings.value("whiteboardOrigin"); }
  static get fitWindow(): string { return Strings.value("fitWindow"); }
  static get productInitial(): string { return Strings.value("productInitial"); }
  static get penWidthLevels(): string { return Strings.value("penWidthLevels"); }
  static get inkFeatureHint(): string { return Strings.value("inkFeatureHint"); }
  static get stylusHint(): string { return Strings.value("stylusHint"); }
  static get usbLowLatency(): string { return Strings.value("usbLowLatency"); }
  static get usbAutoHint(): string { return Strings.value("usbAutoHint"); }
  static get automaticHint(): string { return Strings.value("automaticHint"); }
  static get usbOnlyHint(): string { return Strings.value("usbOnlyHint"); }
  static get wifiHint(): string { return Strings.value("wifiHint"); }
  static get macPDFHint(): string { return Strings.value("macPDFHint"); }
  static get automaticHostPlaceholder(): string { return Strings.value("automaticHostPlaceholder"); }
  static get scanMac(): string { return Strings.value("scanMac"); }
  static get autoConnectMac(): string { return Strings.value("autoConnectMac"); }
  static get usbConnectMac(): string { return Strings.value("usbConnectMac"); }
  static get wifiConnectMac(): string { return Strings.value("wifiConnectMac"); }
  static get returnAccessibility(): string { return Strings.value("returnAccessibility"); }
  static get mirrorAccessibility(): string { return Strings.value("mirrorAccessibility"); }
  static get stopMirrorAccessibility(): string { return Strings.value("stopMirrorAccessibility"); }
  static get eraserRange(): string { return Strings.value("eraserRange"); }
  static get eraserRing(): string { return Strings.value("eraserRing"); }
  static get secondaryMenu(): string { return Strings.value("secondaryMenu"); }
  static get highlighterHold(): string { return Strings.value("highlighterHold"); }
  static get pressureEraseOn(): string { return Strings.value("pressureEraseOn"); }
  static get pressureEraseOff(): string { return Strings.value("pressureEraseOff"); }
  static get sensitivityLow(): string { return Strings.value("sensitivityLow"); }
  static get sensitivityMedium(): string { return Strings.value("sensitivityMedium"); }
  static get sensitivityHigh(): string { return Strings.value("sensitivityHigh"); }
  static get confirm(): string { return Strings.value("confirm"); }
  static get clearPDFConfirm(): string { return Strings.value("clearPDFConfirm"); }
  static get clearWhiteboardConfirm(): string { return Strings.value("clearWhiteboardConfirm"); }
  static get mirrorForegroundHint(): string { return Strings.value("mirrorForegroundHint"); }
  static get notesFallback(): string { return Strings.value("notesFallback"); }
  static get mirrorStopped(): string { return Strings.value("mirrorStopped"); }
  static get returnedMac(): string { return Strings.value("returnedMac"); }
  static get notesOpened(): string { return Strings.value("notesOpened"); }
  static get returnSaveHint(): string { return Strings.value("returnSaveHint"); }
  static get fileSizeUnsupported(): string { return Strings.value("fileSizeUnsupported"); }
  static get fileReadIncomplete(): string { return Strings.value("fileReadIncomplete"); }
  static get scanUnavailable(): string { return Strings.value("scanUnavailable"); }
  static get scanInvalid(): string { return Strings.value("scanInvalid"); }
  static get pdfDownloading(): string { return Strings.value("pdfDownloading"); }
  static get pdfReturning(): string { return Strings.value("pdfReturning"); }
  static get mirrorRunning(): string { return Strings.value("mirrorRunning"); }
  static get notesOpening(): string { return Strings.value("notesOpening"); }
  static get noReturnTask(): string { return Strings.value("noReturnTask"); }
  static get switchUSBFirst(): string { return Strings.value("switchUSBFirst"); }
  static get waitConnection(): string { return Strings.value("waitConnection"); }
  static get lowLatency(): string { return Strings.value("lowLatency"); }
}

export enum ConnectionState {
  disconnected = "disconnected",
  usbConnected = "usbConnected",
  waitingForMode = "waitingForMode",
  working = "working",
  error = "error",
}
export class ConnectionPresentation {
  static title(state: ConnectionState): string {
    switch (state) {
      case ConnectionState.disconnected: return Strings.stateDisconnected;
      case ConnectionState.usbConnected: return Strings.stateUSBConnected;
      case ConnectionState.waitingForMode: return Strings.stateWaitingForMode;
      case ConnectionState.working: return Strings.stateWorking;
      case ConnectionState.error: return Strings.stateError;
    }
  }
  static color(state: ConnectionState, dark: boolean): string {
    switch (state) {
      case ConnectionState.disconnected: return DT.tertiary(dark);
      case ConnectionState.usbConnected: return DT.accent(dark);
      case ConnectionState.waitingForMode: return DT.warning(dark);
      case ConnectionState.working: return DT.success(dark);
      case ConnectionState.error: return DT.error(dark);
    }
  }
}
