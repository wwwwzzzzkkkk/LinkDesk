import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { liveViewManager } from '@kit.LiveViewKit';

const LIVE_VIEW_ID: number = 32120;
const LIVE_VIEW_EVENT: string = 'QUEUE';

export class RoundTripLiveViewController {
  private static active: boolean = false;
  private static sequence: number = 0;
  private static documentName: string = 'PDF 批注';
  private static mirroring: boolean = false;
  private static failure: string = '';

  static async show(documentName: string, mirroring: boolean): Promise<boolean> {
    RoundTripLiveViewController.documentName = RoundTripLiveViewController.shortName(documentName);
    RoundTripLiveViewController.mirroring = mirroring;
    RoundTripLiveViewController.failure = '';
    if (RoundTripLiveViewController.active) {
      return RoundTripLiveViewController.update(documentName, mirroring);
    }
    try {
      const enabled = await liveViewManager.isLiveViewEnabled();
      if (!enabled) {
        RoundTripLiveViewController.failure = '系统未启用实况窗';
        return false;
      }
      RoundTripLiveViewController.sequence = 0;
      const result = await liveViewManager.startLiveView(
        await RoundTripLiveViewController.makeLiveView(RoundTripLiveViewController.sequence)
      );
      if (result.resultCode !== 0) {
        RoundTripLiveViewController.failure = `实况窗启动失败 (${result.resultCode})`;
        return false;
      }
      RoundTripLiveViewController.active = true;
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code === 1003500006) {
        try {
          const existing = await liveViewManager.getActiveLiveView(LIVE_VIEW_ID);
          RoundTripLiveViewController.sequence = existing.sequence ?? 0;
          RoundTripLiveViewController.active = true;
          return RoundTripLiveViewController.update(documentName, mirroring);
        } catch (_) {}
      }
      RoundTripLiveViewController.failure = RoundTripLiveViewController.describeFailure(failure);
      console.error(`Failed to start round-trip live view: ${failure.code} ${failure.message}`);
      return false;
    }
  }

  static async update(documentName: string, mirroring: boolean): Promise<boolean> {
    RoundTripLiveViewController.documentName = RoundTripLiveViewController.shortName(documentName);
    RoundTripLiveViewController.mirroring = mirroring;
    if (!RoundTripLiveViewController.active) return false;
    RoundTripLiveViewController.failure = '';
    RoundTripLiveViewController.sequence += 1;
    try {
      const result = await liveViewManager.updateLiveView(
        await RoundTripLiveViewController.makeLiveView(RoundTripLiveViewController.sequence)
      );
      if (result.resultCode !== 0) {
        RoundTripLiveViewController.failure = `实况窗更新失败 (${result.resultCode})`;
        return false;
      }
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code === 1003500009 || failure.code === 1003500010) {
        RoundTripLiveViewController.active = false;
      }
      RoundTripLiveViewController.failure = RoundTripLiveViewController.describeFailure(failure);
      console.error(`Failed to update round-trip live view: ${failure.code} ${failure.message}`);
      return false;
    }
  }

  static async stop(): Promise<void> {
    if (!RoundTripLiveViewController.active) return;
    RoundTripLiveViewController.sequence += 1;
    try {
      await liveViewManager.stopLiveView(
        await RoundTripLiveViewController.makeLiveView(RoundTripLiveViewController.sequence)
      );
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code !== 1003500009 && failure.code !== 1003500010) {
        console.error(`Failed to stop round-trip live view: ${failure.code} ${failure.message}`);
      }
    }
    RoundTripLiveViewController.active = false;
  }

  static lastFailure(): string {
    return RoundTripLiveViewController.failure;
  }

  private static async makeLiveView(sequence: number): Promise<liveViewManager.LiveView> {
    const mirrorAction = RoundTripLiveViewController.mirroring ? 'stopMirror' : 'startMirror';
    const mirrorAgent = await RoundTripLiveViewController.makeAgent(mirrorAction,
      RoundTripLiveViewController.mirroring ? 32122 : 32121);
    const openAgent = await RoundTripLiveViewController.makeAgent('openInkBridge', 32123);
    const mirrorStatus = RoundTripLiveViewController.mirroring ? '正在投屏到 Mac' : '当前未投屏';
    const layout: liveViewManager.ProgressLayout = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
      progress: RoundTripLiveViewController.mirroring ? 100 : 0,
      color: '#FF317AF7',
      backgroundColor: '#26317AF7',
      indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_UNDISPLAYED,
      lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE,
      nodeIcons: ['inkbridge_liveview_start.svg', 'inkbridge_liveview_finish.svg'],
      serviceButtons: [
        {
          name: RoundTripLiveViewController.mirroring ? '停止投屏' : '开始投屏',
          clickAction: mirrorAgent
        },
        {
          name: '返回LinkDesk',
          clickAction: openAgent
        }
      ],
      isServiceButtonsDisplayed: true
    };
    return {
      id: LIVE_VIEW_ID,
      event: LIVE_VIEW_EVENT,
      sequence: sequence,
      isMute: true,
      liveViewData: {
        primary: {
          title: 'LinkDesk',
          content: [
            { text: RoundTripLiveViewController.documentName },
            { text: ` · ${mirrorStatus}` }
          ],
          keepTime: 0,
          clickAction: openAgent,
          extensionData: {
            text: mirrorStatus,
            type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
            clickAction: openAgent
          },
          layoutData: layout
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          icon: 'inkbridge_liveview_capsule.svg',
          backgroundColor: '#FF317AF7',
          title: 'LinkDesk',
          content: RoundTripLiveViewController.mirroring ? '投屏中' : '未投屏'
        }
      }
    };
  }

  private static async makeAgent(action: string, requestCode: number): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.zhekuan.linkdesk',
        abilityName: 'EntryAbility',
        parameters: { liveViewAction: action }
      }],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: requestCode,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

  private static shortName(value: string): string {
    const normalized = value.trim() || 'PDF 批注';
    return normalized.length > 42 ? `${normalized.slice(0, 39)}…` : normalized;
  }

  private static describeFailure(failure: BusinessError): string {
    if (failure.code === 1003500004) return '系统未启用实况窗';
    if (failure.code === 1003500005) return '应用尚未获得实况窗权益';
    return `实况窗不可用 (${failure.code})`;
  }
}
