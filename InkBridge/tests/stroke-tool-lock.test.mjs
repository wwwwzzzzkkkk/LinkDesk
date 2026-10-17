import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

function source(relativePath) {
  return readFileSync(new URL(`../${relativePath}`, import.meta.url), "utf8");
}

test("HarmonyOS locks the selected tool for the complete active stroke", () => {
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");
  const handler = arkTS.slice(arkTS.indexOf("private handlePenTouch"));

  assert.match(handler, /event\.type === TouchType\.Down[\s\S]*pendingPenStart = point/);
  assert.match(handler, /TouchType\.Move[\s\S]*pendingPenMaxPressure[\s\S]*commitPendingPenStart\(true\)/);
  assert.match(handler, /commitPendingPenStart\(pressureEraser[\s\S]*beginNativePenStroke/);
  assert.doesNotMatch(handler, /nativePenSwitchToEraser/);
  assert.match(handler, /restorePenAfterStroke[\s\S]*nativeSetEraser\(false\)/);
});

test("highlighter hold timing tolerates pen jitter and keeps one-pass opacity", () => {
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");
  const pdfPad = source("public/pdfpad.js");
  const whiteboard = source("public/whiteboard.js");
  const macCanvas = source("MacPDFAnnotator/Sources/PDFCanvasView.swift");

  assert.match(arkTS, /HIGHLIGHTER_HOLD_DELAY_MS: number = 2000/);
  assert.match(arkTS, /HIGHLIGHTER_HOLD_SLOP: number = 18/);
  assert.match(arkTS, /setTimeout\([\s\S]*HIGHLIGHTER_HOLD_DELAY_MS/);
  assert.match(arkTS, /private enqueueNativePenMove[\s\S]*PEN_BRIDGE_MAX_PENDING_SAMPLES/);
  assert.match(arkTS, /private pumpPenBridge[\s\S]*runJavaScript\(code\)[\s\S]*finishPenBridgeCommand/);
  assert.match(arkTS, /highlighterStraightLocked = true;[\s\S]*enqueuePenScript\('nativePenStraighten\(\)'\)/);
  assert.match(pdfPad, /function drawHighlighterPath[\s\S]*ctx\.beginPath\(\)[\s\S]*ctx\.stroke\(\)/);
  assert.match(whiteboard, /function drawHighlighterStroke[\s\S]*targetContext\.beginPath\(\)[\s\S]*targetContext\.stroke\(\)/);
  assert.match(macCanvas, /if stroke\.isHighlighter[\s\S]*context\.beginPath\(\)[\s\S]*context\.strokePath\(\)/);
  for (const sourceText of [pdfPad, whiteboard]) {
    assert.match(sourceText, /HIGHLIGHTER_HOLD_DELAY_MS = 2000/);
    assert.match(sourceText, /function scheduleNativeHighlighterHold[\s\S]*replaceNativeStrokeWithStraight\(\)/);
    assert.match(sourceText, /StraightLocked[\s\S]*replaceNativeStrokeWithStraight/);
  }
});

test("tablet highlighter incrementally paints a one-pass temporary layer", () => {
  const pdfPad = source("public/pdfpad.js");
  const whiteboard = source("public/whiteboard.js");
  const css = source("public/whiteboard.css");

  assert.match(pdfPad, /liveHighlighters: new Map\(\)/);
  assert.match(pdfPad, /liveInkCanvas\.className = "pdf-live-ink"/);
  assert.match(pdfPad, /function renderLiveHighlighter[\s\S]*appendLiveHighlighter\(message\.strokeId/);
  assert.match(pdfPad, /function appendLiveHighlighter[\s\S]*incrementalPoints[\s\S]*opacity: 1/);
  assert.match(pdfPad, /message\.type === "stroke:end"[\s\S]*drawHighlighterPath\(state\.pages\.get\(pageIndex\), stroke\.points, stroke\)/);
  const pdfLivePath = pdfPad.slice(
    pdfPad.indexOf("function renderLiveHighlighter"),
    pdfPad.indexOf("function applyHighlighterOperation"),
  );
  assert.doesNotMatch(pdfLivePath, /redrawInk/);

  assert.match(whiteboard, /className = "live-highlighter-canvas"/);
  assert.match(whiteboard, /function renderLiveHighlighter[\s\S]*appendLiveHighlighter\(message\.strokeId/);
  assert.match(whiteboard, /function appendLiveHighlighter[\s\S]*incrementalPoints[\s\S]*opacity: 1/);
  assert.match(whiteboard, /message\.type === "stroke:end"[\s\S]*drawHighlighterStroke\(stroke\.points, stroke\)/);
  const boardLivePath = whiteboard.slice(
    whiteboard.indexOf("function renderLiveHighlighter"),
    whiteboard.indexOf("function renderHighlighterOperation"),
  );
  assert.doesNotMatch(boardLivePath, /redraw\(\)/);
  assert.match(css, /\.pdf-live-ink,\.live-highlighter-canvas\{z-index:2;pointer-events:none\}/);
});

test("web fallbacks choose pressure eraser only before a stroke starts", () => {
  const whiteboard = source("public/whiteboard.js");
  const collect = whiteboard.slice(
    whiteboard.indexOf("function collect(event)"),
    whiteboard.indexOf("function acceptsPointer(event)"),
  );
  const pointerDown = whiteboard.slice(
    whiteboard.indexOf('canvas.addEventListener("pointerdown"'),
    whiteboard.indexOf('canvas.addEventListener("pointermove"'),
  );

  assert.doesNotMatch(collect, /shouldUsePressureEraser/);
  assert.match(pointerDown, /shouldUsePressureEraser\(event\)/);
  assert.match(whiteboard, /function switchNativeStrokeToEraser\(\) \{[\s\S]*Mid-stroke switching is intentionally disabled/);

  const pdfPad = source("public/pdfpad.js");
  assert.match(pdfPad, /function switchNativeStrokeToEraser\(\) \{[\s\S]*Mid-stroke switching is intentionally disabled/);
});

test("native pen batches bypass a second animation frame while pointer fallback stays coalesced", () => {
  const whiteboard = source("public/whiteboard.js");
  const whiteboardNativeMove = whiteboard.slice(
    whiteboard.indexOf("function moveNativeStroke(samples)"),
    whiteboard.indexOf("function replaceNativeStrokeWithStraight"),
  );
  const whiteboardPointerCollect = whiteboard.slice(
    whiteboard.indexOf("function collect(event)"),
    whiteboard.indexOf("function acceptsPointer(event)"),
  );
  assert.match(whiteboardNativeMove, /if \(state\.pending\.length\)[\s\S]*flush\(\)/);
  assert.doesNotMatch(whiteboardNativeMove, /scheduleFlush\(\)/);
  assert.match(whiteboardPointerCollect, /scheduleFlush\(\)/);

  const pdfPad = source("public/pdfpad.js");
  const pdfNativeMove = pdfPad.slice(
    pdfPad.indexOf("function moveNativeStroke(samples)"),
    pdfPad.indexOf("function replaceNativeStrokeWithStraight"),
  );
  const pdfPointerMove = pdfPad.slice(
    pdfPad.indexOf("function moveStroke(event, view)"),
    pdfPad.indexOf("function endStroke(event)"),
  );
  assert.match(pdfNativeMove, /if \(state\.nativePendingSamples\.length\) flushNativeSamples\(\)/);
  assert.doesNotMatch(pdfNativeMove, /requestAnimationFrame/);
  assert.match(pdfPointerMove, /event\.getCoalescedEvents/);

  for (const sourceText of [whiteboard, pdfPad]) {
    assert.match(sourceText, /splice\(0, 40\)/);
  }
});

test("relay disables Nagle buffering for latency-sensitive WebSocket frames", () => {
  const relay = source("local-server.mjs");
  const attachStart = relay.indexOf("function attachWebSocket(rawSocket, head)");
  const attach = relay.slice(
    attachStart,
    relay.indexOf("server.listen(", attachStart),
  );
  assert.match(attach, /rawSocket\.setNoDelay\(true\)/);
});

test("Mac and tablet coalesce PDF viewport updates at 120 Hz and stream live pinch previews", () => {
  const macCanvas = source("MacPDFAnnotator/Sources/PDFCanvasView.swift");
  const pdfPad = source("public/pdfpad.js");

  assert.match(macCanvas, /viewportSyncInterval: TimeInterval = 1\.0 \/ 120\.0/);
  assert.match(macCanvas, /if isApplyingRemoteViewport \{ return \}/);
  assert.match(macCanvas, /scaleChanged && !isLiveInteraction/);
  assert.match(pdfPad, /VIEWPORT_SYNC_INTERVAL = 1000 \/ 120/);
  assert.match(pdfPad, /remoteViewportFrame = requestAnimationFrame/);
  assert.match(pdfPad, /scheduleViewport\(\{ allowDuringPinch: true \}\)/);
  assert.match(pdfPad, /function previewRemoteViewport\(viewport\)/);
  assert.match(pdfPad, /Math\.abs\(target\.zoom - state\.renderedZoom\)/);
  assert.match(pdfPad, /scheduleRemotePreviewCommit\(target, generation\)/);
  assert.match(pdfPad, /scroll\.addEventListener\("scroll", handleNativeScrollFallback/);
});

test("PDF ink width is normalized against the tablet's rendered page width", () => {
  const macCanvas = source("MacPDFAnnotator/Sources/PDFCanvasView.swift");
  const relayMessage = source("MacPDFAnnotator/Sources/RelayMessage.swift");
  const pdfPad = source("public/pdfpad.js");

  assert.match(pdfPad, /function widthRatioForView\(view\)[\s\S]*state\.width \/ Math\.max\(1, view\.width\)/);
  assert.equal((pdfPad.match(/widthRatio: widthRatioForView\(view\)/g) || []).length, 2);
  assert.match(relayMessage, /var widthRatio: Double\?/);
  assert.match(macCanvas, /pageLineWidth\(from: message\.width \?\? 4\.5, ratio: message\.widthRatio, on: page\)/);
  assert.match(macCanvas, /if let ratio, ratio\.isFinite, ratio > 0[\s\S]*pageVisualWidth\(page\) \* min\(0\.05, CGFloat\(ratio\)\)/);
  assert.match(macCanvas, /pageVisualWidth\(page\) \* padPixels \/ 1_000/);
});

test("Mac and HarmonyOS expose automatic, Wi-Fi, and USB transport switching", () => {
  const manager = source("MacPDFAnnotator/Sources/USBRelayManager.swift");
  const content = source("MacPDFAnnotator/Sources/ContentView.swift");
  const relay = source("MacPDFAnnotator/Sources/RelayClient.swift");
  const launcher = source("MacPDFAnnotator/Sources/LocalRelayLauncher.swift");
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");
  const pdfPad = source("public/pdfpad.js");
  const whiteboard = source("public/whiteboard.js");

  assert.match(manager, /enum ConnectionPreference[\s\S]*case automatic[\s\S]*case wifi[\s\S]*case usb/);
  assert.match(manager, /case \.automatic: desired = isReady \? \.usb : \.wifi/);
  assert.match(manager, /arguments: \["-t", usb\.id, "rport", "tcp:3210", "tcp:3210"\]/);
  assert.match(content, /Picker\("连接方式", selection: \$usbRelay\.preference\)/);
  assert.match(relay, /func sendTransportRequest[\s\S]*type: "transport:request"/);
  assert.match(launcher, /func startIfNeeded\(\)[\s\S]*launchRelay\(\)[\s\S]*isCheckingExistingService = true/);
  assert.match(arkTS, /data\.type === 'transport'[\s\S]*requestTransportSwitch/);
  assert.match(arkTS, /connectionPreference === 'automatic'[\s\S]*fallbackFromUSB/);
  assert.match(arkTS, /if \(this\.penStrokeActive\)[\s\S]*pendingTransportMode/);
  assert.match(pdfPad, /function notifyNativeTransportRequest/);
  assert.match(pdfPad, /"transport-control-v1"/);
  assert.match(whiteboard, /function notifyNativeTransportRequest/);
  assert.match(whiteboard, /"transport-control-v1"/);
});

test("connection startup discovers the current Mac and repairs USB without a saved IP", () => {
  const manager = source("MacPDFAnnotator/Sources/USBRelayManager.swift");
  const launcher = source("MacPDFAnnotator/Sources/LocalRelayLauncher.swift");
  const app = source("MacPDFAnnotator/Sources/MacPDFAnnotatorApp.swift");
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");

  assert.match(launcher, /type: "_inkbridge\._tcp\."/);
  assert.match(launcher, /name: serviceName[\s\S]*port: 3210/);
  assert.match(launcher, /"room": Data\(room\.utf8\)/);
  assert.match(app, /applicationShouldTerminateAfterLastWindowClosed[\s\S]*false/);
  assert.match(manager, /for usb in connectedUSB[\s\S]*rport[\s\S]*fport", "ls"/);
  assert.match(manager, /while process\.isRunning && Date\(\) < deadline/);

  assert.doesNotMatch(arkTS, /@State host: string = '\d+\.\d+\.\d+\.\d+'/);
  assert.match(arkTS, /createDiscoveryService\(context, '_inkbridge\._tcp'\)/);
  assert.match(arkTS, /resolveLocalService\(context, serviceInfo\)/);
  assert.match(arkTS, /candidates\.push\(\{ host: '127\.0\.0\.1', mode: 'usb' \}\)/);
  assert.match(arkTS, /isRelayReachable[\s\S]*\/config/);
  assert.match(arkTS, /scheduleReconnect\(2200\)/);
});

test("Mac accepts bounded snapshots from long highlighter sessions", () => {
  const relay = source("MacPDFAnnotator/Sources/RelayClient.swift");
  assert.match(relay, /maximumMessageSize = 32 \* 1_024 \* 1_024/);
});

test("Mac native toolbar keeps real mouse hit testing", () => {
  const content = source("MacPDFAnnotator/Sources/ContentView.swift");
  const configurator = content.slice(
    content.indexOf("private final class WindowLiquidGlassConfigurationView"),
    content.indexOf("private struct MacModePicker"),
  );
  assert.match(content, /ToolbarItem\(placement: \.navigation\)/);
  assert.match(configurator, /styleMask\.remove\(\.fullSizeContentView\)/);
  assert.doesNotMatch(configurator, /styleMask\.insert\(\.fullSizeContentView\)/);
  assert.match(configurator, /isMovableByWindowBackground = false/);
});

test("Mac recovery toast morphs from a ball and dismisses automatically", () => {
  const content = source("MacPDFAnnotator/Sources/ContentView.swift");
  const workspace = source("MacPDFAnnotator/Sources/PDFWorkspace.swift");
  assert.match(content, /MacStatusToastMorphModifier\(progress: 0\)/);
  assert.match(content, /scaleEffect\([\s\S]*x: 0\.20 \+ 0\.80 \* value[\s\S]*y: 0\.72 \+ 0\.28 \* value/);
  assert.match(content, /value: workspace\.exportStatus\.isEmpty/);
  assert.match(workspace, /private func showExportStatus[\s\S]*isFailure \? 4\.2 : 2\.8/);
  assert.match(workspace, /restoredDrawing[\s\S]*showExportStatus\("已恢复上次完整笔划"\)/);
});

test("Mac search outside-click monitor is bounded and cleaned up", () => {
  const content = source("MacPDFAnnotator/Sources/ContentView.swift");
  assert.match(content, /SearchOutsideClickMonitor\(onOutsideClick: workspace\.closeSearch\)/);
  assert.doesNotMatch(content, /currentEvent\?\.eventNumber/);
  assert.match(content, /asyncAfter\(deadline: \.now\(\) \+ 0\.25/);
  assert.match(content, /bounds\.insetBy\(dx: -6, dy: -6\)\.contains/);
  assert.match(content, /static func dismantleNSView[\s\S]*stopMonitoring\(\)/);
  assert.match(content, /return event/);
});

test("HarmonyOS uses native Scan Kit pairing and hands the result to automatic transport selection", () => {
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");

  assert.match(arkTS, /import \{ scanBarcode, scanCore \} from '@kit\.ScanKit'/);
  assert.match(arkTS, /startScanForResult\(context, \{[\s\S]*scanCore\.ScanType\.QR_CODE/);
  assert.match(arkTS, /parseScannedPairingLink[\s\S]*\[\?&\]room=/);
  assert.match(arkTS, /port !== '3210'/);
  assert.match(arkTS, /applyScannedPairingLink[\s\S]*connectionPreference = 'automatic'/);
  assert.match(arkTS, /discoveredWirelessHost = pairing\.host/);
  assert.match(arkTS, /candidates\.push\(\{ host: '127\.0\.0\.1', mode: 'usb' \}\)[\s\S]*discoveredWirelessHost/);
});

test("HarmonyOS round trip opens Huawei Notes and prepares native LiveView mirror controls", () => {
  const arkTS = source("../HarmonyOS/entry/src/main/ets/pages/InkWorkspace.ets");
  const ability = source("../HarmonyOS/entry/src/main/ets/entryability/EntryAbility.ets");
  const bridge = source("../HarmonyOS/entry/src/main/ets/roundtrip/RoundTripBridge.ets");
  const liveView = source("../HarmonyOS/entry/src/main/ets/roundtrip/RoundTripLiveViewController.ets");
  const roundTripOpen = arkTS.slice(
    arkTS.indexOf("private async handleRoundTripOpen"),
    arkTS.indexOf("private async selectRoundTripReturnPDF"),
  );

  assert.match(roundTripOpen, /bundleName: 'com\.huawei\.hmos\.hinote'/);
  assert.match(roundTripOpen, /abilityName: 'HiNotePcMainAbility'/);
  assert.match(roundTripOpen, /type: 'com\.adobe\.pdf'/);
  assert.match(roundTripOpen, /type: 'application\/pdf'/);
  assert.ok(
    roundTripOpen.indexOf("RoundTripLiveViewController.show") <
      roundTripOpen.indexOf("context.startAbility(huaweiNotesWant)"),
    "LiveView must be created while InkBridge is still foreground",
  );

  assert.match(liveView, /from '@kit\.LiveViewKit'/);
  assert.match(liveView, /LIVE_VIEW_EVENT: string = 'QUEUE'/);
  assert.match(liveView, /LAYOUT_TYPE_PROGRESS/);
  assert.match(liveView, /nodeIcons: \['inkbridge_liveview_start\.svg', 'inkbridge_liveview_finish\.svg'\]/);
  assert.match(liveView, /serviceButtons:/);
  assert.match(liveView, /'停止投屏' : '开始投屏'/);
  assert.match(liveView, /name: '返回LinkDesk'/);
  assert.match(liveView, /OperationType\.START_ABILITIES/);
  assert.match(liveView, /1003500005[\s\S]*应用尚未获得实况窗权益/);
  assert.match(ability, /want\.parameters\?\.liveViewAction/);
  assert.match(bridge, /submitLiveViewAction[\s\S]*registerLiveViewAction/);
  assert.match(arkTS, /handleLiveViewAction[\s\S]*toggleScreenMirror/);
  assert.match(arkTS, /refreshRoundTripLiveView/);
  assert.match(roundTripOpen, /RoundTripLiveViewController\.stop\(\)/);
});
