// 自动生成，勿手改。Source: design-tokens.json + strings.json; python3 scripts/generate-design.py

import AppKit
import SwiftUI

enum DT {
  private static func color(_ light: String, _ dark: String) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
      let raw = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      let hex = String(raw.dropFirst()); let value = UInt64(hex, radix: 16) ?? 0
      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
        blue: CGFloat(value & 255) / 255, alpha: hex.count == 8 ? CGFloat((value >> 24) & 255) / 255 : 1)
    }))
  }
  static var accent: Color { color("#3979DE", "#78ACFF") }
  static var accentSoft: Color { color("#E7EFFD", "#203451") }
  static var creative: Color { color("#19856E", "#58D3B7") }
  static var canvas: Color { color("#F4F6FA", "#0E1523") }
  static var surface: Color { color("#FFFFFF", "#182337") }
  static var control: Color { color("#EDF1F8", "#223149") }
  static var glass: Color { color("#CCF8FAFF", "#CC16243A") }
  static var text: Color { color("#152441", "#E8EEF8") }
  static var secondary: Color { color("#596B85", "#A5B4CA") }
  static var tertiary: Color { color("#73839A", "#8B9DB7") }
  static var border: Color { color("#DFE6F1", "#30425F") }
  static var success: Color { color("#19856E", "#58D3B7") }
  static var warning: Color { color("#986808", "#F0C267") }
  static var error: Color { color("#BD3949", "#FF9FA9") }
  static var onAccent: Color { color("#FFFFFF", "#0E1523") }
  static var paper: Color { color("#FFFFFF", "#FFFFFF") }
  static var ink: Color { color("#152441", "#152441") }
  static var video: Color { color("#000000", "#000000") }
  static var clear: Color { color("#00000000", "#00000000") }
  static var scrim: Color { color("#19283C", "#000000") }
  static var selection: Color { color("#D7E7FF", "#2C4973") }
  static var panelColor0: Color { color("#20FFFFFF", "#20FFFFFF") }
  static var panelColor1: Color { color("#00FFFFFF", "#00FFFFFF") }
  static var panelColor2: Color { color("#08000000", "#08000000") }
  static var panelColor3: Color { color("#407888A0", "#407888A0") }
  static var panelColor4: Color { color("#B3FFFFFF", "#B3FFFFFF") }
  static var panelColor5: Color { color("#22000000", "#22000000") }
  enum font {
    static let caption: CGFloat = 12
    static let body: CGFloat = 14
    static let label: CGFloat = 17
    static let section: CGFloat = 22
    static let title: CGFloat = 30
  }
  enum spacing {
    static let s0: CGFloat = 0
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s28: CGFloat = 28
    static let s32: CGFloat = 32
    static let s36: CGFloat = 36
    static let s40: CGFloat = 40
    static let s44: CGFloat = 44
    static let s48: CGFloat = 48
    static let s52: CGFloat = 52
    static let s56: CGFloat = 56
    static let s60: CGFloat = 60
    static let s64: CGFloat = 64
    static let s68: CGFloat = 68
    static let s72: CGFloat = 72
    static let s76: CGFloat = 76
    static let s80: CGFloat = 80
    static let s84: CGFloat = 84
    static let s88: CGFloat = 88
    static let s92: CGFloat = 92
    static let s96: CGFloat = 96
  }
  enum radius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 20
    static let large: CGFloat = 28
  }
  enum layout {
    static let touchTarget: CGFloat = 48
    static let macControl: CGFloat = 28
    static let sidebar: CGFloat = 224
    static let sidebarMin: CGFloat = 208
    static let sidebarMax: CGFloat = 272
    static let wideBreakpoint: CGFloat = 840
    static let singleColumnBreakpoint: CGFloat = 600
    static let pageMax: CGFloat = 960
    static let pagePadding: CGFloat = 32
    static let compactPadding: CGFloat = 16
    static let settingRowMac: CGFloat = 64
    static let settingRowTablet: CGFloat = 80
    static let bottomNavigation: CGFloat = 80
    static let iconSmall: CGFloat = 16
    static let icon: CGFloat = 24
    static let iconTile: CGFloat = 48
    static let statusDot: CGFloat = 8
    static let cardMinHeight: CGFloat = 176
    static let headerMinHeight: CGFloat = 80
    static let menuMaxWidth: CGFloat = 384
    static let toolbarHeight: CGFloat = 64
    static let formMaxWidth: CGFloat = 480
    static let stroke: CGFloat = 1
    static let mirrorWindowWidth: CGFloat = 960
    static let mirrorWindowHeight: CGFloat = 640
    static let mirrorWindowFallbackHeight: CGFloat = 900
    static let mirrorWindowMaxHeight: CGFloat = 720
    static let mirrorWindowVisibleFraction: CGFloat = 0.78
    static let mirrorWindowMinWidth: CGFloat = 720
    static let mirrorWindowMinHeight: CGFloat = 480
  }
  enum dimensions {
    static let d120: CGFloat = 120
    static let d112: CGFloat = 112
    static let d144: CGFloat = 144
    static let d208: CGFloat = 208
    static let d220: CGFloat = 220
    static let d420: CGFloat = 420
    static let d320: CGFloat = 320
    static let d1000: CGFloat = 1000
    static let d680: CGFloat = 680
    static let d184: CGFloat = 184
    static let d360: CGFloat = 360
    static let d380: CGFloat = 380
    static let d392: CGFloat = 392
    static let d1160: CGFloat = 1160
    static let d800: CGFloat = 800
    static let panelValue3: CGFloat = 3
    static let panelValue6: CGFloat = 6
    static let panelValue10: CGFloat = 10
    static let panelValue11: CGFloat = 11
    static let panelValue12: CGFloat = 12
    static let panelValue13: CGFloat = 13
    static let panelValue14: CGFloat = 14
    static let panelValue18: CGFloat = 18
    static let panelValue24: CGFloat = 24
    static let panelValue32: CGFloat = 32
    static let panelValue48: CGFloat = 48
    static let panelValue224: CGFloat = 224
    static let panelValue336: CGFloat = 336
  }
  enum motion {
    static let feedback: Double = 0.12
    static let menuEnter: Double = 0.24
    static let menuExit: Double = 0.18
    static let collapse: Double = 0.52
    static let none: Double = 0.0
    static let notice: Double = 2.8
    static let errorNotice: Double = 4.2
    static let panelFade: Double = 0.16
    static let muted: Double = 0.6
    static let subtle: Double = 0.08
    static let border: Double = 0.16
    static let pressed: Double = 0.84
    static let menuScale: Double = 0.96
    static let exitScale: Double = 0.98
    static let searchScale: Double = 0.96
    static func standard(_ duration: Double) -> Animation { .timingCurve(0.42, 0, 0.58, 1, duration: duration) }
    static func enter(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    static func exit(_ duration: Double) -> Animation { .timingCurve(0.4, 0, 1, 1, duration: duration) }
  }
  enum icon {
    static let home = "square.grid.2x2"
    static let display = "display.2"
    static let pdf = "doc.richtext"
    static let whiteboard = "pencil.and.outline"
    static let mirror = "ipad.and.arrow.forward"
  }
  enum inkPalette {
    static let ink = "#152441"
    static let red = "#e74c3c"
    static let blue = "#2980b9"
    static let green = "#27ae60"
    static let purple = "#8e44ad"
    static let orange = "#f39c12"
    static let white = "#ffffff"
    static let color7 = "#2269ef"
    static let color8 = "#e45a4f"
    static let color9 = "#1b9a7e"
    static let highlight = "#ffe56f"
  }
}

enum L10n {
  static let language = Locale.preferredLanguages.first ?? "zh-Hans"
  static func format(_ key: String, _ args: CustomStringConvertible...) -> String {
    var result = value(key)
    for (i, arg) in args.enumerated() { result = result.replacingOccurrences(of: "{\(i)}", with: arg.description) }
    return result
  }
  static func source(_ key: String) -> String { value(key, english: false) }
  static func value(_ key: String, english: Bool = language.hasPrefix("en")) -> String {
    switch key {
    case "productName": return english ? "LinkDesk" : "LinkDesk"
    case "productSubtitle": return english ? "Your workspace across screens" : "你的跨屏工作空间"
    case "workspaces": return english ? "Workspaces" : "工作空间"
    case "homeTitle": return english ? "Workspace" : "工作台"
    case "displayTitle": return english ? "Extended Display" : "扩展屏幕"
    case "pdfTitle": return english ? "PDF Annotation" : "PDF 批注"
    case "whiteboardTitle": return english ? "Live Whiteboard" : "实时白板"
    case "mirrorTitle": return english ? "Tablet Mirroring" : "平板投屏"
    case "homeSubtitle": return english ? "Bring your Mac and MatePad together." : "让 Mac 与 MatePad 一起工作。"
    case "displaySubtitle": return english ? "Use your MatePad as an extended Mac display." : "把 MatePad 变成 Mac 的高清扩展屏幕。"
    case "pdfSubtitle": return english ? "Write on your tablet, read and organize on your Mac." : "在平板上书写，在 Mac 上同步阅读与整理。"
    case "whiteboardSubtitle": return english ? "One canvas. Room for every idea." : "一块画布，让想法自由延伸。"
    case "mirrorSubtitle": return english ? "Bring tablet notes and presentations to your Mac." : "将平板上的笔记、演示和灵感带到 Mac。"
    case "heroTitle": return english ? "Ideas flow across screens." : "让灵感，在屏幕间流动。"
    case "heroSubtitle": return english ? "Extend your desktop, annotate, or think together." : "扩展桌面，随手批注，或一起构思。"
    case "connectionHint": return english ? "Use USB for display and mirroring; PDF and whiteboard also support Wi-Fi." : "扩展屏幕与平板投屏使用 USB；PDF 和白板也支持 Wi-Fi。"
    case "pairingCode": return english ? "Pairing code" : "配对码"
    case "pairingCodeValue": return english ? "Pairing code {0}" : "配对码 {0}"
    case "pairingTitle": return english ? "Connect & Pair" : "连接与配对"
    case "pairingSubtitle": return english ? "Choose a connection and use the same pairing code." : "选择连接方式，使用相同的配对码。"
    case "connectTablet": return english ? "Connect Tablet" : "连接平板"
    case "connectMac": return english ? "Connect to Mac" : "连接 Mac"
    case "connect": return english ? "Connect" : "连接"
    case "reconnect": return english ? "Reconnect" : "重新连接"
    case "done": return english ? "Done" : "完成"
    case "cancel": return english ? "Cancel" : "取消"
    case "hide": return english ? "Hide" : "隐藏"
    case "close": return english ? "Close" : "关闭"
    case "backHome": return english ? "Back to Workspace" : "返回工作台"
    case "appearance": return english ? "Appearance" : "外观"
    case "themeAutomatic": return english ? "System" : "跟随系统"
    case "themeLight": return english ? "Light" : "浅色"
    case "themeDark": return english ? "Dark" : "深色"
    case "themeHelp": return english ? "Follow your Mac appearance, or sync a light or dark theme." : "跟随 Mac 系统外观，或选择两端同步的浅色／深色主题。"
    case "themeAccessibility": return english ? "Change appearance on both devices" : "切换外观，两端同步"
    case "stateDisconnected": return english ? "Disconnected" : "未连接"
    case "stateUSBConnected": return english ? "USB connected" : "USB 已连接"
    case "stateWaitingForMode": return english ? "Choose a mode on your tablet" : "等待平板选择模式"
    case "stateWorking": return english ? "Working" : "工作中"
    case "stateError": return english ? "Connection issue" : "异常"
    case "transportWifi": return english ? "Wi-Fi connected" : "Wi-Fi 已连接"
    case "transportUSB": return english ? "USB" : "USB"
    case "transportWireless": return english ? "Wi-Fi" : "Wi-Fi"
    case "pdfEmptyTitle": return english ? "Start with a PDF" : "从一份 PDF 开始"
    case "pdfEmptyDescription": return english ? "Open a PDF on your Mac and write naturally on your tablet." : "在 Mac 打开文档，在平板上自然书写。"
    case "openPDF": return english ? "Open PDF…" : "打开 PDF…"
    case "waitPDFTitle": return english ? "Waiting for a PDF" : "等待 Mac 打开 PDF"
    case "waitPDFDescription": return english ? "Open a PDF on your Mac to read and annotate here." : "在 Mac 打开文档后，即可在此阅读与批注。"
    case "mirrorEmptyTitle": return english ? "Bring your tablet to your Mac" : "把平板画面带到 Mac"
    case "mirrorEmptyDescription": return english ? "Connect with USB, then allow screen capture on your tablet." : "保持 USB 连接，启动后在平板允许录屏。"
    case "startMirror": return english ? "Start Mirroring" : "开始平板投屏"
    case "stopMirror": return english ? "Stop Mirroring" : "停止平板投屏"
    case "startDisplay": return english ? "Start Display" : "启动扩展"
    case "stopDisplay": return english ? "Stop Display" : "停止扩展"
    case "displayEmptyTitle": return english ? "Connect your MatePad" : "连接你的 MatePad"
    case "displayEmptyDescription": return english ? "Connect with USB, then select Extended Display." : "连接 USB 数据线，再选择扩展屏幕。"
    case "recentFiles": return english ? "Recent Files" : "最近使用"
    case "displaySettings": return english ? "Display" : "显示"
    case "displayScale": return english ? "Workspace Size" : "工作空间大小"
    case "displayScaleDescription": return english ? "Choose a scale for reading or multitasking." : "选择适合阅读或多任务的显示比例。"
    case "frameRate": return english ? "Target Frame Rate" : "目标帧率"
    case "frameRateDescription": return english ? "Higher rates depend on your Mac, tablet, and connection." : "更高帧率取决于 Mac、平板与连接性能。"
    case "frameRateValue": return english ? "{0} fps" : "{0} 帧/秒"
    case "arrangeDisplays": return english ? "Arrange Displays…" : "排列显示器…"
    case "testDisplay": return english ? "Show Test Pattern" : "显示测试画面"
    case "audioSettings": return english ? "Audio & Microphone" : "声音与麦克风"
    case "tabletSpeaker": return english ? "Tablet Speaker" : "平板扬声器"
    case "useTablet": return english ? "Use Tablet" : "使用平板"
    case "restoreMac": return english ? "Restore Mac" : "恢复 Mac"
    case "tabletMicrophone": return english ? "Tablet Microphone" : "平板麦克风"
    case "microphoneDescription": return english ? "Use the tablet microphone as Mac input." : "允许平板麦克风作为 Mac 输入。"
    case "audioDelay": return english ? "Mac Audio Delay" : "Mac 声音延后"
    case "audioDelayDescription": return english ? "Adjust audio and video alignment." : "调整音画同步。"
    case "milliseconds": return english ? "{0} ms" : "{0} ms"
    case "chooseMode": return english ? "Choose a Workspace" : "选择工作空间"
    case "usbHint": return english ? "Connect and unlock your tablet using USB." : "使用 USB 数据线连接并解锁平板。"
    case "scanPairing": return english ? "Scan to Pair" : "扫码连接"
    case "hostAddress": return english ? "Mac Address" : "Mac 地址"
    case "hostPlaceholder": return english ? "Enter your Mac address" : "输入 Mac 地址"
    case "pairingPlaceholder": return english ? "Enter the six-character pairing code" : "输入六位配对码"
    case "invalidPairing": return english ? "Enter a six-character pairing code using letters and numbers." : "请输入六位字母或数字配对码。"
    case "genericError": return english ? "Check your cable or network, then retry." : "连接遇到问题，请检查数据线或网络后重试。"
    case "connectionMethod": return english ? "Connection" : "连接方式"
    case "automatic": return english ? "Automatic" : "自动选择"
    case "usbOnly": return english ? "USB Only" : "仅 USB"
    case "wifiOnly": return english ? "Wi-Fi Only" : "仅 Wi-Fi"
    case "inkTools": return english ? "Writing Tools" : "书写工具"
    case "collapseTools": return english ? "Collapse Toolbar" : "收起工具栏"
    case "expandTools": return english ? "Expand Toolbar" : "展开工具栏"
    case "returnPDF": return english ? "Return Annotated PDF" : "回传批注"
    case "searchPDF": return english ? "Search PDF" : "搜索 PDF"
    case "searchPlaceholder": return english ? "Search PDF text" : "搜索 PDF 文字"
    case "noResults": return english ? "No results" : "无结果"
    case "previousMatch": return english ? "Previous Match" : "上一个匹配"
    case "nextMatch": return english ? "Next Match" : "下一个匹配"
    case "closeSearch": return english ? "Close Search" : "关闭搜索"
    case "pen": return english ? "Pen" : "画笔"
    case "eraser": return english ? "Eraser" : "橡皮"
    case "highlighter": return english ? "Highlighter" : "荧光笔"
    case "undo": return english ? "Undo" : "撤销"
    case "redo": return english ? "Redo" : "重做"
    case "clearAnnotations": return english ? "Clear Annotations" : "清空批注"
    case "clearWhiteboard": return english ? "Clear Whiteboard" : "清空白板"
    case "penWidth": return english ? "Pen Width" : "画笔粗细"
    case "penColor": return english ? "Pen Color" : "画笔颜色"
    case "eraserSettings": return english ? "Eraser Settings" : "橡皮设置"
    case "opacity": return english ? "Opacity" : "不透明度"
    case "width": return english ? "Width" : "粗细"
    case "pixelValue": return english ? "{0} px" : "{0} px"
    case "percentValue": return english ? "{0}%" : "{0}%"
    case "macAndTablet": return english ? "MAC + MATEPAD" : "MAC + MATEPAD"
    case "navigation": return english ? "Main Navigation" : "主导航"
    case "connectionStatus": return english ? "Connection Status" : "连接状态"
    case "stop": return english ? "Stop" : "停止"
    case "allowMicrophone": return english ? "Allow Tablet Microphone" : "允许 Mac 使用平板麦克风"
    case "disableMicrophone": return english ? "Disable Tablet Microphone" : "关闭平板麦克风"
    case "microphoneOff": return english ? "Tablet microphone: off" : "平板麦克风：关闭"
    case "microphoneSending": return english ? "Sending microphone audio to Mac over USB" : "麦克风正在通过 USB 发送到 Mac"
    case "microphoneMacHint": return english ? "Enable the tablet microphone on Mac" : "请在 Mac 中开启平板麦克风"
    case "microphoneDenied": return english ? "Allow microphone access in Settings" : "未允许麦克风，可在设置中重新授权"
    case "microphoneError": return english ? "Check microphone permission" : "无法开启麦克风，请检查权限"
    case "microphoneForeground": return english ? "Allow microphone access again after returning" : "返回应用后请重新允许麦克风"
    case "lowLatencyOn": return english ? "Low Latency: On" : "低延迟显示：开"
    case "lowLatencyOff": return english ? "Low Latency: Off" : "低延迟显示：关"
    case "receiverHint": return english ? "Keep USB connected and start the display on Mac." : "保持数据线连接，在 Mac 中启动扩展屏幕。"
    case "capturePermissionHint": return english ? "Allow screen capture on Mac" : "请先在 Mac 上允许录屏"
    case "macNotResponding": return english ? "Mac is not responding; check it is running" : "Mac 未响应，请确认电脑仍在运行"
    case "usbChannelHint": return english ? "Check your USB cable and device authorization" : "等待 Mac USB 通道，请检查数据线与授权"
    case "connectingDisplay": return english ? "Connecting to Mac" : "正在连接 Mac"
    case "diagnosticCode": return english ? "Reconnecting. Diagnostic code: {0}" : "连接已中断，正在重试。诊断码：{0}"
    case "receiverMetrics": return english ? "USB · {0} × {1} · {2} fps · target {3} fps" : "USB · {0} × {1} · 实时 {2} 帧/秒 · 目标 {3} 帧/秒"
    case "receiverProcessing": return english ? "Tablet processing: {0} ms" : "最近一帧平板处理 {0} ms"
    case "receiverStatistics": return english ? "Last-second statistics; static content reduces frame output" : "近 1 秒统计，静止画面会减少出帧"
    case "audioPlaying": return english ? "Playing Mac audio" : "正在播放 Mac 声音"
    case "audioSelectHint": return english ? "Select MatePad Speaker in Mac audio output" : "在 Mac 声音输出中选择 MatePad 扬声器"
    case "scaleLarger": return english ? "Larger Text" : "更大字体"
    case "scaleLarge": return english ? "Large" : "较大"
    case "scaleDefault": return english ? "Default" : "默认"
    case "scaleMore": return english ? "More Space" : "较多空间"
    case "scaleMost": return english ? "Most Space" : "更多空间"
    case "roundTripTitle": return english ? "Huawei Notes Round Trip" : "华为笔记往返"
    case "roundTripDescription": return english ? "Send a PDF to Huawei Notes, annotate, and share it back to LinkDesk." : "发送 PDF 到华为笔记，批注后通过分享菜单回传 LinkDesk。"
    case "sendToNotes": return english ? "Send PDF to Huawei Notes…" : "发送 PDF 到华为笔记…"
    case "searchHelp": return english ? "Search PDF text (⌘F)" : "搜索 PDF 文字（⌘F）"
    case "searchUnavailable": return english ? "Open a PDF to search text" : "打开 PDF 后可搜索文字"
    case "modePicker": return english ? "Workspace Mode" : "工作区模式"
    case "modePickerHelp": return english ? "Switch between PDF Annotation and Live Whiteboard" : "在 PDF 批注与实时白板之间切换"
    case "cancelTransfer": return english ? "Cancel PDF Transfer" : "取消 PDF 传送"
    case "retryTransfer": return english ? "Resend PDF" : "重新发送 PDF"
    case "switching": return english ? "Switching" : "切换中"
    case "connected": return english ? "Connected" : "已连接"
    case "chooseConnection": return english ? "Choose a connection; your Mac will keep searching and switch automatically." : "选择连接方式后，Mac 会持续搜索并自动切换。"
    case "scanHint": return english ? "Scan to pair for the first time; paired tablets reconnect automatically." : "首次连接可扫码；已安装的平板客户端会自动加入房间。"
    case "discoveredDevices": return english ? "Discovered Devices" : "已发现设备"
    case "recentEmpty": return english ? "No Recent Files" : "暂无历史记录"
    case "sendPDF": return english ? "Send PDF to Tablet…" : "发送 PDF 到平板批注…"
    case "savePDF": return english ? "Save PDF As…" : "另存为 PDF…"
    case "searchMenu": return english ? "Search PDF…" : "搜索 PDF…"
    case "zoomIn": return english ? "Zoom In" : "放大"
    case "zoomOut": return english ? "Zoom Out" : "缩小"
    case "whiteboardOrigin": return english ? "Return to Canvas Origin" : "回到白板原点"
    case "fitWindow": return english ? "Fit to Window" : "适合窗口"
    case "productInitial": return english ? "L" : "L"
    case "penWidthLevels": return english ? "4 levels" : "4 档"
    case "inkFeatureHint": return english ? "PDF annotation · Live whiteboard · Shared workspace" : "PDF 批注 · 无限白板 · 双端同步"
    case "stylusHint": return english ? "Stylus hover · Pressure sensitivity · Live sync" : "触控笔悬停定位 · 压感书写 · 实时同步"
    case "usbLowLatency": return english ? "Low-latency USB connection" : "USB 超低延时连接"
    case "usbAutoHint": return english ? "Keep USB connected; your Mac sets up the connection automatically" : "保持数据线连接，Mac 会自动建立有线通道"
    case "automaticHint": return english ? "Prefer USB; discover your Mac over Wi-Fi when unplugged" : "优先 USB，无数据线时自动发现同 Wi-Fi 下的 Mac"
    case "usbOnlyHint": return english ? "USB mode uses the cable connection" : "USB 模式不使用 Wi-Fi，保持数据线连接即可"
    case "wifiHint": return english ? "Connect your tablet and Mac to the same Wi-Fi network" : "确保平板与 Mac 处于同一 Wi-Fi 网络"
    case "macPDFHint": return english ? "Open LinkDesk and a PDF on your Mac" : "Mac 端需先启动LinkDesk服务并打开 PDF"
    case "automaticHostPlaceholder": return english ? "Discover Mac automatically or enter an address" : "自动发现 Mac（也可手动输入 IP）"
    case "scanMac": return english ? "Scan Mac QR Code" : "扫描 Mac 二维码"
    case "autoConnectMac": return english ? "Connect Automatically" : "自动连接 Mac"
    case "usbConnectMac": return english ? "Connect over USB" : "通过 USB 连接 Mac"
    case "wifiConnectMac": return english ? "Connect over Wi-Fi" : "通过 Wi-Fi 连接 Mac"
    case "returnAccessibility": return english ? "Select an annotated PDF and return it to Mac" : "选择已批注 PDF 并回传到 Mac"
    case "mirrorAccessibility": return english ? "Mirror to Mac over USB" : "通过 USB 投屏到 Mac"
    case "stopMirrorAccessibility": return english ? "Stop mirroring to Mac" : "停止投屏到 Mac"
    case "eraserRange": return english ? "Eraser Range" : "当前擦除范围"
    case "eraserRing": return english ? "Show a gray ring while erasing" : "擦除时显示灰色范围圆环"
    case "secondaryMenu": return english ? "Tool Options" : "工具选项"
    case "highlighterHold": return english ? "Hold for 2 seconds to straighten" : "停顿 2 秒自动拉直"
    case "pressureEraseOn": return english ? "Pressure Erasing: On" : "重按临时擦除 开"
    case "pressureEraseOff": return english ? "Pressure Erasing: Off" : "重按临时擦除 关"
    case "sensitivityLow": return english ? "Low" : "低"
    case "sensitivityMedium": return english ? "Medium" : "中"
    case "sensitivityHigh": return english ? "High" : "高"
    case "confirm": return english ? "Confirm" : "确定"
    case "clearPDFConfirm": return english ? "Clear all PDF annotations? You can undo this." : "确定要清空全部 PDF 批注吗？清空后仍可撤销。"
    case "clearWhiteboardConfirm": return english ? "Clear the whiteboard? You can undo this." : "确定要清空白板吗？清空后仍可撤销。"
    case "mirrorForegroundHint": return english ? "Keep LinkDesk in the foreground to continue mirroring" : "全局投屏保活失败，请保持LinkDesk在前台"
    case "notesFallback": return english ? "Huawei Notes is unavailable; opened with the system PDF app" : "华为笔记不可用，已交给系统 PDF 应用"
    case "mirrorStopped": return english ? "Mirroring stopped" : "已停止投屏"
    case "returnedMac": return english ? "Returned to Mac" : "已回传到 Mac"
    case "notesOpened": return english ? "Opened in Huawei Notes; export and share back to LinkDesk after annotating" : "已在华为笔记打开，批注后请导出并分享到LinkDesk"
    case "returnSaveHint": return english ? "Annotated PDF returned; choose a save location on Mac" : "批注版已回传，请在 Mac 选择保存位置"
    case "fileSizeUnsupported": return english ? "Unsupported file size" : "文件大小不受支持"
    case "fileReadIncomplete": return english ? "Could not read the entire file" : "文件读取不完整"
    case "scanUnavailable": return english ? "Could not start the scanner" : "无法启动系统扫码服务"
    case "scanInvalid": return english ? "No valid LinkDesk pairing QR code found" : "未识别到有效的LinkDesk连接二维码"
    case "pdfDownloading": return english ? "Downloading to tablet…" : "正在下载到平板…"
    case "pdfReturning": return english ? "Returning to Mac…" : "正在回传到 Mac…"
    case "mirrorRunning": return english ? "Mirroring to Mac" : "正在投屏到 Mac"
    case "notesOpening": return english ? "Opening Huawei Notes…" : "正在用华为笔记打开…"
    case "noReturnTask": return english ? "No PDF is waiting to be returned" : "没有等待回传的 PDF 任务"
    case "switchUSBFirst": return english ? "Switch to USB first" : "请先切换到 USB 连接"
    case "waitConnection": return english ? "Waiting for connection" : "等待连接"
    case "lowLatency": return english ? "Low Latency" : "低延迟显示"
    case "versionInfo": return english ? "Version {0} · Protocol v{1}" : "版本 {0} · 协议 v{1}"
    case "sensitivityValue": return english ? "Sensitivity {0}" : "灵敏度 {0}"
    case "mirrorUSBFailure": return english ? "The tablet is not using USB" : "平板当前不是 USB 连接"
    case "mirrorStartFailure": return english ? "Mirroring could not start ({0})" : "投屏启动失败 ({0})"
    case "mirrorStartHint": return english ? "{0}. Check LinkDesk is open on your Mac" : "{0}，请确认 Mac 端LinkDesk已打开"
    case "mirrorReturnHint": return english ? "{0}. Return to LinkDesk to control mirroring" : "{0}，可返回LinkDesk控制投屏"
    case "externalAppError": return english ? "Could not open the external app: {0}" : "打开外部应用失败：{0}"
    case "selectReturnError": return english ? "Could not select the annotated PDF: {0}" : "选择批注文件失败：{0}"
    case "returnError": return english ? "Return failed: {0}" : "回传失败：{0}"
    case "scanRecognized": return english ? "Pairing code {0} found; choosing USB / Wi-Fi" : "已识别配对码 {0}，正在自动选择 USB / Wi-Fi"
    case "annotatedSuffix": return english ? "_annotated.pdf" : "_已批注.pdf"
    case "failureMarker": return english ? "failed" : "失败"
    case "unavailableMarker": return english ? "unable" : "无法"
    case "insufficientMarker": return english ? "insufficient" : "不足"
    case "glyphPen": return english ? "✎" : "✎"
    case "glyphUndo": return english ? "↶" : "↶"
    case "glyphRedo": return english ? "↷" : "↷"
    case "glyphZoomOut": return english ? "−" : "−"
    case "glyphZoomIn": return english ? "+" : "+"
    case "glyphClear": return english ? "⌫" : "⌫"
    case "glyphExpand": return english ? "⌄" : "⌄"
    case "penReady": return english ? "Stylus ready" : "手写笔待命"
    case "tabletCaptureFailure": return english ? "The tablet could not start screen capture" : "平板未能开始录屏"
    case "sendPDFTitle": return english ? "Send PDF to Tablet" : "发送 PDF 到平板批注"
    case "sendToTablet": return english ? "Send to Tablet" : "发送到平板"
    case "sendingPDF": return english ? "Sending to tablet…" : "正在发送到平板…"
    case "sentPDF": return english ? "Sent to tablet; waiting for the PDF app…" : "已发送到平板，等待外部应用打开…"
    case "restorePDFHint": return english ? "Reopen the PDF from Recent Files" : "自动恢复失败，可从“最近文档”重新打开"
    case "restoredInk": return english ? "Previous strokes restored" : "已恢复上次完整笔划"
    case "receivingPDF": return english ? "Receiving annotated PDF…" : "正在接收平板批注版…"
    case "returnPDFFailure": return english ? "Retry returning the annotated PDF on the tablet" : "批注文件回传失败，可在平板重试"
    case "saveReturnPDF": return english ? "Save Annotated PDF" : "保存平板批注版"
    case "saveToMac": return english ? "Save to Mac" : "保存到 Mac"
    case "returnNotSaved": return english ? "Annotated PDF received; not saved yet" : "批注版已接收，但尚未保存"
    case "exportPDFFailure": return english ? "Export failed; the original PDF was preserved" : "导出失败，原 PDF 未被修改"
    case "openFileError": return english ? "Could not open {0}" : "无法打开 {0}"
    case "saveSuccess": return english ? "Saved {0}" : "已保存 {0}"
    case "saveError": return english ? "Save failed: {0}" : "保存失败：{0}"
    case "saveAsSuccess": return english ? "Saved as {0}" : "已另存为 {0}"
    case "exportSuffix": return english ? "-annotated.pdf" : "-批注.pdf"
    case "exportDefaultName": return english ? "annotated.pdf" : "批注.pdf"
    case "penSummary": return english ? "Pressure pen {0}" : "压感笔 {0}"
    case "eraserSummary": return english ? "Eraser {0}" : "橡皮擦 {0}"
    case "liveViewDisabled": return english ? "Live View is disabled" : "系统未启用实况窗"
    case "liveViewEntitlement": return english ? "Live View is not enabled for this app" : "应用尚未获得实况窗权益"
    case "liveViewStartError": return english ? "Live View could not start ({0})" : "实况窗启动失败 ({0})"
    case "liveViewUpdateError": return english ? "Live View could not update ({0})" : "实况窗更新失败 ({0})"
    case "liveViewUnavailable": return english ? "Live View unavailable ({0})" : "实况窗不可用 ({0})"
    case "mirrorIdle": return english ? "Mirroring is off" : "当前未投屏"
    case "returnToApp": return english ? "Return to LinkDesk" : "返回LinkDesk"
    case "mirrorActiveShort": return english ? "Mirroring" : "投屏中"
    case "mirrorIdleShort": return english ? "Not mirroring" : "未投屏"
    case "speakerDescription": return english ? "Play Mac audio through your tablet." : "将 Mac 的声音播放到平板。"
    case "panelDrag": return english ? "Drag display controls" : "拖动控制面板"
    case "panelActualFPS": return english ? "Live frame rate" : "实时帧率"
    case "panelFPSDescription": return english ? "Live {0} fps, target {1} fps" : "实时 {0} 帧/秒，目标 {1} 帧/秒"
    case "panelMicError": return english ? "Microphone error" : "麦克风异常"
    case "panelMicOff": return english ? "Microphone off" : "麦克风已关闭"
    case "panelMicSending": return english ? "Microphone streaming" : "麦克风传输中"
    case "panelMicWaiting": return english ? "Microphone waiting for Mac" : "麦克风等待 Mac"
    case "panelTurnOn": return english ? "Enable" : "开启"
    case "panelTurnOff": return english ? "Disable" : "关闭"
    case "panelExpand": return english ? "Expand display controls" : "展开扩展屏幕控制面板"
    case "panelScreenRefresh": return english ? "Actual display refresh rate {0} Hz" : "屏幕实际刷新率 {0} Hz"
    default: return key
    }
  }
  static var productName: String { value("productName") }
  static var productSubtitle: String { value("productSubtitle") }
  static var workspaces: String { value("workspaces") }
  static var homeTitle: String { value("homeTitle") }
  static var displayTitle: String { value("displayTitle") }
  static var pdfTitle: String { value("pdfTitle") }
  static var whiteboardTitle: String { value("whiteboardTitle") }
  static var mirrorTitle: String { value("mirrorTitle") }
  static var homeSubtitle: String { value("homeSubtitle") }
  static var displaySubtitle: String { value("displaySubtitle") }
  static var pdfSubtitle: String { value("pdfSubtitle") }
  static var whiteboardSubtitle: String { value("whiteboardSubtitle") }
  static var mirrorSubtitle: String { value("mirrorSubtitle") }
  static var heroTitle: String { value("heroTitle") }
  static var heroSubtitle: String { value("heroSubtitle") }
  static var connectionHint: String { value("connectionHint") }
  static var pairingCode: String { value("pairingCode") }
  static var pairingCodeValue: String { value("pairingCodeValue") }
  static var pairingTitle: String { value("pairingTitle") }
  static var pairingSubtitle: String { value("pairingSubtitle") }
  static var connectTablet: String { value("connectTablet") }
  static var connectMac: String { value("connectMac") }
  static var connect: String { value("connect") }
  static var reconnect: String { value("reconnect") }
  static var done: String { value("done") }
  static var cancel: String { value("cancel") }
  static var hide: String { value("hide") }
  static var close: String { value("close") }
  static var backHome: String { value("backHome") }
  static var appearance: String { value("appearance") }
  static var themeAutomatic: String { value("themeAutomatic") }
  static var themeLight: String { value("themeLight") }
  static var themeDark: String { value("themeDark") }
  static var themeHelp: String { value("themeHelp") }
  static var themeAccessibility: String { value("themeAccessibility") }
  static var stateDisconnected: String { value("stateDisconnected") }
  static var stateUSBConnected: String { value("stateUSBConnected") }
  static var stateWaitingForMode: String { value("stateWaitingForMode") }
  static var stateWorking: String { value("stateWorking") }
  static var stateError: String { value("stateError") }
  static var transportWifi: String { value("transportWifi") }
  static var transportUSB: String { value("transportUSB") }
  static var transportWireless: String { value("transportWireless") }
  static var pdfEmptyTitle: String { value("pdfEmptyTitle") }
  static var pdfEmptyDescription: String { value("pdfEmptyDescription") }
  static var openPDF: String { value("openPDF") }
  static var waitPDFTitle: String { value("waitPDFTitle") }
  static var waitPDFDescription: String { value("waitPDFDescription") }
  static var mirrorEmptyTitle: String { value("mirrorEmptyTitle") }
  static var mirrorEmptyDescription: String { value("mirrorEmptyDescription") }
  static var startMirror: String { value("startMirror") }
  static var stopMirror: String { value("stopMirror") }
  static var startDisplay: String { value("startDisplay") }
  static var stopDisplay: String { value("stopDisplay") }
  static var displayEmptyTitle: String { value("displayEmptyTitle") }
  static var displayEmptyDescription: String { value("displayEmptyDescription") }
  static var recentFiles: String { value("recentFiles") }
  static var displaySettings: String { value("displaySettings") }
  static var displayScale: String { value("displayScale") }
  static var displayScaleDescription: String { value("displayScaleDescription") }
  static var frameRate: String { value("frameRate") }
  static var frameRateDescription: String { value("frameRateDescription") }
  static var frameRateValue: String { value("frameRateValue") }
  static var arrangeDisplays: String { value("arrangeDisplays") }
  static var testDisplay: String { value("testDisplay") }
  static var audioSettings: String { value("audioSettings") }
  static var tabletSpeaker: String { value("tabletSpeaker") }
  static var useTablet: String { value("useTablet") }
  static var restoreMac: String { value("restoreMac") }
  static var tabletMicrophone: String { value("tabletMicrophone") }
  static var microphoneDescription: String { value("microphoneDescription") }
  static var audioDelay: String { value("audioDelay") }
  static var audioDelayDescription: String { value("audioDelayDescription") }
  static var milliseconds: String { value("milliseconds") }
  static var chooseMode: String { value("chooseMode") }
  static var usbHint: String { value("usbHint") }
  static var scanPairing: String { value("scanPairing") }
  static var hostAddress: String { value("hostAddress") }
  static var hostPlaceholder: String { value("hostPlaceholder") }
  static var pairingPlaceholder: String { value("pairingPlaceholder") }
  static var invalidPairing: String { value("invalidPairing") }
  static var genericError: String { value("genericError") }
  static var connectionMethod: String { value("connectionMethod") }
  static var automatic: String { value("automatic") }
  static var usbOnly: String { value("usbOnly") }
  static var wifiOnly: String { value("wifiOnly") }
  static var inkTools: String { value("inkTools") }
  static var collapseTools: String { value("collapseTools") }
  static var expandTools: String { value("expandTools") }
  static var returnPDF: String { value("returnPDF") }
  static var searchPDF: String { value("searchPDF") }
  static var searchPlaceholder: String { value("searchPlaceholder") }
  static var noResults: String { value("noResults") }
  static var previousMatch: String { value("previousMatch") }
  static var nextMatch: String { value("nextMatch") }
  static var closeSearch: String { value("closeSearch") }
  static var pen: String { value("pen") }
  static var eraser: String { value("eraser") }
  static var highlighter: String { value("highlighter") }
  static var undo: String { value("undo") }
  static var redo: String { value("redo") }
  static var clearAnnotations: String { value("clearAnnotations") }
  static var clearWhiteboard: String { value("clearWhiteboard") }
  static var penWidth: String { value("penWidth") }
  static var penColor: String { value("penColor") }
  static var eraserSettings: String { value("eraserSettings") }
  static var opacity: String { value("opacity") }
  static var width: String { value("width") }
  static var pixelValue: String { value("pixelValue") }
  static var percentValue: String { value("percentValue") }
  static var macAndTablet: String { value("macAndTablet") }
  static var navigation: String { value("navigation") }
  static var connectionStatus: String { value("connectionStatus") }
  static var stop: String { value("stop") }
  static var allowMicrophone: String { value("allowMicrophone") }
  static var disableMicrophone: String { value("disableMicrophone") }
  static var microphoneOff: String { value("microphoneOff") }
  static var microphoneSending: String { value("microphoneSending") }
  static var microphoneMacHint: String { value("microphoneMacHint") }
  static var microphoneDenied: String { value("microphoneDenied") }
  static var microphoneError: String { value("microphoneError") }
  static var microphoneForeground: String { value("microphoneForeground") }
  static var lowLatencyOn: String { value("lowLatencyOn") }
  static var lowLatencyOff: String { value("lowLatencyOff") }
  static var receiverHint: String { value("receiverHint") }
  static var capturePermissionHint: String { value("capturePermissionHint") }
  static var macNotResponding: String { value("macNotResponding") }
  static var usbChannelHint: String { value("usbChannelHint") }
  static var connectingDisplay: String { value("connectingDisplay") }
  static var diagnosticCode: String { value("diagnosticCode") }
  static var receiverMetrics: String { value("receiverMetrics") }
  static var receiverProcessing: String { value("receiverProcessing") }
  static var receiverStatistics: String { value("receiverStatistics") }
  static var audioPlaying: String { value("audioPlaying") }
  static var audioSelectHint: String { value("audioSelectHint") }
  static var scaleLarger: String { value("scaleLarger") }
  static var scaleLarge: String { value("scaleLarge") }
  static var scaleDefault: String { value("scaleDefault") }
  static var scaleMore: String { value("scaleMore") }
  static var scaleMost: String { value("scaleMost") }
  static var roundTripTitle: String { value("roundTripTitle") }
  static var roundTripDescription: String { value("roundTripDescription") }
  static var sendToNotes: String { value("sendToNotes") }
  static var searchHelp: String { value("searchHelp") }
  static var searchUnavailable: String { value("searchUnavailable") }
  static var modePicker: String { value("modePicker") }
  static var modePickerHelp: String { value("modePickerHelp") }
  static var cancelTransfer: String { value("cancelTransfer") }
  static var retryTransfer: String { value("retryTransfer") }
  static var switching: String { value("switching") }
  static var connected: String { value("connected") }
  static var chooseConnection: String { value("chooseConnection") }
  static var scanHint: String { value("scanHint") }
  static var discoveredDevices: String { value("discoveredDevices") }
  static var recentEmpty: String { value("recentEmpty") }
  static var sendPDF: String { value("sendPDF") }
  static var savePDF: String { value("savePDF") }
  static var searchMenu: String { value("searchMenu") }
  static var zoomIn: String { value("zoomIn") }
  static var zoomOut: String { value("zoomOut") }
  static var whiteboardOrigin: String { value("whiteboardOrigin") }
  static var fitWindow: String { value("fitWindow") }
  static var productInitial: String { value("productInitial") }
  static var penWidthLevels: String { value("penWidthLevels") }
  static var inkFeatureHint: String { value("inkFeatureHint") }
  static var stylusHint: String { value("stylusHint") }
  static var usbLowLatency: String { value("usbLowLatency") }
  static var usbAutoHint: String { value("usbAutoHint") }
  static var automaticHint: String { value("automaticHint") }
  static var usbOnlyHint: String { value("usbOnlyHint") }
  static var wifiHint: String { value("wifiHint") }
  static var macPDFHint: String { value("macPDFHint") }
  static var automaticHostPlaceholder: String { value("automaticHostPlaceholder") }
  static var scanMac: String { value("scanMac") }
  static var autoConnectMac: String { value("autoConnectMac") }
  static var usbConnectMac: String { value("usbConnectMac") }
  static var wifiConnectMac: String { value("wifiConnectMac") }
  static var returnAccessibility: String { value("returnAccessibility") }
  static var mirrorAccessibility: String { value("mirrorAccessibility") }
  static var stopMirrorAccessibility: String { value("stopMirrorAccessibility") }
  static var eraserRange: String { value("eraserRange") }
  static var eraserRing: String { value("eraserRing") }
  static var secondaryMenu: String { value("secondaryMenu") }
  static var highlighterHold: String { value("highlighterHold") }
  static var pressureEraseOn: String { value("pressureEraseOn") }
  static var pressureEraseOff: String { value("pressureEraseOff") }
  static var sensitivityLow: String { value("sensitivityLow") }
  static var sensitivityMedium: String { value("sensitivityMedium") }
  static var sensitivityHigh: String { value("sensitivityHigh") }
  static var confirm: String { value("confirm") }
  static var clearPDFConfirm: String { value("clearPDFConfirm") }
  static var clearWhiteboardConfirm: String { value("clearWhiteboardConfirm") }
  static var mirrorForegroundHint: String { value("mirrorForegroundHint") }
  static var notesFallback: String { value("notesFallback") }
  static var mirrorStopped: String { value("mirrorStopped") }
  static var returnedMac: String { value("returnedMac") }
  static var notesOpened: String { value("notesOpened") }
  static var returnSaveHint: String { value("returnSaveHint") }
  static var fileSizeUnsupported: String { value("fileSizeUnsupported") }
  static var fileReadIncomplete: String { value("fileReadIncomplete") }
  static var scanUnavailable: String { value("scanUnavailable") }
  static var scanInvalid: String { value("scanInvalid") }
  static var pdfDownloading: String { value("pdfDownloading") }
  static var pdfReturning: String { value("pdfReturning") }
  static var mirrorRunning: String { value("mirrorRunning") }
  static var notesOpening: String { value("notesOpening") }
  static var noReturnTask: String { value("noReturnTask") }
  static var switchUSBFirst: String { value("switchUSBFirst") }
  static var waitConnection: String { value("waitConnection") }
  static var lowLatency: String { value("lowLatency") }
  static var versionInfo: String { value("versionInfo") }
  static var sensitivityValue: String { value("sensitivityValue") }
  static var mirrorUSBFailure: String { value("mirrorUSBFailure") }
  static var mirrorStartFailure: String { value("mirrorStartFailure") }
  static var mirrorStartHint: String { value("mirrorStartHint") }
  static var mirrorReturnHint: String { value("mirrorReturnHint") }
  static var externalAppError: String { value("externalAppError") }
  static var selectReturnError: String { value("selectReturnError") }
  static var returnError: String { value("returnError") }
  static var scanRecognized: String { value("scanRecognized") }
  static var annotatedSuffix: String { value("annotatedSuffix") }
  static var failureMarker: String { value("failureMarker") }
  static var unavailableMarker: String { value("unavailableMarker") }
  static var insufficientMarker: String { value("insufficientMarker") }
  static var glyphPen: String { value("glyphPen") }
  static var glyphUndo: String { value("glyphUndo") }
  static var glyphRedo: String { value("glyphRedo") }
  static var glyphZoomOut: String { value("glyphZoomOut") }
  static var glyphZoomIn: String { value("glyphZoomIn") }
  static var glyphClear: String { value("glyphClear") }
  static var glyphExpand: String { value("glyphExpand") }
  static var penReady: String { value("penReady") }
  static var tabletCaptureFailure: String { value("tabletCaptureFailure") }
  static var sendPDFTitle: String { value("sendPDFTitle") }
  static var sendToTablet: String { value("sendToTablet") }
  static var sendingPDF: String { value("sendingPDF") }
  static var sentPDF: String { value("sentPDF") }
  static var restorePDFHint: String { value("restorePDFHint") }
  static var restoredInk: String { value("restoredInk") }
  static var receivingPDF: String { value("receivingPDF") }
  static var returnPDFFailure: String { value("returnPDFFailure") }
  static var saveReturnPDF: String { value("saveReturnPDF") }
  static var saveToMac: String { value("saveToMac") }
  static var returnNotSaved: String { value("returnNotSaved") }
  static var exportPDFFailure: String { value("exportPDFFailure") }
  static var openFileError: String { value("openFileError") }
  static var saveSuccess: String { value("saveSuccess") }
  static var saveError: String { value("saveError") }
  static var saveAsSuccess: String { value("saveAsSuccess") }
  static var exportSuffix: String { value("exportSuffix") }
  static var exportDefaultName: String { value("exportDefaultName") }
  static var penSummary: String { value("penSummary") }
  static var eraserSummary: String { value("eraserSummary") }
  static var liveViewDisabled: String { value("liveViewDisabled") }
  static var liveViewEntitlement: String { value("liveViewEntitlement") }
  static var liveViewStartError: String { value("liveViewStartError") }
  static var liveViewUpdateError: String { value("liveViewUpdateError") }
  static var liveViewUnavailable: String { value("liveViewUnavailable") }
  static var mirrorIdle: String { value("mirrorIdle") }
  static var returnToApp: String { value("returnToApp") }
  static var mirrorActiveShort: String { value("mirrorActiveShort") }
  static var mirrorIdleShort: String { value("mirrorIdleShort") }
  static var speakerDescription: String { value("speakerDescription") }
  static var panelDrag: String { value("panelDrag") }
  static var panelActualFPS: String { value("panelActualFPS") }
  static var panelFPSDescription: String { value("panelFPSDescription") }
  static var panelMicError: String { value("panelMicError") }
  static var panelMicOff: String { value("panelMicOff") }
  static var panelMicSending: String { value("panelMicSending") }
  static var panelMicWaiting: String { value("panelMicWaiting") }
  static var panelTurnOn: String { value("panelTurnOn") }
  static var panelTurnOff: String { value("panelTurnOff") }
  static var panelExpand: String { value("panelExpand") }
  static var panelScreenRefresh: String { value("panelScreenRefresh") }
}

enum ConnectionState: String, CaseIterable {
  case disconnected, usbConnected, waitingForMode, working, error
  var title: String { switch self {
    case .disconnected: L10n.stateDisconnected
    case .usbConnected: L10n.stateUSBConnected
    case .waitingForMode: L10n.stateWaitingForMode
    case .working: L10n.stateWorking
    case .error: L10n.stateError
  } }
  var color: Color { switch self {
    case .disconnected: DT.tertiary
    case .usbConnected: DT.accent
    case .waitingForMode: DT.warning
    case .working: DT.success
    case .error: DT.error
  } }
}
