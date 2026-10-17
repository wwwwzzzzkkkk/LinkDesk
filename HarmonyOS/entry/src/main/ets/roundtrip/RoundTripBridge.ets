export type SharedPDFHandler = (uri: string) => void;
export type LiveViewActionHandler = (action: string) => void;

export class RoundTripBridge {
  private static pendingURI: string = '';
  private static handler: SharedPDFHandler | undefined = undefined;
  private static pendingAction: string = '';
  private static actionHandler: LiveViewActionHandler | undefined = undefined;

  static submit(uri: string): void {
    if (!uri) return;
    if (RoundTripBridge.handler) {
      RoundTripBridge.handler(uri);
    } else {
      RoundTripBridge.pendingURI = uri;
    }
  }

  static register(handler: SharedPDFHandler): void {
    RoundTripBridge.handler = handler;
    if (RoundTripBridge.pendingURI) {
      const uri = RoundTripBridge.pendingURI;
      RoundTripBridge.pendingURI = '';
      handler(uri);
    }
  }

  static unregister(): void {
    RoundTripBridge.handler = undefined;
  }

  static submitLiveViewAction(action: string): void {
    if (!action) return;
    if (RoundTripBridge.actionHandler) {
      RoundTripBridge.actionHandler(action);
    } else {
      RoundTripBridge.pendingAction = action;
    }
  }

  static registerLiveViewAction(handler: LiveViewActionHandler): void {
    RoundTripBridge.actionHandler = handler;
    if (RoundTripBridge.pendingAction) {
      const action = RoundTripBridge.pendingAction;
      RoundTripBridge.pendingAction = '';
      handler(action);
    }
  }

  static unregisterLiveViewAction(): void {
    RoundTripBridge.actionHandler = undefined;
  }
}
